#!/usr/bin/env bash
# [宿主侧] P1 PoC 验收（幂等）: 枚举 → 解绑 usbtouchscreen → option 绑定 → AT 往返
set -uo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR"
SSH_OPTS="-i ../p0/keys/id_ed25519 -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
PASS=0; FAIL=0
step() { echo; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

step "[1/4] guest 识别定制 VID/PID (1234:5678)"
IDS=$(ssh $SSH_OPTS test@127.0.0.1 '
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] || continue
  printf "%s:%s %s\n" "$(cat $d/idVendor)" "$(cat $d/idProduct)" "$(basename $d)"
done')
echo "$IDS"
echo "$IDS" | grep -q "1234:5678" && ok "枚举: 1234:5678 存在" || bad "未发现 1234:5678"

step "[2/4] 置备: 解绑 usbtouchscreen → option 绑定 → ttyUSB0"
OUT2=$(ssh $SSH_OPTS test@127.0.0.1 '
# 1) 解绑抢占者（usbtouchscreen 会按接口类 0xff 整类匹配定制 VID 设备）
IF=/sys/bus/usb/devices/1-1:1.0
if [ "$(readlink -f $IF/driver 2>/dev/null | xargs basename 2>/dev/null)" != "option" ] \
   && [ "$(readlink -f $IF/driver 2>/dev/null | xargs basename 2>/dev/null)" != "option1" ]; then
  echo 1-1:1.0 | sudo tee /sys/bus/usb/drivers/usbtouchscreen/unbind >/dev/null 2>&1
fi
# 2) option 动态 ID
sudo modprobe option 2>/dev/null
D=/sys/bus/usb-serial/drivers/option1; [ -d "$D" ] || D=/sys/bus/usb-serial/drivers/option
echo "1234 5678" | sudo tee $D/new_id >/dev/null
sleep 2
# 3) 清理历史遗留的假节点（bash 重定向可能创建同名普通文件）
if [ -e /dev/ttyUSB0 ] && [ ! -c /dev/ttyUSB0 ]; then sudo rm -f /dev/ttyUSB0; fi
if [ ! -e /dev/ttyUSB0 ]; then sudo mknod /dev/ttyUSB0 c 188 0; fi
ls -l /dev/ttyUSB0
readlink -f $IF/driver | xargs basename')
echo "$OUT2"
echo "$OUT2" | grep -q "^crw" && ok "ttyUSB0 为字符设备节点" || bad "ttyUSB0 节点异常"
echo "$OUT2" | tail -1 | grep -q "^option" && ok "接口驱动 = option" || bad "接口驱动非 option"

step "[3/4] host 侧 AT 应答器上线"
pkill -f "21_at_responder" 2>/dev/null || true
nohup python3 scripts/21_at_responder.py run/at0.sock 300 > logs/at_responder.log 2>&1 &
RESP_PID=$!
sleep 2
grep -q "connected" logs/at_responder.log && ok "应答器已连接 chardev" || { bad "应答器未连上"; exit 1; }

step "[4/4] AT 命令经 USB 串口往返"
ATOUT=$(ssh $SSH_OPTS test@127.0.0.1 '
sudo bash -c "
stty -F /dev/ttyUSB0 -echo raw 2>/dev/null
exec 3<>/dev/ttyUSB0
printf \"ATI\r\" >&3
sleep 2
echo READ1:
timeout 3 cat <&3
printf \"AT+CSQ\r\" >&3
sleep 2
echo READ2:
timeout 3 cat <&3
exec 3<&-
"')
echo "$ATOUT"
echo "$ATOUT" | grep -q "WModem PoC 1.0" && ok "ATI 应答正确" || bad "ATI 应答异常"
echo "$ATOUT" | grep -q "+CSQ: 18,99" && ok "AT+CSQ 应答正确" || bad "AT+CSQ 应答异常"

echo
echo "=== PoC 结果: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] && echo "POC_ALL_GREEN" || echo "POC_HAS_FAILURES"
kill $RESP_PID 2>/dev/null || true
