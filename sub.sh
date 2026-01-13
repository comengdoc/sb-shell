#!/bin/bash
WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"
PREF_FILE="$WORKDIR/.interface_pref"  # 新增：网卡配置记忆文件

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "正在安装 jq..."
        apt-get update -y && apt-get install -y jq || apk add jq
    fi
}

urlencode() {
    echo -n "$1" | jq -sRr @uri
}

# === 新增功能：网卡选择交互 ===
select_interface() {
    CURRENT_PREF=$(cat "$PREF_FILE" 2>/dev/null)
    
    echo -e "----------------------------------------------------"
    if [ -n "$CURRENT_PREF" ]; then
        echo -e "当前网络出口设定: \033[32m手动指定 ($CURRENT_PREF)\033[0m"
    else
        echo -e "当前网络出口设定: \033[32m自动智能检测 (默认)\033[0m"
    fi
    
    echo -e "在多网口/Docker环境下，自动检测可能会失效。"
    read -p "是否需要更改网卡设定? [y/N]: " CHANGE_IF
    
    if [[ "$CHANGE_IF" == "y" ]] || [[ "$CHANGE_IF" == "Y" ]]; then
        echo -e "\n系统可用物理网卡:"
        ls /sys/class/net | grep -v "lo" | grep -v "docker" | grep -v "veth"
        echo -e "----------------------------------------------------"
        read -p "请输入要绑定的网卡名称 (输入 auto 恢复自动): " INPUT_IF
        
        if [[ "$INPUT_IF" == "auto" ]] || [[ -z "$INPUT_IF" ]]; then
            rm -f "$PREF_FILE"
            echo -e "\033[32m已恢复为自动检测模式。\033[0m"
            MANUAL_IF=""
        else
            echo "$INPUT_IF" > "$PREF_FILE"
            echo -e "\033[32m已设定强制出口网卡为: $INPUT_IF\033[0m"
            MANUAL_IF="$INPUT_IF"
        fi
    else
        MANUAL_IF="$CURRENT_PREF"
    fi
    echo -e "----------------------------------------------------"
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

    # 调用网卡选择逻辑
    select_interface

    PREV_BACKEND=""
    [ -f "$WORKDIR/.backend_url" ] && PREV_BACKEND=$(cat "$WORKDIR/.backend_url")
    echo "请输入转换后端地址 (如 https://singbox.xxx.xyz)"
    echo "注意: 必须是适配 Sing-box-subscribe 的后端"
    read -p "后端地址 [默认: ${PREV_BACKEND:-无}]: " BACKEND_INPUT
    [ -n "$BACKEND_INPUT" ] && BACKEND_URL="$BACKEND_INPUT" || BACKEND_URL="$PREV_BACKEND"
    BACKEND_URL=${BACKEND_URL%/}
    [ -n "$BACKEND_URL" ] && echo "$BACKEND_URL" > "$WORKDIR/.backend_url"

    read -p "请输入订阅链接 (Sub URL): " SUB_URL
    if [[ -z "$SUB_URL" ]]; then echo "URL不能为空"; return; fi

    DOWNLOAD_TEMP="/tmp/sb_nodes_raw.json"
    FINAL_TEMP="/tmp/sb_config_ready.json"
    rm -f "$DOWNLOAD_TEMP" "$FINAL_TEMP"

    TARGET_URL="$SUB_URL"
    if [[ -n "$BACKEND_URL" ]]; then
        echo "正在构建转换链接..."
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
    
    if ! jq -e . "$DOWNLOAD_TEMP" >/dev/null 2>&1; then
        echo -e "\033[31m下载内容不是有效的 JSON！\033[0m"
        echo "后端返回内容预览:"
        head -n 5 "$DOWNLOAD_TEMP"
        rm -f "$DOWNLOAD_TEMP"; return
    fi

    echo "正在合并配置 (本地正则筛选 + 网卡绑定)..."
    
    # === JQ 逻辑更新：注入 manual_if 参数 ===
    jq -n --slurpfile tpl "$LOCAL_TEMPLATE" --slurpfile remote "$DOWNLOAD_TEMP" --arg iface "$MANUAL_IF" '
       (if ($remote[0] | type) == "array" then $remote[0] else $remote[0].outbounds end) as $raw_nodes |
       ($raw_nodes | map(select(.type != "selector" and .type != "urltest" and .type != "direct" and .type != "block" and .type != "dns"))) as $nodes |
       
       # 1. 处理分组筛选 (保持原有逻辑)
       ($tpl[0].outbounds | map(
           if .type == "selector" or .type == "urltest" then
               if .filter then
                   . as $group |
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

       # 2. 新增逻辑：如果指定了网卡，给所有 Direct 出口绑定网卡
       ($processed_groups + $nodes | map(
           if .type == "direct" and $iface != "" then 
               . + {bind_interface: $iface} 
           else . end
       )) as $final_outbounds |

       # 3. 新增逻辑：如果指定了网卡，关闭 DNS 自动检测
       ($tpl[0].dns | if $iface != "" then . + {auto_detect_interface: false} else . end) as $final_dns |

       {
           log: $tpl[0].log, 
           dns: $final_dns, 
           inbounds: $tpl[0].inbounds, 
           route: $tpl[0].route, 
           experimental: $tpl[0].experimental, 
           outbounds: $final_outbounds
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
        rm -f "$DOWNLOAD_TEMP"
    fi
}