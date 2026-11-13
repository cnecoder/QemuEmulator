#!/usr/bin/env bash
# [容器内] 编译带 usb-wmodem 设备的自定义 QEMU
# 版本由 QEMU_VER 控制（默认 11.1.3），产物复制到稳定路径 build/qemu-custom/
set -euo pipefail
export QEMU_VER="${QEMU_VER:-11.1.3}"

if [ ! -f "/work/src/qemu-${QEMU_VER}.tar.xz" ]; then
    echo "ERROR: /work/src/qemu-${QEMU_VER}.tar.xz not found（先下载到 p1/src/）"
    exit 1
fi

cd /work/build
[ -d "qemu-${QEMU_VER}" ] || tar -xf "/work/src/qemu-${QEMU_VER}.tar.xz"
cd "qemu-${QEMU_VER}"

bash /work/scripts/11_apply_device.sh

mkdir -p build && cd build
if [ ! -f config-host.mak ]; then
    ../configure \
        --target-list=aarch64-softmmu \
        --disable-docs \
        --disable-guest-agent \
        --disable-werror
fi
make -j"$(nproc)"

# 稳定产物路径（与版本号解耦，供 20_run_vm.sh / CI 使用）
mkdir -p /work/build/qemu-custom
cp -f qemu-system-aarch64 /work/build/qemu-custom/
cp -f qemu-img /work/build/qemu-custom/ 2>/dev/null || true
echo "BUILD_OK: $(ls -la /work/build/qemu-custom/)"
