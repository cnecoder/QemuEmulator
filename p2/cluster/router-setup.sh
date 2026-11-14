#!/bin/bash
# 路由容器入口: 校验转发 → 配置六腿真实段 IP（网关职能）→ ifb 双向损伤接线 → 启动损伤控制守护
#
# 腿命名: <对端设备><链路号> —— a1/b1/s1 = path1（设备A/B/server 的 link1 侧）, a2/b2/s2 = path2
# 簿记 IP → 真实 IP 映射（簿记 IP 仅用于定位接口，真实 IP 才是 guest/server 眼中的地址）:
#   10.9.1.3 → a1: 10.0.100.3   10.9.2.3 → b1: 10.0.101.3   10.9.3.3 → s1: 10.0.102.1
#   10.9.4.3 → a2: 10.0.200.3   10.9.5.3 → b2: 10.0.201.3   10.9.6.3 → s2: 10.0.202.1
set -e
test "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" || { echo "ERROR: ip_forward 未开启"; exit 1; }

declare -A REAL_IP=( [a1]=10.0.100.3 [b1]=10.0.101.3 [s1]=10.0.102.1 \
                     [a2]=10.0.200.3 [b2]=10.0.201.3 [s2]=10.0.202.1 )
declare -A BOOK_IP=( [a1]=10.9.1.3 [b1]=10.9.2.3 [s1]=10.9.3.3 \
                     [a2]=10.9.4.3 [b2]=10.9.5.3 [s2]=10.9.6.3 )

LEG_JSON="{"
for LEG in a1 b1 s1 a2 b2 s2; do
    IF=$(ip -o -4 addr show | grep " ${BOOK_IP[$LEG]}/" | awk '{print $2}' | head -1)
    [ -n "$IF" ] || { echo "ERROR: 腿 $LEG 接口未找到 (${BOOK_IP[$LEG]})"; exit 1; }
    ip addr add "${REAL_IP[$LEG]}/24" dev "$IF"
    # 双向损伤接线: egress qdisc 挂在腿接口（router→对端）;
    # ingress（对端→router）经 ifb 镜像（u32 全匹配 + mirred redirect），损伤挂 ifb
    ip link add "ifb-$LEG" type ifb
    ip link set "ifb-$LEG" up
    tc qdisc add dev "$IF" handle ffff: ingress
    tc filter add dev "$IF" parent ffff: u32 match u8 0 0 action mirred egress redirect dev "ifb-$LEG"
    echo "[router] leg-$LEG: $IF (${REAL_IP[$LEG]}) + ifb-$LEG"
    SEP=$([ "$LEG" = "a1" ] && echo "" || echo ",")
    LEG_JSON="$LEG_JSON$SEP\"$LEG\": {\"if\": \"$IF\", \"ifb\": \"ifb-$LEG\"}"
done
LEG_JSON="$LEG_JSON}"

mkdir -p "$(dirname "$P2_DIR/run/linkd.sock")" "$P2_DIR/logs"
echo "$LEG_JSON" > "$P2_DIR/run/legs.json"

if [ "${STRICT_HUB:-0}" = "1" ]; then
    # 强制 hub：仅放行 设备↔server 方向，A/B 子网间直通转发丢弃（真实段地址）
    iptables -P FORWARD DROP
    for PAIR in "10.0.100.0/24 10.0.102.0/24" "10.0.101.0/24 10.0.102.0/24" \
                "10.0.200.0/24 10.0.202.0/24" "10.0.201.0/24 10.0.202.0/24"; do
        set -- $PAIR
        iptables -A FORWARD -s "$1" -d "$2" -j ACCEPT
        iptables -A FORWARD -s "$2" -d "$1" -j ACCEPT
    done
    echo "[router] STRICT_HUB=1: A↔B 直通已禁用（互传强制只走 server）"
fi

echo "[router] 启动损伤控制守护（$(readlink -f /wm_router_ctl.py)）"
python3 -u /wm_router_ctl.py "$P2_DIR/run/linkd.sock" "$P2_DIR/run/legs.json" \
    >> "$P2_DIR/logs/linkd.log" 2>&1
