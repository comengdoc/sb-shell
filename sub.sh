#!/bin/bash

# ==========================================
#  Sing-box 订阅管理 (TProxy 适配版)
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

    # --- 1. 交互输入：转换后端地址 ---
    PREV_BACKEND=$(cat "$WORKDIR/.backend_url" 2>/dev/null)
    DEFAULT_BACKEND="http://127.0.0.1:5000"
    
    echo -e "${YELLOW}1. 请输入 Sing-box 转换服务后端地址:${PLAIN}"
    if [[ -n "$PREV_BACKEND" ]]; then
        read -p "   地址 [回车保持: $PREV_BACKEND]: " INPUT_BACKEND
        BACKEND_URL="${INPUT_BACKEND:-$PREV_BACKEND}"
    else
        read -p "   地址 [回车默认: $DEFAULT_BACKEND]: " INPUT_BACKEND
        BACKEND_URL="${INPUT_BACKEND:-$DEFAULT_BACKEND}"
    fi
    BACKEND_URL=${BACKEND_URL%/}
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
        echo -e "${RED}错误: 订阅链接不能为空！${PLAIN}"; return
    fi
    echo "$SUB_URL" > "$WORKDIR/.sub_url"

    # --- 3. 交互输入：规则模板地址 (关键修改) ---
    PREV_TPL=$(cat "$WORKDIR/.tpl_url" 2>/dev/null)
    
    # [关键] 这里必须换成你自己的 Github Raw 地址！
    # 只有使用你刚才打磨好的 tproxy.json，才能保证不出死循环
    # 请确认这个 URL 是你存放 tproxy.json 的真实地址
    DEFAULT_TPL="https://raw.githubusercontent.com/comengdoc/sb-shell/main/templates/tproxy.json"

    echo -e "\n${YELLOW}3. 请输入规则模板链接 (必须是 TProxy 适配版):${PLAIN}"
    echo -e "   * 警告: 不要使用普通的 TUN 模板，否则会导致死循环断网！"
    
    if [[ -n "$PREV_TPL" ]]; then
        read -p "   模板 [回车保持: ${PREV_TPL:0:25}...]: " INPUT_TPL
        TPL_URL="${INPUT_TPL:-$PREV_TPL}"
    else
        read -p "   模板 [回车默认: 你的Github仓库配置]: " INPUT_TPL
        TPL_URL="${INPUT_TPL:-$DEFAULT_TPL}"
    fi
    echo "$TPL_URL" > "$WORKDIR/.tpl_url"

    # --- 4. 拼接请求并下载 ---
    echo -e "\n${GREEN}正在请求转换服务...${PLAIN}"
    
    # 强制启用 emoji (emoji=1) 和 跳过证书验证 (insecure=1) 也是常见需求
    TARGET_URL="${BACKEND_URL}/config/${SUB_URL}&file=${TPL_URL}"
    
    echo -e "请求地址: $TARGET_URL"
    TMP_CONFIG="$CONFIG_FILE.tmp"
    
    # 使用 curl 下载
    curl -L -s --fail -o "$TMP_CONFIG" "$TARGET_URL"
    
    if [[ $? -ne 0 ]] || [[ ! -s "$TMP_CONFIG" ]]; then
        echo -e "${RED}下载失败！${PLAIN}"; rm -f "$TMP_CONFIG"; return
    fi

    # --- 5. 校验与重启 ---
    echo -e "${YELLOW}正在校验配置完整性...${PLAIN}"
    
    # 这里的校验非常重要，Sing-box 1.12+ 可能会报 WARN，但只要 exit code 是 0 就可以
    if "$SINGBOX_BIN" check -c "$TMP_CONFIG" >/dev/null 2>&1; then
        mv "$TMP_CONFIG" "$CONFIG_FILE"
        systemctl restart sing-box
        echo -e "${GREEN}配置更新成功！Sing-box 已重启。${PLAIN}"
    else
        echo -e "${RED}配置校验失败！详情如下：${PLAIN}"
        "$SINGBOX_BIN" check -c "$TMP_CONFIG"
    fi
}