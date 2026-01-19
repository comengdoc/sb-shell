#!/bin/bash

# ==========================================
#  Sing-box 订阅管理 (修复拼接逻辑版)
# ==========================================

WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
SINGBOX_BIN="/usr/local/bin/sing-box"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查环境
check_env() {
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}错误: 未找到 curl，请安装。${PLAIN}"
        exit 1
    fi
    mkdir -p "$WORKDIR"
}

update_subscription() {
    check_env
    
    echo -e "${GREEN}=== 开始构建 Sing-box 配置 ===${PLAIN}"

    # --- 1. 交互输入：转换后端地址 (根路径) ---
    # 读取历史记录
    PREV_BACKEND=$(cat "$WORKDIR/.backend_url" 2>/dev/null)
    # 默认值只给到端口，不带 /config，由脚本自动处理
    DEFAULT_BACKEND="http://127.0.0.1:5000"
    
    echo -e "${YELLOW}1. 请输入 Sing-box 转换服务后端地址 (根域名/IP:端口):${PLAIN}"
    echo -e "   (例如: http://192.168.1.5:5000 或 https://singbox.example.com)"
    
    if [[ -n "$PREV_BACKEND" ]]; then
        read -p "   地址 [回车保持: $PREV_BACKEND]: " INPUT_BACKEND
        BACKEND_URL="${INPUT_BACKEND:-$PREV_BACKEND}"
    else
        read -p "   地址 [回车默认: $DEFAULT_BACKEND]: " INPUT_BACKEND
        BACKEND_URL="${INPUT_BACKEND:-$DEFAULT_BACKEND}"
    fi
    
    # 移除末尾的斜杠 (如果有)
    BACKEND_URL=${BACKEND_URL%/}
    # 移除末尾可能误输入的 /config (为了统一处理)
    BACKEND_URL=${BACKEND_URL%/config}
    
    echo "$BACKEND_URL" > "$WORKDIR/.backend_url"


    # --- 2. 交互输入：机场订阅链接 ---
    PREV_SUB=$(cat "$WORKDIR/.sub_url" 2>/dev/null)
    
    echo -e "\n${YELLOW}2. 请输入机场订阅链接 (支持多个，用 | 分隔):${PLAIN}"
    
    if [[ -n "$PREV_SUB" ]]; then
        read -p "   链接 [回车保持: ${PREV_SUB:0:25}...]: " INPUT_SUB
        SUB_URL="${INPUT_SUB:-$PREV_SUB}"
    else
        read -p "   链接: " INPUT_SUB
        SUB_URL="$INPUT_SUB"
    fi

    if [[ -z "$SUB_URL" ]]; then
        echo -e "${RED}错误: 订阅链接不能为空！${PLAIN}"
        return
    fi
    echo "$SUB_URL" > "$WORKDIR/.sub_url"


    # --- 3. 交互输入：规则模板地址 ---
    PREV_TPL=$(cat "$WORKDIR/.tpl_url" 2>/dev/null)
    DEFAULT_TPL="https://github.com/Toperlock/sing-box-subscribe/raw/main/config_template/config_template_groups_tun.json"

    echo -e "\n${YELLOW}3. 请输入规则模板链接 (HTTP URL 或 Docker 容器内绝对路径):${PLAIN}"
    
    if [[ -n "$PREV_TPL" ]]; then
        read -p "   模板 [回车保持: ${PREV_TPL:0:25}...]: " INPUT_TPL
        TPL_URL="${INPUT_TPL:-$PREV_TPL}"
    else
        read -p "   模板 [回车默认: Toperlock-TUN版]: " INPUT_TPL
        TPL_URL="${INPUT_TPL:-$DEFAULT_TPL}"
    fi
    echo "$TPL_URL" > "$WORKDIR/.tpl_url"


    # --- 4. 拼接请求并下载 ---
    echo -e "\n${GREEN}正在请求转换服务...${PLAIN}"
    
    # 修正后的 URL 拼接逻辑：
    # 强制添加 /config/ 路径，并使用 &file= 参数
    TARGET_URL="${BACKEND_URL}/config/${SUB_URL}&file=${TPL_URL}"
    
    echo -e "请求地址: $TARGET_URL"
    
    TMP_CONFIG="$CONFIG_FILE.tmp"
    
    # 下载配置 (-g 参数允许 URL 中包含大括号等特殊字符，虽这里主要防 & 截断但 curl 默认 url 不需转义 &)
    # 必须加引号 "$TARGET_URL" 防止 shell 解析 & 符号
    curl -L -s --fail -o "$TMP_CONFIG" "$TARGET_URL"
    
    if [[ $? -ne 0 ]] || [[ ! -s "$TMP_CONFIG" ]]; then
        echo -e "${RED}下载失败！${PLAIN}"
        echo -e "可能原因："
        echo -e "1. 后端地址无法连接"
        echo -e "2. URL 拼接错误 (请检查上方打印的请求地址)"
        rm -f "$TMP_CONFIG"
        return
    fi


    # --- 5. 校验与重启 ---
    echo -e "${YELLOW}正在校验配置完整性...${PLAIN}"
    
    if "$SINGBOX_BIN" check -c "$TMP_CONFIG" >/dev/null 2>&1; then
        mv "$TMP_CONFIG" "$CONFIG_FILE"
        systemctl restart sing-box
        echo -e "${GREEN}配置更新成功！Sing-box 已重启。${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "后端: $BACKEND_URL"
        echo -e "订阅: ${SUB_URL:0:20}..."
        echo -e "------------------------------------------------"
    else
        echo -e "${RED}配置校验失败！${PLAIN}"
        echo -e "错误详情："
        "$SINGBOX_BIN" check -c "$TMP_CONFIG"
    fi
}