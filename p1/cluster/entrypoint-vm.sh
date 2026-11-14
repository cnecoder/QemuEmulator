#!/bin/bash
# 设备容器入口（一期·可行性）: root 搭 tap/网桥 → 降权 exec QEMU
#
# 容器网络（compose）: eth(第一个网) = 链路1 所在段, eth(第二个网) = 链路2 所在段
# QEMU 侧: mgmt=slirp(hostfwd SSH) + l1/l2=tap（经容器内网桥上 docker 段，真以太网帧）
set -euo pipefail

QEMU="$P1_DIR/build/qemu-custom/qemu-system-aarch64"
[[ -x "$QEMU" ]] || { echo "ERROR: 自定义 QEMU 未构建"; exit 1; }

# 按容器自身 IP 前缀定位链路段接口（compose 静态 IP .10）
ETH_L1=$(ip -o -4 addr show | grep "${SEG_L1}" | awk '{print $2}' | head -1)
ETH_L2=$(ip -o -4 addr show | grep "${SEG_L2}" | awk '{print $2}' | head -1)
[[ -n "$ETH_L1" && -n "$ETH_L2" ]] || { echo "ERROR: 链路网段接口未找到 ($SEG_L1 / $SEG_L2)"; exit 1; }

mk_link() {  # <br> <tap> <eth>
    ip link add "$1" type bridge
    ip tuntap add dev "$2" mode tap user "${HOST_UID}"   # 属主=QEMU 运行 uid，非 root 可 attach
    ip link set "$2" master "$1"
    ip link set "$3" master "$1"
    ip link set "$1" up && ip link set "$2" up && ip link set "$3" up
    # 容器自身 IP 从端口挪到网桥：enslave 后端口上的 IP 会导致容器协议栈 ARP 路径损坏，
    # docker 端口发布/DNAT 随之失效（实测坑）
    local cidr
    cidr=$(ip -o -4 addr show "$3" | awk '{print $4}' | head -1)
    if [ -n "$cidr" ]; then
        ip addr flush dev "$3"
        ip addr add "$cidr" dev "$1"
    fi
    echo "[vm-$ROLE] $3($2) -> $1"
}
mk_link br-link1 tap-l1 "$ETH_L1"
mk_link br-link2 tap-l2 "$ETH_L2"

mkdir -p "$P1_DIR/logs" "$P1_DIR/run"

echo "[vm-$ROLE] exec QEMU (uid=$HOST_UID)"
exec setpriv --reuid "$HOST_UID" --regid "$HOST_GID" --clear-groups "$QEMU" \
    -M virt -cpu max -accel tcg,thread=multi -smp 4 -m 2G \
    -global virtio-pci.romfile= \
    -bios "$P1_DIR/compat/QEMU_EFI.fd" \
    -display none \
    -serial file:"$P1_DIR/logs/serial-$ROLE.log" \
    -qmp unix:"$P1_DIR/run/qmp-$ROLE.sock",server,nowait \
    -netdev user,id=mgmt,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=mgmt,mac=${MGMT_MAC},romfile= \
    -device virtio-rng-pci \
    -netdev tap,id=l1,ifname=tap-l1,script=no,downscript=no \
    -device virtio-net-pci,netdev=l1,mac=${L1_MAC},romfile= \
    -netdev tap,id=l2,ifname=tap-l2,script=no,downscript=no \
    -device virtio-net-pci,netdev=l2,mac=${L2_MAC},romfile= \
    -drive file="$DISK",if=virtio,format=qcow2 \
    -drive file="$P0_DIR/seed/seed.iso",if=virtio,format=raw,readonly=on
