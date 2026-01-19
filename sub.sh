#!/bin/bash

# ==========================================
#  Sing-box 订阅管理 (Sub-Store 专用版)
# ==========================================

WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"
SINGBOX_BIN="/usr/local/bin/sing-box"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查依赖
check_env() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}错误: 未找到 jq，正在尝试安装...${PLAIN}"
        if command -v apt-get >/dev/null; then apt-get install -y jq; elif command -v apk >/dev/null; then apk add jq; fi
    fi
    mkdir -p "$WORKDIR/providers"
}

update_subscription() {
    check_env
    
    # 1. 确定模板模式
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    [[ "$MODE" == "TUN" ]] && LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json" || LOCAL_TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    
    # 容错：如果没有 tproxy 模板，回退到 tun
    if [[ ! -f "$LOCAL_TEMPLATE" ]] && [[ "$MODE" == "TPROXY" ]]; then
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json"
    fi
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then
        echo -e "${RED}致命错误: 找不到模板文件 $LOCAL_TEMPLATE${PLAIN}"
        echo -e "请确保 /etc/sbshell/templates/ 目录下有 tun.json"
        return
    fi

    # 2. 获取/读取 Sub-Store 地址
    PREV_URL=$(cat "$WORKDIR/.substore_url" 2>/dev/null)
    echo -e "${GREEN}当前模式: ${MODE}${PLAIN}"
    echo -e "${YELLOW}请输入 Sub-Store 组合订阅链接 (Sing-box 格式):${PLAIN}"
    echo -e "提示: 建议在 Sub-Store 中勾选 'Output for Sing-box' 或链接末尾带 &target=singbox"
    read -p "链接 [回车保持: ${PREV_URL:0:30}...]: " INPUT_URL

    if [[ -n "$INPUT_URL" ]]; then
        SUB_URL="$INPUT_URL"
        echo "$SUB_URL" > "$WORKDIR/.substore_url"
    else
        SUB_URL="$PREV_URL"
    fi

    if [[ -z "$SUB_URL" ]]; then
        echo -e "${RED}错误: 订阅链接不能为空${PLAIN}"
        return
    fi

    echo -e "${GREEN}正在构建配置...${PLAIN}"

    # 3. 核心逻辑：使用 jq 动态注入 Provider
    # 我们不下载节点文件，而是写入配置让 Sing-box 自己去管理更新
    
    jq --arg url "$SUB_URL" '
        .outbound_providers = [
            {
                "tag": "substore_provider",
                "type": "http",
                "url": $url,
                "path": "./providers/substore_cache.json",
                "download_interval": "60m",
                "download_detour": "🎯 全球直连", 
                "healthcheck_interval": "10m",
                "healthcheck_url": "https://www.gstatic.com/generate_204"
            }
        ]
    ' "$LOCAL_TEMPLATE" > "$CONFIG_FILE.tmp"

    # 4. 自动关联 Selector
    # 检查模板里的 selector 组，强制把 substore_provider 加入到 providers 列表中
    # 这样你就不用手动改模板里的 provider tag 了
    jq '
        .outbounds |= map(
            if .type == "selector" then 
                . + { "providers": ( (.providers // []) + ["substore_provider"] | unique ) }
            else 
                . 
            end
        )
    ' "$CONFIG_FILE.tmp" > "$CONFIG_FILE"
    
    rm -f "$CONFIG_FILE.tmp"

    # 5. 校验与重启
    echo -e "${YELLOW}正在校验配置完整性...${PLAIN}"
    if "$SINGBOX_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        systemctl restart sing-box
        echo -e "${GREEN}配置更新成功！Sing-box 已重启。${PLAIN}"
        echo -e "节点来源: Sub-Store"
        echo -e "更新机制: Sing-box 原生 HTTP Provider (每60分钟自动更新)"
    else
        echo -e "${RED}配置校验失败！${PLAIN}"
        echo -e "可能的错误原因："
        echo -e "1. Sub-Store 链接返回的不是标准的 Sing-box JSON 格式。"
        echo -e "2. 本地模板 tun.json 语法错误。"
        echo -e "3. 详细报错如下："
        "$SINGBOX_BIN" check -c "$CONFIG_FILE"
    fi
}