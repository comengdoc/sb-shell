#!/bin/bash

# ==========================================
#  安装 Sing-box (PuerNya 独家优化版)
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
        # 强制标记为 PuerNya
        VER="${VER_NUM} (PuerNya)"
    else
        VER="${RED}未安装${PLAIN}"
    fi

    MODE_RAW=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    echo -e "运行状态: ${STATUS}  |  当前版本: ${GREEN}${VER}${PLAIN}  |  模式: ${CYAN}${MODE_RAW}${PLAIN}"
}

install_singbox() {
    echo -e "${GREEN}正在准备安装 PuerNya 核心...${PLAIN}"
    
    # 1. 安装依赖
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget tar nftables git jq
    elif command -v apk >/dev/null; then
        apk add curl wget tar nftables git jq
    fi
    
    # 2. 架构判断 (PuerNya 命名规则适配)
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|armv8) 
            ARCH_CODE="linux-arm64" 
            ;;
        x86_64|amd64)  
            ARCH_CODE="linux-amd64" 
            ;;
        *) 
            echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
            return 
            ;;
    esac

    echo -e "${YELLOW}正在获取 PuerNya 最新版本信息...${PLAIN}"
    
    # 获取最新 Tag
    LATEST_TAG=$(curl -sL --retry 3 "https://api.github.com/repos/PuerNya/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$LATEST_TAG" ]]; then
        echo -e "${RED}获取版本失败，尝试使用硬编码备用版本 (v1.10.7)${PLAIN}"
        LATEST_TAG="v1.10.7"
    else
        echo -e "${GREEN}检测到最新版本: ${LATEST_TAG}${PLAIN}"
    fi

    # 构造下载链接 (PuerNya 标准命名: sing-box-linux-amd64.tar.gz)
    DOWNLOAD_URL="https://github.com/PuerNya/sing-box/releases/download/${LATEST_TAG}/sing-box-${ARCH_CODE}.tar.gz"

    echo -e "正在下载: $DOWNLOAD_URL"
    TMP_DIR=$(mktemp -d)
    
    if ! wget -T 60 -t 3 -O "$TMP_DIR/sb.tar.gz" "$DOWNLOAD_URL"; then
        echo -e "${RED}下载失败！请检查网络或 Github 连接。${PLAIN}"
        rm -rf "$TMP_DIR"
        return
    fi
    
    echo "解压中..."
    tar -zxvf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1
    
    # 查找二进制文件 (排除解压出的文件夹结构影响)
    BINARY_FOUND=$(find "$TMP_DIR" -type f -name "sing-box" | head -n 1)

    if [[ -n "$BINARY_FOUND" ]]; then
        systemctl stop sing-box 2>/dev/null
        mv -f "$BINARY_FOUND" "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        echo -e "${GREEN}PuerNya 核心安装成功${PLAIN}"
    else
        echo -e "${RED}解压失败：未找到二进制文件${PLAIN}"
        rm -rf "$TMP_DIR"
        return
    fi

    rm -rf "$TMP_DIR"
    
    # 创建必要目录
    mkdir -p "$CONFIG_DIR" "$TEMPLATE_DIR" "$WORKDIR"
    mkdir -p "$WORKDIR/providers" # 确保 provider 目录存在

    # 写入版本标记
    echo "PuerNya" > "$WORKDIR/.version_tag"

    # 写入 Systemd 服务
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
    echo -e "${GREEN}安装完成! 请运行菜单中的 [7. 更新订阅] 初始化配置。${PLAIN}"
}

start_service() {
    # 开启转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    
    # NAT
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