#!/bin/bash

# ==========================================
#  Sing-box 核心管理 (TProxy Dedicated)
#  专用于 Armbian/Linux 裸核透明代理部署
#  特点: 仅支持 TProxy 模式，极致精简与稳定
# ==========================================

# 开启兼容模式，防止 Sub-Store 转换的配置报错
export ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true

SINGBOX_BIN="/usr/local/bin/sing-box"
# 清理可能存在的干扰文件
[ -f "/usr/bin/sing-box" ] && rm -f "/usr/bin/sing-box"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
WORKDIR="/etc/sbshell"

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
#  状态检查
# ==========================================
check_status() {
    if systemctl is-active --quiet sing-box; then
        STATUS="${GREEN}运行中${PLAIN}"
    else
        STATUS="${RED}未运行${PLAIN}"
    fi

    if [ -f "$SINGBOX_BIN" ]; then
        VER_RAW=$($SINGBOX_BIN version 2>/dev/null)
        VER_NUM=$(echo "$VER_RAW" | grep -oE 'version [0-9.]+' | head -1 | awk '{print $2}')
        TAG_FILE="$WORKDIR/.version_tag"
        [ -f "$TAG_FILE" ] && TAG_INFO=" ($(cat "$TAG_FILE"))" || TAG_INFO=""
        VER="${VER_NUM}${TAG_INFO}"
    else
        VER="${RED}未安装${PLAIN}"
    fi

    # TProxy 专用版不需要检测模式
    echo -e "运行状态: ${STATUS}  |  当前版本: ${GREEN}${VER}${PLAIN}  |  架构: ${CYAN}TProxy Only${PLAIN}"
}

# ==========================================
#  安装逻辑 (保持双源支持)
# ==========================================
install_official() {
    echo -e "${GREEN}正在准备安装 Sing-box [Official/SagerNet]...${PLAIN}"
    install_deps
    
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|armv8) ARCH_CODE="linux-arm64" ;;
        x86_64|amd64)  ARCH_CODE="linux-amd64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "${YELLOW}正在查询最新版本...${PLAIN}"
    API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    LATEST_TAG=$(curl -sL --retry 3 "$API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$LATEST_TAG" ]]; then
        read -p "API 获取失败，请输入版本号 (例如 v1.11.0): " LATEST_TAG
        [[ -z "$LATEST_TAG" ]] && return
    fi
    
    VERSION_NO_V=${LATEST_TAG#v}
    FILE_NAME="sing-box-${VERSION_NO_V}-${ARCH_CODE}.tar.gz"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/${FILE_NAME}"

    install_download_logic "$DOWNLOAD_URL" "Official"
}

install_ref1nd() {
    echo -e "${GREEN}正在准备安装 Sing-box [Ref1nd] (更多协议/去广告)...${PLAIN}"
    install_deps

    ARCH=$(uname -m)
    case $ARCH in
        aarch64|armv8) FILE_NAME="sing-box-ref1nd-main-linux-armv8.tar.gz" ;;
        x86_64|amd64)  FILE_NAME="sing-box-ref1nd-main-linux-amd64.tar.gz" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    DOWNLOAD_URL="https://github.com/DustinWin/proxy-tools/releases/download/sing-box/${FILE_NAME}"
    install_download_logic "$DOWNLOAD_URL" "Ref1nd"
}

install_deps() {
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y curl wget tar nftables git jq
    elif command -v apk >/dev/null; then
        apk add curl wget tar nftables git jq
    fi
}

install_download_logic() {
    URL="$1"
    LABEL="$2"
    TMP_DIR=$(mktemp -d)
    
    echo -e "正在下载: $URL"
    wget -T 60 -t 3 -U "Mozilla/5.0" -O "$TMP_DIR/sb.tar.gz" "$URL" || { echo -e "${RED}下载失败${PLAIN}"; rm -rf "$TMP_DIR"; return; }
    
    tar -zxvf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1
    BINARY_FOUND=$(find "$TMP_DIR" -type f \( -name "sing-box" -o -name "CrashCore" \) | head -n 1)

    if [[ -n "$BINARY_FOUND" ]]; then
        systemctl stop sing-box 2>/dev/null
        cp -f "$BINARY_FOUND" "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        
        mkdir -p "$WORKDIR" "$CONFIG_DIR"
        chmod 777 "$CONFIG_DIR"
        echo "$LABEL" > "$WORKDIR/.version_tag"
        
        install_ui
        write_service
        echo -e "${GREEN}核心部署成功 [${LABEL}]${PLAIN}"
    else
        echo -e "${RED}未找到二进制文件${PLAIN}"
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

# ==========================================
#  服务配置 (Systemd)
# ==========================================
write_service() {
    cat > $SERVICE_FILE <<SYSTEMD
[Unit]
Description=sing-box service (TProxy)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
Group=root
Environment="ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true"

# TProxy 必须的权限，明确声明以保证稳定性
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
#  TProxy 核心启动逻辑 (Stable)
# ==========================================
start_service() {
    echo -e "${YELLOW}正在启动 Sing-box (TProxy 模式)...${PLAIN}"

    # 1. 基础内核参数优化
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    # 【TProxy 核心】开启 Mark 验证
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1
    
    # 【TProxy 稳定性关键】放宽反向路径过滤 (rp_filter)
    # 如果 rp_filter=1 (Strict)，非对称路由的数据包会被内核丢弃，导致 TProxy 断流
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
    
    # 禁用 IPv6 (防止泄露)
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1

    # 2. 路由策略清理与重建
    # 清理所有可能残留的策略路由，包括 TUN 模式的 2022 表和 TProxy 的 100 表
    ip rule del from 192.168.0.0/16 lookup 2022 >/dev/null 2>&1
    ip rule del fwmark 1 table 100 >/dev/null 2>&1
    ip route del local 0.0.0.0/0 dev lo table 100 >/dev/null 2>&1

    # 【路由核心】让被 NFTables 打标 (fwmark 1) 的流量查表 100
    ip rule add fwmark 1 table 100
    # 【路由核心】表 100 将所有流量重定向到本地回环，交给 Sing-box 监听
    ip route add local 0.0.0.0/0 dev lo table 100

    # 3. 加载 NFTables 规则
    configure_nftables_tproxy

    # 4. 配置 NAT 伪装
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
    
    nft add table ip singbox 2>/dev/null
    # 注意: TProxy 模式下，NAT 链不需要与 TProxy 链混淆，只需处理出站伪装
    nft add chain ip singbox nat_postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
    nft flush chain ip singbox nat_postrouting 2>/dev/null
    
    if [ -n "$DEFAULT_IF" ]; then
        nft add rule ip singbox nat_postrouting oifname "$DEFAULT_IF" masquerade 2>/dev/null
        echo -e "NAT 接口: ${CYAN}$DEFAULT_IF${PLAIN}"
    else
        echo -e "${RED}警告: 未找到默认网卡，NAT 可能失败${PLAIN}"
    fi

    # 5. 启动服务
    systemctl restart sing-box
    sleep 1
    
    if systemctl is-active --quiet sing-box; then 
        echo -e "${GREEN}服务启动成功 (TProxy Ready)${PLAIN}"
    else 
        echo -e "${RED}启动失败，请检查日志 (journalctl -u sing-box -n 20)${PLAIN}"
        # 回滚路由规则以免断网
        stop_service
    fi
}

stop_service() {
    systemctl stop sing-box
    # 清理 NFTables
    nft delete table ip singbox 2>/dev/null
    # 清理路由策略
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    echo -e "${GREEN}服务已停止并清理规则${PLAIN}"
}

restart_service() { start_service; }
show_log() { journalctl -u sing-box -f -n 50; }

# ==========================================
#  NFTables 规则生成 (纯净版)
# ==========================================
configure_nftables_tproxy() {
    # 自动获取端口，默认 7891
    TP_PORT="7891"
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        DETECTED_PORT=$(jq '.inbounds[] | select(.type=="tproxy") | .listen_port' "$CONFIG_FILE" 2>/dev/null | head -1)
        # 增强检测逻辑：如果 jq 返回空或 null，保持默认
        [[ -n "$DETECTED_PORT" && "$DETECTED_PORT" != "null" ]] && TP_PORT="$DETECTED_PORT"
    fi
    
    echo -e "TProxy 监听端口: ${CYAN}${TP_PORT}${PLAIN}"

    nft flush ruleset 2>/dev/null
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        # 放行局域网广播、组播和保留地址
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        # 放行发往局域网内部的流量 (避免访问内网 NAS 也走代理)
        ip daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return
        # 劫持 TCP 和 UDP 流量，打上标记 1，并转发给 TProxy 端口
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :$TP_PORT accept
    }
    chain output {
        type route hook output priority mangle; policy accept;
        # 本机出站流量处理
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        ip daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return
        # 防止无限循环：Sing-box 发出的流量通常由系统用户或 fwmark 识别，这里简单通过 mark 255 规避
        # 注意：需要在 sing-box config.json 的 outbound 中设置 routing_mark: 255 配合最佳，或者依赖 sing-box 自动处理
        meta mark 255 return
        meta l4proto { tcp, udp } meta mark set 1 accept
    }
}
NFT
}