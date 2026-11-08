#!/usr/bin/env bash
# 启动 P1 验证 VM（两种模式）:
#   默认（宿主/WSL）: QEMU 作为分离容器的前台进程（docker run -d）
#   QEMU_DIRECT=1（CI 容器内）: 直接 nohup 启动 QEMU 进程（pid 记录在 run/qemu.pid）
# 用法: 20_run_vm.sh [--fresh] 或 20_run_vm.sh --loadvm <tag>
set -euo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P0_DIR="$(cd "$P1_DIR/.." && pwd)/p0"
cd "$P1_DIR"
mkdir -p run logs

LOADVM_ARGS=""
if [[ "${1:-}" == "--loadvm" ]]; then
    LOADVM_ARGS="-loadvm $2"
elif [[ "${1:-}" == "--fresh" ]]; then
    rm -f run/disk.qcow2 run/qemu.pid
fi

# 停掉已有实例（模式自适应）
bash "$(dirname "${BASH_SOURCE[0]}")/vm_stop.sh" 2>/dev/null || true
rm -f run/qmp.sock run/at0.sock
: > logs/serial.log

QEMU_DEFAULT="$P1_DIR/build/qemu-9.2.0/build/qemu-system-aarch64"
if [[ -n "${QEMU_CUSTOM:-}" ]]; then
    QDIR="$(dirname "$QEMU_CUSTOM")"
    QEMU="$QEMU_CUSTOM"
    QIMG="$QDIR/qemu-img"
else
    QEMU="$QEMU_DEFAULT"
    QIMG="$P1_DIR/build/qemu-9.2.0/build/qemu-img"
fi

T0=$(date +%s)
if [[ "${QEMU_DIRECT:-0}" == "1" ]]; then
    # ---- 直跑模式（CI 容器内）: 路径即真实路径 ----
    [[ -x "$QEMU" ]] || QEMU="qemu-system-aarch64"
    [[ -x "$QEMU" ]] || { echo "ERROR: qemu not found"; exit 1; }
    QIMG="$(dirname "$(command -v $QEMU)")/qemu-img"
    command -v qemu-img >/dev/null 2>&1 && QIMG="$(command -v qemu-img)"
    [[ -f run/disk.qcow2 ]] || $QIMG create -f qcow2 \
        -b "$P0_DIR/images/golden-noble-arm64.img" -F qcow2 run/disk.qcow2
    nohup $QEMU \
        -M virt -cpu max -accel tcg,thread=multi -smp 4 -m 2G \
        -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        -display none \
        -serial file:logs/serial.log \
        -qmp unix:run/qmp.sock,server,nowait \
        -pidfile run/qemu.pid \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2223-:22 \
        -device virtio-net-pci,netdev=n0,romfile= \
        -device virtio-rng-pci \
        -chardev socket,id=at0,path=run/at0.sock,server=on,wait=off \
        -chardev null,id=diag \
        -chardev null,id=nmea \
        -netdev user,id=wnet,net=10.0.3.0/24,dhcpstart=10.0.3.15 \
        -device usb-wmodem,id=wm0,vendorid=0x1234,productid=0x5678,chardev=at0,serial1=diag,serial2=nmea,netdev=wnet \
        -drive file=run/disk.qcow2,if=virtio,format=qcow2 \
        -drive file="$P0_DIR/seed/seed.iso",if=virtio,format=raw,readonly=on \
        ${LOADVM_ARGS} \
        > logs/qemu.stderr 2>&1 &
    echo $! > run/qemu.pid
    echo "[p1-vm] started (QEMU_DIRECT, pid $(cat run/qemu.pid)) (t0=$T0)"
    exit 0
fi

# ---- 容器模式（WSL/宿主默认）----
docker rm -f p1-vm >/dev/null 2>&1 || true

docker run -d --name p1-vm --network host --user "$(id -u):$(id -g)" \
    -v "$P1_DIR":"$P1_DIR" -v "$P0_DIR":"$P0_DIR" -w "$P1_DIR" \
    p1-qemu-build bash -c "
    [[ -f '$P1_DIR/run/disk.qcow2' ]] || $QIMG create -f qcow2 \
        -b '$P0_DIR/images/golden-noble-arm64.img' -F qcow2 '$P1_DIR/run/disk.qcow2'
    exec $QEMU \
        -M virt \
        -cpu max \
        -accel tcg,thread=multi \
        -smp 4 -m 2G \
        -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        -display none \
        -serial file:$P1_DIR/logs/serial.log \
        -qmp unix:$P1_DIR/run/qmp.sock,server,nowait \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2223-:22 \
        -device virtio-net-pci,netdev=n0,romfile= \
        -device virtio-rng-pci \
        -device qemu-xhci \
        -chardev socket,id=at0,path=$P1_DIR/run/at0.sock,server=on,wait=off \
        -chardev null,id=diag \
        -chardev null,id=nmea \
        -netdev user,id=wnet,net=10.0.3.0/24,dhcpstart=10.0.3.15 \
        -device usb-wmodem,id=wm0,vendorid=0x1234,productid=0x5678,chardev=at0,serial1=diag,serial2=nmea,netdev=wnet \
        -drive file=$P1_DIR/run/disk.qcow2,if=virtio,format=qcow2 \
        -drive file=$P0_DIR/seed/seed.iso,if=virtio,format=raw,readonly=on \
        ${LOADVM_ARGS}
    " >/dev/null

echo "[p1-vm] started (SSH port 2223) (t0=$T0)"
