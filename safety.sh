#!/bin/bash

# ==========================================
#  Sing-box 安全守卫 (适配 Dual Core & NFTables)
# ==========================================

# 定义备份存放路径
BACKUP_BASE_DIR="/root/sb-shell-backups"
CURRENT_TIME=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$BACKUP_BASE_DIR/$CURRENT_TIME"

# --- 辅助函数：获取 SSH 端口 ---
function get_ssh_port() {
    # 尝试从 sshd 配置或网络状态中获取端口
    # 优先使用 netstat/ss 检测实际监听端口
    if command -v ss >/dev/null; then
        SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    elif command -v netstat >/dev/null; then
        SSH_PORT=$(netstat -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    fi

    # 如果检测失败，回退到默认 22
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT="22"
    fi
    echo "$SSH_PORT"
}

# --- 功能1：深度备份 ---
function backup_environment() {
    echo -e "\033[33m正在执行环境备份...\033[0m"
    mkdir -p "$BACKUP_DIR"
    
    # 1. 备份防火墙规则 (iptables & ip6tables)
    if command -v iptables-save >/dev/null; then
        iptables-save > "$BACKUP_DIR/iptables.v4.bak"
    fi
    if command -v ip6tables-save >/dev/null; then
        ip6tables-save > "$BACKUP_DIR/iptables.v6.bak"
    fi

    # 2. 备份 NFTables (如果存在)
    if command -v nft >/dev/null; then
        nft list ruleset > "$BACKUP_DIR/nftables.bak" 2>/dev/null
    fi
    
    # 3. 备份路由表 (这对 TProxy 很重要)
    ip rule show > "$BACKUP_DIR/ip_rule.bak"
    ip route show table all > "$BACKUP_DIR/ip_route.bak"
    
    # 4. 备份关键网络配置
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak"
    
    echo -e "\033[32m备份完成！路径: $BACKUP_DIR\033[0m"
}

# --- 功能2：防断联炸弹 (Dead Man's Switch) ---
function start_safety_timer() {
    DETECTED_PORT=$(get_ssh_port)
    echo -e "\033[31m[警告] 正在启动防断联机制！\033[0m"
    echo -e "当前检测到的 SSH 端口为: \033[36m$DETECTED_PORT\033[0m"
    echo "如果在配置过程中 SSH 断开，系统将在 10 分钟后自动重启以恢复连接。"
    
    # 强制放行 SSH 端口 (插入到最前面)
    if command -v iptables >/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$DETECTED_PORT" -j ACCEPT
    fi
    
    # 设置 10 分钟重启
    shutdown -r +10 "Network Safety Reboot initiated by sb-shell"
    echo -e "\033[33m倒计时已开始。配置成功后请务必在菜单中选择“c. 取消防断联”！\033[0m"
    read -p "按回车键继续..."
}

function stop_safety_timer() {
    shutdown -c 2>/dev/null
    # 尝试清理刚才临时添加的规则 (简单清理 INPUT 链第一条，如果不确定也可以不清理，影响不大)
    # 这里保守起见，只取消重启，不随意动 iptables，以免误删用户规则
    echo -e "\033[32m已取消自动重启。网络配置确认安全。\033[0m"
    read -p "按回车键返回..."
}

# --- 功能3：紧急恢复 ---
function restore_environment() {
    # 寻找最新的备份
    LATEST_BACKUP=$(ls -td $BACKUP_BASE_DIR/* 2>/dev/null | head -1)
    
    if [ -z "$LATEST_BACKUP" ]; then
        echo -e "\033[31m未找到备份文件！无法恢复。\033[0m"
        return
    fi
    
    echo -e "\033[33m正在从 $LATEST_BACKUP 恢复...\033[0m"
    
    # 1. 停止服务
    systemctl stop sing-box
    
    # 2. 清理当前所有规则 (包括 nftables，这是新版核心的关键)
    if command -v nft >/dev/null; then
        echo "清理 nftables 规则..."
        nft flush ruleset 2>/dev/null
    fi
    
    # 3. 恢复 iptables
    if [ -f "$LATEST_BACKUP/iptables.v4.bak" ]; then
        iptables-restore < "$LATEST_BACKUP/iptables.v4.bak"
    fi
    if [ -f "$LATEST_BACKUP/iptables.v6.bak" ]; then
        ip6tables-restore < "$LATEST_BACKUP/iptables.v6.bak"
    fi
    
    # 4. 恢复 DNS
    [ -f "$LATEST_BACKUP/resolv.conf.bak" ] && cp -f "$LATEST_BACKUP/resolv.conf.bak" /etc/resolv.conf
    
    # 5. 清理 TProxy 可能残留的路由规则 (ip rule table 100)
    # core.sh 使用了 fwmark 1 和 table 100
    ip rule del fwmark 1 lookup 100 2>/dev/null
    ip route flush table 100 2>/dev/null
    
    echo -e "\033[32m恢复完成。建议重启服务器以确保环境彻底干净。\033[0m"
    read -p "按回车键返回..."
}