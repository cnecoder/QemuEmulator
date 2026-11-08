#!/usr/bin/env bash
# [宿主侧] P2 场景引擎验收: 状态机/URC/数据面联动/弱网注入
# 前置: p1-vm 运行中且已置备（25 通过）; 引擎未运行
set -uo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR"
SSH_OPTS="-i ../p0/keys/id_ed25519 -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
PASS=0; FAIL=0
step() { echo; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
ctl()  { python3 scripts/engine_ctl.py "$@"; }
gat()  { ssh $SSH_OPTS test@127.0.0.1 "sudo python3 /tmp/at_client.py cmd '$1'" 2>/dev/null; }
# guest 侧 URC 监听窗口（独占读端；TCG 下 python 启动慢，留足预热）
mon_start() { ssh $SSH_OPTS test@127.0.0.1 "rm -f /tmp/urc.log; nohup sudo python3 /tmp/at_client.py monitor $1 > /tmp/urc.log 2>&1 &" 2>/dev/null; sleep 4; }
mon_stop()  { ssh $SSH_OPTS test@127.0.0.1 "sudo pkill -f 'at_client.py monitor'; sleep 0.5" 2>/dev/null; }
urc_has()   { ssh $SSH_OPTS test@127.0.0.1 "grep -q '$1' /tmp/urc.log" 2>/dev/null; }
NETIF=enx525400123457

step "[0/7] 启动场景引擎 + 推送 guest AT 客户端"
pkill -f "21_at_responder" 2>/dev/null || true
pkill -f "wm_scenario_engine" 2>/dev/null || true
sleep 1
nohup python3 engine/wm_scenario_engine.py run/at0.sock run/engine.sock run/qmp.sock \
    > logs/engine.log 2>&1 &
for i in $(seq 1 15); do
  grep -q "control api listening" logs/engine.log 2>/dev/null && break; sleep 1
done
grep -q "control api listening" logs/engine.log && ok "引擎已就绪" || { bad "引擎未就绪: $(tail -2 logs/engine.log)"; exit 1; }
grep -q "device connected" logs/engine.log && ok "已连接 AT 通道" || bad "AT 通道未连接"
ssh $SSH_OPTS test@127.0.0.1 "sudo tee /tmp/at_client.py > /dev/null" < scripts/at_client.py
ok "guest AT 客户端就绪"

step "[1/7] 场景 normal: 标准注册态"
ctl scenario normal >/dev/null
sleep 1
R=$(gat "AT+CPIN?"); echo "$R" | grep -q "READY" && ok "CPIN READY" || bad "CPIN: $R"
R=$(gat "AT+CEREG?"); echo "$R" | grep -q "+CEREG: .*,1" && ok "CEREG 已注册(home)" || bad "CEREG: $R"
R=$(gat "AT+CGATT?"); echo "$R" | grep -q "+CGATT: 1" && ok "CGATT 已附着" || bad "CGATT: $R"
ssh $SSH_OPTS test@127.0.0.1 "sudo ip link set $NETIF up; sudo dhclient -1 $NETIF 2>/dev/null; ip -4 addr show $NETIF | grep -q inet" \
  && ok "RNDIS 口有地址" || bad "RNDIS 口无地址"
C=$(ssh $SSH_OPTS test@127.0.0.1 "sudo ip route replace default via 10.0.3.2 dev $NETIF 2>/dev/null; ip route | grep default; curl -4 --interface $NETIF -s -m 15 -o /dev/null -w '%{http_code}' http://www.baidu.com")
echo "  route+code: $C"
echo "$C" | grep -q 200 && ok "真实联网 200" || bad "联网失败: $C"

step "[2/7] 订阅 URC（AT+CEREG=1 / AT+CGEREP=1）"
gat "AT+CEREG=1" >/dev/null; gat "AT+CGEREP=1" >/dev/null
R=$(gat "AT+CEREG?"); echo "$R" | grep -q "+CEREG: 1," && ok "URC 订阅生效" || bad "订阅: $R"

step "[3/7] 场景 no_sim: 拔卡（含 URC 捕获窗口）"
mon_start 12
ctl scenario no_sim >/dev/null
sleep 4
mon_stop
urc_has "+CEREG: 0" && ok "收到 URC +CEREG: 0" || bad "URC 未捕获"
R=$(gat "AT+CPIN?"); echo "$R" | grep -q "+CME ERROR: 10" && ok "CPIN? -> +CME ERROR: 10" || bad "CPIN: $R"
R=$(gat "AT+CEREG?"); echo "$R" | grep -q "+CEREG: .*,0" && ok "CEREG 未注册" || bad "CEREG: $R"
S=$(ctl status); echo "$S" | grep -q '"sim": "absent"' && ok "引擎状态 sim=absent" || bad "引擎状态: $S"

step "[4/7] 场景 normal 恢复"
ctl scenario normal >/dev/null
sleep 1
R=$(gat "AT+CPIN?"); echo "$R" | grep -q "READY" && ok "SIM 恢复" || bad "SIM: $R"
R=$(gat "AT+CEREG?"); echo "$R" | grep -q "+CEREG: .*,1" && ok "注册恢复" || bad "CEREG: $R"

step "[5/7] 场景 detached: 数据面真断（AT + 链路联动）"
mon_start 12
ctl scenario detached >/dev/null
sleep 4
mon_stop
urc_has "CGEV: ME DETACH" && ok "收到 URC +CGEV: ME DETACH" || bad "CGEV URC 未捕获"
R=$(gat "AT+CGATT?"); echo "$R" | grep -q "+CGATT: 0" && ok "CGATT 已去附着" || bad "CGATT: $R"
C=$(ssh $SSH_OPTS test@127.0.0.1 "curl -s -m 8 -o /dev/null -w '%{http_code}' http://www.baidu.com" 2>/dev/null)
echo "$C" | grep -qv 200 && ok "断网后 HTTP 不可达 (code=$C)" || bad "断网后仍可达: $C"

step "[6/7] 恢复 + 弱网注入（filter-buffer 500ms）"
ctl scenario normal >/dev/null
sleep 1
ssh $SSH_OPTS test@127.0.0.1 "sudo dhclient -1 $NETIF 2>/dev/null" >/dev/null
T0=$(ssh $SSH_OPTS test@127.0.0.1 "curl -s -m 20 -o /dev/null -w '%{time_total}' http://www.baidu.com")
ctl set_delay 500 >/dev/null
sleep 1
T=$(ssh $SSH_OPTS test@127.0.0.1 "curl -s -m 20 -o /dev/null -w '%{time_total}' http://www.baidu.com")
echo "  基线 ${T0}s -> 弱网 ${T}s"
python3 -c "import sys; sys.exit(0 if float('${T:-0}') >= float('${T0:-0}') + 0.2 else 1)" \
  && ok "弱网延迟生效 (+${T}s vs ${T0}s)" || bad "延迟未生效: ${T0}s -> ${T}s"
ctl set_delay 0 >/dev/null
sleep 1
T2=$(ssh $SSH_OPTS test@127.0.0.1 "curl -s -m 20 -o /dev/null -w '%{time_total}' http://www.baidu.com")
echo "  恢复后时延: ${T2}s"
python3 -c "import sys; sys.exit(0 if float('${T2:-9}') < float('${T:-0}') - 0.1 else 1)" \
  && ok "弱网清除后时延回落 (${T2}s)" || bad "时延未回落: ${T2}s"

step "[7/7] 信号注入 + 厂商扩展"
ctl set_signal 5 >/dev/null
R=$(gat "AT+CSQ"); echo "$R" | grep -q "+CSQ: 5,99" && ok "set_signal -> AT+CSQ: 5,99" || bad "CSQ: $R"
R=$(gat "AT+WMSTAT"); echo "$R" | grep -q "+WMSTAT:" && ok "厂商扩展 AT+WMSTAT 可用" || bad "WMSTAT: $R"
ctl scenario normal >/dev/null

echo
echo "=== P2 场景引擎验收: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] && echo "P2_ALL_GREEN" || echo "P2_HAS_FAILURES"
