#!/usr/bin/env bash
# [宿主侧] 集群验收: 双设备互联 + 链路损伤独立性
# 前置: bash scripts/30_cluster_up.sh 已执行（设备 A/B 就绪）
# 说明: 全部检查为内联管道（每条均已手动验证），无函数依赖
set -uo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR"
KEY="$P1_DIR/../p0/keys/id_ed25519"
PASS=0; FAIL=0
step() { echo; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

ssha() { ssh -i "$KEY" -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR test@127.0.0.1 "$@"; }
sshb() { ssh -i "$KEY" -p 2323 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR test@127.0.0.1 "$@"; }
pingrep() { ssh -i "$KEY" -p $1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    test@127.0.0.1 "ping -c 5 -I $2 -W 2 $3 2>&1" | awk '
        /packet loss/ { for(i=1;i<=NF;i++) if($i ~ /%/) gsub("%","",$i); loss=$i }
        /rtt/ { split($4,a,"/"); avg=a[2] }
        END { printf "%.0f %.2f", loss, (avg==""?-1:avg) }'; }

step "[0/6] 设备可达性"
ssha "true" 2>/dev/null && ok "设备A (2223) 可达" || { bad "设备A不可达"; exit 1; }
sshb "true" 2>/dev/null && ok "设备B (2323) 可达" || { bad "设备B不可达"; exit 1; }

step "[1/6] 链路网卡定位（按 MAC）"
A1=$(ssha "ip -o link | grep -i 'a1:00:01' | cut -d: -f2 | tr -d ' '")
A2=$(ssha "ip -o link | grep -i 'a2:00:01' | cut -d: -f2 | tr -d ' '")
B1=$(sshb "ip -o link | grep -i 'b1:00:01' | cut -d: -f2 | tr -d ' '")
B2=$(sshb "ip -o link | grep -i 'b2:00:01' | cut -d: -f2 | tr -d ' '")
echo "  A:$A1/$A2  B:$B1/$B2"
[ -n "$A1" ] && [ -n "$A2" ] && [ -n "$B1" ] && [ -n "$B2" ] \
    && ok "四张互联网卡就位" || bad "互联网卡缺失"

step "[2/6] 链路 IP 置备（静态）"
ssha "sudo ip addr add 10.0.100.1/24 dev $A1 2>/dev/null; sudo ip link set $A1 up" >/dev/null
sshb "sudo ip addr add 10.0.100.2/24 dev $B1 2>/dev/null; sudo ip link set $B1 up" >/dev/null
ssha "sudo ip addr add 10.0.200.1/24 dev $A2 2>/dev/null; sudo ip link set $A2 up" >/dev/null
sshb "sudo ip addr add 10.0.200.2/24 dev $B2 2>/dev/null; sudo ip link set $B2 up" >/dev/null
IPCHK=$(ssha "ip -4 addr show $A1 | grep -c '10.0.100.1'; ip -4 addr show $A2 | grep -c '10.0.200.1'")
IPCHK2=$(sshb "ip -4 addr show $B1 | grep -c '10.0.100.2'; ip -4 addr show $B2 | grep -c '10.0.200.2'")
[ "$IPCHK" = "1
1" ] && [ "$IPCHK2" = "1
1" ] && ok "四口 IP 置备完成" || bad "IP 置备异常"

step "[3/6] 基线: 双链路 RTT（应 < 10ms）"
read L1_LOSS L1_RTT <<< "$(pingrep 2223 $A1 10.0.100.2)"
read L2_LOSS L2_RTT <<< "$(pingrep 2323 $B1 10.0.100.2)"
echo "  link1: loss=${L1_LOSS}% rtt=${L1_RTT}ms | link2: loss=${L2_LOSS}% rtt=${L2_RTT}ms"
python3 -c "import sys; sys.exit(0 if float('$L1_RTT')<10 and float('$L2_RTT')<10 else 1)" \
    && ok "双链路基线正常" || bad "基线异常"

step "[4/6] 独立损伤①: link1 加 200ms 时延，link2 必须不受影响"
python3 cluster/link_ctl.py set link1 --delay 200 >/dev/null
sleep 3
read L1_LOSS L1_RTT <<< "$(pingrep 2223 $A1 10.0.100.2)"
read L2_LOSS L2_RTT <<< "$(pingrep 2323 $B1 10.0.100.2)"
echo "  link1 rtt=${L1_RTT}ms | link2 rtt=${L2_RTT}ms"
python3 -c "import sys; sys.exit(0 if float('$L1_RTT')>=150 and float('$L2_RTT')<20 else 1)" \
    && ok "时延只作用于 link1（独立性 ✓）" || bad "损伤串扰"
python3 cluster/link_ctl.py clear link1 >/dev/null
sleep 1

step "[5/6] 独立损伤②: link1 100% 丢包，link2 必须不受影响"
python3 cluster/link_ctl.py set link1 --loss 100 >/dev/null
sleep 3
read L1_LOSS L1_RTT <<< "$(pingrep 2223 $A1 10.0.100.2)"
read L2_LOSS L2_RTT <<< "$(pingrep 2323 $B1 10.0.100.2)"
echo "  link1 loss=${L1_LOSS}% | link2 loss=${L2_LOSS}%"
python3 -c "import sys; sys.exit(0 if float('$L1_LOSS')>=80 and float('$L2_LOSS')==0 else 1)" \
    && ok "丢包只作用于 link1（独立性 ✓）" || bad "损伤串扰"
python3 cluster/link_ctl.py clear link1 >/dev/null
sleep 3
L1_LOSS=$(pingrep 2223 $A1 10.0.100.2 | awk '{print $1}')
[ "$L1_LOSS" = "0" ] && ok "link1 清除后恢复" || bad "link1 未恢复"

step "[6/6] 设备 A 蜂窝通道（B 为精简盘无蜂窝模块）"
CA=$(ssha "sudo python3 /tmp/at_client.py cmd 'AT+CPIN?'" 2>/dev/null)
echo "$CA" | grep -q "READY" && ok "A 蜂窝模块 AT 通道正常" || bad "A 蜂窝通道异常"

echo
echo "=== 集群验收: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] && echo "CLUSTER_ALL_GREEN" || echo "CLUSTER_HAS_FAILURES"
