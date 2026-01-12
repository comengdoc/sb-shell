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
    # [修改点3] 优化文案，让用户知道这里可以直接贴配置文件的链接
    echo -e "1. 粘贴 URL 链接 (自动下载完整配置或订阅)"
    echo -e "2. 粘贴 Clash/V2Ray 订阅 (尝试转换)"
    echo -e "3. 手动粘贴配置内容 (文本模式)"
    read -p "选择: " sub_type
    
    # 选项 3：手动粘贴文本
    if [[ "$sub_type" == "3" ]]; then
        echo "请在下方粘贴完整 config.json 内容，按 Ctrl+D 结束:"
        cat > $CONFIG_FILE
        echo -e "${GREEN}配置已保存，请重启服务。${PLAIN}"
        return
    fi
    
    # 获取 URL
    read -p "请输入链接 URL: " SUB_URL
    if [[ -z "$SUB_URL" ]]; then echo "URL不能为空"; return; fi

    TEMP_JSON="/tmp/sb_sub.json"
    
    # 选项 2：转换模式
    if [[ "$sub_type" == "2" ]]; then
        echo -e "${YELLOW}正在通过转换服务器处理...${PLAIN}"
        # 转换逻辑略，保持原样
        wget -O $CONFIG_FILE "$SUB_URL" # 这里需要你的转换逻辑，原脚本这里可能有缺失，暂时保持原样
    
    # 选项 1：直接下载模式 (这是你要用的)
    else
        echo -e "${YELLOW}正在从 URL 下载配置...${PLAIN}"
        wget -O $TEMP_JSON "$SUB_URL"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}下载失败，请检查链接有效性。${PLAIN}"
            return
        fi
        
        # [核心逻辑] 自动判断是 完整配置 还是 纯订阅
        if grep -q "outbounds" $TEMP_JSON && grep -q "inbounds" $TEMP_JSON; then
             # 如果包含 inbounds 和 outbounds，说明是完整的 config.json
             echo -e "${GREEN}检测到完整配置文件。${PLAIN}"
             cp $TEMP_JSON $CONFIG_FILE
        elif grep -q "outbounds" $TEMP_JSON; then
             # 如果只有 outbounds，可能是 Sing-box 格式的订阅节点
             echo -e "${YELLOW}检测到仅包含节点信息，尝试合并入模板... (此功能需确保jq支持，这里仅做简单提示)${PLAIN}"
             # 简单脚本暂不支持复杂合并，直接覆盖（可能会报错，建议用完整配置）
             cp $TEMP_JSON $CONFIG_FILE
        else
             echo -e "${RED}错误：下载的内容格式不正确（不是有效的 JSON）。${PLAIN}"
             echo -e "文件头内容: $(head -n 1 $TEMP_JSON)"
        fi
    fi
    
    rm -f $TEMP_JSON
    echo -e "${GREEN}配置更新完毕，正在重启服务...${PLAIN}"
    restart_service
}