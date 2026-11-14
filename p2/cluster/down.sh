#!/usr/bin/env bash
# 回收 p2 四容器集群
set -uo pipefail
P2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P2_DIR/cluster"
docker compose -p p2cluster down --remove-orphans
echo "[down] 集群已回收"
