#!/bin/bash

# ==========================================
#  Sing-box 核心函数库 (core.sh)
# ==========================================

SINGBOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
TEMPLATE_DIR="/etc/sbshell/templates"
WORKDIR="/etc/sbshell"

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 1. 获取当前模式显示 (修复菜单报错) ---
get_current_mode_display() {
    if [[ -f "$WORKDIR/.mode" ]]; then
        cat "$WORKDIR/.mode"
    else
        echo "未设置 (默认 TUN)"
    fi
}

# --- 2. 检查运行状态 (修复菜单报错) ---
check_status() {
    if systemctl is-active --quiet sing-box; then
        # 尝试获取版本号
        VER=$($SINGBOX_BIN version 2>/dev/null | head -n 1 | awk '{print $3}')
        echo -e "运行状态: ${GREEN}已启动${PLAIN} (内核版本: ${VER:-未知})"
    else
        echo -e "运行状态: ${RED}未运行${PLAIN}"
    fi
}

# --- 3. 安装 Sing-box (自动判断架构与版本) ---
install_singbox() {
    echo -e "${GREEN}开始安装依赖...${PLAIN}"
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget unzip tar nftables git
    elif command -v apk >/dev/null; then
        apk add curl wget unzip tar nftables git
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|arm64) DOWNLOAD_ARCH="linux-arm64" ;;
        x86_64|amd64)  DOWNLOAD_ARCH="linux-amd64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "${GREEN}正在获取最新正式版...${PLAIN}"
    
    # API 获取
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    # 网页重定向获取 (备用)
    if [[ -z "$TAG" ]]; then
        TAG=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/SagerNet/sing-box/releases/latest | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+")
    fi

    # 手动输入 (备用)
    if [[ -z "$TAG" ]]; then
        echo -e "${RED}无法自动获取版本号。${PLAIN}"
        read -p "请输入版本号 (如 1.11.4): " MANUAL_VER
        [[ -z "$MANUAL_VER" ]] && return
        [[ "$MANUAL_VER" != v* ]] && TAG="v$MANUAL_VER" || TAG="$MANUAL_VER"
    fi

    VERSION=${TAG#v}
    URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VERSION}-${DOWNLOAD_ARCH}.tar.gz"
    
    echo -e "正在下载: $URL"
    wget -T 30 -t 3 -O /tmp/sing-box.tar.gz "$URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败，请检查网络。${PLAIN}"
        return
    fi
    
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp/ >/dev/null 2>&1
    mv /tmp/sing-box*${DOWNLOAD_ARCH}/sing-box $SINGBOX_BIN
    chmod +x $SINGBOX_BIN
    rm -rf /tmp/sing-box*

    mkdir -p $CONFIG_DIR
    mkdir -p $TEMPLATE_DIR

    # 写入 systemd 服务文件
    cat > $SERVICE_FILE <<SYSTEMD
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
SYSTEMD

    systemctl daemon-reload
    systemctl enable sing-box
    echo -e "${GREEN}Sing-box 安装完成！版本: $VERSION${PLAIN}"
}

# --- 4. 启动服务 ---
start_service() {
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    echo -e "正在启动 Sing-box ($MODE 模式)..."
    
    # 只有 TPROXY 模式需要配置防火墙规则
    if [[ "$MODE" == "TPROXY" ]]; then
        configure_nftables_tproxy
    fi

    if systemctl restart sing-box; then
        echo -e "${GREEN}服务启动成功${PLAIN}"
    else
        echo -e "${RED}服务启动失败，请使用选项 5 查看日志${PLAIN}"
    fi
}

stop_service() {
    systemctl stop sing-box
    # 清理 nftables 规则
    if command -v nft >/dev/null; then
        nft flush ruleset 2>/dev/null
    fi
    echo -e "${GREEN}服务已停止${PLAIN}"
}

restart_service() {
    start_service
}

show_log() {
    journalctl -u sing-box -f -n 50
}

# --- 5. 切换模式 ---
switch_mode() {
    echo -e "请选择模式:"
    echo -e "1. TUN 模式 (推荐，兼容性最好)"
    echo -e "2. TProxy 模式 (需配合软路由环境)"
    read -p "选择: " choice
    
    if [[ "$choice" == "1" ]]; then
        echo "TUN" > "$WORKDIR/.mode"
        echo -e "${GREEN}已切换为 TUN 模式。请去菜单项 7 更新配置以应用变更。${PLAIN}"
    elif [[ "$choice" == "2" ]]; then
        echo "TPROXY" > "$WORKDIR/.mode"
        echo -e "${GREEN}已切换为 TProxy 模式。请去菜单项 7 更新配置以应用变更。${PLAIN}"
    fi
}

# --- 6. TProxy 专用防火墙规则 ---
configure_nftables_tproxy() {
    nft flush ruleset
    nft -f - <<NFT
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
NFT
    ip rule add fwmark 1 table 100 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null
    echo -e "${GREEN}NFTables TProxy 规则已应用${PLAIN}"
}