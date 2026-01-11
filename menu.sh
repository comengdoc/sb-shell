#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

WORKDIR="/etc/sbshell"
source "$WORKDIR/core.sh"
source "$WORKDIR/sub.sh"

# 检查是否以root运行
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

menu() {
    clear
    echo -e "#############################################################"
    echo -e "#               Sing-box 客户端管理脚本 (Armbian专版)         #"
    echo -e "#############################################################"
    echo -e ""
    check_status
    echo -e ""
    echo -e "${GREEN}1.${PLAIN} 安装/更新 Sing-box 核心"
    echo -e "${GREEN}2.${PLAIN} 启动服务"
    echo -e "${GREEN}3.${PLAIN} 停止服务"
    echo -e "${GREEN}4.${PLAIN} 重启服务"
    echo -e "${GREEN}5.${PLAIN} 查看实时日志"
    echo -e "-------------------------------------------------------------"
    echo -e "${YELLOW}6.${PLAIN} 切换模式 (当前: $(get_current_mode_display))"
    echo -e "${YELLOW}7.${PLAIN} 更新订阅 / 导入配置"
    echo -e "${YELLOW}8.${PLAIN} 编辑当前配置文件 (vim)"
    echo -e "-------------------------------------------------------------"
    echo -e "${RED}9.${PLAIN} 卸载脚本与服务"
    echo -e "${RED}0.${PLAIN} 退出"
    echo -e ""
    read -p " 请输入数字 [0-9]: " num

    case "$num" in
        1) install_singbox ;;
        2) start_service ;;
        3) stop_service ;;
        4) restart_service ;;
        5) show_log ;;
        6) switch_mode ;;
        7) update_subscription ;;
        8) vim /etc/sing-box/config.json && restart_service ;;
        9) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入正确的数字！${PLAIN}" ;;
    esac
    
    echo -e ""
    read -p "按回车键返回菜单..." 
    menu
}

menu