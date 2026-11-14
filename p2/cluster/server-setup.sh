#!/bin/bash
# server 容器入口: 配置真实段 IP + 回程路由 → 启动透传 relay
#
# 簿记 → 真实: 10.9.3.2(seg-s1) → 10.0.102.2 ; 10.9.6.2(seg-s2) → 10.0.202.2
# 回程路由按 path 指向 router 对应腿（保证对称）
set -e

find_if() { ip -o -4 addr show | grep " $1/" | awk '{print $2}' | head -1; }

IF_S1=$(find_if 10.9.3.2)
IF_S2=$(find_if 10.9.6.2)
[ -n "$IF_S1" ] && [ -n "$IF_S2" ] || { echo "ERROR: seg-s1/seg-s2 接口未找到"; exit 1; }

ip addr add 10.0.102.2/24 dev "$IF_S1"
ip addr add 10.0.202.2/24 dev "$IF_S2"
ip route replace 10.0.100.0/24 via 10.0.102.1
ip route replace 10.0.101.0/24 via 10.0.102.1
ip route replace 10.0.200.0/24 via 10.0.202.1
ip route replace 10.0.201.0/24 via 10.0.202.1
echo "[server] real IPs: $IF_S1=10.0.102.2, $IF_S2=10.0.202.2; routes OK"

mkdir -p "$P2_DIR/logs"
exec python3 -u /wm_relay.py
