#!/bin/bash

# 定义备份存放路径
BACKUP_BASE_DIR="/root/sb-shell-backups"
CURRENT_TIME=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$BACKUP_BASE_DIR/$CURRENT_TIME"

# --- 功能1：深度备份 ---
function backup_environment() {
    echo -e "\033[33m正在执行环境备份...\033[0m"
    mkdir -p "$BACKUP_DIR"
    
    # 1. 备份防火墙规则
    if command -v iptables-save >/dev/null; then
        iptables-save > "$BACKUP_DIR/iptables.v4.bak"
    fi
    if command -v ip6tables-save >/dev/null; then
        ip6tables-save > "$BACKUP_DIR/iptables.v6.bak"
    fi
    
    # 2. 备份路由表 (这对 TProxy 很重要)
    ip rule show > "$BACKUP_DIR/ip_rule.bak"
    ip route show table all > "$BACKUP_DIR/ip_route.bak"
    
    # 3. 备份关键网络配置
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak"
    [ -d /etc/network ] && cp -r /etc/network "$BACKUP_DIR/etc_network_dir"
    
    echo -e "\033[32m备份完成！路径: $BACKUP_DIR\033[0m"
}

# --- 功能2：防断联炸弹 (Dead Man's Switch) ---
function start_safety_timer() {
    echo -e "\033[31m[警告] 正在启动防断联机制！\033[0m"
    echo "如果在配置过程中 SSH 断开，系统将在 10 分钟后自动重启以恢复连接。"
    
    # 强制放行 SSH (假设端口22，如有不同请修改)
    iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
    
    # 设置 10 分钟重启
    shutdown -r +10 "Network Safety Reboot initiated by sb-shell"
    echo -e "\033[33m倒计时已开始。配置成功后请务必在菜单中选择“取消重启”！\033[0m"
    read -p "按回车键继续..."
}

function stop_safety_timer() {
    shutdown -c
    echo -e "\033[32m已取消自动重启。网络配置确认安全。\033[0m"
    read -p "按回车键返回..."
}

# --- 功能3：紧急恢复 ---
function restore_environment() {
    # 寻找最新的备份
    LATEST_BACKUP=$(ls -td $BACKUP_BASE_DIR/* | head -1)
    
    if [ -z "$LATEST_BACKUP" ]; then
        echo -e "\033[31m未找到备份文件！无法恢复。\033[0m"
        return
    fi
    
    echo -e "\033[33m正在从 $LATEST_BACKUP 恢复...\033[0m"
    
    # 停止服务
    systemctl stop sing-box
    
    # 恢复 iptables
    iptables-restore < "$LATEST_BACKUP/iptables.v4.bak"
    [ -f "$LATEST_BACKUP/iptables.v6.bak" ] && ip6tables-restore < "$LATEST_BACKUP/iptables.v6.bak"
    
    # 恢复 DNS
    [ -f "$LATEST_BACKUP/resolv.conf.bak" ] && cp "$LATEST_BACKUP/resolv.conf.bak" /etc/resolv.conf
    
    # 清理 TProxy 可能残留的路由规则 (暴力清除 sing-box 常见的 table 100)
    ip rule del fwmark 1 lookup 100 2>/dev/null
    ip route flush table 100 2>/dev/null
    
    echo -e "\033[32m恢复完成。建议重启服务器确保干净。\033[0m"
    read -p "按回车键返回..."
}