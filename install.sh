#!/bin/bash

# ==========================================
#  Sing-box Shell 在线安装脚本 (适配版)
# ==========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# !!! 关键设置 !!!
# 请确保此 URL 指向存放 menu.sh, core.sh, sub.sh 等文件的仓库根目录
# 建议在上传到 Github 后，检查 raw 链接是否可访问
REPO_URL="https://raw.githubusercontent.com/comengdoc/sb-shell/main"

# 定义安装路径
INSTALL_DIR="/etc/sbshell"
BIN_LINK="/usr/local/bin/sbshell"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

echo -e "${GREEN}正在开始在线安装 sbshell...${PLAIN}"

# 1. 安装全套依赖 (新增 nftables 用于 TProxy)
echo -e "${YELLOW}检查并安装系统依赖 (curl, wget, tar, jq, nftables)...${PLAIN}"
if command -v apt-get >/dev/null; then
    apt-get update -y && apt-get install -y curl wget tar jq nftables
elif command -v yum >/dev/null; then
    yum install -y curl wget tar jq nftables
elif command -v apk >/dev/null; then
    apk add curl wget tar jq nftables
fi

# 2. 创建完整的目录结构 (适配新版配置)
echo -e "${YELLOW}正在创建目录结构...${PLAIN}"
mkdir -p "$INSTALL_DIR/templates"
mkdir -p "$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/ui"
# [关键修改] 创建 providers 目录，防止订阅下载失败
mkdir -p "$INSTALL_DIR/providers" 

# 3. 定义通用下载函数
download_file() {
    local remote_path=$1
    local local_path=$2
    local url="${REPO_URL}/${remote_path}"
    
    echo -n "正在下载 ${remote_path} ... "
    
    # 增加 --retry 和 --connect-timeout 提高由于网络波动的成功率
    if curl -sL --retry 3 --connect-timeout 10 -f "$url" -o "$local_path"; then
        echo -e "${GREEN}[OK]${PLAIN}"
        # 如果是 .sh 文件，自动赋予执行权限
        if [[ "$local_path" == *.sh ]]; then
            chmod +x "$local_path"
        fi
    else
        echo -e "${RED}[Failed]${PLAIN}"
        echo -e "${RED}错误: 无法下载 $url${PLAIN}"
        echo -e "${RED}可能原因: 1. 仓库地址错误 2. 文件未上传 3. GitHub 网络连接问题${PLAIN}"
        exit 1
    fi
}

# 4. 开始下载文件
# 确保你已经把 core.sh, sub.sh, menu.sh, safety.sh 上传到了仓库根目录
download_file "menu.sh"   "$INSTALL_DIR/menu.sh"
download_file "core.sh"   "$INSTALL_DIR/core.sh"
download_file "sub.sh"    "$INSTALL_DIR/sub.sh"
download_file "safety.sh" "$INSTALL_DIR/safety.sh"

# 下载模板文件
# 确保你已经把 tun.json, tproxy.json 上传到了仓库的 templates/ 目录下
download_file "templates/tun.json"    "$INSTALL_DIR/templates/tun.json"
download_file "templates/tproxy.json" "$INSTALL_DIR/templates/tproxy.json"

# 5. 创建系统命令软连接
rm -f "$BIN_LINK"
ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"
chmod +x "$BIN_LINK"

# 6. 执行安装后初始化
echo -e "${GREEN}文件下载完成，正在进行初始化检查...${PLAIN}"

# 检查 safety.sh 是否存在并尝试运行备份
if [ -f "$INSTALL_DIR/safety.sh" ]; then
    cd "$INSTALL_DIR" || exit
    # 尝试加载 safety.sh，但不强制退出，防止 safety.sh 有语法错误导致安装中断
    if source ./safety.sh 2>/dev/null; then
        echo -e "${YELLOW}正在执行环境安全备份...${PLAIN}"
        if type backup_environment >/dev/null 2>&1; then
            backup_environment
        else
            echo -e "${YELLOW}提示: safety.sh 中未检测到自动备份函数，跳过。${PLAIN}"
        fi
    else
        echo -e "${YELLOW}提示: safety.sh 加载跳过 (可能是新文件)。${PLAIN}"
    fi
fi

# 清理可能存在的旧版本标记 (如果是重装)
rm -f "$INSTALL_DIR/.version_tag"

echo -e "\n${GREEN}=============================================${PLAIN}"
echo -e "${GREEN}   sbshell 安装成功！(适配 reF1nd/Official)${PLAIN}"
echo -e "${GREEN}=============================================${PLAIN}"
echo -e "1. 输入命令 ${GREEN}sbshell${PLAIN} 即可启动面板"
echo -e "2. 请首先运行面板菜单中的 [1. 安装/更新核心] 以确定核心版本"
echo -e "3. 然后运行 [7. 更新订阅] 填入你的机场链接"
echo -e "${GREEN}=============================================${PLAIN}"