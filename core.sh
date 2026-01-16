#!/bin/bash

# ==========================================
#  安装 Sing-box (reF1nd 社区版 / 专家优化)
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
        if [ -f "$WORKDIR/.version_tag" ]; then
            TAG=$(cat "$WORKDIR/.version_tag")
            VER="${VER_NUM} (${TAG})"
        else
            VER="${VER_NUM}"
        fi
    else
        VER="${RED}未安装${PLAIN}"
    fi

    MODE_RAW=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    echo -e "运行状态: ${STATUS}  |  当前版本: ${GREEN}${VER}${PLAIN}  |  模式: ${CYAN}${MODE_RAW}${PLAIN}"
}

install_singbox() {
    echo -e "${GREEN}开始安装依赖...${PLAIN}"
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget unzip tar nftables git jq
    elif command -v apk >/dev/null; then
        apk add curl wget unzip tar nftables git jq
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|armv8) DOWNLOAD_ARCH="linux-armv8" ;;
        x86_64|amd64)  DOWNLOAD_ARCH="linux-amd64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "-----------------------------------------------"
    echo -e "${GREEN}请选择 reF1nd 安装版本:${PLAIN}"
    echo -e "1. Latest Main (稳定推荐 - 兼容性佳)"
    echo -e "2. Latest Dev  (激进更新 - 新特性)"
    echo -e "-----------------------------------------------"
    read -p "请输入选项 [默认1]: " VER_OPT

    BASE_URL="https://github.com/enpioodada/sing-box-core/releases/download/sing-box"

    if [[ "$VER_OPT" == "2" ]]; then
        URL="${BASE_URL}/sing-box-ref1nd-dev-${DOWNLOAD_ARCH}.tar.gz"
        VERSION_TYPE="reF1nd-Dev"
    else
        URL="${BASE_URL}/sing-box-ref1nd-main-${DOWNLOAD_ARCH}.tar.gz"
        VERSION_TYPE="reF1nd-Main"
    fi
    
    echo -e "正在下载: $URL"
    TMP_DIR=$(mktemp -d)
    wget -T 30 -t 3 -O "$TMP_DIR/sing-box.tar.gz" "$URL"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败！${PLAIN}"
        rm -rf "$TMP_DIR"
        return
    fi
    
    tar -zxvf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1
    BINARY_FOUND=$(find "$TMP_DIR" -type f -name "sing-box" | head -n 1)

    if [[ -n "$BINARY_FOUND" ]]; then
        systemctl stop sing-box 2>/dev/null
        mv -f "$BINARY_FOUND" "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        echo -e "${GREEN}核心安装成功${PLAIN}"
    else
        echo -e "${RED}解压失败：未找到二进制文件${PLAIN}"
        rm -rf "$TMP_DIR"
        return
    fi

    rm -rf "$TMP_DIR"
    mkdir -p "$CONFIG_DIR" "$TEMPLATE_DIR" "$WORKDIR"
    
    # 写入版本标记，供 sub.sh 识别
    echo "$VERSION_TYPE" > "$WORKDIR/.version_tag"

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
    # 开启 IP 转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    
    # NAT 规则 (关键)
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [ -n "$DEFAULT_IF" ]; then
        iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    fi

    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    if [[ "$MODE" == "TPROXY" ]]; then configure_nftables_tproxy; fi
    
    systemctl restart sing-box
    if systemctl is-active --quiet sing-box; then 
        echo -e "${GREEN}服务已启动 ($MODE模式)${PLAIN}"
    else 
        echo -e "${RED}启动失败，请检查日志 (选项5)${PLAIN}"
    fi
}

stop_service() {
    systemctl stop sing-box
    # 清理 NAT
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    [ -n "$DEFAULT_IF" ] && iptables -t nat -D POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null
    nft flush ruleset 2>/dev/null
    echo -e "${GREEN}服务已停止${PLAIN}"
}

restart_service() { start_service; }
show_log() { journalctl -u sing-box -f -n 50; }

switch_mode() {
    echo -e "1. TUN (推荐)  2. TProxy"
    read -p "选择: " choice
    [[ "$choice" == "1" ]] && echo "TUN" > "$WORKDIR/.mode" && echo "已切换为 TUN"
    [[ "$choice" == "2" ]] && echo "TPROXY" > "$WORKDIR/.mode" && echo "已切换为 TProxy"
}

configure_nftables_tproxy() {
    nft flush ruleset
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255, 192.168.0.0/16, 10.0.0.0/8 } return
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :7895 accept
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