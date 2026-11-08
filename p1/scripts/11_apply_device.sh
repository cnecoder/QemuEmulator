#!/usr/bin/env bash
# 将 usb-wmodem 设备模型接入 QEMU 源码树（幂等）
set -euo pipefail
cd /work/build/qemu-9.2.0

cp /work/device/dev-wmodem.c hw/usb/dev-wmodem.c

if ! grep -q 'config USB_WMODEM' hw/usb/Kconfig; then
cat >> hw/usb/Kconfig <<'EOF'

config USB_WMODEM
    bool
    default y
    depends on USB
EOF
fi

if ! grep -q 'dev-wmodem.c' hw/usb/meson.build; then
cat >> hw/usb/meson.build <<'EOF'
system_ss.add(when: 'CONFIG_USB_WMODEM', if_true: files('dev-wmodem.c'))
EOF
fi

echo "[wire] dev-wmodem wired into hw/usb"
