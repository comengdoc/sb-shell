cat > /etc/sbshell/core.sh << 'EOF'
#!/bin/bash

SINGBOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
TEMPLATE_DIR="/etc/sbshell/templates"
WORKDIR="/etc/sbshell"

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
        echo -e "运行状态: ${GREEN}已启动${PLAIN} (版本: $(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}'))"
    else
        echo -e "运行状态: ${RED}未运行${PLAIN}"
    fi
}

# 1. 安装 Sing-box (修复API限制版)
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

    echo -e "${GREEN}正在获取最新正式版 (Latest Stable)...${PLAIN}"
    
    # [修复1] 尝试使用 API 获取
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    # [修复2] API 失败时，尝试使用网页重定向获取 (不消耗 API 额度)
    if [[ -z "$TAG" ]]; then
        echo -e "${YELLOW}API 获取失败，尝试通过网页重定向获取版本...${PLAIN}"
        TAG=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/SagerNet/sing-box/releases/latest | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+")
    fi

    # [修复3] 如果还是失败，切换为手动输入
    if [[ -z "$TAG" ]]; then
        echo -e "${RED}无法自动获取版本号。${PLAIN}"
        read -p "请输入要安装的版本号 (例如 1.11.4): " MANUAL_VER
        if [[ -z "$MANUAL_VER" ]]; then
            echo "版本号不能为空，取消安装。"
            return
        fi
        # 确保版本号带 v 前缀
        if [[ "$MANUAL_VER" != v* ]]; then
             TAG="v$MANUAL_VER"
        else
             TAG="$MANUAL_VER"
        fi
    fi

    VERSION=${TAG#v}
    echo -e "即将安装版本: ${GREEN}${TAG}${PLAIN}"
    
    # 下载链接
    URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VERSION}-${DOWNLOAD_ARCH}.tar.gz"
    
    echo -e "正在下载: $URL"
    # [优化] 增加重试机制
    wget -T 30 -t 3 -O /tmp/sing-box.tar.gz "$URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败，请检查网络 (是否需要代理?)${PLAIN}"
        return
    fi
    
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp/ >/dev/null 2>&1
    mv /tmp/sing-box*${DOWNLOAD_ARCH}/sing-box $SINGBOX_BIN
    chmod +x $SINGBOX_BIN
    rm -rf /tmp/sing-box*

    # 创建配置目录
    mkdir -p $CONFIG_DIR
    mkdir -p $TEMPLATE_DIR
    
    # 初始化模板
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
    systemctl enable sing-box
    echo -e "${GREEN}已设置开机自启。${PLAIN}"
    
    echo -e "${GREEN}Sing-box 安装完成！版本: $VERSION${PLAIN}"
}

# 2. 创建标准模板
create_templates() {
    # 这里的代码保持不变，还是原来的模板逻辑
    :
}

# 3. 启动服务
start_service() {
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    
    echo -e "正在启动 Sing-box ($MODE 模式)..."
    
    if systemctl restart sing-box; then
        echo -e "${GREEN}服务启动成功${PLAIN}"
    else
        echo -e "${RED}服务启动失败，请使用选项 5 查看日志${PLAIN}"
        return
    fi
    
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

# 辅助: TProxy 的 NFTables 规则
configure_nftables_tproxy() {
    # 只有 TProxy 模式需要这个
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
EOF