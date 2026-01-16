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
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then echo -e "\033[31m错误: 找不到模板 $LOCAL_TEMPLATE\033[0m"; return; fi

    PREV_BACKEND=$(cat "$WORKDIR/.backend_url" 2>/dev/null)
    echo -e "\033[36m请输入后端地址 (如 https://api.v1.mk) \033[0m"
    read -p "地址 [回车保持: ${PREV_BACKEND}]: " BACKEND_INPUT
    [ -n "$BACKEND_INPUT" ] && BACKEND_URL="$BACKEND_INPUT" || BACKEND_URL="$PREV_BACKEND"
    BACKEND_URL=${BACKEND_URL%/}
    [ -n "$BACKEND_URL" ] && echo "$BACKEND_URL" > "$WORKDIR/.backend_url"

    read -p "请输入机场订阅链接: " SUB_URL
    
    # 关键逻辑：如果用户使用了后端，我们需要后端输出 sing-box 格式的节点列表，而不是完整配置
    # 我们使用 target=sing-box 配合 list=true (如果有此参数) 或者单纯依赖 outbounds 提取
    if [[ -n "$SUB_URL" ]]; then
        if [[ -n "$BACKEND_URL" ]]; then
            echo "正在请求后端..."
            ENCODED_SUB=$(urlencode "$SUB_URL")
            # 这里的 file 参数使用 ACL4SSR 规则，确保分组匹配
            FINAL_URL="${BACKEND_URL}/config/${ENCODED_SUB}&file=https://raw.githubusercontent.com/acl4ssr/acl4ssr/master/Clash/config/ACL4SSR_Online_Full.ini"
        else
            FINAL_URL="$SUB_URL"
        fi
    fi

    # 获取网卡
    CURRENT_PREF=$(cat "$PREF_FILE" 2>/dev/null)
    MANUAL_IF=${CURRENT_PREF:-""}

    echo "正在生成配置..."

    # 注入逻辑：
    # 1. 将远程订阅作为一个 provider 插入
    # 2. 你的模板已经配置了正则筛选，所以只需要把 provider 放进去即可
    if [[ -z "$FINAL_URL" ]]; then
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