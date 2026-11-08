#!/usr/bin/env bash
# [宿主侧] P1 全量验收: 枚举/in字段/多串口/RNDIS联网/AT往返（幂等，含置备）
set -uo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR"
SSH_OPTS="-i ../p0/keys/id_ed25519 -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
PASS=0; FAIL=0
step() { echo; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

step "[0/5] 置备（幂等：黑名单抢占驱动 → 顺序置备 → 重新枚举）"
ssh $SSH_OPTS test@127.0.0.1 'sudo bash -s' <<'PROV' >/dev/null 2>&1
for i in $(seq 1 15); do ls /sys/bus/usb/devices/ 2>/dev/null | grep -q '^1-1:1' && break; sleep 1; done
# 1) 防抢占：usbtouchscreen 会认领 0xff/0xEF/0x0A 接口 —— 黑名单阻止 modalias 自动加载
grep -q usbtouchscreen /etc/modprobe.d/99-wmodem.conf 2>/dev/null || \
  printf "blacklist usbtouchscreen\n" > /etc/modprobe.d/99-wmodem.conf
rmmod usbtouchscreen 2>/dev/null
# 2) option 依赖包按需安装
D=/sys/bus/usb-serial/drivers/option1; [ -d "$D" ] || D=/sys/bus/usb-serial/drivers/option
if ! [ -d "$D" ]; then
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq linux-modules-extra-"$(uname -r)" >/dev/null 2>&1
fi
rmmod option 2>/dev/null
# 3) 顺序置备：先 rndis_host 认领 RNDIS 接口，再 option 认领串口
modprobe rndis_host 2>/dev/null
echo 0 > /sys/bus/usb/devices/1-1/authorized
sleep 1
echo 1 > /sys/bus/usb/devices/1-1/authorized
sleep 2
modprobe option 2>/dev/null
[ -d "$D" ] && echo "1234 5678" > "$D/new_id" 2>/dev/null
sleep 1
# 4) 假节点防护
for t in /dev/ttyUSB*; do [ -e "$t" ] && [ ! -c "$t" ] && rm -f "$t"; done
for t in /sys/class/tty/ttyUSB*; do
  b=$(basename "$t"); dm=$(cat "$t/dev" 2>/dev/null)
  [ -n "$dm" ] && [ ! -c "/dev/$b" ] && mknod "/dev/$b" c ${dm%:*} ${dm#*:}
done
# 5) 轮询就绪: 3 个串口字符节点 + RNDIS 网口（最多 60s，TCG 下驱动探测可能偏慢）
for i in $(seq 1 60); do
  ready=1
  for t in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do [ -c "$t" ] || ready=0; done
  rndis_net=0
  for n in /sys/class/net/*; do readlink -f "$n/device" 2>/dev/null | grep -q "1-1:1.3" && rndis_net=1; done
  [ "$ready" = "1" ] && [ "$rndis_net" = "1" ] && break
  sleep 1
done
exit 0
PROV
ok "置备脚本执行完成"

step "[1/5] 定制 VID/PID 枚举"
IDS=$(ssh $SSH_OPTS test@127.0.0.1 'for d in /sys/bus/usb/devices/1-1*; do [ -f "$d/idVendor" ] && echo "$(cat $d/idVendor):$(cat $d/idProduct) $(basename $d)"; done')
echo "$IDS"
echo "$IDS" | grep -q "1234:5678" && ok "复合设备枚举 1234:5678" || bad "未发现设备"

step "[2/5] uevent MODALIAS 的 in 字段核对（软件识别依据）"
MODS=$(ssh $SSH_OPTS test@127.0.0.1 'for i in 0 1 2 3 4; do echo "if$i: $(grep MODALIAS /sys/bus/usb/devices/1-1:1.$i/uevent 2>/dev/null)"; done')
echo "$MODS"
echo "$MODS" | grep -q "if0: MODALIAS=.*in00" && echo "$MODS" | grep -q "if0: MODALIAS=.*icFFisc00" && ok "in00 = 0xff 串口 (AT)" || bad "in00 异常"
echo "$MODS" | grep -q "if1: MODALIAS=.*in01" && ok "in01 = 0xff 串口 (diag)" || bad "in01 异常"
echo "$MODS" | grep -q "if2: MODALIAS=.*in02" && ok "in02 = 0xff 串口 (nmea)" || bad "in02 异常"
echo "$MODS" | grep -q "if3: MODALIAS=.*in03" && echo "$MODS" | grep -q "icEFisc04ip01in03" && ok "in03 = 0xEF/0x04/0x01 RNDIS 控制" || bad "in03 异常"
echo "$MODS" | grep -q "if4: MODALIAS=.*in04" && echo "$MODS" | grep -q "if4: MODALIAS=.*ic0A" && ok "in04 = 0x0a RNDIS 数据" || bad "in04 异常"

step "[3/5] 多串口绑定 (ttyUSB0/1/2) + 网口出现"
DEV=$(ssh $SSH_OPTS test@127.0.0.1 '
ls -l /dev/ttyUSB* 2>/dev/null
basename "$(readlink -f /sys/bus/usb/devices/1-1:1.0/driver 2>/dev/null)" 2>/dev/null
for n in /sys/class/net/*; do readlink -f "$n/device" 2>/dev/null | grep -q "1-1:1.3" && echo "NETIF=$(basename $n)"; done')
echo "$DEV"
echo "$DEV" | grep -q "ttyUSB0" && echo "$DEV" | grep -q "ttyUSB1" && echo "$DEV" | grep -q "ttyUSB2" && echo "$DEV" | grep -q "crw" && ok "ttyUSB0/1/2 全部为字符设备" || bad "串口节点异常"
echo "$DEV" | grep -q "option" && ok "AT 接口驱动 = option" || bad "驱动绑定异常"
NETIF=$(echo "$DEV" | grep '^NETIF=' | cut -d= -f2)
[ -n "$NETIF" ] && ok "RNDIS 网口出现: $NETIF" || bad "未发现 RNDIS 网口"

# 假节点清理 + 缺失节点兜底（脚本红线：绝不在非字符设备上做 AT 测试）
ssh $SSH_OPTS test@127.0.0.1 '
for t in /dev/ttyUSB*; do [ -e "$t" ] && [ ! -c "$t" ] && sudo rm -f "$t"; done
for t in /sys/class/tty/ttyUSB*; do
  b=$(basename "$t"); dm=$(cat "$t/dev" 2>/dev/null)
  [ -n "$dm" ] && [ ! -c "/dev/$b" ] && sudo mknod "/dev/$b" c ${dm%:*} ${dm#*:}
done; exit 0'

step "[4/5] RNDIS 数据面: DHCP + 真实联网"
NETOUT=$(ssh $SSH_OPTS test@127.0.0.1 "
sudo dhclient -1 $NETIF 2>/dev/null; sleep 1
ip -4 addr show $NETIF | grep inet
ping -c1 -W3 10.0.2.2 >/dev/null 2>&1 && echo GW_OK
if command -v curl >/dev/null; then curl -s -m 15 -o /dev/null -w '%{http_code}' http://www.baidu.com
elif command -v wget >/dev/null; then wget -q -T 15 -O /dev/null http://www.baidu.com && echo 200
else echo NO_TOOL; fi")
echo "$NETOUT"
echo "$NETOUT" | grep -q "inet 10\.0\.2\.15" && ok "DHCP 获得 10.0.2.15" || bad "DHCP 失败"
echo "$NETOUT" | grep -q "GW_OK" && ok "网关可达" || bad "网关不通"
echo "$NETOUT" | grep -q "200" && ok "真实互联网 HTTP 200" || bad "互联网不通"

step "[5/5] AT 往返 (ttyUSB0 ↔ 场景引擎)"
pkill -f "21_at_responder" 2>/dev/null || true
nohup python3 scripts/21_at_responder.py run/at0.sock 300 > logs/at_responder.log 2>&1 &
RESP_PID=$!
for i in $(seq 1 15); do grep -q "connected" logs/at_responder.log 2>/dev/null && break; sleep 1; done
ATOUT=$(ssh $SSH_OPTS test@127.0.0.1 '
sudo bash -c "
stty -F /dev/ttyUSB0 -echo raw 2>/dev/null
exec 3<>/dev/ttyUSB0
printf \"ATI\r\" >&3; sleep 2; echo R1:; timeout 3 cat <&3
printf \"AT+CSQ\r\" >&3; sleep 2; echo R2:; timeout 3 cat <&3
exec 3<&-"')
echo "$ATOUT"
echo "$ATOUT" | grep -q "WModem PoC 1.0" && ok "ATI 应答正确" || bad "ATI 应答异常"
echo "$ATOUT" | grep -q "+CSQ: 18,99" && ok "AT+CSQ 应答正确" || bad "AT+CSQ 应答异常"

echo
echo "=== P1 全量验收: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] && echo "P1_ALL_GREEN" || echo "P1_HAS_FAILURES"
kill $RESP_PID 2>/dev/null || true
