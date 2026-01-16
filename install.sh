#!/bin/bash

# ==========================================
#  Sing-box Shell 安装脚本 (官方核心版)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# !!! 注意：请修改为你存放修改后脚本的仓库地址 !!!
REPO_URL="https://raw.githubusercontent.com/your-repo/sb-shell-official/main"
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

# 3. 下载文件 (如果不使用远程下载，请手动将上述脚本复制到 $INSTALL_DIR)
# download_file() { ... } 
# 此处逻辑取决于你如何分发这些新脚本。
# 如果是本地直接运行，只需确保上述文件都在 /etc/sbshell/ 下并赋予执行权限。

# 建立软链接
rm -f "$BIN_LINK"
ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"
chmod +x "$INSTALL_DIR/"*.sh
chmod +x "$BIN_LINK"

echo -e "\n${GREEN}安装环境准备就绪！${PLAIN}"
echo -e "1. 请确保 core.sh, menu.sh, sub.sh, safety.sh 已放入 $INSTALL_DIR"
echo -e "2. 请确保 templates/ 目录下有 tun.json 和 tproxy.json 模板"
echo -e "3. 输入 ${GREEN}sbshell${PLAIN} 启动菜单"
echo -e "4. 在菜单中选择 [1] 安装官方核心"