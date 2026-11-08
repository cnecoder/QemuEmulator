#!/usr/bin/env bash
# [容器内] 配置并编译带 usb-wmodem 的自定义 QEMU (aarch64-softmmu)
set -euo pipefail
cd /work/build/qemu-9.2.0

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
echo "BUILD_OK: $(ls -la qemu-system-aarch64)"
