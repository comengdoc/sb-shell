#!/bin/bash

# ==========================================
#  Sing-box Shell 安装脚本 (Dual Core)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

INSTALL_DIR="/etc/sbshell"
BIN_LINK="/usr/local/bin/sbshell"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户${PLAIN}" && exit 1

echo -e "${GREEN}正在开始安装...${PLAIN}"

# 1. 安装依赖
echo -e "${YELLOW}安装系统依赖...${PLAIN}"
if command -v apt-get >/dev/null; then apt-get update -y && apt-get install -y curl wget tar jq nftables; elif command -v apk >/dev/null; then apk add curl wget tar jq nftables; fi

# 2. 创建目录
echo -e "${YELLOW}创建目录结构...${PLAIN}"
mkdir -p "$INSTALL_DIR/templates"
mkdir -p "$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/providers"

# 3. 提示
echo -e "\n${GREEN}安装环境准备就绪！${PLAIN}"
echo -e "1. 请将 core.sh, menu.sh, sub.sh, safety.sh 放入 $INSTALL_DIR"
echo -e "2. 确保 templates/ 目录下有 tun.json"
echo -e "3. 建立链接: ln -s $INSTALL_DIR/menu.sh /usr/local/bin/sbshell && chmod +x /usr/local/bin/sbshell"
echo -e "4. 输入 ${GREEN}sbshell${PLAIN} 启动菜单，选择 [1] 安装核心 (Official 或 Ref1nd)"

# 自动建立链接 (如果在本地运行)
if [ -f "$INSTALL_DIR/menu.sh" ]; then
    rm -f "$BIN_LINK"
    ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"
    chmod +x "$INSTALL_DIR/"*.sh
    chmod +x "$BIN_LINK"
    echo -e "${GREEN}快捷命令 'sbshell' 已创建。${PLAIN}"
fi