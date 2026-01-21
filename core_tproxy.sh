#!/bin/bash

# ==========================================
#  Sing-box 核心管理 (TProxy 旁路由整合版)
#  功能: 下载安装、版本管理 + 修复后的旁路由网络逻辑
#  修复: 2026-01-22 (增加内核模块自动加载 & 依赖补全)
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
#  1. 状态检查与安装功能
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

    echo -e "运行状态: ${STATUS}  |  当前版本: ${GREEN}${VER}${PLAIN}  |  架构: ${CYAN}TProxy Only${PLAIN}"
}

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
    # 2026-01-22 修复：增加对 chrony, ca-certificates, iproute2 的检查
    echo -e "${YELLOW}正在检查系统依赖...${PLAIN}"
    if command -v apt-get >/dev/null; then
        apt-get update
        apt-get install -y curl wget tar nftables git jq ca-certificates iproute2 chrony tzdata
        systemctl enable --now chrony >/dev/null 2>&1
    elif command -v apk >/dev/null; then
        apk add curl wget tar nftables git jq ca-certificates iproute2 chrony tzdata
        rc-service chronyd start
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
#  2. 核心网络逻辑 (修复版)
# ==========================================
start_service() {
    echo -e "${YELLOW}正在启动 Sing-box (旁路由 TProxy 模式)...${PLAIN}"

    # 0. 【关键修复】强制加载 NFTables TProxy 和 NAT 所需的内核模块
    #    解决 "nft_nat" 未加载导致 masquerade 失败的问题
    echo -e "正在加载内核模块..."
    modprobe nft_tproxy >/dev/null 2>&1
    modprobe nft_socket >/dev/null 2>&1
    modprobe nf_conntrack >/dev/null 2>&1
    modprobe nf_nat >/dev/null 2>&1

    # 1. 内核参数优化 (旁路由三件套)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1
    
    # 【重要】关闭 ICMP 重定向，防止设备跳过旁路由
    sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null 2>&1
    
    # 【重要】宽松的反向路径过滤，防止丢包
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1

    # 2. 路由策略清理与重建
    ip rule del from 192.168.0.0/16 lookup 2022 >/dev/null 2>&1
    ip rule del fwmark 1 table 100 >/dev/null 2>&1
    ip route del local 0.0.0.0/0 dev lo table 100 >/dev/null 2>&1

    # 配置策略路由：打标流量 -> 查表100 -> 送入本地回环
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # 3. 加载 NFTables 规则
    configure_nftables_tproxy

    # 4. 配置强制 NAT (旁路由必须！)
    DEFAULT_IF="eth0"
    
    nft add table ip singbox 2>/dev/null
    nft add chain ip singbox nat_postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
    nft flush chain ip singbox nat_postrouting 2>/dev/null
    
    # 【核心】所有出站流量进行伪装，解决三角路由回程问题
    # 依赖 nf_nat 模块
    if [ -n "$DEFAULT_IF" ]; then
        nft add rule ip singbox nat_postrouting oifname "$DEFAULT_IF" masquerade 2>/dev/null
        echo -e "NAT 接口 (Masquerade): ${CYAN}$DEFAULT_IF${PLAIN}"
    else
        echo -e "${RED}警告: 未找到 eth0 网卡，NAT 可能失败${PLAIN}"
    fi

    # 5. 启动服务
    systemctl restart sing-box
    sleep 1
    
    if systemctl is-active --quiet sing-box; then 
        echo -e "${GREEN}服务启动成功 (旁路由模式 Ready)${PLAIN}"
    else 
        echo -e "${RED}启动失败，请检查日志 (journalctl -u sing-box -n 20)${PLAIN}"
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
#  3. NFTables 规则
# ==========================================
configure_nftables_tproxy() {
    TP_PORT="7895"
    
    # 自动获取本机 IP，防止把自己锁在外面
    LOCAL_IPS=$(ip addr | grep 'inet ' | awk '{print $2}' | sed 's/\/.*//' | tr '\n' ',' | sed 's/,$//')

    echo -e "TProxy 监听端口: ${CYAN}${TP_PORT}${PLAIN}"
    echo -e "本机 IP 豁免: ${CYAN}${LOCAL_IPS}${PLAIN}"

    nft flush ruleset 2>/dev/null
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        
        # 1. 基础豁免
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        
        # 2. 【防锁死】豁免发往 R5C 本机的流量 (SSH, 面板, DNS)
        ip daddr { $LOCAL_IPS } return
        
        # 3. 【防掉线】豁免 DHCP 广播 (UDP 67/68)
        udp sport { 67, 68 } return
        udp dport { 67, 68 } return

        # 4. 豁免局域网互访 (LAN to LAN)
        # 确保这里涵盖了你的所有内网段
        ip daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return

        # 5. 劫持剩余所有 TCP/UDP 流量 -> TProxy
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :$TP_PORT accept
    }
    chain output {
        type route hook output priority mangle; policy accept;
        
        # 1. 基础豁免
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        ip daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return
        ip daddr { $LOCAL_IPS } return

        # 2. 【防死循环核心】
        # 匹配 JSON 中 "➡️ 直连" 的 routing_mark: 255
        meta mark 255 return
        
        # 3. 豁免 NTP (防止时间同步死循环)
        udp dport 123 return
    }
}
NFT
}

# 增加菜单调用 (可选)
case "\$1" in
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    log) show_log ;;
    install_off) install_official ;;
    install_ref) install_ref1nd ;;
    *) echo "Usage: \$0 {start|stop|restart|log|install_off|install_ref}" ;;
esac