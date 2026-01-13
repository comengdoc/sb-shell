#!/bin/bash

# ==========================================
#  Sing-box 客户端管理主菜单 (menu.sh)
#  功能: 服务管理、模式切换、彻底卸载
# ==========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
CYAN='\033[0;36m'

WORKDIR="/etc/sbshell"
BACKUP_DIR="/root/sb-shell-backups"
LINK_FILE="/usr/local/bin/sbshell"

# --- 1. 加载核心模块 ---
source "$WORKDIR/core.sh"
source "$WORKDIR/sub.sh"

# --- 2. 加载安全模块 (带容错处理) ---
if [ -f "$WORKDIR/safety.sh" ]; then
    source "$WORKDIR/safety.sh"
else
    # 定义空函数防止报错（如果文件丢失）
    start_safety_timer() { echo "错误：safety.sh 丢失"; }
    stop_safety_timer() { echo "错误：safety.sh 丢失"; }
    backup_environment() { echo "错误：safety.sh 丢失"; }
    restore_environment() { echo "错误：safety.sh 丢失"; }
fi

# --- 3. 权限检查 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# --- 4. 定义增强版卸载函数 (覆盖 core.sh 中的旧逻辑) ---
uninstall_all() {
    echo -e "${RED}=================================================${PLAIN}"
    echo -e "${RED}   警告：危险操作！${PLAIN}"
    echo -e "${RED}=================================================${PLAIN}"
    echo -e "此操作将执行以下清理："
    echo -e "1. 停止并删除 Sing-box 系统服务"
    echo -e "2. 删除 Sing-box 核心程序"
    echo -e "3. 删除所有配置文件 (/etc/sing-box)"
    echo -e "4. 删除脚本安装目录 ($WORKDIR)"
    echo -e "5. 删除 'sbshell' 快捷命令"
    echo -e "6. 删除所有网络备份文件 ($BACKUP_DIR)"
    echo -e ""
    read -p "确定要彻底卸载吗? [y/N]: " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "操作已取消。"
        return
    fi

    echo -e "${YELLOW}正在停止服务...${PLAIN}"
    stop_service 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    
    echo -e "${YELLOW}正在清理文件...${PLAIN}"
    
    # 删除服务文件
    [ -f "$SERVICE_FILE" ] && rm -f "$SERVICE_FILE" && echo " - 服务文件已删除"
    
    # 删除二进制文件
    [ -f "$SINGBOX_BIN" ] && rm -f "$SINGBOX_BIN" && echo " - 核心程序已删除"
    
    # 删除配置文件目录
    [ -d "$CONFIG_DIR" ] && rm -rf "$CONFIG_DIR" && echo " - 配置目录已删除"
    
    # 删除脚本工作目录
    [ -d "$WORKDIR" ] && rm -rf "$WORKDIR" && echo " - 脚本目录已删除"
    
    # [新增] 删除快捷命令软链接
    [ -L "$LINK_FILE" ] || [ -f "$LINK_FILE" ] && rm -f "$LINK_FILE" && echo " - 快捷命令已删除"
    
    # [新增] 删除安全备份目录
    [ -d "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR" && echo " - 备份文件已删除"

    # 重载系统服务守护进程
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成！系统已恢复纯净。${PLAIN}"
    echo -e "程序即将退出..."
    exit 0
}

# --- 5. 主菜单逻辑 ---
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
    echo -e "${CYAN}s.${PLAIN} 🛡️  开启防断联保护 (危险操作前必点!)"
    echo -e "${CYAN}c.${PLAIN} ✅  取消防断联重启 (配置成功后点)"
    echo -e "${CYAN}b.${PLAIN} 📦  手动备份网络配置"
    echo -e "${RED}r.${PLAIN} 🚑  紧急恢复网络备份 (救砖用)"
    echo -e "-------------------------------------------------------------"
    echo -e "${RED}9.${PLAIN} 彻底卸载脚本与服务"
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
        
        # 安全功能
        s|S) start_safety_timer ;;
        c|C) stop_safety_timer ;;
        b|B) backup_environment ;;
        r|R) restore_environment ;;
        
        9) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入正确的选项！${PLAIN}" ;;
    esac
    
    echo -e ""
    read -p "按回车键返回菜单..." 
    menu
}

# 启动菜单
menu