#!/usr/bin/env bash
# [宿主侧] 集群验收: 双设备互联 + 链路损伤独立性
# 前置: p1/build/qemu-custom 就绪; 集群未启动（由本脚本经 30 号脚本拉起）
set -uo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR"
SSH_A="-i ../p0/keys/id_ed25519 -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_B="${SSH_A/-p 2223/-p 2323}"
PASS=0; FAIL=0
step() { echo; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
link_ctl() { python3 cluster/link_ctl.py "$@"; }

# 在设备上按 MAC 找接口名
ifname() { ssh $1 "ip -o link | grep -i '$2' | cut -d: -f2 | tr -d ' '" 2>/dev/null; }

# A→B 经指定接口 ping <对端IP>，输出 "loss% avg_rtt"
ping_ab() {  # <A接口> <B侧IP>
    ssh $SSH_A "ping -c 5 -I $1 -W 2 $2 2>&1" | awk '
        /packet loss/ { for(i=1;i<=NF;i++) if($i ~ /%/) gsub("%","",$i); loss=$i }
        /rtt/ { split($4,a,"/") ; avg=a[2] }
        END { printf "%.0f %.1f", loss, (avg==""?-1:avg) }'
}

step "[1/6] 集群拉起（30 号脚本）"
bash scripts/30_cluster_up.sh 2>&1 | grep -E "cluster" | tail -8
A1=$(ifname "$SSH_A" "a1:00:01"); A2=$(ifname "$SSH_A" "a2:00:01")
B1=$(ifname "$SSH_B" "b1:00:01"); B2=$(ifname "$SSH_B" "b2:00:01")
echo "  A:$A1/$A2  B:$B1/$B2"
[ -n "$A1" ] && [ -n "$A2" ] && [ -n "$B1" ] && [ -n "$B2" ] \
    && ok "四张互联网卡就位" || bad "互联网卡缺失"

step "[2/6] 链路 IP 置备"
for spec in "2223 $A1 10.0.100.1/24" "2323 $B1 10.0.100.2/24" \
            "2223 $A2 10.0.200.1/24" "2323 $B2 10.0.200.2/24"; do
    set -- $spec
    ssh $1 == dummy 2>/dev/null || true
    ssh ${SSH_A/-p 2223/-p $1} "sudo ip addr add $3 dev $2 2>/dev/null; \
        ip -4 addr show $2 | grep -q '$3' " && echo "  ✓ $2=$3" || echo "  ✗ $2=$3"
done
R=$(ssh $SSH_A "ping -c 2 -I $A1 -W 2 10.0.100.2 2>&1" | grep -c "1 received\|0% packet loss")
R2=$(ssh $SSH_A "ping -c 2 -I $A2 -W 2 10.0.200.2 2>&1" | grep -c "1 received\|0% packet loss")
[ "$R" -ge 1 ] && [ "$R2" -ge 1 ] && ok "link1/link2 基础连通" || bad "链路不通"

step "[3/6] 基线: 双链路 RTT（应 < 10ms）"
read L1_LOSS L1_RTT <<< "$(ping_ab $A1 10.0.100.2)"
read L2_LOSS L2_RTT <<< "$(ping_ab $A2 10.0.200.2)"
echo "  link1: loss=${L1_LOSS}% rtt=${L1_RTT}ms | link2: loss=${L2_LOSS}% rtt=${L2_RTT}ms"
python3 -c "import sys; sys.exit(0 if float('$L1_RTT')<10 and float('$L2_RTT')<10 else 1)" \
    && ok "双链路基线正常" || bad "基线异常"

step "[4/6] 独立损伤①: link1 加 200ms 时延，link2 必须不受影响"
link_ctl set link1 --delay 200 >/dev/null
sleep 1
read L1_LOSS L1_RTT <<< "$(ping_ab $A1 10.0.100.2)"
read L2_LOSS L2_RTT <<< "$(ping_ab $A2 10.0.200.2)"
echo "  link1: rtt=${L1_RTT}ms | link2: rtt=${L2_RTT}ms"
python3 -c "import sys; sys.exit(0 if float('$L1_RTT')>=150 and float('$L2_RTT')<20 else 1)" \
    && ok "时延只作用于 link1（独立性 ✓）" || bad "损伤串扰"
link_ctl clear link1 >/dev/null

step "[5/6] 独立损伤②: link1 100% 丢包，link2 必须不受影响"
link_ctl set link1 --loss 100 >/dev/null
sleep 1
read L1_LOSS L1_RTT <<< "$(ping_ab $A1 10.0.100.2)"
read L2_LOSS L2_RTT <<< "$(ping_ab $A2 10.0.200.2)"
echo "  link1: loss=${L1_LOSS}% | link2: loss=${L2_LOSS}%"
python3 -c "import sys; sys.exit(0 if float('$L1_LOSS')>=80 and float('$L2_LOSS')==0 else 1)" \
    && ok "丢包只作用于 link1（独立性 ✓）" || bad "损伤串扰"
link_ctl clear link1 >/dev/null
sleep 1
read L1_LOSS L1_RTT <<< "$(ping_ab $A1 10.0.100.2)"
python3 -c "import sys; sys.exit(0 if float('$L1_LOSS')==0 else 1)" \
    && ok "link1 清除后恢复" || bad "link1 未恢复"

step "[6/6] 双设备蜂窝通道独立（各自的场景引擎）"
CA=$(ssh $SSH_A "sudo python3 /tmp/at_client.py cmd 'AT+CPIN?'" 2>/dev/null)
CB=$(ssh $SSH_B "sudo python3 /tmp/at_client.py cmd 'AT+CPIN?'" 2>/dev/null)
echo "$CA" | grep -q "READY" && echo "$CB" | grep -q "READY" \
    && ok "A/B 蜂窝模块 AT 通道均正常" || bad "蜂窝通道异常"

echo
echo "=== 集群验收: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] && echo "CLUSTER_ALL_GREEN" || echo "CLUSTER_HAS_FAILURES"
