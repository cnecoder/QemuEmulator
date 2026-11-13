#!/usr/bin/env bash
# [宿主侧] 集群回收
set -u
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker rm -f p1-vm-a p1-vm-b >/dev/null 2>&1 || true
pkill -f "wm_linkd.py" 2>/dev/null || true
pkill -f "engine-a.sock" 2>/dev/null || true
pkill -f "engine-b.sock" 2>/dev/null || true
echo "[cluster] down"
