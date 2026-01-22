#!/bin/bash

# =========================================================
#  Sing-box Core Lite (R5C 旁路由适配版)
#  兼容性: 完美适配 menu.sh / sub.sh
#  核心逻辑: 仅代理局域网入站流量 (Prerouting)，本机直连 (No Output)
# =========================================================

# --- 1. 变量定义 (保持与 menu.sh 兼容) ---
WORKDIR="/etc/sbshell"
SINGBOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 2. 辅助函数 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限${PLAIN}" && exit 1
}

# 适配 menu.sh 的状态检查
check_status() {
    if systemctl is-active --quiet sing-box; then
        STATUS="${GREEN}运行中 (TProxy)${PLAIN}"
    else
        STATUS="${RED}未运行${PLAIN}"
    fi

    if [ -f "$SINGBOX_BIN" ]; then
        # 简单粗暴获取版本
        VER_RAW=$($SINGBOX_BIN version 2>/dev/null | grep -oE 'version [0-9.]+' | head -1)
        VER="${VER_RAW:-未知版本}"
    else
        VER="${RED}未安装${PLAIN}"
    fi
    # 输出格式适配 menu.sh
    echo -e "运行状态: ${STATUS}  |  当前版本: ${GREEN}${VER}${PLAIN}  |  模式: ${CYAN}旁路由(本机直连)${PLAIN}"
}

# --- 3. 依赖安装 (极简版) ---
install_deps() {
    echo -e "${YELLOW}正在检查必要依赖 (chrony, nftables)...${PLAIN}"
    # 仅安装核心组件，去除 git/jq/unzip 等冗余
    apt-get update -q
    apt-get install -y curl wget tar nftables iproute2 ca-certificates chrony
    systemctl enable --now chrony >/dev/null 2>&1
    mkdir -p "$WORKDIR" "$CONFIG_DIR"
}

# --- 4. 安装逻辑 (适配 install_official / install_ref1nd) ---
install_logic() {
    REPO="$1" # SagerNet 或 DustinWin
    NAME="$2" # Official 或 Ref1nd
    
    install_deps
    echo -e "${GREEN}正在安装 Sing-box [${NAME}]...${PLAIN}"

    # 获取最新 Release (使用 grep/sed 替代 jq)
    if [ "$NAME" == "Official" ]; then
        API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
        TAG=$(curl -sL "$API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        FILE="sing-box-${TAG#v}-linux-arm64.tar.gz"
        URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/${FILE}"
    else
        # Ref1nd 固定链接逻辑
        URL="https://github.com/DustinWin/proxy-tools/releases/download/sing-box/sing-box-ref1nd-main-linux-armv8.tar.gz"
    fi

    echo -e "下载地址: $URL"
    TMP_DIR=$(mktemp -d)
    wget -q --show-progress -O "$TMP_DIR/sb.tar.gz" "$URL"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败${PLAIN}"; rm -rf "$TMP_DIR"; return
    fi

    tar -zxf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR"
    
    # 查找并移动二进制
    find "$TMP_DIR" -type f -name "sing-box" -exec cp -f {} "$SINGBOX_BIN" \;
    chmod +x "$SINGBOX_BIN"
    
    # 写入 Systemd (极简配置)
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Sing-box TProxy (Lite)
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

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}安装完成 [${NAME}]${PLAIN}"
}

# 导出函数供 menu.sh 调用
install_official() { install_logic "SagerNet" "Official"; }
install_ref1nd()   { install_logic "DustinWin" "Ref1nd"; }

# --- 5. 核心网络逻辑 (Start/Stop) ---

# 定义 NFTables 规则函数 (内部调用)
configure_nftables_lite() {
    # 自动获取物理网卡接口 (用于 NAT)
    OUT_INTF=$(ip route show | grep default | awk '{print $5}' | head -1)
    [[ -z "$OUT_INTF" ]] && OUT_INTF="eth0"
    
    TP_PORT="7895" # 必须对应 config.json

    echo -e "应用规则: ${CYAN}TProxy (LAN Only)${PLAIN} -> 出口: ${GREEN}$OUT_INTF${PLAIN}"

    nft flush ruleset
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # 1. 豁免保留地址和广播
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        # 2. 豁免局域网 (避免回环)
        ip daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return

        # 3. 劫持局域网流量 (不包含本机流量，因为 Output 链不存在)
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :$TP_PORT accept
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        
        # 4. 旁路由必须做 Masquerade (源地址伪装)
        oifname "$OUT_INTF" masquerade
    }
}
NFT
}

start_service() {
    echo -e "${YELLOW}正在启动服务 (Lite模式)...${PLAIN}"
    
    # 1. 加载模块 (防患未然)
    modprobe nft_tproxy 2>/dev/null
    modprobe nft_socket 2>/dev/null
    modprobe nf_nat 2>/dev/null

    # 2. 开启转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

    # 3. 设置策略路由 (将标记为1的流量送入本地回路)
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # 4. 应用 NFT 规则
    configure_nftables_lite

    # 5. 启动进程
    systemctl restart sing-box
    
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}启动成功${PLAIN}"
    else
        echo -e "${RED}启动失败，请检查配置${PLAIN}"
        journalctl -u sing-box -n 10 --no-pager
    fi
}

stop_service() {
    systemctl stop sing-box
    # 清理规则
    nft flush ruleset
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    echo -e "${GREEN}服务已停止，网络恢复直连${PLAIN}"
}

restart_service() {
    start_service
}

show_log() {
    journalctl -u sing-box -f -n 50
}

# --- 6. 命令行入口 (兼容 source 调用) ---
# 如果脚本被直接执行，则处理参数；如果被 source，则忽略
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        install_off) install_official ;;
        install_ref) install_ref1nd ;;
        log) show_log ;;
        *) echo "Usage: $0 {start|stop|restart|log|install_off|install_ref}" ;;
    esac
fi