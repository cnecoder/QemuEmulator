#!/usr/bin/env bash
# [宿主侧] 等待 VM 可 SSH 登录（监听 cloud-init 完成标记 + ssh 探测）
# 用法: 04_wait_ssh.sh [timeout_sec]
set -euo pipefail
P0_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P0_DIR"
TIMEOUT="${1:-900}"
T0=$(date +%s)
SSH_OPTS="-i keys/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

echo "[wait] polling serial log for boot progress ..."
while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - T0))
    if (( ELAPSED > TIMEOUT )); then
        echo "[wait] TIMEOUT after ${ELAPSED}s. Last serial output:"
        tail -20 logs/serial.log
        exit 1
    fi
    if grep -q "P0_CLOUD_INIT_DONE" logs/serial.log 2>/dev/null; then
        echo "[wait] cloud-init finished at ${ELAPSED}s"
        break
    fi
    sleep 5
done

echo "[wait] probing ssh ..."
for i in $(seq 1 30); do
    if ssh $SSH_OPTS test@127.0.0.1 "echo SSH_OK from \$(hostname) \$(uname -m)" 2>/dev/null; then
        echo "[wait] total time to SSH: $(( $(date +%s) - T0 ))s"
        exit 0
    fi
    sleep 5
done
echo "[wait] ssh probe failed"
tail -30 logs/serial.log
exit 1
