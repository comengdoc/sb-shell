#!/bin/bash

# ==========================================
#  Sing-box 核心管理 (适配 Official & Ref1nd)
# ==========================================

SINGBOX_BIN="/usr/local/bin/sing-box"
# 兼容旧路径，优先使用 /usr/local/bin
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

# 通用安装函数
# 参数 1: Repo Owner (e.g., SagerNet)
# 参数 2: Repo Name (e.g., sing-box)
# 参数 3: Tag Label (用于显示，e.g., Official)
install_core_logic() {
    REPO_OWNER="$1"
    REPO_NAME="$2"
    LABEL="$3"

    echo -e "${GREEN}正在准备安装 Sing-box [${LABEL}] 版本...${PLAIN}"
    
    # 检查依赖
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

    echo -e "${YELLOW}正在查询 ${REPO_OWNER}/${REPO_NAME} 最新版本...${PLAIN}"
    
    # 获取最新 Release Tag
    API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    LATEST_TAG=$(curl -sL --retry 3 "$API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$LATEST_TAG" ]]; then
        echo -e "${RED}获取版本失败，可能是 API 限制或仓库不存在。${PLAIN}"
        echo -e "${YELLOW}尝试回退到手动输入版本? (y/n)${PLAIN}"
        read -p ": " manual_opt
        if [[ "$manual_opt" == "y" ]]; then
            read -p "请输入版本号 (例如 v1.8.0): " LATEST_TAG
        else
            return
        fi
    fi
    
    VERSION_NO_V=${LATEST_TAG#v}
    
    # 构建下载链接 (适配通常的命名规则)
    # 大多数 release 命名为: sing-box-1.8.0-linux-amd64.tar.gz
    FILE_NAME="sing-box-${VERSION_NO_V}-${ARCH_CODE}.tar.gz"
    DOWNLOAD_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${LATEST_TAG}/${FILE_NAME}"

    echo -e "检测到版本: ${CYAN}${LATEST_TAG}${PLAIN}"
    echo -e "下载地址: ${DOWNLOAD_URL}"
    
    TMP_DIR=$(mktemp -d)
    wget -T 60 -t 3 -O "$TMP_DIR/sb.tar.gz" "$DOWNLOAD_URL" || { echo -e "${RED}下载失败${PLAIN}"; rm -rf "$TMP_DIR"; return; }
    
    echo -e "正在解压..."
    tar -zxvf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1
    
    # 查找二进制文件 (处理解压后可能存在的子目录)
    BINARY_FOUND=$(find "$TMP_DIR" -type f -name "sing-box" | head -n 1)

    if [[ -n "$BINARY_FOUND" ]]; then
        systemctl stop sing-box 2>/dev/null
        cp -f "$BINARY_FOUND" "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        echo -e "${GREEN}核心部署成功${PLAIN}"
    else
        echo -e "${RED}解压后未找到 sing-box 二进制文件，结构可能已变更${PLAIN}"
        rm -rf "$TMP_DIR"
        return
    fi
    rm -rf "$TMP_DIR"
    
    # 标记版本
    mkdir -p "$WORKDIR"
    echo "$LABEL" > "$WORKDIR/.version_tag"

    # 初始化目录
    mkdir -p "$CONFIG_DIR" "$TEMPLATE_DIR" "$WORKDIR/providers" "$WORKDIR/ui"

    # 安装 UI (Yacd)
    if [ ! -d "$WORKDIR/ui/assets" ]; then
        echo -e "${YELLOW}正在安装 Dashboard UI...${PLAIN}"
        curl -sL -o "$WORKDIR/ui.zip" "https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip"
        unzip -o -q "$WORKDIR/ui.zip" -d "$WORKDIR/"
        mv "$WORKDIR/Yacd-meta-gh-pages"/* "$WORKDIR/ui/" 2>/dev/null
        rm -rf "$WORKDIR/ui.zip" "$WORKDIR/Yacd-meta-gh-pages"
    fi

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
    echo -e "${GREEN}安装完成! 请运行菜单更新订阅并启动。${PLAIN}"
}

install_official() {
    install_core_logic "SagerNet" "sing-box" "Official"
}

install_ref1nd() {
    # Ref1nd 的仓库，请确认这是你期望的仓库
    # 这里假设仓库名为 ref1nd/sing-box
    install_core_logic "ref1nd" "sing-box" "Ref1nd"
}

start_service() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [ -n "$DEFAULT_IF" ]; then
        iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    fi

    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    
    if [[ "$MODE" == "TPROXY" ]]; then 
        configure_nftables_tproxy
    fi
    
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
    echo -e "1. TUN (推荐，适配 tun.json)\n2. TProxy (高级)"
    read -p "选择: " choice
    [[ "$choice" == "1" ]] && echo "TUN" > "$WORKDIR/.mode" && echo "已切换为 TUN"
    [[ "$choice" == "2" ]] && echo "TPROXY" > "$WORKDIR/.mode" && echo "已切换为 TProxy"
}

configure_nftables_tproxy() {
    # 自动适配逻辑：尝试从当前配置文件中读取 TProxy 端口
    # 如果读取失败，且当前使用的是 tun.json (它通常没有 tproxy-in)，则警告
    # 默认回退到 7891
    
    TP_PORT="7891"
    
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        # 尝试查找 tag 为 tproxy-in 的入站端口，或者类型为 tproxy 的第一个入站端口
        DETECTED_PORT=$(jq '.inbounds[] | select(.type=="tproxy") | .listen_port' "$CONFIG_FILE" 2>/dev/null | head -1)
        if [ -n "$DETECTED_PORT" ] && [ "$DETECTED_PORT" != "null" ]; then
            TP_PORT="$DETECTED_PORT"
            echo -e "${CYAN}自动检测到 TProxy 端口: $TP_PORT${PLAIN}"
        fi
    fi

    nft flush ruleset
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255, 192.168.0.0/16, 10.0.0.0/8 } return
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :$TP_PORT accept
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