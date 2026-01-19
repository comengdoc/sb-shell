#!/bin/bash

# ==========================================
#  Sing-box 核心管理 (Expert Modified)
#  优化: 修复 CrashCore 识别 / 目录缺失 / 兼容旧版配置
# ==========================================

# [关键修复] 开启兼容模式，防止 Sub-Store 转换的配置报错 (Legacy Special Outbounds)
export ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true

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
    
    # 依赖检查
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget tar nftables git jq
    elif command -v apk >/dev/null; then
        apk add curl wget tar nftables git jq
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        # 修正: 官方版使用 linux-arm64
        aarch64|armv8) ARCH_CODE="linux-arm64" ;;
        x86_64|amd64)  ARCH_CODE="linux-amd64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "${YELLOW}正在查询 SagerNet/sing-box 最新版本...${PLAIN}"
    API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    LATEST_TAG=$(curl -sL --retry 3 "$API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$LATEST_TAG" ]]; then
        echo -e "${RED}API 获取失败，请输入版本号 (例如 v1.11.0): ${PLAIN}"
        read -p ": " LATEST_TAG
        [[ -z "$LATEST_TAG" ]] && return
    fi
    
    VERSION_NO_V=${LATEST_TAG#v}
    FILE_NAME="sing-box-${VERSION_NO_V}-${ARCH_CODE}.tar.gz"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/${FILE_NAME}"

    echo -e "版本: ${CYAN}${LATEST_TAG}${PLAIN}"
    echo -e "下载源: ${CYAN}SagerNet (Official)${PLAIN}"
    install_download_logic "$DOWNLOAD_URL" "Official"
}

# ==========================================
#  核心安装逻辑 (Ref1nd - DustinWin)
# ==========================================
install_ref1nd() {
    echo -e "${GREEN}正在准备安装 Sing-box [Ref1nd] 版本...${PLAIN}"
    echo -e "${YELLOW}注意: 此版本包含更多协议支持与去广告优化 (Source: DustinWin)${PLAIN}"

    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget tar nftables git jq
    elif command -v apk >/dev/null; then
        apk add curl wget tar nftables git jq
    fi

    ARCH=$(uname -m)
    # 修正: 适配 DustinWin 新版命名规则 (linux-armv8)
    case $ARCH in
        aarch64|armv8) FILE_NAME="sing-box-ref1nd-main-linux-armv8.tar.gz" ;;
        x86_64|amd64)  FILE_NAME="sing-box-ref1nd-main-linux-amd64.tar.gz" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    # 修正: 正确的下载地址结构
    DOWNLOAD_URL="https://github.com/DustinWin/proxy-tools/releases/download/sing-box/${FILE_NAME}"
    
    echo -e "下载源: ${CYAN}DustinWin/proxy-tools (Ref1nd-Main)${PLAIN}"
    echo -e "文件URL: ${CYAN}${DOWNLOAD_URL}${PLAIN}"
    install_download_logic "$DOWNLOAD_URL" "Ref1nd"
}

# ==========================================
#  通用下载与部署函数 (修复 CrashCore 识别)
# ==========================================
install_download_logic() {
    URL="$1"
    LABEL="$2"
    
    TMP_DIR=$(mktemp -d)
    echo -e "正在下载..."
    # 增加 User-Agent 和重定向跟随
    wget -T 60 -t 3 -U "Mozilla/5.0" -O "$TMP_DIR/sb.tar.gz" "$URL" || { echo -e "${RED}下载失败，请检查网络或 URL 是否有效${PLAIN}"; rm -rf "$TMP_DIR"; return; }
    
    echo -e "正在解压..."
    tar -zxvf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1
    
    # === 关键修正: 同时查找 sing-box 和 CrashCore ===
    BINARY_FOUND=$(find "$TMP_DIR" -type f \( -name "sing-box" -o -name "CrashCore" \) | head -n 1)

    if [[ -n "$BINARY_FOUND" ]]; then
        systemctl stop sing-box 2>/dev/null
        cp -f "$BINARY_FOUND" "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        
        # 标记版本
        mkdir -p "$WORKDIR"
        echo "$LABEL" > "$WORKDIR/.version_tag"
        
        # === 关键修正: 确保配置目录存在 ===
        if [ ! -d "$CONFIG_DIR" ]; then
            echo -e "${YELLOW}正在创建配置目录: $CONFIG_DIR ...${PLAIN}"
            mkdir -p "$CONFIG_DIR"
            chmod 777 "$CONFIG_DIR"
        fi
        
        install_ui
        write_service
        
        echo -e "${GREEN}核心部署成功 [${LABEL}]${PLAIN}"
    else
        echo -e "${RED}解压后未找到二进制文件 (sing-box 或 CrashCore)${PLAIN}"
        echo -e "调试信息 - 解压目录内容:"
        ls -R "$TMP_DIR"
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
# 开启兼容模式 (解决 FATAL: legacy special outbounds 错误)
Environment="ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true"
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
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    
    # 自动获取默认网卡
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    
    # 确保 singbox 表存在
    nft add table ip singbox 2>/dev/null
    
    # 添加 NAT 链和规则 (如果不存在)
    nft add chain ip singbox nat_postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
    
    if [ -n "$DEFAULT_IF" ]; then
        # 对默认网卡开启伪装
        nft add rule ip singbox nat_postrouting oifname "$DEFAULT_IF" masquerade 2>/dev/null
    fi

    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    
    if [[ "$MODE" == "TPROXY" ]]; then 
        configure_nftables_tproxy
    else
        nft delete table ip singbox 2>/dev/null
        ip rule del fwmark 1 table 100 2>/dev/null
        ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    fi
    
    systemctl restart sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then 
        echo -e "${GREEN}服务已启动 ($MODE模式)${PLAIN}"
    else 
        echo -e "${RED}启动失败，建议运行 'journalctl -u sing-box -n 20' 查看日志${PLAIN}"
    fi
}

stop_service() {
    systemctl stop sing-box
    nft delete table ip singbox 2>/dev/null
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    echo -e "${GREEN}服务已停止${PLAIN}"
}

restart_service() { start_service; }
show_log() { journalctl -u sing-box -f -n 50; }

switch_mode() {
    echo -e "1. TUN (推荐)\n2. TProxy (高级)"
    read -p "选择: " choice
    [[ "$choice" == "1" ]] && echo "TUN" > "$WORKDIR/.mode" && echo "已切换为 TUN"
    [[ "$choice" == "2" ]] && echo "TPROXY" > "$WORKDIR/.mode" && echo "已切换为 TProxy"
}

configure_nftables_tproxy() {
    TP_PORT="7891"
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        DETECTED_PORT=$(jq '.inbounds[] | select(.type=="tproxy") | .listen_port' "$CONFIG_FILE" 2>/dev/null | head -1)
        [ -n "$DETECTED_PORT" ] && [ "$DETECTED_PORT" != "null" ] && TP_PORT="$DETECTED_PORT"
    fi

    nft flush ruleset 2>/dev/null
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return
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
    ip rule add fwmark 1 table 100 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null
}