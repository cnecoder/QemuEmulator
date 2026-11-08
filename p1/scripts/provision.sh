#!/bin/bash
# [guest 内执行] 虚拟蜂窝模块置备（幂等）
# 1) 黑名单抢占驱动 2) 顺序置备(rndis_host 先 / option 后) 3) 节点防护 4) 就绪轮询
set -u
for i in $(seq 1 15); do ls /sys/bus/usb/devices/ 2>/dev/null | grep -q '^1-1:1' && break; sleep 1; done

# 1) 防抢占：usbtouchscreen 会认领 0xff/0xEF/0x0A 接口 —— 黑名单 + 卸载
grep -q usbtouchscreen /etc/modprobe.d/99-wmodem.conf 2>/dev/null || \
  printf "blacklist usbtouchscreen\n" > /etc/modprobe.d/99-wmodem.conf
rmmod usbtouchscreen 2>/dev/null

# 2) option 依赖包按需安装（优先走已有索引；缺索引时先 update）
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
for i in $(seq 1 20); do [ -d /sys/bus/usb/devices/1-1:1.4 ] && break; sleep 1; done
sleep 1
modprobe option 2>/dev/null
[ -d "$D" ] && echo "1234 5678" > "$D/new_id" 2>/dev/null
sleep 1

# 4) 假节点防护：非字符设备的 ttyUSB 一律删除；内核已注册而节点缺失的补建
for t in /dev/ttyUSB*; do [ -e "$t" ] && [ ! -c "$t" ] && rm -f "$t"; done
for t in /sys/class/tty/ttyUSB*; do
  b=$(basename "$t"); dm=$(cat "$t/dev" 2>/dev/null)
  [ -n "$dm" ] && [ ! -c "/dev/$b" ] && mknod "/dev/$b" c ${dm%:*} ${dm#*:}
done

# 5) 轮询就绪: 3 个串口字符节点 + RNDIS 网口（最多 60s；未绑定时重试 new_id）
for i in $(seq 1 60); do
  ready=1
  for t in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do [ -c "$t" ] || ready=0; done
  rndis_net=0
  for n in /sys/class/net/*; do readlink -f "$n/device" 2>/dev/null | grep -q "1-1:1.3" && rndis_net=1; done
  [ "$ready" = "1" ] && [ "$rndis_net" = "1" ] && break
  [ "$ready" = "0" ] && [ -d "$D" ] && echo "1234 5678" > "$D/new_id" 2>/dev/null
  sleep 1
done
exit 0
