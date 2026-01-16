#!/bin/bash
WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"
PREF_FILE="$WORKDIR/.interface_pref"
VERSION_TAG_FILE="$WORKDIR/.version_tag"

# 依赖检查
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "正在安装 jq..."
        if command -v apt-get >/dev/null; then apt-get update -y && apt-get install -y jq; else apk add jq; fi
    fi
}

# URL 编码函数 (用于后端转换)
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

# 核心订阅更新
update_subscription() {
    check_jq
    
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    [[ "$MODE" == "TUN" ]] && LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json" || LOCAL_TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then
        echo -e "\033[31m错误: 找不到模板 $LOCAL_TEMPLATE\033[0m"; return
    fi

    # 1. 识别核心能力
    CORE_TAG=$(cat "$VERSION_TAG_FILE" 2>/dev/null)
    USE_ADVANCED_MODE=false

    # 逻辑：reF1nd (v1.9+) 和 Puer 都支持 outbound_providers。
    # 只有旧版官方或明确不支持的版本才降级。
    if [[ "$CORE_TAG" =~ "reF1nd" ]] || [[ "$CORE_TAG" =~ "Puer" ]] || [[ "$CORE_TAG" =~ "Dev" ]]; then
        USE_ADVANCED_MODE=true
        echo -e "\033[32m检测到高性能核心 ($CORE_TAG)：已启用 Provider 订阅模式。\033[0m"
    else
        # 兜底逻辑：虽然新版官方也支持，但为了保险起见，如果是非 reF1nd/Puer，我们假设用户可能用的是旧版
        # 如果你确认你用的官方版也是 v1.10+，可以强制改这里，但对 reF1nd 用户来说，上面的 if 已经够了。
        USE_ADVANCED_MODE=false 
        echo -e "\033[33m检测到普通核心 ($CORE_TAG)：启用兼容模式 (无动态 Provider)。\033[0m"
    fi

    # 2. 获取订阅链接与后端处理
    FINAL_URL=""
    if [ "$USE_ADVANCED_MODE" = true ]; then
        PREV_BACKEND=""
        [ -f "$WORKDIR/.backend_url" ] && PREV_BACKEND=$(cat "$WORKDIR/.backend_url")
        
        echo -e "\033[36m请输入后端转换地址 (例如 https://api.v1.mk)\033[0m"
        read -p "地址 [回车保持: ${PREV_BACKEND}]: " BACKEND_INPUT
        [ -n "$BACKEND_INPUT" ] && BACKEND_URL="$BACKEND_INPUT" || BACKEND_URL="$PREV_BACKEND"
        
        # 去除末尾斜杠
        BACKEND_URL=${BACKEND_URL%/}
        [ -n "$BACKEND_URL" ] && echo "$BACKEND_URL" > "$WORKDIR/.backend_url"

        read -p "请输入机场订阅链接: " SUB_URL
        
        if [[ -n "$SUB_URL" ]]; then
            if [[ -n "$BACKEND_URL" ]]; then
                echo "正在通过后端转换链接..."
                ENCODED_SUB=$(urlencode "$SUB_URL")
                # 构造标准 Sing-box 订阅链接
                FINAL_URL="${BACKEND_URL}/config/${ENCODED_SUB}&file=https://raw.githubusercontent.com/acl4ssr/acl4ssr/master/Clash/config/ACL4SSR_Online_Full.ini"
            else
                # 无后端，假定用户给的就是 JSON
                FINAL_URL="$SUB_URL"
            fi
        fi
    fi

    # 3. 处理网卡绑定
    CURRENT_PREF=$(cat "$PREF_FILE" 2>/dev/null)
    MANUAL_IF="$CURRENT_PREF"
    if [[ -z "$MANUAL_IF" ]]; then
        # 简单自动检测
        MANUAL_IF="" 
    fi

    echo "正在生成配置..."

    if [ "$USE_ADVANCED_MODE" = true ]; then
        # === 高级模式 (reF1nd 专用) ===
        # 注入 providers，保留 filter，并把 selector 指向 provider
        
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

    else
        # === 兼容模式 (删除不支持的字段) ===
        jq --arg iface "$MANUAL_IF" 'del(.outbound_providers) | del(.outbounds[].filter) | del(.outbounds[].providers) | .outbounds |= map(if .type == "direct" and $iface != "" then . + { "bind_interface": $iface } else . end)' "$LOCAL_TEMPLATE" > "$CONFIG_FILE"
    fi

    # 4. 验证与重启
    if [[ $? -eq 0 ]]; then
        if "$SINGBOX_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
            systemctl restart sing-box
            echo -e "\033[32m配置更新成功！服务已重启。\033[0m"
        else
            echo -e "\033[31m配置校验失败！可能是转换后的 JSON 格式错误或网络问题。\033[0m"
            "$SINGBOX_BIN" check -c "$CONFIG_FILE"
        fi
    else
        echo -e "\033[31mJQ 处理失败。\033[0m"
    fi
}