#!/bin/bash
# 路由容器入口: 校验 ip_forward（compose sysctls 注入）→ 可选 strict-hub 策略 → 常驻
set -e
test "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" || { echo "ERROR: ip_forward 未开启"; exit 1; }
echo "[router] ip_forward=1, 接口:"
ip -o -4 addr show | grep -v ' lo ' || true

if [ "${STRICT_HUB:-0}" = "1" ]; then
    # 强制 hub：仅放行 设备↔server 方向，A/B 子网间直通转发丢弃
    iptables -P FORWARD DROP
    iptables -A FORWARD -s 10.0.100.0/24 -d 10.0.102.0/24 -j ACCEPT
    iptables -A FORWARD -s 10.0.102.0/24 -d 10.0.100.0/24 -j ACCEPT
    iptables -A FORWARD -s 10.0.101.0/24 -d 10.0.102.0/24 -j ACCEPT
    iptables -A FORWARD -s 10.0.102.0/24 -d 10.0.101.0/24 -j ACCEPT
    iptables -A FORWARD -s 10.0.200.0/24 -d 10.0.202.0/24 -j ACCEPT
    iptables -A FORWARD -s 10.0.202.0/24 -d 10.0.200.0/24 -j ACCEPT
    iptables -A FORWARD -s 10.0.201.0/24 -d 10.0.202.0/24 -j ACCEPT
    iptables -A FORWARD -s 10.0.202.0/24 -d 10.0.201.0/24 -j ACCEPT
    echo "[router] STRICT_HUB=1: A↔B 直通已禁用（互传只走 server）"
fi

exec sleep infinity
