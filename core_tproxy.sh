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

check_arch() {
    # 简单防止在 x86 机器上误跑导致 Exec format error
    case "$(uname -m)" in
        aarch64|armv8*) ;;
        *) echo -e "${RED}警告: 检测到非 ARM64 架构，此脚本专为 R5C 设计，继续运行可能会失败。${PLAIN}" ;;
    esac
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

# --- 修正后的 NFTables 配置函数 ---
configure_nftables_lite() {
    # 1. 自动获取出口网卡和局域网网段
    # 获取出口网卡 (通过访问阿里DNS探测)
    OUT_INTF=$(ip route get 223.5.5.5 | grep -oP 'dev \K\S+')
    [[ -z "$OUT_INTF" ]] && OUT_INTF="eth0" # 兜底
    
    TP_PORT="7895"
    FWMARK="1"

    echo -e "应用规则: ${CYAN}TProxy (LAN + Local)${PLAIN} -> 出口: ${GREEN}$OUT_INTF${PLAIN}"

    # 2. 清理旧表 (防止重复堆叠)
    nft delete table ip singbox 2>/dev/null

    # 3. 应用新的 NFTables 规则 (结合了 macin.top 的结构和 R5C 旁路由的必要特性)
    nft -f - <<NFT
# 定义变量：保留 IP 地址段 (私有地址 + 组播 + 广播)
# 包含: 10.x.x.x, 127.x.x.x, 169.254.x.x, 172.16-31.x.x, 192.168.x.x, 224.x.x.x, 240.x.x.x, 255.x.x.x
define RESERVED_IP = { 
    10.0.0.0/8, 
    127.0.0.0/8, 
    169.254.0.0/16, 
    172.16.0.0/12, 
    192.168.0.0/16, 
    224.0.0.0/4, 
    240.0.0.0/4, 
    255.255.255.255/32 
}

table ip singbox {
    # -----------------------------------------------------------
    # 链 1: Prerouting - 处理局域网其他设备流入 R5C 的流量
    # -----------------------------------------------------------
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # 豁免目标地址是保留 IP 的流量 (直连内网)
        ip daddr \$RESERVED_IP return

        # 劫持剩余流量 (TCP/UDP) 到 TProxy 端口
        # meta l4proto { tcp, udp } 这种写法比分开写两行更简洁
        meta l4proto { tcp, udp } meta mark set $FWMARK tproxy to :$TP_PORT accept
    }

    # -----------------------------------------------------------
    # 链 2: Output - 处理 R5C 本机发出的流量 (新增功能)
    # -----------------------------------------------------------
    chain output {
        type route hook output priority mangle; policy accept;

        # 豁免目标地址是保留 IP 的流量 (本机访问内网不走代理)
        ip daddr \$RESERVED_IP return

        # 豁免 sing-box 进程自身发出的流量，防止死循环
        # 注意：这里需要 sing-box 配置文件 outbound 配合 "routing_mark": 255
        meta mark 255 return

        # 劫持本机发出的流量 (TCP/UDP) 打上标记
        # 经过路由判定后，这些包会重路由到 loopback 接口被 sing-box 捕获
        meta l4proto { tcp, udp } meta mark set $FWMARK accept
    }

    # -----------------------------------------------------------
    # 链 3: Postrouting - 源地址伪装 (旁路由核心)
    # -----------------------------------------------------------
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # 对从出口网卡发出的流量进行 Masquerade
        # 这是 macin.top 文章中未强调但对 R5C 旁路由至关重要的步骤
        oifname "$OUT_INTF" masquerade
    }
}
NFT
}

start_service() {
    echo -e "${YELLOW}正在启动服务 (Lite模式)...${PLAIN}"
    
    # 优化点 4: 配置文件预检
    # 如果配置文件有语法错误，直接拦截，防止服务反复重启
    if [ -f "$SINGBOX_BIN" ] && [ -f "$CONFIG_FILE" ]; then
        if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" > /dev/null 2>&1; then
            echo -e "${RED}启动失败: 配置文件格式错误！请检查 config.json${PLAIN}"
            # 输出具体的错误信息给用户看
            "$SINGBOX_BIN" check -c "$CONFIG_FILE"
            return 1
        fi
    fi

    # 1. 加载模块
    modprobe nft_tproxy 2>/dev/null
    modprobe nft_socket 2>/dev/null
    modprobe nf_nat 2>/dev/null

    # 2. 开启转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null
    # R5C/Armbian 有时需要松开 rp_filter 限制，否则 TProxy 回包可能被丢弃
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
    
    # 针对特定的出口网卡也松开 rp_filter (结合上面的 OUT_INTF 变量)
    OUT_INTF=$(ip route get 223.5.5.5 | grep -oP 'dev \K\S+')
    [[ -n "$OUT_INTF" ]] && sysctl -w net.ipv4.conf.$OUT_INTF.rp_filter=0 >/dev/null

    # 3. 设置策略路由 (保持原逻辑，加上 set +e 防止报错退出)
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # 4. 应用 NFT 规则
    configure_nftables_lite

    # 5. 启动进程
    systemctl restart sing-box
    
    # 稍微等待一下再检查状态，防止 systemd 还没反应过来
    sleep 1
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}启动成功${PLAIN}"
    else
        echo -e "${RED}启动失败，请检查以下日志:${PLAIN}"
        journalctl -u sing-box -n 10 --no-pager
    fi
}

stop_service() {
    systemctl stop sing-box
    
    # 优化点 3: 只清理 singbox 相关的路由和 NFT 表
    # 严禁执行 nft flush ruleset
    nft delete table ip singbox 2>/dev/null
    
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    
    echo -e "${GREEN}服务已停止，singbox规则已移除，其他防火墙规则未受影响${PLAIN}"
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