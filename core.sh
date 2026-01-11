#!/bin/bash

SINGBOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
TEMPLATE_DIR="/etc/sbshell/templates"

# 获取当前模式显示
get_current_mode_display() {
    if [[ -f "$WORKDIR/.mode" ]]; then
        cat "$WORKDIR/.mode"
    else
        echo "未设置"
    fi
}

# 检查运行状态
check_status() {
    if systemctl is-active --quiet sing-box; then
        echo -e "运行状态: ${GREEN}已启动${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行${PLAIN}"
    fi
}

# 1. 安装 Sing-box
install_singbox() {
    echo -e "${GREEN}开始安装依赖...${PLAIN}"
    apt-get update && apt-get install -y curl wget unzip tar nftables git
    
    # 架构判断
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|arm64) DOWNLOAD_ARCH="linux-arm64" ;;
        x86_64|amd64)  DOWNLOAD_ARCH="linux-amd64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "${GREEN}下载 Sing-box (Pre-release)...${PLAIN}"
    # 这里使用最新的 Release API 获取
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | grep '"tag_name":' | head -n 1 | awk -F '"' '{print $4}')
    VERSION=${TAG#v}
    URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VERSION}-${DOWNLOAD_ARCH}.tar.gz"
    
    wget -O /tmp/sing-box.tar.gz "$URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败，请检查网络 (是否需要代理?)${PLAIN}"
        return
    fi
    
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp/
    mv /tmp/sing-box-${VERSION}-${DOWNLOAD_ARCH}/sing-box $SINGBOX_BIN
    chmod +x $SINGBOX_BIN
    rm -rf /tmp/sing-box*

    # 创建配置目录
    mkdir -p $CONFIG_DIR
    mkdir -p $TEMPLATE_DIR
    
    # 初始化模板 (如果不存在)
    create_templates

    # 创建 systemd 服务
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SINGBOX_BIN run -c $CONFIG_FILE -D $CONFIG_DIR
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo -e "${GREEN}Sing-box 安装完成！版本: $VERSION${PLAIN}"
}

# 2. 创建标准模板 (修复了旧脚本模板混乱的问题)
create_templates() {
    # TProxy 模板 (透明代理)
    cat > "$TEMPLATE_DIR/tproxy.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "google", "address": "tls://8.8.8.8", "detour": "proxy" },
      { "tag": "local", "address": "223.5.5.5", "detour": "direct" }
    ],
    "rules": [
      { "outbound": "any", "server": "local" }
    ],
    "final": "local"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": 9888,
      "sniff": true,
      "sniff_override_destination": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" },
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "clash_mode": "Direct", "outbound": "direct" },
      { "clash_mode": "Global", "outbound": "proxy" }
    ],
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    # TUN 模板 (虚拟网卡)
    cat > "$TEMPLATE_DIR/tun.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "google", "address": "tls://8.8.8.8", "detour": "proxy" },
      { "tag": "local", "address": "223.5.5.5", "detour": "direct" }
    ],
    "rules": [
      { "outbound": "any", "server": "local" }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "singbox-tun",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "sniff": true
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" },
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" }
    ],
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF
}

# 3. 启动服务 (自动清理和配置 NFTables)
start_service() {
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    
    echo -e "正在启动 Sing-box ($MODE 模式)..."
    
    # 无论什么模式，先启动服务
    if systemctl restart sing-box; then
        echo -e "${GREEN}服务启动成功${PLAIN}"
    else
        echo -e "${RED}服务启动失败，请使用选项 5 查看日志${PLAIN}"
        return
    fi
    
    # 如果是 TProxy 模式，需要加载 NFTables 规则
    if [[ "$MODE" == "TPROXY" ]]; then
        configure_nftables_tproxy
    fi
}

stop_service() {
    systemctl stop sing-box
    nft flush ruleset 2>/dev/null
    echo -e "${GREEN}服务已停止，网络规则已清理${PLAIN}"
}

restart_service() {
    start_service
}

show_log() {
    journalctl -u sing-box -f -n 50
}

switch_mode() {
    echo -e "请选择模式:"
    echo -e "1. TUN 模式 (推荐，兼容性最好)"
    echo -e "2. TProxy 模式 (性能稍好，需Router环境)"
    read -p "选择: " choice
    
    if [[ "$choice" == "1" ]]; then
        echo "TUN" > "$WORKDIR/.mode"
        echo -e "${GREEN}已切换为 TUN 模式，请去菜单项 7 更新/重新生成配置${PLAIN}"
    elif [[ "$choice" == "2" ]]; then
        echo "TPROXY" > "$WORKDIR/.mode"
        echo -e "${GREEN}已切换为 TProxy 模式，请去菜单项 7 更新/重新生成配置${PLAIN}"
    fi
}

# 辅助: TProxy 的 NFTables 规则 (客户端专用)
configure_nftables_tproxy() {
    # 只有 TProxy 模式需要这个，TUN 模式由 sing-box 自身接管
    nft flush ruleset
    nft -f - <<EOF
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        ip daddr 192.168.0.0/16 return
        ip daddr 10.0.0.0/8 return
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :9888 accept
    }
    chain output {
        type route hook output priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        ip daddr 192.168.0.0/16 return
        ip daddr 10.0.0.0/8 return
        meta l4proto { tcp, udp } meta mark set 1 accept
    }
}
EOF
    # 策略路由
    ip rule add fwmark 1 table 100 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null
    echo -e "${GREEN}NFTables TProxy 规则已应用${PLAIN}"
}

uninstall_all() {
    read -p "确定要卸载吗? [y/N]: " confirm
    [[ "$confirm" != "y" ]] && return
    
    stop_service
    systemctl disable sing-box
    rm $SERVICE_FILE
    rm $SINGBOX_BIN
    rm -rf $CONFIG_DIR
    rm -rf $WORKDIR
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成${PLAIN}"
    exit 0
}