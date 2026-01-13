#!/bin/bash
WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "正在安装 jq..."
        apt-get update -y && apt-get install -y jq || apk add jq
    fi
}

urlencode() {
    echo -n "$1" | jq -sRr @uri
}

update_subscription() {
    check_jq
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    if [[ "$MODE" == "TUN" ]]; then
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json"
    else
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    fi
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then
        echo -e "\033[31m错误: 找不到模板文件 $LOCAL_TEMPLATE\033[0m"
        return
    fi

    PREV_BACKEND=""
    [ -f "$WORKDIR/.backend_url" ] && PREV_BACKEND=$(cat "$WORKDIR/.backend_url")
    echo "请输入转换后端地址 (如 https://singbox.xxx.xyz)"
    echo "注意: 必须是适配 Sing-box-subscribe 的后端"
    read -p "后端地址 [默认: ${PREV_BACKEND:-无}]: " BACKEND_INPUT
    [ -n "$BACKEND_INPUT" ] && BACKEND_URL="$BACKEND_INPUT" || BACKEND_URL="$PREV_BACKEND"
    # 去除末尾可能存在的斜杠
    BACKEND_URL=${BACKEND_URL%/}
    [ -n "$BACKEND_URL" ] && echo "$BACKEND_URL" > "$WORKDIR/.backend_url"

    read -p "请输入订阅链接 (Sub URL): " SUB_URL
    if [[ -z "$SUB_URL" ]]; then echo "URL不能为空"; return; fi

    DOWNLOAD_TEMP="/tmp/sb_nodes_raw.json"
    FINAL_TEMP="/tmp/sb_config_ready.json"
    rm -f "$DOWNLOAD_TEMP" "$FINAL_TEMP"

    TARGET_URL="$SUB_URL"
    if [[ -n "$BACKEND_URL" ]]; then
        echo "正在构建转换链接 (sing-box-subscribe 格式)..."
        ENCODED_SUB=$(urlencode "$SUB_URL")
        TARGET_URL="${BACKEND_URL}/config/${ENCODED_SUB}"
    fi

    echo -e "请求地址: ${TARGET_URL}"
    echo "正在下载节点..."
    curl -L -k -o "$DOWNLOAD_TEMP" --connect-timeout 15 --max-time 30 "$TARGET_URL"
    
    if [[ $? -ne 0 ]] || [[ ! -s "$DOWNLOAD_TEMP" ]]; then
        echo -e "\033[31m下载失败，请检查网络或后端地址\033[0m"
        rm -f "$DOWNLOAD_TEMP"; return
    fi
    
    # 尝试解析 JSON
    if ! jq -e . "$DOWNLOAD_TEMP" >/dev/null 2>&1; then
        echo -e "\033[31m下载内容不是有效的 JSON！\033[0m"
        echo "后端返回内容预览:"
        head -n 5 "$DOWNLOAD_TEMP"
        rm -f "$DOWNLOAD_TEMP"; return
    fi

    echo "正在合并配置 (本地正则筛选)..."
    
    # === JQ 核心修复：增加了 select() 包装器 ===
    jq -n --slurpfile tpl "$LOCAL_TEMPLATE" --slurpfile remote "$DOWNLOAD_TEMP" '
       (if ($remote[0] | type) == "array" then $remote[0] else $remote[0].outbounds end) as $raw_nodes |
       ($raw_nodes | map(select(.type != "selector" and .type != "urltest" and .type != "direct" and .type != "block" and .type != "dns"))) as $nodes |
       
       ($tpl[0].outbounds | map(
           if .type == "selector" or .type == "urltest" then
               if .filter then
                   . as $group |
                   # 修复点：这里增加了 select(...)，确保 $matches 是节点对象数组，而不是布尔值数组
                   ($nodes | map(select(
                       . as $node |
                       (if ($group.filter | map(select(.action == "include")) | length) > 0 then
                           ($group.filter | map(select(.action == "include")) | any(.keywords[] as $k | ($node.tag | test($k; "i"))))
                       else true end)
                       and
                       (if ($group.filter | map(select(.action == "exclude")) | length) > 0 then
                           ($group.filter | map(select(.action == "exclude")) | any(.keywords[] as $k | ($node.tag | test($k; "i"))) | not)
                       else true end)
                   ))) as $matches |
                   
                   {
                       tag: $group.tag,
                       type: $group.type,
                       outbounds: (if ($matches | length) > 0 then ($matches | map(.tag)) else ["➡️ 直连"] end)
                   } 
                   + (if $group.interval then {interval: $group.interval} else {} end)
                   + (if $group.tolerance then {tolerance: $group.tolerance} else {} end)
                   + (if $group.strategy then {strategy: $group.strategy} else {} end)
               else . end
           else . end
       )) as $processed_groups |
       {
           log: $tpl[0].log, dns: $tpl[0].dns, inbounds: $tpl[0].inbounds, 
           route: $tpl[0].route, experimental: $tpl[0].experimental, 
           outbounds: ($processed_groups + $nodes)
       }
       ' > "$FINAL_TEMP"

    if [[ $? -eq 0 ]]; then
        cp "$FINAL_TEMP" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        rm -f "$DOWNLOAD_TEMP" "$FINAL_TEMP"
        echo -e "\033[32m配置更新成功！正在重启服务...\033[0m"
        systemctl restart sing-box
        echo -e "\033[32m服务已重启\033[0m"
    else
        echo -e "\033[31m配置生成失败 (JQ Error)\033[0m"
        echo "保留临时文件以供检查: $DOWNLOAD_TEMP"
    fi
}