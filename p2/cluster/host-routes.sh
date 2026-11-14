#!/usr/bin/env bash
# [宿主侧] 为真实段网段加宿主路由（路线甲收尾件）。
#
# 背景：docker 网段为 10.9.x 簿记后，宿主对真实段（10.0.100~202.0/24）没有路由，
# 宿主侧的 SSH 直连/验收（check.py）到不了 guest。真实段经各 docker 网桥二层可达
# （guest MAC 会被宿主网桥学习），只需 dev 路由，无需网关。
#
# 注意：与 p1 集群共存时 replace 会让 p2 路由胜出（两套真实段重叠，不可同时验收）。
set -euo pipefail
BR_A1=$(docker network inspect p2cluster_seg-a1 --format '{{.Id}}' | head -c 12)
BR_B1=$(docker network inspect p2cluster_seg-b1 --format '{{.Id}}' | head -c 12)
BR_S1=$(docker network inspect p2cluster_seg-s1 --format '{{.Id}}' | head -c 12)
BR_A2=$(docker network inspect p2cluster_seg-a2 --format '{{.Id}}' | head -c 12)
BR_B2=$(docker network inspect p2cluster_seg-b2 --format '{{.Id}}' | head -c 12)
BR_S2=$(docker network inspect p2cluster_seg-s2 --format '{{.Id}}' | head -c 12)

docker run --rm --privileged --net=host ubuntu:26.04 bash -c '
apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq iproute2 >/dev/null 2>&1
ip route replace 10.0.100.0/24 dev br-'"$BR_A1"'
ip route replace 10.0.101.0/24 dev br-'"$BR_B1"'
ip route replace 10.0.102.0/24 dev br-'"$BR_S1"'
ip route replace 10.0.200.0/24 dev br-'"$BR_A2"'
ip route replace 10.0.201.0/24 dev br-'"$BR_B2"'
ip route replace 10.0.202.0/24 dev br-'"$BR_S2"'
echo "[host-routes] 6 条真实段路由就位"
ip route show | grep "^10\.0\." | head -6'
