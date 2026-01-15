#!/bin/bash

# ==========================================
#  安装 Sing-box (reF1nd 社区版)
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

# --- 安装 Sing-box (reF1nd 社区版) ---
install_singbox() {
    echo -e "${GREEN}开始安装依赖...${PLAIN}"
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget unzip tar nftables git jq
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
    echo -e "${GREEN}请选择 reF1nd 安装版本:${PLAIN}"
    echo -e "1. 安装 Latest Main (稳定版 - 推荐)"
    echo -e "2. 安装 Latest Dev  (开发版 - 含最新特性)"
    echo -e "-----------------------------------------------"
    read -p "请输入选项 [默认1]: " VER_OPT

    # 定义社区版下载基地址 (滚动更新源)
    BASE_URL="https://github.com/enpioodada/sing-box-core/releases/download/sing-box"

    if [[ "$VER_OPT" == "2" ]]; then
        # Dev 版本文件名格式
        URL="${BASE_URL}/sing-box-ref1nd-dev-${DOWNLOAD_ARCH}.tar.gz"
        VERSION_TYPE="reF1nd-Dev"
    else
        # Main 版本文件名格式
        URL="${BASE_URL}/sing-box-ref1nd-main-${DOWNLOAD_ARCH}.tar.gz"
        VERSION_TYPE="reF1nd-Main"
    fi
    
    echo -e "正在下载 ${VERSION_TYPE}: $URL"
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    
    wget -T 30 -t 3 -O "$TMP_DIR/sing-box.tar.gz" "$URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败！请检查网络连接或代理设置。${PLAIN}"
        rm -rf "$TMP_DIR"
        return
    fi
    
    echo -e "正在解压..."
    tar -zxvf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1
    
    # 智能查找二进制文件 (社区版压缩包内不一定有特定文件夹结构)
    # 查找名为 sing-box 的文件，排除压缩包本身
    BINARY_FOUND=$(find "$TMP_DIR" -type f -name "sing-box" | head -n 1)

    if [[ -n "$BINARY_FOUND" ]]; then
        # 停止旧服务以确保覆盖成功
        systemctl stop sing-box 2>/dev/null
        mv -f "$BINARY_FOUND" "$SINGBOX_BIN"
        echo -e "${GREEN}核心文件已更新${PLAIN}"
    else
        echo -e "${RED}解压异常：未找到二进制文件${PLAIN}"
        ls -R "$TMP_DIR" # 调试用，显示解压内容
        rm -rf "$TMP_DIR"
        return
    fi

    chmod +x "$SINGBOX_BIN"
    rm -rf "$TMP_DIR"
    mkdir -p "$CONFIG_DIR" "$TEMPLATE_DIR"

    # 生成 Systemd 文件 (保持原样)
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
    
    # 获取实际安装的版本号显示
    INSTALLED_VER=$($SINGBOX_BIN version 2>/dev/null | grep -oE 'version .*' | head -1)
    echo -e "${GREEN}Sing-box 安装完成！${PLAIN}"
    echo -e "当前版本: ${CYAN}$INSTALLED_VER${PLAIN}"
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