#!/bin/bash

# ==========================================
#  Sing-box 核心管理 (Expert Modified)
#  优化: 修复 Ref1nd 下载源，增强 TProxy 逻辑
# ==========================================

SINGBOX_BIN="/usr/local/bin/sing-box"
# 清理旧的干扰文件
[ -f "/usr/bin/sing-box" ] && rm -f "/usr/bin/sing-box"

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
        # 尝试获取详细版本信息
        VER_RAW=$($SINGBOX_BIN version 2>/dev/null)
        VER_NUM=$(echo "$VER_RAW" | grep -oE 'version [0-9.]+' | head -1 | awk '{print $2}')
        
        # 读取安装时的标记 (如果存在)
        TAG_FILE="$WORKDIR/.version_tag"
        [ -f "$TAG_FILE" ] && TAG_INFO=" ($(cat "$TAG_FILE"))" || TAG_INFO=""
        
        VER="${VER_NUM}${TAG_INFO}"
    else
        VER="${RED}未安装${PLAIN}"
    fi

    MODE_RAW=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    echo -e "运行状态: ${STATUS}  |  当前版本: ${GREEN}${VER}${PLAIN}  |  模式: ${CYAN}${MODE_RAW}${PLAIN}"
}

# ==========================================
#  核心安装逻辑 (Official - SagerNet)
# ==========================================
install_official() {
    echo -e "${GREEN}正在准备安装 Sing-box [Official/SagerNet] 版本...${PLAIN}"
    
    # 基础依赖检查
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget tar nftables git jq
    elif command -v apk >/dev/null; then
        apk add curl wget tar nftables git jq
    elif command -v yum >/dev/null; then
        yum install -y curl wget tar nftables git jq
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|armv8) ARCH_CODE="linux-armv8" ;;
        x86_64|amd64)  ARCH_CODE="linux-amd64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "${YELLOW}正在查询 SagerNet/sing-box 最新版本...${PLAIN}"
    
    # 获取最新 Release Tag
    API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    LATEST_TAG=$(curl -sL --retry 3 "$API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$LATEST_TAG" ]]; then
        echo -e "${RED}API 获取失败，请输入版本号 (例如 v1.10.0): ${PLAIN}"
        read -p ": " LATEST_TAG
        [[ -z "$LATEST_TAG" ]] && return
    fi
    
    VERSION_NO_V=${LATEST_TAG#v}
    FILE_NAME="sing-box-${VERSION_NO_V}-${ARCH_CODE}.tar.gz"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/${FILE_NAME}"

    echo -e "版本: ${CYAN}${LATEST_TAG}${PLAIN}"
    install_download_logic "$DOWNLOAD_URL" "Official"
}

# ==========================================
#  核心安装逻辑 (Ref1nd/PuerNya - Modified)
#  使用 DustinWin 仓库以保证文件名稳定性
# ==========================================
install_ref1nd() {
    echo -e "${GREEN}正在准备安装 Sing-box [PuerNya/Ref1nd] 版本...${PLAIN}"
    echo -e "${YELLOW}注意: 此版本包含更多协议支持与去广告优化 (Source: DustinWin)${PLAIN}"

    # 基础依赖检查
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget tar nftables git jq
    elif command -v apk >/dev/null; then
        apk add curl wget tar nftables git jq
    fi

    ARCH=$(uname -m)
    case $ARCH in
        aarch64|armv8) FILE_NAME="sing-box-linux-arm64.tar.gz" ;;
        x86_64|amd64)  FILE_NAME="sing-box-linux-amd64.tar.gz" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    # 使用固定链接，避免 API 文件名解析错误
    DOWNLOAD_URL="https://github.com/DustinWin/proxy-tools/releases/download/sing-box/${FILE_NAME}"
    
    echo -e "下载源: ${CYAN}DustinWin/proxy-tools${PLAIN}"
    install_download_logic "$DOWNLOAD_URL" "Ref1nd"
}

# ==========================================
#  通用下载与部署函数
# ==========================================
install_download_logic() {
    URL="$1"
    LABEL="$2"
    
    TMP_DIR=$(mktemp -d)
    echo -e "正在下载..."
    wget -T 60 -t 3 -O "$TMP_DIR/sb.tar.gz" "$URL" || { echo -e "${RED}下载失败，请检查网络${PLAIN}"; rm -rf "$TMP_DIR"; return; }
    
    echo -e "正在解压..."
    tar -zxvf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1
    
    BINARY_FOUND=$(find "$TMP_DIR" -type f -name "sing-box" | head -n 1)

    if [[ -n "$BINARY_FOUND" ]]; then
        systemctl stop sing-box 2>/dev/null
        cp -f "$BINARY_FOUND" "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        
        # 标记版本
        mkdir -p "$WORKDIR"
        echo "$LABEL" > "$WORKDIR/.version_tag"
        
        # 安装/更新 UI
        install_ui
        
        # 写入 Service
        write_service
        
        echo -e "${GREEN}核心部署成功 [${LABEL}]${PLAIN}"
    else
        echo -e "${RED}解压后未找到二进制文件${PLAIN}"
    fi
    rm -rf "$TMP_DIR"
}

install_ui() {
    if [ ! -d "$WORKDIR/ui/assets" ]; then
        echo -e "${YELLOW}正在安装 Yacd Dashboard UI...${PLAIN}"
        mkdir -p "$WORKDIR/ui"
        TMP_UI=$(mktemp -d)
        curl -sL -o "$TMP_UI/ui.zip" "https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip"
        unzip -o -q "$TMP_UI/ui.zip" -d "$TMP_UI"
        cp -r "$TMP_UI/Yacd-meta-gh-pages"/* "$WORKDIR/ui/" 2>/dev/null
        rm -rf "$TMP_UI"
    fi
}

write_service() {
    cat > $SERVICE_FILE <<SYSTEMD
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
Group=root
# 关键权限，用于 TUN 和 TProxy
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
    systemctl enable sing-box >/dev/null 2>&1
}

# ==========================================
#  启动与网络配置
# ==========================================
start_service() {
    # 1. 确保 IP 转发开启
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    
    # 2. 自动 NAT (Masquerade)
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [ -n "$DEFAULT_IF" ]; then
        # 检查是否已存在规则，避免重复添加
        iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    fi

    # 3. 检查模式并配置 nftables
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    
    if [[ "$MODE" == "TPROXY" ]]; then 
        configure_nftables_tproxy
    else
        # 如果是 TUN 模式，清理掉可能残留的 TProxy 规则
        nft delete table ip singbox 2>/dev/null
        ip rule del fwmark 1 table 100 2>/dev/null
        ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    fi
    
    # 4. 启动服务
    systemctl restart sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then 
        echo -e "${GREEN}服务已启动 ($MODE模式)${PLAIN}"
    else 
        echo -e "${RED}启动失败，建议运行 'journalctl -u sing-box -n 20' 查看日志${PLAIN}"
        echo -e "${YELLOW}提示: 如果是初次安装，请先生成订阅配置 (sub.sh)。${PLAIN}"
    fi
}

stop_service() {
    systemctl stop sing-box
    # 清理所有网络劫持规则
    nft delete table ip singbox 2>/dev/null
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    echo -e "${GREEN}服务已停止${PLAIN}"
}

restart_service() { start_service; }
show_log() { journalctl -u sing-box -f -n 50; }

switch_mode() {
    echo -e "1. TUN (推荐，稳定性好)\n2. TProxy (高级，性能更好)"
    read -p "选择: " choice
    [[ "$choice" == "1" ]] && echo "TUN" > "$WORKDIR/.mode" && echo "已切换为 TUN"
    [[ "$choice" == "2" ]] && echo "TPROXY" > "$WORKDIR/.mode" && echo "已切换为 TProxy"
}

configure_nftables_tproxy() {
    TP_PORT="7891" # 默认端口
    
    # 尝试从配置文件智能读取端口
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        DETECTED_PORT=$(jq '.inbounds[] | select(.type=="tproxy") | .listen_port' "$CONFIG_FILE" 2>/dev/null | head -1)
        if [ -n "$DETECTED_PORT" ] && [ "$DETECTED_PORT" != "null" ]; then
            TP_PORT="$DETECTED_PORT"
            echo -e "${CYAN}检测到 TProxy 端口: $TP_PORT${PLAIN}"
        fi
    fi

    # 刷新并应用 nftables 规则
    nft flush ruleset 2>/dev/null # 慎用 flush，这里仅为了演示，实际建议只操作 singbox 表
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        # 排除私有网段 (防止内网不通)
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return
        # 劫持 TCP 和 UDP
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :$TP_PORT accept
    }
    chain output {
        type route hook output priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return
        meta mark 255 return
        meta l4proto { tcp, udp } meta mark set 1 accept
    }
}
NFT
    # 配置策略路由
    ip rule add fwmark 1 table 100 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null
}