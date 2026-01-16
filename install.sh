#!/bin/bash

# ==========================================
#  Sing-box Shell 安装脚本 (PuerNya 专版)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

REPO_URL="https://raw.githubusercontent.com/comengdoc/sb-shell/main"
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
mkdir -p "$INSTALL_DIR/ui"
mkdir -p "$INSTALL_DIR/providers" # 必须存在

# 3. 下载文件
download_file() {
    local url="${REPO_URL}/$1"; local path="$2"
    echo -n "下载 $1 ... "
    if curl -sL --retry 3 --connect-timeout 10 -f "$url" -o "$path"; then
        echo -e "${GREEN}[OK]${PLAIN}"; [[ "$path" == *.sh ]] && chmod +x "$path"
    else
        echo -e "${RED}[Error]${PLAIN}"; exit 1
    fi
}

download_file "menu.sh"   "$INSTALL_DIR/menu.sh"
download_file "core.sh"   "$INSTALL_DIR/core.sh"
download_file "sub.sh"    "$INSTALL_DIR/sub.sh"
download_file "safety.sh" "$INSTALL_DIR/safety.sh"
download_file "templates/tun.json"    "$INSTALL_DIR/templates/tun.json"
download_file "templates/tproxy.json" "$INSTALL_DIR/templates/tproxy.json"

rm -f "$BIN_LINK"
ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"
chmod +x "$BIN_LINK"

# 清理旧标记
rm -f "$INSTALL_DIR/.version_tag"

echo -e "\n${GREEN}安装成功！${PLAIN}"
echo -e "1. 输入 ${GREEN}sbshell${PLAIN} 启动"
echo -e "2. 请先运行 [1. 安装 PuerNya 核心]"
echo -e "3. 再运行 [7. 更新订阅]"