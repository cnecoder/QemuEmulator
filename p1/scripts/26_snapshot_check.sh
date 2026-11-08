#!/usr/bin/env bash
# [宿主侧] 快照兼容验证: AT 正常 → savevm → 停机 → loadvm → 设备/网络/AT 恢复
set -uo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR"
SSH_OPTS="-i ../p0/keys/id_ed25519 -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
PASS=0; FAIL=0
step() { echo; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

step "[1/4] 快照前: 置备 + 写标记 + AT 确认"
pkill -f "wm_scenario_engine.py" 2>/dev/null || true
sleep 1
bash scripts/25_verify_all.sh 2>&1 | grep -E "^===|✓|✗|ALL_GREEN|HAS_FAILURES" | tail -3
ssh $SSH_OPTS test@127.0.0.1 'echo "before-snapshot $(date)" | sudo tee /var/tmp/p1-marker >/dev/null; cat /proc/uptime' || exit 1
ok "标记已写入"

step "[2/4] savevm (QMP snapshot-save)"
python3 ../p0/scripts/qmp_savevm.py run/qmp.sock p1snap || { bad "savevm 失败"; exit 1; }
ok "快照写入"

step "[3/4] 停机 → loadvm 重启"
bash "$(dirname "${BASH_SOURCE[0]}")/vm_stop.sh" >/dev/null
T0=$(date +%s)
bash scripts/20_run_vm.sh --loadvm p1snap
sleep 8
echo "[3/4] loadvm 重启 wall: $(( $(date +%s) - T0 ))s"

step "[4/4] 恢复态断言"
OUT=""
for i in $(seq 1 60); do
  OUT=$(ssh $SSH_OPTS test@127.0.0.1 '
    cat /var/tmp/p1-marker 2>/dev/null
    ls /dev/ttyUSB* 2>/dev/null | tr "\n" " "
    readlink -f /sys/bus/usb/devices/1-1:1.0/driver 2>/dev/null | xargs basename 2>/dev/null' 2>/dev/null) && break
  sleep 3
done
echo "$OUT"
echo "$OUT" | grep -q "before-snapshot" && ok "标记还原（状态恢复）" || bad "标记丢失"
echo "$OUT" | grep -q "ttyUSB0" && ok "ttyUSB0 恢复" || bad "ttyUSB0 丢失"
echo "$OUT" | grep -q "option" && ok "option 绑定恢复" || bad "绑定丢失"

# 恢复后 AT 往返
pkill -f "21_at_responder" 2>/dev/null || true
nohup python3 scripts/21_at_responder.py run/at0.sock 300 > logs/at_responder.log 2>&1 &
RESP_PID=$!
sleep 2
ATOUT=$(ssh $SSH_OPTS test@127.0.0.1 'sudo bash -c "exec 3<>/dev/ttyUSB0; printf \"ATI\r\" >&3; sleep 2; timeout 3 cat <&3; exec 3<&-"')
echo "$ATOUT"
echo "$ATOUT" | grep -q "WModem PoC 1.0" && ok "loadvm 后 AT 往返恢复" || bad "loadvm 后 AT 不通"

echo
echo "=== 快照兼容验证: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] && echo "SNAPSHOT_ALL_GREEN" || echo "SNAPSHOT_HAS_FAILURES"
kill $RESP_PID 2>/dev/null || true
