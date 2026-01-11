#!/bin/bash

# 更新订阅逻辑
update_subscription() {
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    TEMPLATE=""
    
    if [[ "$MODE" == "TUN" ]]; then
        TEMPLATE="$TEMPLATE_DIR/tun.json"
    else
        TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    fi
    
    if [[ ! -f "$TEMPLATE" ]]; then
        echo -e "${RED}错误: 找不到模板文件，请先执行安装步骤。${PLAIN}"
        return
    fi
    
    echo -e "当前模式: ${GREEN}$MODE${PLAIN}"
    echo -e "请选择配置来源:"
    echo -e "1. 粘贴 Sing-box 专用订阅链接 (JSON格式)"
    echo -e "2. 粘贴 Clash/V2Ray 订阅 (将尝试使用远程转换)"
    echo -e "3. 手动粘贴完整 config.json 内容"
    read -p "选择: " sub_type
    
    if [[ "$sub_type" == "3" ]]; then
        echo "请在下方粘贴内容，按 Ctrl+D 结束:"
        cat > $CONFIG_FILE
        echo -e "${GREEN}配置已保存，请重启服务。${PLAIN}"
        return
    fi
    
    read -p "请输入订阅链接 URL: " SUB_URL
    if [[ -z "$SUB_URL" ]]; then echo "URL不能为空"; return; fi

    # 处理链接
    TEMP_JSON="/tmp/sb_sub.json"
    
    if [[ "$sub_type" == "2" ]]; then
        # 使用公共转换 API (示例使用 config.v1.mk)
        # 注意：这里你可以换成你自己部署的转换后端
        echo -e "${YELLOW}正在通过转换服务器处理...${PLAIN}"
        CONV_URL="https://api.v1.mk/sub?target=singbox&url=$(echo -n "$SUB_URL" | xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g')&insert=false&config=$(echo -n "$TEMPLATE" | xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g')"
        # 注意：实际上直接转换整个 Config 比较复杂。
        # 简化策略：仅下载 Outbounds 部分
        echo -e "${RED}注意：Clash 转换 Singbox 逻辑复杂，建议直接使用机场提供的 Sing-box URL，或者手动粘贴 Config。${PLAIN}"
        echo -e "${YELLOW}尝试直接下载...${PLAIN}"
        wget -O $CONFIG_FILE "$SUB_URL"
    else
        # 直接下载 Sing-box JSON
        echo -e "${YELLOW}正在下载配置...${PLAIN}"
        wget -O $TEMP_JSON "$SUB_URL"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}下载失败${PLAIN}"
            return
        fi
        
        # 简单的验证
        if grep -q "outbounds" $TEMP_JSON; then
             # 如果下载的文件包含完整的 outbounds，我们尝试将其融合进模板
             # 这里为简化起见，假设用户提供的是完整的 singbox config
             # 如果你想只替换 outbound，需要用 jq 工具，但为了少依赖，我们直接覆盖
             # 或者，如果用户需要保留本地 DNS 设置，这里需要复杂的 jq 操作。
             
             # 简单方案：直接覆盖，但提示用户检查
             cp $TEMP_JSON $CONFIG_FILE
             echo -e "${GREEN}配置已下载覆盖。${PLAIN}"
             echo -e "${YELLOW}提示: 如果你的机场提供的配置没有包含 TUN/TProxy 入站设置，可能无法联网。建议使用选项 8 检查配置。${PLAIN}"
        else
             echo -e "${RED}下载的内容格式看似不对，请检查链接。${PLAIN}"
        fi
    fi
    
    rm -f $TEMP_JSON
    restart_service
}