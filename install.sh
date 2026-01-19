#!/bin/bash

# ==========================================
#  Sing-box Shell 全自动安装脚本
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

INSTALL_DIR="/etc/sbshell"
BIN_LINK="/usr/local/bin/sbshell"

# --- 关键修改 1: 定义你的仓库地址 ---
# 请将下面这个地址换成你实际存放脚本的 GitHub Raw 地址
REPO_URL="https://raw.githubusercontent.com/comengdoc/sb-shell/main"
# ----------------------------------

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户${PLAIN}" && exit 1

echo -e "${GREEN}正在开始全自动安装...${PLAIN}"

# 1. 安装依赖
echo -e "${YELLOW}1. 安装系统依赖...${PLAIN}"
if command -v apt-get >/dev/null; then 
    apt-get update -y && apt-get install -y curl wget tar jq nftables
elif command -v apk >/dev/null; then 
    apk add curl wget tar jq nftables
elif command -v yum >/dev/null; then
    yum install -y curl wget tar nftables jq
fi

# 2. 创建目录
echo -e "${YELLOW}2. 创建目录结构...${PLAIN}"
mkdir -p "$INSTALL_DIR/templates"
mkdir -p "$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/providers"

# 3. 自动下载文件 (关键修改部分)
echo -e "${YELLOW}3. 正在从远程仓库下载脚本...${PLAIN}"

download_file() {
    local url="$1"
    local dest="$2"
    local filename="$3"
    
    echo -e "正在下载 $filename ..."
    wget -q --no-check-certificate -O "$dest/$filename" "$url/$filename"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 $filename 失败！请检查网络或 URL。${PLAIN}"
        exit 1
    fi
}

# 下载核心脚本到 /etc/sbshell
download_file "$REPO_URL" "$INSTALL_DIR" "core.sh"
download_file "$REPO_URL" "$INSTALL_DIR" "menu.sh"
download_file "$REPO_URL" "$INSTALL_DIR" "sub.sh"
download_file "$REPO_URL" "$INSTALL_DIR" "safety.sh"

# 下载模板文件到 /etc/sbshell/templates
# 注意：确保你仓库里的文件名叫 tun.json 和 tproxy.json
download_file "$REPO_URL/templates" "$INSTALL_DIR/templates" "tun.json"
download_file "$REPO_URL/templates" "$INSTALL_DIR/templates" "tproxy.json"

# 4. 自动赋权与链接
echo -e "${YELLOW}4. 设置权限与快捷方式...${PLAIN}"
chmod +x "$INSTALL_DIR/"*.sh

rm -f "$BIN_LINK"
ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"
chmod +x "$BIN_LINK"

# 5. 完成
echo -e "\n${GREEN}======================================${PLAIN}"
echo -e "${GREEN}  安装成功！  ${PLAIN}"
echo -e "${GREEN}======================================${PLAIN}"
echo -e "输入 ${GREEN}sbshell${PLAIN} 即可启动管理面板"