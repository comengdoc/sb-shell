#!/bin/bash

# ==========================================
#  安装 Sing-box (针对用户模板 7891 端口优化)
# ==========================================

SINGBOX_BIN="/usr/local/bin/sing-box"
[ ! -f "$SINGBOX_BIN" ] && SINGBOX_BIN="/usr/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
TEMPLATE_DIR="/etc/sbshell/templates"
WORKDIR="/etc/sbshell"

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

check_status() {
    if systemctl is-active --quiet sing-box; then
        STATUS="${GREEN}运行中${PLAIN}"
    else
        STATUS="${RED}未运行${PLAIN}"
    fi

    if [ -f "$SINGBOX_BIN" ]; then
        VER_NUM=$($SINGBOX_BIN version 2>/dev/null | grep -oE 'version [0-9.]+' | head -1 | awk '{print $2}')
        VER="${VER_NUM} (Official)"
    else
        VER="${RED}未安装${PLAIN}"
    fi

    MODE_RAW=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    echo -e "运行状态: ${STATUS}  |  当前版本: ${GREEN}${VER}${PLAIN}  |  模式: ${CYAN}${MODE_RAW}${PLAIN}"
}

install_singbox() {
    echo -e "${GREEN}正在准备安装 Sing-box 官方核心...${PLAIN}"
    
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget tar nftables git jq
    elif command -v apk >/dev/null; then
        apk add curl wget tar nftables git jq
    elif command -v yum >/dev/null; then
        yum install -y curl wget tar nftables git jq
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|armv8) ARCH_CODE="linux-arm64" ;;
        x86_64|amd64)  ARCH_CODE="linux-amd64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "${YELLOW}正在获取最新版本...${PLAIN}"
    LATEST_TAG=$(curl -sL --retry 3 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$LATEST_TAG" ]] && echo -e "${RED}获取版本失败${PLAIN}" && return
    
    VERSION_NO_V=${LATEST_TAG#v}
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${VERSION_NO_V}-${ARCH_CODE}.tar.gz"

    echo -e "正在下载: $DOWNLOAD_URL"
    TMP_DIR=$(mktemp -d)
    wget -T 60 -t 3 -O "$TMP_DIR/sb.tar.gz" "$DOWNLOAD_URL" || { echo -e "${RED}下载失败${PLAIN}"; rm -rf "$TMP_DIR"; return; }
    
    tar -zxvf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1
    BINARY_FOUND=$(find "$TMP_DIR" -type f -name "sing-box" | head -n 1)

    if [[ -n "$BINARY_FOUND" ]]; then
        systemctl stop sing-box 2>/dev/null
        mv -f "$BINARY_FOUND" "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        echo -e "${GREEN}安装成功${PLAIN}"
    else
        echo -e "${RED}未找到二进制文件${PLAIN}"; rm -rf "$TMP_DIR"; return
    fi
    rm -rf "$TMP_DIR"
    
    mkdir -p "$CONFIG_DIR" "$TEMPLATE_DIR" "$WORKDIR" "$WORKDIR/providers" "$WORKDIR/ui"
    echo "Official" > "$WORKDIR/.version_tag"

    # 下载 Dashboard UI (Yacd/Metacubex)
    echo -e "${YELLOW}正在安装 Dashboard UI...${PLAIN}"
    curl -sL -o "$WORKDIR/ui.zip" "https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip"
    unzip -o -q "$WORKDIR/ui.zip" -d "$WORKDIR/"
    mv "$WORKDIR/Yacd-meta-gh-pages"/* "$WORKDIR/ui/" 2>/dev/null
    rm -rf "$WORKDIR/ui.zip" "$WORKDIR/Yacd-meta-gh-pages"

    cat > $SERVICE_FILE <<SYSTEMD
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
Group=root
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
    echo -e "${GREEN}安装完成!${PLAIN}"
}

start_service() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [ -n "$DEFAULT_IF" ]; then
        iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    fi

    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    if [[ "$MODE" == "TPROXY" ]]; then configure_nftables_tproxy; fi
    
    systemctl restart sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then 
        echo -e "${GREEN}服务已启动 ($MODE模式)${PLAIN}"
    else 
        echo -e "${RED}启动失败，请运行 [5] 查看日志${PLAIN}"
        echo -e "${YELLOW}常见原因: 模板中的 'outbounds' 为空，请先运行 [7] 更新订阅。${PLAIN}"
    fi
}

stop_service() {
    systemctl stop sing-box
    nft flush ruleset 2>/dev/null
    echo -e "${GREEN}服务已停止${PLAIN}"
}

restart_service() { start_service; }
show_log() { journalctl -u sing-box -f -n 50; }

switch_mode() {
    echo -e "1. TUN  2. TProxy"
    read -p "选择: " choice
    [[ "$choice" == "1" ]] && echo "TUN" > "$WORKDIR/.mode" && echo "已切换为 TUN"
    [[ "$choice" == "2" ]] && echo "TPROXY" > "$WORKDIR/.mode" && echo "已切换为 TProxy"
}

configure_nftables_tproxy() {
    # 修正：此处端口必须对应模板中的 tproxy-in (7891)
    nft flush ruleset
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255, 192.168.0.0/16, 10.0.0.0/8 } return
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :7891 accept
    }
    chain output {
        type route hook output priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255, 192.168.0.0/16, 10.0.0.0/8 } return
        meta l4proto { tcp, udp } meta mark set 1 accept
    }
}
NFT
    ip rule add fwmark 1 table 100 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null
}