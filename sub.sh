#!/bin/bash
WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"
PREF_FILE="$WORKDIR/.interface_pref"

# 依赖检查
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "正在安装 jq..."
        if command -v apt-get >/dev/null; then apt-get update -y && apt-get install -y jq; else apk add jq; fi
    fi
}

urlencode() {
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

update_subscription() {
    check_jq
    
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    [[ "$MODE" == "TUN" ]] && LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json" || LOCAL_TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then
        echo -e "\033[31m错误: 找不到模板 $LOCAL_TEMPLATE\033[0m"; return
    fi

    echo -e "\033[32m当前核心: PuerNya (默认开启本地分流支持)\033[0m"

    # 获取/输入后端
    PREV_BACKEND=$(cat "$WORKDIR/.backend_url" 2>/dev/null)
    echo -e "\033[36m请输入后端转换地址 (例如 https://api.v1.mk)\033[0m"
    read -p "地址 [回车保持: ${PREV_BACKEND}]: " BACKEND_INPUT
    [ -n "$BACKEND_INPUT" ] && BACKEND_URL="$BACKEND_INPUT" || BACKEND_URL="$PREV_BACKEND"
    BACKEND_URL=${BACKEND_URL%/}
    [ -n "$BACKEND_URL" ] && echo "$BACKEND_URL" > "$WORKDIR/.backend_url"

    read -p "请输入机场订阅链接: " SUB_URL
    FINAL_URL=""
    
    if [[ -n "$SUB_URL" ]]; then
        if [[ -n "$BACKEND_URL" ]]; then
            echo "正在进行后端转换..."
            ENCODED_SUB=$(urlencode "$SUB_URL")
            FINAL_URL="${BACKEND_URL}/config/${ENCODED_SUB}&file=https://raw.githubusercontent.com/acl4ssr/acl4ssr/master/Clash/config/ACL4SSR_Online_Full.ini"
        else
            FINAL_URL="$SUB_URL"
        fi
    fi

    # 确定网卡
    CURRENT_PREF=$(cat "$PREF_FILE" 2>/dev/null)
    MANUAL_IF=${CURRENT_PREF:-""}

    echo "正在生成配置..."

    # === PuerNya 专用生成逻辑 (保留 Filter) ===
    # 核心逻辑：注入 Provider -> 关联 Provider 到 Selector -> 绑定网卡
    if [[ -z "$FINAL_URL" ]]; then
         # 仅刷新网卡，不改订阅
         jq --arg iface "$MANUAL_IF" '.outbounds |= map(if .type == "direct" and $iface != "" then . + { "bind_interface": $iface } else . end)' "$LOCAL_TEMPLATE" > "$CONFIG_FILE"
    else
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
             if .filter then
                . + { "providers": ["my_subscription"] }
             else . end
           ) |
           .outbounds |= map(
             if .type == "direct" and $iface != "" then
                . + { "bind_interface": $iface }
             else . end
           )
        ' "$LOCAL_TEMPLATE" > "$CONFIG_FILE"
    fi

    if [[ $? -eq 0 ]]; then
        if "$SINGBOX_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
            systemctl restart sing-box
            echo -e "\033[32m配置更新成功！服务已重启。\033[0m"
        else
            echo -e "\033[31m配置校验失败！请检查转换后的 JSON 或网络连接。\033[0m"
            "$SINGBOX_BIN" check -c "$CONFIG_FILE"
        fi
    else
        echo -e "\033[31mJQ 处理失败。\033[0m"
    fi
}