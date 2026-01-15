#!/bin/bash
WORKDIR="/etc/sbshell"
CONFIG_FILE="/etc/sing-box/config.json"
TEMPLATE_DIR="$WORKDIR/templates"
PREF_FILE="$WORKDIR/.interface_pref"

# === 依赖检查 ===
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "正在安装 jq..."
        if command -v apt-get >/dev/null; then
            apt-get update -y && apt-get install -y jq
        else
            apk add jq
        fi
    fi
}

urlencode() {
    echo -n "$1" | jq -sRr @uri
}

# === 网卡选择交互 (保持您原有的逻辑) ===
select_interface() {
    CURRENT_PREF=$(cat "$PREF_FILE" 2>/dev/null)
    echo -e "----------------------------------------------------"
    if [ -n "$CURRENT_PREF" ]; then
        echo -e "当前网络出口: \033[32m手动指定 ($CURRENT_PREF)\033[0m"
    else
        echo -e "当前网络出口: \033[32m自动智能检测\033[0m"
    fi
    read -p "是否更改网卡设定? [y/N]: " CHANGE_IF
    if [[ "$CHANGE_IF" =~ ^[yY]$ ]]; then
        ls /sys/class/net | grep -vE "lo|docker|veth"
        read -p "输入网卡名称 (输入 auto 恢复自动): " INPUT_IF
        if [[ "$INPUT_IF" == "auto" ]] || [[ -z "$INPUT_IF" ]]; then
            rm -f "$PREF_FILE"
            MANUAL_IF=""
        else
            echo "$INPUT_IF" > "$PREF_FILE"
            MANUAL_IF="$INPUT_IF"
        fi
    else
        MANUAL_IF="$CURRENT_PREF"
    fi
}

# === 核心订阅更新函数 (适配 reF1nd + 保留用户模板) ===
update_subscription() {
    check_jq
    
    # 1. 确定模板文件
    MODE=$(cat "$WORKDIR/.mode" 2>/dev/null || echo "TUN")
    # 如果是 TUN 模式，强制使用用户提供的 tun.json
    if [[ "$MODE" == "TUN" ]]; then
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tun.json"
    else
        LOCAL_TEMPLATE="$TEMPLATE_DIR/tproxy.json"
    fi
    
    if [[ ! -f "$LOCAL_TEMPLATE" ]]; then
        echo -e "\033[31m错误: 找不到模板文件 $LOCAL_TEMPLATE\033[0m"
        echo "请确保您已将原来的 json 保存为该文件。"
        return
    fi

    select_interface

    # 2. 获取并处理订阅链接
    PREV_BACKEND=""
    [ -f "$WORKDIR/.backend_url" ] && PREV_BACKEND=$(cat "$WORKDIR/.backend_url")
    read -p "后端地址 (reF1nd通常不需要，回车跳过): " BACKEND_INPUT
    [ -n "$BACKEND_INPUT" ] && BACKEND_URL="$BACKEND_INPUT" || BACKEND_URL="$PREV_BACKEND"
    # 去除末尾斜杠
    BACKEND_URL=${BACKEND_URL%/}
    [ -n "$BACKEND_URL" ] && echo "$BACKEND_URL" > "$WORKDIR/.backend_url"

    read -p "请输入订阅链接 (支持 Clash/Mihomo/Singbox 链接): " SUB_URL
    if [[ -z "$SUB_URL" ]]; then echo "URL不能为空"; return; fi

    # 如果有后端，进行转换；否则直接使用
    if [[ -n "$BACKEND_URL" ]]; then
        echo "正在构建转换链接..."
        ENCODED_SUB=$(urlencode "$SUB_URL")
        # 即使是 reF1nd，如果订阅很乱，依然建议转成 Clash 格式
        FINAL_URL="${BACKEND_URL}/config/${ENCODED_SUB}&file=https://raw.githubusercontent.com/acl4ssr/acl4ssr/master/Clash/config/ACL4SSR_Online_Full.ini"
    else
        FINAL_URL="$SUB_URL"
    fi

    echo "正在根据模板生成 reF1nd 配置文件..."

    # === JQ 魔法：融合模板与 Providers ===
    # 逻辑说明：
    # 1. 在根目录插入 providers 字段。
    # 2. 遍历 outbounds：
    #    - 凡是带有 "filter" 字段的对象 (说明它是靠关键词筛选节点的)，
    #      自动给它添加 "providers": ["my_subscription"]。
    #    - 其他对象保持不变。
    # 3. 如果指定了网卡，给 direct 出站绑定网卡。

    jq --arg url "$FINAL_URL" \
       --arg iface "$MANUAL_IF" '
       # 1. 注入 Providers 定义
       .providers = {
         "my_subscription": {
           "type": "http",
           "url": $url,
           "interval": "3600s",
           "path": "./providers/proxy.yaml",
           "healthcheck": {
             "enabled": true,
             "interval": "600s",
             "url": "http://www.gstatic.com/generate_204"
           }
         }
       } |

       # 2. 智能注入 Providers 到 Selector/URLTest
       .outbounds |= map(
         if .filter then
            . + { "providers": ["my_subscription"] }
         else
            .
         end
       ) |

       # 3. 处理网卡绑定 (防回环)
       .outbounds |= map(
         if .type == "direct" and $iface != "" then
            . + { "bind_interface": $iface }
         else
            .
         end
       )

    ' "$LOCAL_TEMPLATE" > "$CONFIG_FILE"

    if [[ $? -eq 0 ]]; then
        echo -e "\033[32m配置文件生成成功！\033[0m"
        
        # 验证一下生成的文件是否合法
        if "$SINGBOX_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
            echo "配置校验通过，正在重启服务..."
            systemctl restart sing-box
            if systemctl is-active --quiet sing-box; then
                echo -e "\033[32m服务启动成功！reF1nd 模式运行中。\033[0m"
                # 提示面板地址 (从模板里读取 external_controller 端口)
                PORT=$(jq -r '.experimental.clash_api.external_controller // empty' "$CONFIG_FILE" | cut -d: -f2)
                [[ -n "$PORT" ]] && echo -e "控制面板: http://设备IP:$PORT/ui"
            else
                echo -e "\033[31m服务启动失败，请查看日志。\033[0m"
                journalctl -u sing-box -n 20 --no-pager
            fi
        else
             echo -e "\033[31m配置校验失败！可能是模板格式有误。\033[0m"
             "$SINGBOX_BIN" check -c "$CONFIG_FILE"
        fi
    else
        echo -e "\033[31mJSON 处理失败 (JQ Error)\033[0m"
    fi
}