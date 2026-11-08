#!/usr/bin/env bash
# [宿主侧] 用分离容器启动 QEMU（QEMU 为容器前台进程，容器存活=VM存活）
# 用法: 03_run_vm.sh [--loadvm <tag>]
set -euo pipefail
P0_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$P0_DIR"

LOADVM_ARGS=""
if [[ "${1:-}" == "--loadvm" ]]; then
    LOADVM_ARGS="-loadvm $2"
fi

docker rm -f p0-vm >/dev/null 2>&1 || true
rm -f run/qmp.sock
: > logs/serial.log

T0=$(date +%s)
docker run -d --name p0-vm --network host --user "$(id -u):$(id -g)" \
    -v "$P0_DIR":/work -w /work p0-qemu bash -c "
    [[ -f run/disk.qcow2 ]] || qemu-img create -f qcow2 -b /work/images/golden-noble-arm64.img -F qcow2 /work/run/disk.qcow2
    exec qemu-system-aarch64 \
        -M virt \
        -cpu max \
        -accel tcg,thread=multi \
        -smp 4 -m 2G \
        -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        -display none \
        -serial file:logs/serial.log \
        -qmp unix:run/qmp.sock,server,nowait \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -device virtio-net-pci,netdev=n0,romfile= \
        -device virtio-rng-pci \
        -drive file=run/disk.qcow2,if=virtio,format=qcow2 \
        -drive file=seed/seed.iso,if=virtio,format=raw,readonly=on \
        ${LOADVM_ARGS}
    " >/dev/null

echo "[vm] container p0-vm started (t0=$T0)"
