#!/bin/bash

# ==========================================
#  Sing-box 客户端管理主菜单 (优化版)
# ==========================================

# 1. 强制定义核心路径
WORKDIR="/etc/sbshell"
BACKUP_DIR="/root/sb-shell-backups"
LINK_FILE="/usr/local/bin/sbshell"

# 2. 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 3. 加载核心模块 (带容错)
if [ -f "$WORKDIR/core.sh" ]; then
    source "$WORKDIR/core.sh"
else
    echo -e "${RED}严重错误: 找不到核心文件 $WORKDIR/core.sh${PLAIN}"
    exit 1
fi

# 确保加载 sub.sh (如果存在)
if [ -f "$WORKDIR/sub.sh" ]; then
    source "$WORKDIR/sub.sh"
fi

# 加载安全模块
if [ -f "$WORKDIR/safety.sh" ]; then
    source "$WORKDIR/safety.sh"
fi

# 4. 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 5. 卸载函数
uninstall_all() {
    echo -e "${RED}确定要彻底卸载 sbshell 吗? [y/N]${PLAIN}"
    read -p ": " confirm
    [[ "$confirm" != "y" ]] && return
    
    stop_service 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    
    rm -f "$SERVICE_FILE" "$SINGBOX_BIN" "$LINK_FILE"
    rm -rf "$CONFIG_DIR" "$WORKDIR" "$BACKUP_DIR"
    
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

# 6. 主菜单
menu() {
    clear
    echo -e "#############################################################"
    echo -e "#            Sing-box 客户端管理 (Armbian修复版)            #"
    echo -e "#############################################################"
    check_status
    echo -e "-------------------------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 安装/更新 Sing-box 核心"
    echo -e "${GREEN}2.${PLAIN} 启动服务"
    echo -e "${GREEN}3.${PLAIN} 停止服务"
    echo -e "${GREEN}4.${PLAIN} 重启服务"
    echo -e "${GREEN}5.${PLAIN} 查看日志"
    echo -e "-------------------------------------------------------------"
    echo -e "${YELLOW}6.${PLAIN} 切换模式 (TUN/TProxy)"
    echo -e "${YELLOW}7.${PLAIN} 更新订阅 (已集成正则筛选+后端转换)"
    echo -e "${YELLOW}8.${PLAIN} 编辑当前配置"
    echo -e "-------------------------------------------------------------"
    echo -e "${CYAN}s.${PLAIN} 开启防断联保护"
    echo -e "${CYAN}c.${PLAIN} 取消防断联"
    echo -e "${RED}9.${PLAIN} 卸载脚本"
    echo -e "${RED}0.${PLAIN} 退出"
    echo -e ""
    read -p " 请输入选项: " num

    case "$num" in
        1) install_singbox ;;
        2) start_service ;;
        3) stop_service ;;
        4) restart_service ;;
        5) show_log ;;
        6) switch_mode ;;
        7) update_subscription ;;
        8) vim /etc/sing-box/config.json && restart_service ;;
        s|S) start_safety_timer ;;
        c|C) stop_safety_timer ;;
        9) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
    echo -e ""
    read -p "按回车键返回..." 
    menu
}

# 启动菜单
menu