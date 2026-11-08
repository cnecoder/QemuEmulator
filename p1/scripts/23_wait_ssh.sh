#!/usr/bin/env bash
# [宿主侧] 等待 P1 VM 可 SSH（端口 2223）
set -euo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR"
TIMEOUT="${1:-900}"
T0=$(date +%s)
SSH_OPTS="-i ../p0/keys/id_ed25519 -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

while true; do
    NOW=$(date +%s); ELAPSED=$((NOW - T0))
    (( ELAPSED > TIMEOUT )) && { echo "[wait] TIMEOUT"; tail -20 logs/serial.log; exit 1; }
    grep -q "P0_CLOUD_INIT_DONE" logs/serial.log 2>/dev/null && { echo "[wait] cloud-init done at ${ELAPSED}s"; break; }
    sleep 5
done

for i in $(seq 1 30); do
    ssh $SSH_OPTS test@127.0.0.1 "echo SSH_OK \$(uname -m)" 2>/dev/null && { echo "[wait] ssh OK, total $(( $(date +%s) - T0 ))s"; exit 0; }
    sleep 5
done
echo "[wait] ssh probe failed"; tail -30 logs/serial.log; exit 1
