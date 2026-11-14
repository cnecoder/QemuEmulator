#!/usr/bin/env bash
# 生成集群 SSH 密钥对（仅本地虚拟机测试用；缺失才生成，幂等）
set -euo pipefail
KEYS_DIR="${1:-/work/keys}"
mkdir -p "$KEYS_DIR"
if [ ! -f "$KEYS_DIR/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -C "p2-lab" -f "$KEYS_DIR/id_ed25519" >/dev/null
    echo "[keys] generated $KEYS_DIR/id_ed25519"
else
    echo "[keys] exists: $KEYS_DIR/id_ed25519"
fi
