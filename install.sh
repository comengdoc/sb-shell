#!/bin/bash

# ==========================================
#  Sing-box Shell 全自动安装脚本 (TProxy版)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

INSTALL_DIR="/etc/sbshell"
BIN_LINK="/usr/local/bin/sbshell"

# 仓库地址
REPO_URL="https://raw.githubusercontent.com/comengdoc/sb-shell/main"

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
mkdir -p "$INSTALL_DIR/templates"
mkdir -p "$INSTALL_DIR/logs"

# 3. 自动下载文件
download_file() {
    local url="$1"
    local dest="$2"
    local filename="$3"
    echo -e "正在下载 $filename ..."
    wget -q --no-check-certificate -O "$dest/$filename" "$url/$filename"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 $filename 失败！${PLAIN}"; exit 1
    fi
}

# 核心脚本 (直接下载 core_tproxy.sh，不再重命名为 core.sh)
download_file "$REPO_URL" "$INSTALL_DIR" "core_tproxy.sh"
download_file "$REPO_URL" "$INSTALL_DIR" "menu.sh"
download_file "$REPO_URL" "$INSTALL_DIR" "sub.sh"
download_file "$REPO_URL" "$INSTALL_DIR" "safety.sh"

# 下载模板 (TProxy 版)
download_file "$REPO_URL/templates" "$INSTALL_DIR/templates" "tproxy.json"

# 4. 设置权限
chmod +x "$INSTALL_DIR/"*.sh
rm -f "$BIN_LINK"
ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"
chmod +x "$BIN_LINK"

echo -e "\n${GREEN}安装成功！输入 sbshell 启动管理面板${PLAIN}"