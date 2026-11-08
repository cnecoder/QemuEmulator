#!/usr/bin/env bash
# 停止 VM（模式自适应）：CI 直跑模式按 pidfile 杀进程；容器模式 docker stop
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P1_DIR"
mkdir -p run

if [[ "${QEMU_DIRECT:-0}" == "1" ]]; then
    if [[ -f run/qemu.pid ]]; then
        pid="$(cat run/qemu.pid)"
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        rm -f run/qemu.pid
    fi
else
    docker stop -t 15 p1-vm >/dev/null 2>&1 || true
fi
exit 0
