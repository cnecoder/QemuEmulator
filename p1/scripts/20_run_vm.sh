#!/usr/bin/env bash
# [宿主侧] P1 PoC: 用自定义 QEMU 启动 VM（叠加 usb-wmodem 设备 + AT chardev）
# 用法: 20_run_vm.sh [--loadvm <tag>] 或 20_run_vm.sh --fresh（删除 overlay 全新冷启动）
set -euo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P0_DIR="$(cd "$P1_DIR/.." && pwd)"
cd "$P1_DIR"

LOADVM_ARGS=""
if [[ "${1:-}" == "--loadvm" ]]; then
    LOADVM_ARGS="-loadvm $2"
elif [[ "${1:-}" == "--fresh" ]]; then
    rm -f run/disk.qcow2
fi

QEMU="/work/build/qemu-9.2.0/build/qemu-system-aarch64"
QIMG="/work/build/qemu-9.2.0/build/qemu-img"
[[ -x "$P1_DIR/build/qemu-9.2.0/build/qemu-system-aarch64" ]] || { echo "ERROR: custom qemu not built"; exit 1; }

docker rm -f p1-vm >/dev/null 2>&1 || true
mkdir -p run logs
rm -f run/qmp.sock run/at0.sock
: > logs/serial.log

docker run -d --name p1-vm --network host --user "$(id -u):$(id -g)" \
    -v "$P1_DIR":/work -v "$P0_DIR/p0":/p0 -w /work p1-qemu-build bash -c "
    [[ -f run/disk.qcow2 ]] || $QIMG create -f qcow2 -b /p0/images/golden-noble-arm64.img -F qcow2 /work/run/disk.qcow2
    exec $QEMU \
        -M virt \
        -cpu max \
        -accel tcg,thread=multi \
        -smp 4 -m 2G \
        -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        -display none \
        -serial file:logs/serial.log \
        -qmp unix:run/qmp.sock,server,nowait \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2223-:22 \
        -device virtio-net-pci,netdev=n0,romfile= \
        -device virtio-rng-pci \
        -device qemu-xhci \
        -chardev socket,id=at0,path=/work/run/at0.sock,server=on,wait=off \
        -chardev null,id=diag \
        -chardev null,id=nmea \
        -netdev user,id=wnet \
        -device usb-wmodem,id=wm0,vendorid=0x1234,productid=0x5678,chardev=at0,serial1=diag,serial2=nmea,netdev=wnet \
        -drive file=run/disk.qcow2,if=virtio,format=qcow2 \
        -drive file=/p0/seed/seed.iso,if=virtio,format=raw,readonly=on \
        ${LOADVM_ARGS}
    " >/dev/null

echo "[p1-vm] started (SSH port 2223)"
