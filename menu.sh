#!/bin/bash

# ==========================================
#  Sing-box 客户端管理 (PuerNya 专版)
# ==========================================

WORKDIR="/etc/sbshell"
BACKUP_DIR="/root/sb-shell-backups"
LINK_FILE="/usr/local/bin/sbshell"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

if [ -f "$WORKDIR/core.sh" ]; then source "$WORKDIR/core.sh"; else echo -e "${RED}缺失核心文件 core.sh${PLAIN}"; exit 1; fi
if [ -f "$WORKDIR/sub.sh" ]; then source "$WORKDIR/sub.sh"; fi
if [ -f "$WORKDIR/safety.sh" ]; then source "$WORKDIR/safety.sh"; fi

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 需要 root 权限${PLAIN}" && exit 1

uninstall_all() {
    echo -e "${RED}确定卸载? [y/N]${PLAIN}"; read -p ": " c; [[ "$c" != "y" ]] && return
    stop_service 2>/dev/null; systemctl disable sing-box 2>/dev/null
    rm -f "$SERVICE_FILE" "$SINGBOX_BIN" "$LINK_FILE"; rm -rf "$CONFIG_DIR" "$WORKDIR" "$BACKUP_DIR"
    echo -e "${GREEN}卸载完成${PLAIN}"; exit 0
}

menu() {
    clear
    echo -e "#############################################################"
    echo -e "#            Sing-box 专家面板 (PuerNya Core)               #"
    echo -e "#############################################################"
    check_status
    echo -e "-------------------------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 安装/更新 PuerNya 核心 (支持本地分流)"
    echo -e "${GREEN}2.${PLAIN} 启动服务"
    echo -e "${GREEN}3.${PLAIN} 停止服务"
    echo -e "${GREEN}4.${PLAIN} 重启服务"
    echo -e "${GREEN}5.${PLAIN} 查看日志"
    echo -e "-------------------------------------------------------------"
    echo -e "${YELLOW}6.${PLAIN} 切换模式 (TUN/TProxy)"
    echo -e "${YELLOW}7.${PLAIN} 更新订阅 (Provider + Filter)"
    echo -e "${YELLOW}8.${PLAIN} 编辑模板"
    echo -e "-------------------------------------------------------------"
    echo -e "${CYAN}s.${PLAIN} 开启防断联"; echo -e "${CYAN}c.${PLAIN} 取消防断联"
    echo -e "${RED}9.${PLAIN} 卸载脚本"; echo -e "${RED}0.${PLAIN} 退出"
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
        8) 
           MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
           [[ "$MODE" == "TUN" ]] && vim /etc/sbshell/templates/tun.json || vim /etc/sbshell/templates/tproxy.json
           echo -e "${YELLOW}提示：修改后请运行 [7] 更新配置${PLAIN}" ;;
        s|S) start_safety_timer ;;
        c|C) stop_safety_timer ;;
        9) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
    echo -e ""; read -p "按回车键返回..." ; menu
}
menu