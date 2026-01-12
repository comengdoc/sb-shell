#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 定义路径
INSTALL_DIR="/etc/sbshell"
BIN_LINK="/usr/local/bin/sbshell"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo "请使用 root 运行此脚本" && exit 1

echo -e "${GREEN}正在安装/更新 sbshell...${PLAIN}"

# --- [新增] 安装前安全备份 ---
if [ -f "./safety.sh" ]; then
    echo -e "${YELLOW}检测到安全模块，正在执行安装前自动备份...${PLAIN}"
    source ./safety.sh
    # 调用 safety.sh 中的备份函数
    backup_environment
else
    echo -e "${YELLOW}警告：未找到 safety.sh，跳过自动备份。建议确保该文件存在。${PLAIN}"
fi
# ---------------------------

# 1. 创建安装目录
mkdir -p "$INSTALL_DIR/templates"
mkdir -p "$INSTALL_DIR/logs"

# 2. 复制脚本文件 (强制覆盖)
# 注意：这里增加了 safety.sh 的复制
cp -f menu.sh core.sh sub.sh safety.sh "$INSTALL_DIR/"
cp -f templates/*.json "$INSTALL_DIR/templates/"

# 3. 赋予执行权限
chmod +x "$INSTALL_DIR"/*.sh

# 4. 创建系统软连接 (让你可以直接输入 sbshell 运行)
rm -f "$BIN_LINK"
ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"

echo -e "${GREEN}安装完成！${PLAIN}"
echo -e "请在终端输入 ${GREEN}sbshell${PLAIN} 启动管理面板。"