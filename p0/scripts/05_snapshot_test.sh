#!/usr/bin/env bash
# [宿主侧] P0 快照复位验证:
#   VM 内写标记 → savevm → 停机 → loadvm 重启 → 标记/uptime 应还原（证明秒级复位）
set -euo pipefail
P0_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P0_DIR"
TAG=p0snap
SSH_OPTS="-i keys/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

echo "=== [1/5] VM 内写标记 + 记录 uptime ==="
ssh $SSH_OPTS test@127.0.0.1 \
    'echo "before-snapshot $(date)" | sudo tee /var/tmp/p0-marker && cat /proc/uptime'

echo "=== [2/5] savevm ==="
python3 scripts/qmp_savevm.py run/qmp.sock "$TAG"

echo "=== [3/5] 停机 ==="
docker stop -t 15 p0-vm >/dev/null
echo "[3/5] VM stopped"

echo "=== [4/5] loadvm 重启 ==="
T0=$(date +%s)
scripts/03_run_vm.sh --loadvm "$TAG"
sleep 5
echo "[4/5] loadvm restart wall time: $(( $(date +%s) - T0 ))s"

echo "=== [5/5] 验证还原状态 ==="
OUT=""
for i in $(seq 1 40); do
    OUT=$(ssh $SSH_OPTS test@127.0.0.1 \
        'cat /var/tmp/p0-marker && cat /proc/uptime' 2>/dev/null) && break
    sleep 3
done
if [[ -z "$OUT" ]]; then echo "SNAPSHOT_TEST_FAIL: ssh unreachable"; exit 1; fi
echo "$OUT"
MARKER=$(echo "$OUT" | head -1 | grep -c "before-snapshot" || true)
UP=$(echo "$OUT" | tail -1 | awk '{print $1}' | awk -F. '{print $1}')
if [[ "$MARKER" == "1" && "$UP" -gt 60 ]]; then
    echo "SNAPSHOT_TEST_PASS: 标记还原 ✓, uptime=${UP}s (非冷启动, 状态已还原)"
else
    echo "SNAPSHOT_TEST_FAIL: marker=$MARKER uptime=${UP}s"
    exit 1
fi
