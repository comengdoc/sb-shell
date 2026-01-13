#!/bin/bash

# ==========================================
#  Sing-box 订阅管理增强版 (适配自定义后端 + 本地正则筛选)
#  文件路径: /etc/sbshell/sub.sh
# ==========================================

WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"

# 检查并自动安装 jq
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}检测到缺少必要组件 jq，正在自动安装...${PLAIN}"
        if command -v apt-get >/dev/null; then
            apt-get update -y && apt-get install -y jq
        elif command -v apk >/dev/null; then
            apk add jq
        elif command -v yum >/dev/null; then
            yum install -y jq
        else
            echo -e "${RED}错误: 无法自动安装 jq，请手动安装后重试。${PLAIN}"
            return 1
        fi
    fi
}

# URL 编码函数
urlencode() {
    echo -n "$1" | jq -sRr @uri
}

# 更新订阅主逻辑
update_subscription() {
    # 0. 依赖检查
    check_jq || return 1
    
    # 1. 确定当前工作模式
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    if [[ "$MODE" == "TUN" ]]; then
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json"
    else
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    fi
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then
        echo -e "${RED}错误: 找不到本地模板文件 $LOCAL_TEMPLATE${PLAIN}"
        return
    fi

    echo -e "当前系统运行模式: ${GREEN}$MODE${PLAIN}"
    echo -e "使用模板: ${CYAN}$LOCAL_TEMPLATE${PLAIN}"
    echo -e "----------------------------------------------------"
    
    # === 获取用户输入 ===
    # 读取之前的后端地址缓存
    PREV_BACKEND=""
    [ -f "$WORKDIR/.backend_url" ] && PREV_BACKEND=$(cat "$WORKDIR/.backend_url")
    
    echo -e "请输入转换后端地址 (通常以 http/https 开头)"
    echo -e "如果你的订阅已经是 Sing-box 格式，这里可以直接留空"
    if [[ -n "$PREV_BACKEND" ]]; then
        read -p "后端地址 [回车用默认: $PREV_BACKEND]: " BACKEND_INPUT
        [ -z "$BACKEND_INPUT" ] && BACKEND_URL="$PREV_BACKEND" || BACKEND_URL="$BACKEND_INPUT"
    else
        read -p "后端地址 (例如 https://api.v1.mk): " BACKEND_URL
    fi
    
    # 保存后端地址
    if [[ -n "$BACKEND_URL" ]]; then
        echo "$BACKEND_URL" > "$WORKDIR/.backend_url"
    fi

    read -p "请输入订阅链接 (Sub URL): " SUB_URL
    if [[ -z "$SUB_URL" ]]; then echo "URL不能为空"; return; fi

    # === 构建下载地址 ===
    DOWNLOAD_TEMP="/tmp/sb_nodes_raw.json"
    FINAL_TEMP="/tmp/sb_config_ready.json"
    rm -f "$DOWNLOAD_TEMP" "$FINAL_TEMP"

    TARGET_URL="$SUB_URL"
    
    # 如果配置了后端，构建转换链接
    if [[ -n "$BACKEND_URL" ]]; then
        echo -e "${YELLOW}正在构建转换请求...${PLAIN}"
        ENCODED_SUB=$(urlencode "$SUB_URL")
        # 这里假设后端兼容 Subconverter 格式 (?target=singbox&url=...)
        # 如果你的后端API不同，请手动修改下面这一行
        TARGET_URL="${BACKEND_URL}/sub?target=singbox&url=${ENCODED_SUB}"
        
        # 也可以尝试这种格式 (适配 sing-box-subscribe 项目)
        # TARGET_URL="${BACKEND_URL}/config/${ENCODED_SUB}" 
    fi

    echo -e "${YELLOW}正在从后端获取节点...${PLAIN}"
    echo -e "请求地址: $TARGET_URL"
    curl -L -k -o "$DOWNLOAD_TEMP" --connect-timeout 15 --max-time 30 "$TARGET_URL"

    if [[ $? -ne 0 ]] || [[ ! -s "$DOWNLOAD_TEMP" ]]; then
        echo -e "${RED}下载失败！请检查后端地址或网络连通性。${PLAIN}"
        rm -f "$DOWNLOAD_TEMP"
        return
    fi

    # 简单验证 JSON
    if ! jq -e . "$DOWNLOAD_TEMP" >/dev/null 2>&1; then
        echo -e "${RED}错误: 下载的内容不是有效的 JSON 格式。可能是后端报错。${PLAIN}"
        cat "$DOWNLOAD_TEMP" | head -n 10
        rm -f "$DOWNLOAD_TEMP"
        return
    fi

    echo -e "${GREEN}节点获取成功！正在根据模板进行正则筛选与合并...${PLAIN}"

    # === JQ 核心处理 (魔法部分) ===
    # 逻辑说明：
    # 1. 提取下载文件中的纯节点 (排除 selector/urltest 等，防止策略组嵌套)
    # 2. 遍历本地模板的 outbounds
    # 3. 如果发现 outbound 有 "filter" 字段：
    #    - 遍历所有节点，匹配 include/exclude 关键词
    #    - 将匹配到的节点 tag 填入 outbounds 数组
    #    - 删除 filter 字段 (Sing-box 不认识它)
    # 4. 如果没有 filter，保持原样
    # 5. 最后将所有纯节点追加到 outbounds 列表末尾，防止找不到引用

    jq -n \
       --slurpfile tpl "$LOCAL_TEMPLATE" \
       --slurpfile remote "$DOWNLOAD_TEMP" \
       '
       # 1. 提取远程节点 (过滤掉策略组，只留实际代理节点)
       ($remote[0].outbounds | map(select(.type != "selector" and .type != "urltest" and .type != "direct" and .type != "block" and .type != "dns"))) as $nodes |
       
       # 2. 处理模板中的策略组
       ($tpl[0].outbounds | map(
           if .type == "selector" or .type == "urltest" then
               if .filter then
                   . as $group |
                   # 执行筛选逻辑
                   ($nodes | map(
                       . as $node |
                       # 检查 Includes (是 OR 关系)
                       (if ($group.filter | map(select(.action == "include")) | length) > 0 then
                           ($group.filter | map(select(.action == "include")) | any(.keywords[] as $k | ($node.tag | test($k; "i"))))
                       else
                           true # 没有 include 规则则默认全选
                       end)
                       and
                       # 检查 Excludes (是 OR 关系，命中任意一个即排除)
                       (if ($group.filter | map(select(.action == "exclude")) | length) > 0 then
                           ($group.filter | map(select(.action == "exclude")) | any(.keywords[] as $k | ($node.tag | test($k; "i"))) | not)
                       else
                           true
                       end)
                   )) as $matches |
                   
                   # 重构该策略组对象
                   {
                       tag: $group.tag,
                       type: $group.type,
                       # 提取匹配到的 tag，如果没有匹配到，保留直连或不做任何操作以防报错，这里默认留空会报错，建议手动加个 fallback
                       outbounds: (if ($matches | length) > 0 then ($matches | map(.tag)) else ["➡️ 直连"] end)
                   } 
                   # 保留其他可选字段
                   + (if $group.interval then {interval: $group.interval} else {} end)
                   + (if $group.tolerance then {tolerance: $group.tolerance} else {} end)
                   + (if $group.strategy then {strategy: $group.strategy} else {} end)
                   + (if $group.interrupt_exist_connections then {interrupt_exist_connections: $group.interrupt_exist_connections} else {} end)
               else
                   . # 没有 filter 的策略组直接保留 (如 "GLOBAL" 或 "手动选择")
               end
           else
               . # 非策略组对象直接保留
           end
       )) as $processed_groups |
       
       # 3. 组装最终 JSON
       {
           log: $tpl[0].log,
           dns: $tpl[0].dns,
           inbounds: $tpl[0].inbounds,
           route: $tpl[0].route,
           experimental: $tpl[0].experimental,
           outbounds: ($processed_groups + $nodes)
       }
       ' > "$FINAL_TEMP"

    if [[ $? -ne 0 ]]; then
         echo -e "${RED}JSON 合并处理失败 (jq 语法错误)。${PLAIN}"
         rm -f "$DOWNLOAD_TEMP"
         return
    fi

    # === 验证与应用 ===
    echo -e "${YELLOW}正在校验生成的配置...${PLAIN}"
    SB_BIN="/usr/local/bin/sing-box"
    [ ! -f "$SB_BIN" ] && SB_BIN="/usr/bin/sing-box"
    
    if "$SB_BIN" check -c "$FINAL_TEMP" > /dev/null 2>&1; then
        echo -e "${GREEN}配置校验通过！${PLAIN}"
        
        # 备份旧配置
        [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
        
        # 覆盖新配置
        cp "$FINAL_TEMP" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        
        # 清理临时文件
        rm -f "$DOWNLOAD_TEMP" "$FINAL_TEMP"
        
        echo -e "${GREEN}正在重启 Sing-box 服务...${PLAIN}"
        restart_service
    else
        echo -e "${RED}配置校验失败！${PLAIN}"
        echo -e "错误详情:"
        "$SB_BIN" check -c "$FINAL_TEMP"
        echo -e "${YELLOW}生成的配置文件保留在: $FINAL_TEMP (可供调试)${PLAIN}"
    fi
}