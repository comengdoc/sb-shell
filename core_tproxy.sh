# ==========================================
#  TProxy 核心启动逻辑 (旁路由优化版)
# ==========================================
start_service() {
    echo -e "${YELLOW}正在启动 Sing-box (旁路由 TProxy 模式)...${PLAIN}"

    # 1. 内核参数优化 (旁路由三件套)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1
    
    # 【重要】关闭 ICMP 重定向，防止设备跳过旁路由
    sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null 2>&1
    
    # 【重要】宽松的反向路径过滤，防止丢包
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1

    # 2. 路由策略清理与重建
    ip rule del from 192.168.0.0/16 lookup 2022 >/dev/null 2>&1
    ip rule del fwmark 1 table 100 >/dev/null 2>&1
    ip route del local 0.0.0.0/0 dev lo table 100 >/dev/null 2>&1

    # 配置策略路由：打标流量 -> 查表100 -> 送入本地回环
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # 3. 加载 NFTables 规则
    configure_nftables_tproxy

    # 4. 配置强制 NAT (旁路由必须！)
    # 既然你确认是 eth0，这里直接硬编码
    DEFAULT_IF="eth0"
    
    nft add table ip singbox 2>/dev/null
    nft add chain ip singbox nat_postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
    nft flush chain ip singbox nat_postrouting 2>/dev/null
    
    # 【核心】所有出站流量进行伪装，解决三角路由回程问题
    if [ -n "$DEFAULT_IF" ]; then
        nft add rule ip singbox nat_postrouting oifname "$DEFAULT_IF" masquerade 2>/dev/null
        echo -e "NAT 接口 (Masquerade): ${CYAN}$DEFAULT_IF${PLAIN}"
    fi

    # 5. 启动服务
    systemctl restart sing-box
    sleep 1
    
    if systemctl is-active --quiet sing-box; then 
        echo -e "${GREEN}服务启动成功 (旁路由模式 Ready)${PLAIN}"
    else 
        echo -e "${RED}启动失败，请检查日志 (journalctl -u sing-box -n 20)${PLAIN}"
        stop_service
    fi
}

# ==========================================
#  NFTables 规则生成 (防回环/防锁死)
# ==========================================
configure_nftables_tproxy() {
    TP_PORT="7895"
    
    # 自动获取本机 IP，防止把自己锁在外面
    LOCAL_IPS=$(ip addr | grep 'inet ' | awk '{print $2}' | sed 's/\/.*//' | tr '\n' ',' | sed 's/,$//')

    echo -e "TProxy 监听端口: ${CYAN}${TP_PORT}${PLAIN}"
    echo -e "本机 IP 豁免: ${CYAN}${LOCAL_IPS}${PLAIN}"

    nft flush ruleset 2>/dev/null
    nft -f - <<NFT
table ip singbox {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        
        # 1. 基础豁免
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        
        # 2. 【防锁死】豁免发往 R5C 本机的流量 (SSH, 面板, DNS)
        ip daddr { $LOCAL_IPS } return
        
        # 3. 【防掉线】豁免 DHCP 广播 (UDP 67/68)
        udp sport { 67, 68 } return
        udp dport { 67, 68 } return

        # 4. 豁免局域网互访 (LAN to LAN)
        # 确保这里涵盖了你的所有内网段
        ip daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return

        # 5. 劫持剩余所有 TCP/UDP 流量 -> TProxy
        meta l4proto { tcp, udp } meta mark set 1 tproxy to :$TP_PORT accept
    }
    chain output {
        type route hook output priority mangle; policy accept;
        
        # 1. 基础豁免
        ip daddr { 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        ip daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return
        ip daddr { $LOCAL_IPS } return

        # 2. 【防死循环核心】
        # 匹配 JSON 中 "➡️ 直连" 的 routing_mark: 255
        meta mark 255 return
        
        # 3. 豁免 NTP (防止时间同步死循环)
        udp dport 123 return

        # 4. 劫持本机流量 (可选，如需 Docker 走代理则保留)
        meta l4proto { tcp, udp } meta mark set 1 accept
    }
}
NFT
}