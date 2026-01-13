cat > /etc/sbshell/sub.sh << 'EOF'
#!/bin/bash

# ==========================================
#  Sing-box 订阅管理增强版 (sb-shell/sub.sh)
# ==========================================

WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"

# 检查并自动安装 jq (JSON 处理核心工具)
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

# 更新订阅主逻辑
update_subscription() {
    # 0. 依赖检查
    check_jq || return 1
    
    # 1. 确定当前工作模式 (TUN 或 TPROXY)
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    if [[ "$MODE" == "TUN" ]]; then
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json"
    else
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    fi
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then
        echo -e "${RED}错误: 找不到本地模板文件 $LOCAL_TEMPLATE${PLAIN}"
        echo -e "${RED}请检查安装是否完整。${PLAIN}"
        return
    fi

    echo -e "当前系统运行模式: ${GREEN}$MODE${PLAIN}"
    echo -e "${YELLOW}提示: 脚本将保留本机的入站接口设置(Inbounds)，只更新节点和规则。${PLAIN}"
    echo -e "----------------------------------------------------"
    echo -e "1. 粘贴 Sing-box 格式 JSON 订阅链接"
    echo -e "2. 粘贴 Clash / V2Ray / SSR 订阅链接 (自动转换)"
    echo -e "3. 手动粘贴 JSON 文本内容"
    echo -e "----------------------------------------------------"
    read -p "请选择操作 [1-3]: " sub_type

    # 临时文件路径
    DOWNLOAD_TEMP="/tmp/sb_download.json"
    FINAL_TEMP="/tmp/sb_config_ready.json"
    rm -f "$DOWNLOAD_TEMP" "$FINAL_TEMP"

    # === 分支处理 ===
    if [[ "$sub_type" == "3" ]]; then
        # --- 场景 3: 手动粘贴 ---
        echo "请在下方粘贴完整的 config.json 内容 (粘贴完成后按 Ctrl+D 结束):"
        cat > "$FINAL_TEMP"
    
    else
        # --- 场景 1 & 2: 下载链接 ---
        read -p "请输入订阅链接 (URL): " SUB_URL
        if [[ -z "$SUB_URL" ]]; then echo "URL不能为空"; return; fi
        
        # 转换后端配置 (使用稳定公共后端 + ACL4SSR 规则)
        CONVERT_API="https://api.v1.mk/sub?target=singbox&config=https://raw.githubusercontent.com/acl4ssr/acl4ssr/master/Clash/config/ACL4SSR_Online_Full_MultiMode.ini"
        
        TARGET_URL="$SUB_URL"
        
        # 如果选择转换模式，构建转换链接
        if [[ "$sub_type" == "2" ]]; then
            echo -e "${YELLOW}正在对链接进行编码处理...${PLAIN}"
            # URL Encode
            ENCODED_URL=$(echo -n "$SUB_URL" | jq -sRr @uri)
            TARGET_URL="${CONVERT_API}&url=${ENCODED_URL}"
            echo -e "${YELLOW}已构建转换请求，准备下载...${PLAIN}"
        fi
        
        echo -e "${YELLOW}正在下载配置 (超时时间 30秒)...${PLAIN}"
        curl -L -o "$DOWNLOAD_TEMP" --connect-timeout 15 --max-time 30 "$TARGET_URL"
        
        if [[ $? -ne 0 ]] || [[ ! -s "$DOWNLOAD_TEMP" ]]; then
            echo -e "${RED}下载失败！请检查网络连通性或代理设置。${PLAIN}"
            rm -f "$DOWNLOAD_TEMP"
            return
        fi

        # 检查是否为有效 JSON
        if ! jq -e . "$DOWNLOAD_TEMP" >/dev/null 2>&1; then
            echo -e "${RED}错误: 下载的内容不是有效的 JSON 格式。${PLAIN}"
            echo -e "文件头预览: $(head -n 1 "$DOWNLOAD_TEMP")"
            rm -f "$DOWNLOAD_TEMP"
            return
        fi
        
        echo -e "${GREEN}下载成功，正在执行智能合并...${PLAIN}"
        
        # === 智能合并核心逻辑 ===
        # 逻辑说明:
        # 1. 以 $remote (下载的配置) 为基础，获取它的 outbounds(节点), route(路由), dns(解析)
        # 2. 强制覆盖 .inbounds (入站) 和 .experimental (缓存/核心参数) 为本地模板 $local 的设置
        # 3. 这样可以确保透明代理设置不被机场订阅覆盖
        
        jq -n \
           --slurpfile local "$LOCAL_TEMPLATE" \
           --slurpfile remote "$DOWNLOAD_TEMP" \
           '$remote[0] | 
            .inbounds = $local[0].inbounds | 
            .experimental = $local[0].experimental' \
           > "$FINAL_TEMP"
           
        if [[ $? -ne 0 ]]; then
             echo -e "${RED}合并配置失败 (jq error)，操作已取消。${PLAIN}"
             rm -f "$DOWNLOAD_TEMP"
             return
        fi
    fi

    # === 安全校验 ===
    echo -e "${YELLOW}正在校验生成的配置文件...${PLAIN}"
    
    # 检查 sing-box 二进制位置，防止路径不同
    SB_BIN="/usr/local/bin/sing-box"
    [ ! -f "$SB_BIN" ] && SB_BIN="/usr/bin/sing-box"
    
    if "$SB_BIN" check -c "$FINAL_TEMP" > /dev/null 2>&1; then
        echo -e "${GREEN}配置校验通过！${PLAIN}"
        
        # 备份旧配置 (可选)
        [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
        
        # 应用新配置
        cp "$FINAL_TEMP" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        
        # 清理临时文件
        rm -f "$DOWNLOAD_TEMP" "$FINAL_TEMP"
        
        echo -e "${GREEN}正在重启服务...${PLAIN}"
        restart_service
    else
        echo -e "${RED}配置校验失败！系统未受影响。错误日志如下：${PLAIN}"
        "$SB_BIN" check -c "$FINAL_TEMP"
        echo -e "${RED}---------------------------------------------${PLAIN}"
        echo -e "${RED}可能原因: 订阅源提供的节点格式不支持当前内核版本，或转换接口异常。${PLAIN}"
        rm -f "$DOWNLOAD_TEMP" "$FINAL_TEMP"
    fi
}
EOF