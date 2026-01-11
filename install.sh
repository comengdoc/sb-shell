#!/bin/bash

# 定义路径
INSTALL_DIR="/etc/sbshell"
BIN_LINK="/usr/local/bin/sbshell"
REPO_URL="https://raw.githubusercontent.com/comengdoc/sb-shell/main"

# 检查 root
[[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1

echo "正在安装依赖..."
apt-get update && apt-get install -y curl wget

echo "准备安装目录..."
mkdir -p "$INSTALL_DIR/templates"
mkdir -p "$INSTALL_DIR/logs"

echo "正在从 GitHub 拉取最新脚本..."
# 这里改成下载，而不是 cp
wget -O "$INSTALL_DIR/menu.sh" "$REPO_URL/menu.sh"
wget -O "$INSTALL_DIR/core.sh" "$REPO_URL/core.sh"
wget -O "$INSTALL_DIR/sub.sh" "$REPO_URL/sub.sh"
wget -O "$INSTALL_DIR/templates/tun.json" "$REPO_URL/templates/tun.json"
wget -O "$INSTALL_DIR/templates/tproxy.json" "$REPO_URL/templates/tproxy.json"

# 赋予权限
chmod +x "$INSTALL_DIR"/*.sh

# 创建软连接
rm -f "$BIN_LINK"
ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"

echo "安装完成！请输入 sbshell 使用。"