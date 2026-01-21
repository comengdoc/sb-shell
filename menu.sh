#!/bin/bash

# ==========================================
#  Sing-box 专家面板 (TProxy Dedicated)
# ==========================================

# 1. 基础定位 (用于寻找核心文件)
WORKDIR="/etc/sbshell"

# 2. 加载核心 (核心文件是"单点真理"，包含了颜色、路径和通用函数)
if [ -f "$WORKDIR/core_tproxy.sh" ]; then 
    source "$WORKDIR/core_tproxy.sh"
else 
    echo -e "\033[0;31m缺失核心文件 core_tproxy.sh\033[0m"
    exit 1
fi

# 3. 加载扩展模块 (简化写法)
[ -f "$WORKDIR/sub.sh" ] && source "$WORKDIR/sub.sh"
[ -f "$WORKDIR/safety.sh" ] && source "$WORKDIR/safety.sh"

# 4. 定义仅 Menu 使用的变量
LINK_FILE="/usr/local/bin/sbshell"
BACKUP_DIR="/root/sb-shell-backups"

# 检查 Root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 需要 root 权限${PLAIN}" && exit 1

uninstall_all() {
    echo -e "${RED}确定卸载所有组件? [y/N]${PLAIN}"; read -p ": " c; [[ "$c" != "y" ]] && return
    # stop_service 来自 core_tproxy.sh
    stop_service 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f "$SERVICE_FILE" "$SINGBOX_BIN" "$LINK_FILE"
    rm -rf "$CONFIG_DIR" "$WORKDIR" "$BACKUP_DIR"
    echo -e "${GREEN}卸载完成${PLAIN}"; exit 0
}

install_menu() {
    echo -e "-------------------------------------------------------------"
    echo -e "请选择要安装的内核版本："
    echo -e "${GREEN}1.${PLAIN} Official (官方稳定版 - SagerNet)"
    echo -e "${GREEN}2.${PLAIN} Ref1nd   (社区优化版 - 推荐)"
    echo -e "-------------------------------------------------------------"
    read -p "选择: " ins_opt
    case "$ins_opt" in
        1) install_official ;;
        2) install_ref1nd ;;
        *) echo -e "${RED}取消安装${PLAIN}" ;;
    esac
}

menu() {
    clear
    echo -e "#############################################################"
    echo -e "#        Sing-box TProxy 专用面板 (Armbian/Linux)           #"
    echo -e "#############################################################"
    check_status
    echo -e "-------------------------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 安装/切换 核心版本 (Official/Ref1nd)"
    echo -e "${GREEN}2.${PLAIN} 启动服务"
    echo -e "${GREEN}3.${PLAIN} 停止服务"
    echo -e "${GREEN}4.${PLAIN} 重启服务"
    echo -e "${GREEN}5.${PLAIN} 查看日志"
    echo -e "-------------------------------------------------------------"
    echo -e "${YELLOW}6.${PLAIN} 更新订阅 (使用 tproxy.json 模板)"
    echo -e "${YELLOW}7.${PLAIN} 编辑本地模板 (tproxy.json)"
    echo -e "-------------------------------------------------------------"
    echo -e "${CYAN}s.${PLAIN} 开启防断联 (安全模式)"; echo -e "${CYAN}c.${PLAIN} 取消防断联"
    echo -e "${RED}9.${PLAIN} 卸载脚本"; echo -e "${RED}0.${PLAIN} 退出"
    echo -e ""
    read -p " 请输入选项: " num

    case "$num" in
        1) install_menu ;;
        2) start_service ;;
        3) stop_service ;;
        4) restart_service ;;
        5) show_log ;;
        6) update_subscription ;;
        7) 
           # [优化] 使用变量代替硬编码路径
           if [ -f "$WORKDIR/templates/tproxy.json" ]; then
               vim "$WORKDIR/templates/tproxy.json"
               echo -e "${YELLOW}提示：修改后请运行 [6] 更新订阅以重新生成配置${PLAIN}"
           else
               echo -e "${RED}错误：未找到模板文件${PLAIN}"
           fi
           ;;
        s|S) start_safety_timer ;;
        c|C) stop_safety_timer ;;
        9) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
    echo -e ""; read -p "按回车键返回..." ; menu
}
menu