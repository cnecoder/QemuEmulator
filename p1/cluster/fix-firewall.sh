#!/usr/bin/env bash
# [宿主侧] 修复 docker 28 防火墙后端对四容器集群桥内互访的拦截。
#
# 背景（实测）：
#   1) docker 在 raw PREROUTING 为每个容器 IP 加 "iif != 自家网桥则 drop" 规则，
#      杀掉跨段桥转发的帧（guest→server 的目的 IP 是 server 容器 IP）；
#   2) 桥内 netfilter 呈现的 iif 是网桥设备名，按物理端口/网桥名插 ACCEPT 都难覆盖。
#   解法：raw PREROUTING 顶部对 10.0.0.0/8 目的统一放行（仅本集群网段，homevault 等不受影响）。
#
# 注意：docker 在网络/容器事件后可能重建规则——每次 compose up/重建后需重跑本脚本（up.sh 已自动调用）。
set -euo pipefail
docker run --rm --privileged --net=host ubuntu:26.04 bash -c '
apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq iptables >/dev/null 2>&1
iptables -t raw -C PREROUTING -d 10.0.0.0/8 -j ACCEPT 2>/dev/null \
  || iptables -t raw -I PREROUTING 1 -d 10.0.0.0/8 -j ACCEPT
iptables -C FORWARD -i "veth+" -o "veth+" -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -i "veth+" -o "veth+" -j ACCEPT
echo "[fix-firewall] raw/forward 放行规则就位"
iptables -t raw -S PREROUTING | head -2'
