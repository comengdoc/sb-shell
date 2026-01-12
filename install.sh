#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 定义仓库源 (请确保你的仓库是公开的，或者你有 raw 访问权限)
# 这里指向 main 分支
REPO_URL="https://raw.githubusercontent.com/comengdoc/sb-shell/main"

# 定义本地安装路径
INSTALL_DIR="/etc/sbshell"
BIN_LINK="/usr/local/bin/sbshell"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

echo -e "${GREEN}正在开始在线安装 sbshell...${PLAIN}"

# 1. 安装基础下载工具 (防止纯净系统没有 curl/wget)
echo -e "${YELLOW}检查并安装基础依赖...${PLAIN}"
if command -v apt-get >/dev/null; then
    apt-get update -y && apt-get install -y curl wget tar
elif command -v yum >/dev/null; then
    yum install -y curl wget tar
elif command -v apk >/dev/null; then
    apk add curl wget tar
fi

# 2. 创建目录结构
mkdir -p "$INSTALL_DIR/templates"
mkdir -p "$INSTALL_DIR/logs"

# 3. 定义通用下载函数
# 参数1: 远程文件名 (可以带路径，如 templates/tun.json)
# 参数2: 本地保存文件名 (完整路径)
download_file() {
    local remote_path=$1
    local local_path=$2
    local url="${REPO_URL}/${remote_path}"
    
    echo -n "正在下载 ${remote_path} ... "
    
    # 使用 curl 下载，-s 静默，-L 跟随重定向，-f 失败时不输出内容
    if curl -sL -f "$url" -o "$local_path"; then
        echo -e "${GREEN}[OK]${PLAIN}"
        # 如果是 .sh 文件，赋予执行权限
        if [[ "$local_path" == *.sh ]]; then
            chmod +x "$local_path"
        fi
    else
        echo -e "${RED}[Failed]${PLAIN}"
        echo -e "${RED}错误: 无法下载 $url${PLAIN}"
        echo -e "${RED}请检查: 1. GitHub 连接是否正常 (可能需要代理) 2. 仓库里该文件是否存在${PLAIN}"
        exit 1
    fi
}

# 4. 开始下载文件

# --- 下载根目录的脚本 ---
download_file "menu.sh"   "$INSTALL_DIR/menu.sh"
download_file "core.sh"   "$INSTALL_DIR/core.sh"
download_file "sub.sh"    "$INSTALL_DIR/sub.sh"
download_file "safety.sh" "$INSTALL_DIR/safety.sh"

# --- 下载 templates 目录下的模板 ---
# 注意：远程路径带 templates/，本地保存到 templates/ 目录
download_file "templates/tun.json"    "$INSTALL_DIR/templates/tun.json"
download_file "templates/tproxy.json" "$INSTALL_DIR/templates/tproxy.json"


# 5. 创建系统命令软连接
rm -f "$BIN_LINK"
ln -s "$INSTALL_DIR/menu.sh" "$BIN_LINK"

# 6. 执行安装后初始化 (安全备份)
echo -e "${GREEN}文件下载完成，正在进行初始化...${PLAIN}"

if [ -f "$INSTALL_DIR/safety.sh" ]; then
    echo -e "${YELLOW}执行安装初始备份 (Safety Check)...${PLAIN}"
    # 切换到安装目录执行，确保相对路径正确
    cd "$INSTALL_DIR" || exit
    source ./safety.sh
    
    # 尝试调用备份函数
    if type backup_environment >/dev/null 2>&1; then
        backup_environment
    else
        echo -e "${RED}警告: safety.sh 中未找到 backup_environment 函数，跳过备份。${PLAIN}"
    fi
else
    echo -e "${RED}警告: safety.sh 下载似乎失败，跳过初始化备份。${PLAIN}"
fi

echo -e "\n${GREEN}=============================================${PLAIN}"
echo -e "${GREEN}   sbshell 安装成功！${PLAIN}"
echo -e "${GREEN}=============================================${PLAIN}"
echo -e "请在终端直接输入: ${GREEN}sbshell${PLAIN} 启动管理面板"
echo -e "配置文件位于: ${INSTALL_DIR}"