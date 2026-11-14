#!/usr/bin/env bash
# 回收四容器集群
set -uo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR/cluster"
docker compose -p p1cluster down --remove-orphans
echo "[down] 集群已回收"
