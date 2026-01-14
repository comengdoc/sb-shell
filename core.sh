#!/bin/bash

# ==========================================
#  Sing-box 核心函数库 (最终完美版)
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

# --- 检查运行状态 ---
check_status() {
    if systemctl is-active --quiet sing-box; then
        STATUS="${GREEN}运行中${PLAIN}"
    else
        STATUS="${RED}未运行${PLAIN}"
    fi

    if [ -f "$SINGBOX_BIN" ]; then
        VER=$($SINGBOX_BIN version 2>/dev/null | grep -oE 'version [0-9.]+' | head -1 | awk '{print $2}')
        [ -z "$VER" ] && VER="未知"
    else
        VER="${RED}未安装${PLAIN}"
    fi

    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        AUTOSTART="${GREEN}已开启${PLAIN}"
    else
        AUTOSTART="${RED}未开启${PLAIN}"
    fi

    MODE_RAW=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    if [ "$MODE_RAW" == "TUN" ]; then
         MODE_DISPLAY="${CYAN}TUN 模式${PLAIN}"
    else
         MODE_DISPLAY="${YELLOW}TProxy 模式${PLAIN}"
    fi

    echo -e "运行状态: ${STATUS}  |  当前版本: ${GREEN}${VER}${PLAIN}"
    echo -e "开机自启: ${AUTOSTART}  |  工作模式: ${MODE_DISPLAY}"
}

# --- 安装 Sing-box (含版本选择) ---
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

    echo -e "-----------------------------------------------"
    echo -e "${GREEN}请选择安装版本:${PLAIN}"
    echo -e "1. 自动获取最新正式版 (Latest)"
    echo -e "2. 手动指定版本 (例如 1.9.7, 1.10.1)"
    echo -e "-----------------------------------------------"
    read -p "请输入选项 [默认1]: " VER_OPT

    if [[ "$VER_OPT" == "2" ]]; then
        read -p "请输入版本号 (无需带v，例如 1.8.0): " INPUT_VER
        if [[ -z "$INPUT_VER" ]]; then
            echo -e "${RED}版本号不能为空，已取消安装。${PLAIN}"
            return
        fi
        if [[ "$INPUT_VER" == v* ]]; then
            TAG="$INPUT_VER"
            VERSION="${INPUT_VER#v}"
        else
            TAG="v$INPUT_VER"
            VERSION="$INPUT_VER"
        fi
        echo -e "${GREEN}已选定版本: ${TAG}${PLAIN}"
    else
        echo -e "${GREEN}正在获取最新正式版...${PLAIN}"
        TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ -z "$TAG" ]]; then
            TAG=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/SagerNet/sing-box/releases/latest | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+")
        fi
        if [[ -z "$TAG" ]]; then
            echo -e "${RED}无法自动获取最新版本号，请检查网络。${PLAIN}"
            read -p "请手动输入版本号 (如 1.11.4): " MANUAL_VER
            [[ -z "$MANUAL_VER" ]] && return
            [[ "$MANUAL_VER" != v* ]] && TAG="v$MANUAL_VER" || TAG="$MANUAL_VER"
        fi
        VERSION=${TAG#v}
    fi

    URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VERSION}-${DOWNLOAD_ARCH}.tar.gz"
    
    echo -e "正在下载: $URL"
    wget -T 30 -t 3 -O /tmp/sing-box.tar.gz "$URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败！请检查版本号是否存在或网络连接。${PLAIN}"
        return
    fi
    
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp/ >/dev/null 2>&1
    EXTRACTED_DIR=$(find /tmp -type d -name "sing-box*${DOWNLOAD_ARCH}" | head -n 1)
    if [[ -f "$EXTRACTED_DIR/sing-box" ]]; then
        mv "$EXTRACTED_DIR/sing-box" "$SINGBOX_BIN"
    else
        if [[ -f "/tmp/sing-box" ]]; then mv "/tmp/sing-box" "$SINGBOX_BIN"; else echo -e "${RED}解压异常${PLAIN}"; return; fi
    fi

    chmod +x "$SINGBOX_BIN"
    rm -rf /tmp/sing-box*
    mkdir -p "$CONFIG_DIR" "$TEMPLATE_DIR"

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
    echo -e "${GREEN}Sing-box 安装完成！版本: $VERSION${PLAIN}"
}

start_service() {
    # === 关键修复：开启转发与NAT (局域网设备上网必需) ===
    echo -e "正在配置网络参数..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1
    
    # 获取默认网卡名称
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [ -n "$DEFAULT_IF" ]; then
        # 这里的规则对 TUN 模式下的局域网共享至关重要
        # 只要不是从 TUN 接口出去的流量，都做一次伪装
        iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    fi

    if [ -f "$SINGBOX_BIN" ] && command -v setcap >/dev/null; then
        setcap cap_net_admin,cap_net_bind_service=+ep "$SINGBOX_BIN" 2>/dev/null
    fi

    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    echo -e "正在启动 Sing-box ($MODE 模式)..."
    if [[ "$MODE" == "TPROXY" ]]; then configure_nftables_tproxy; fi
    
    systemctl daemon-reload
    if systemctl restart sing-box; then 
        echo -e "${GREEN}服务启动成功${PLAIN}"
    else 
        echo -e "${RED}服务启动失败${PLAIN}"
        journalctl -u sing-box -n 3 --no-pager
    fi
}

stop_service() {
    systemctl stop sing-box
    # 清理 NAT 规则 (防止规则堆积)
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [ -n "$DEFAULT_IF" ]; then
        iptables -t nat -D POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null
    fi
    if command -v nft >/dev/null; then nft flush ruleset 2>/dev/null; fi
    echo -e "${GREEN}服务已停止${PLAIN}"
}

restart_service() { start_service; }
show_log() { journalctl -u sing-box -f -n 50; }

switch_mode() {
    echo -e "请选择模式: 1. TUN (推荐)  2. TProxy"
    read -p "选择: " choice
    if [[ "$choice" == "1" ]]; then echo "TUN" > "$WORKDIR/.mode"; echo "已切换为 TUN"; fi
    if [[ "$choice" == "2" ]]; then echo "TPROXY" > "$WORKDIR/.mode"; echo "已切换为 TProxy"; fi
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