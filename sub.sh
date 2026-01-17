#!/bin/bash
WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"
PREF_FILE="$WORKDIR/.interface_pref"
SINGBOX_BIN="/usr/local/bin/sing-box"

check_jq() { if ! command -v jq &> /dev/null; then apt-get install -y jq || apk add jq; fi; }
urlencode() {
    local length="${#1}"; for (( i = 0; i < length; i++ )); do local c="${1:i:1}"; case $c in [a-zA-Z0-9.~_-]) printf "$c" ;; *) printf '%%%02X' "'$c" ;; esac; done
}

update_subscription() {
    check_jq
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    [[ "$MODE" == "TUN" ]] && LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json" || LOCAL_TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    
    # 兼容性检查：如果 tproxy.json 不存在，回退到 tun.json
    if [[ ! -f "$LOCAL_TEMPLATE" ]] && [[ "$MODE" == "TPROXY" ]]; then
        echo -e "\033[33m警告: 找不到 tproxy.json，正在尝试使用 tun.json...\033[0m"
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json"
    fi
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then echo -e "\033[31m错误: 找不到模板 $LOCAL_TEMPLATE\033[0m"; return; fi

    PREV_BACKEND=$(cat "$WORKDIR/.backend_url" 2>/dev/null)
    echo -e "\033[36m请输入后端地址 (如 https://api.v1.mk) \033[0m"
    read -p "地址 [回车保持: ${PREV_BACKEND}]: " BACKEND_INPUT
    [ -n "$BACKEND_INPUT" ] && BACKEND_URL="$BACKEND_INPUT" || BACKEND_URL="$PREV_BACKEND"
    BACKEND_URL=${BACKEND_URL%/}
    [ -n "$BACKEND_URL" ] && echo "$BACKEND_URL" > "$WORKDIR/.backend_url"

    read -p "请输入机场订阅链接: " SUB_URL
    
    if [[ -n "$SUB_URL" ]]; then
        if [[ -n "$BACKEND_URL" ]]; then
            echo "正在请求后端..."
            ENCODED_SUB=$(urlencode "$SUB_URL")
            # 使用 ACL4SSR 规则进行转换
            FINAL_URL="${BACKEND_URL}/config/${ENCODED_SUB}&file=https://raw.githubusercontent.com/acl4ssr/acl4ssr/master/Clash/config/ACL4SSR_Online_Full.ini"
        else
            FINAL_URL="$SUB_URL"
        fi
    fi

    CURRENT_PREF=$(cat "$PREF_FILE" 2>/dev/null)
    MANUAL_IF=${CURRENT_PREF:-""}

    echo "正在生成配置..."

    if [[ -z "$FINAL_URL" ]]; then
         jq --arg iface "$MANUAL_IF" '.outbounds |= map(if .type == "direct" and $iface != "" then . + { "bind_interface": $iface } else . end)' "$LOCAL_TEMPLATE" > "$CONFIG_FILE"
    else
         # 基于 tun.json 结构注入 remote provider
         jq --arg url "$FINAL_URL" --arg iface "$MANUAL_IF" '
           .outbound_providers = [
             {
               "tag": "my_subscription",
               "type": "remote",
               "download_url": $url,
               "path": "./providers/proxy.json",
               "download_interval": "24h",
               "download_ua": "sing-box",
               "includes": [] 
             }
           ] |
           .outbounds |= map(
             if .type == "direct" and $iface != "" then
                . + { "bind_interface": $iface }
             else . end
           )
        ' "$LOCAL_TEMPLATE" > "$CONFIG_FILE"
    fi

    if "$SINGBOX_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        systemctl restart sing-box
        echo -e "\033[32m配置更新成功！\033[0m"
    else
        echo -e "\033[31m配置校验失败！可能是后端返回的 JSON 格式 Sing-box 无法解析。\033[0m"
        "$SINGBOX_BIN" check -c "$CONFIG_FILE"
    fi
}