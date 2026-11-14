#!/usr/bin/env bash
# [宿主侧] 多设备集群拉起: 两台设备虚拟机 + 两条独立链路 + 每设备场景引擎
#
# 拓扑:
#   设备A (ssh 2223) --link1--> 设备B (ssh 2323)     10.0.100.1 <-> 10.0.100.2
#        A           --link2-->        B            10.0.200.1 <-> 10.0.200.2
#   链路经 wm_linkd 损伤代理（UDP 转发，可独立施加时延/抖动/丢包/带宽）
#
# 每台设备仍带 usb-wmodem 蜂窝模块（各自的 slirp 网络与场景引擎）。
set -euo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P0_DIR="$(cd "$P1_DIR/.." && pwd)/p0"
cd "$P1_DIR"
mkdir -p run logs

QEMU="$P1_DIR/build/qemu-custom/qemu-system-aarch64"
QIMG="$P1_DIR/build/qemu-custom/qemu-img"
[[ -x "$QEMU" ]] || { echo "ERROR: 自定义 QEMU 未构建（p1/build/qemu-custom/）"; exit 1; }

# ---- 损伤代理 ----
pkill -f "wm_linkd.py" 2>/dev/null || true
sleep 0.5
cat > run/links.json <<'EOF'
{"links": {
  "link1": {"a_listen": ["127.0.0.1", 4001], "b_listen": ["127.0.0.1", 4002],
            "a_dest": ["127.0.0.1", 4101], "b_dest": ["127.0.0.1", 4102]},
  "link2": {"a_listen": ["127.0.0.1", 4003], "b_listen": ["127.0.0.1", 4004],
            "a_dest": ["127.0.0.1", 4103], "b_dest": ["127.0.0.1", 4104]}
}}
EOF
nohup python3 cluster/wm_linkd.py run/links.json run/linkd.sock > logs/linkd.log 2>&1 &
sleep 1

# ---- 单台设备启动函数 ----
# start_device <name> <ssh_port> <disk> <mgmt_mac> <l1_mac> <l2_mac> <l1_udp> <l1_local> <l2_udp> <l2_local>
start_device() {
    local NAME=$1 SSH_PORT=$2 DISK=$3 MGMT_MAC=$4 L1_MAC=$5 L2_MAC=$6
    local L1_UDP=$7 L1_LOCAL=$8 L2_UDP=$9 L2_LOCAL=${10}
    docker rm -f "$NAME" >/dev/null 2>&1 || true

    # overlay：优先克隆已置备的主 overlay（避免每台设备重复 20 分钟置备）
    if [ ! -f "$DISK" ]; then
        if [ -f run/disk.qcow2 ]; then
            cp run/disk.qcow2 "$DISK"
        else
            $QIMG create -f qcow2 -b "$P0_DIR/images/golden-noble-arm64.img" \
                -F qcow2 "$DISK"
        fi
    fi

    docker run -d --name "$NAME" --network host --user "$(id -u):$(id -g)" \
        -v "$P1_DIR":"$P1_DIR" -v "$P0_DIR":"$P0_DIR" -w "$P1_DIR" \
        p1-qemu-build bash -c "
    exec $QEMU \
        -M virt -cpu max -accel tcg,thread=multi -smp 4 -m 2G \
        -global virtio-pci.romfile= \
        -bios "$P1_DIR/compat/QEMU_EFI.fd" \
        -display none \
        -serial file:$P1_DIR/logs/serial-${NAME#p1-vm-}.log \
        -qmp unix:$P1_DIR/run/qmp-${NAME#p1-vm-}.sock,server,nowait \
        -netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
        -device virtio-net-pci,netdev=mgmt,mac=$MGMT_MAC,romfile= \
        -device virtio-rng-pci \
        -chardev socket,id=at0,path=$P1_DIR/run/at0-${NAME#p1-vm-}.sock,server=on,wait=off \
        -chardev null,id=diag \
        -chardev null,id=nmea \
        -netdev user,id=cell,net=10.0.3.0/24,dhcpstart=10.0.3.15 \
        -device qemu-xhci \
        -device usb-wmodem,id=wm0,vendorid=0x1234,productid=0x5678,chardev=at0,serial1=diag,serial2=nmea,netdev=cell \
        -device qemu-xhci \
        -netdev socket,id=l1,udp=127.0.0.1:$L1_UDP,localaddr=127.0.0.1:$L1_LOCAL \
        -device virtio-net-pci,netdev=l1,mac=$L1_MAC,romfile= \
        -netdev socket,id=l2,udp=127.0.0.1:$L2_UDP,localaddr=127.0.0.1:$L2_LOCAL \
        -device virtio-net-pci,netdev=l2,mac=$L2_MAC,romfile= \
        -drive file=$DISK,if=virtio,format=qcow2 \
        -drive file=$P0_DIR/seed/seed.iso,if=virtio,format=raw,readonly=on
    " >/dev/null
    echo "[cluster] $NAME started (ssh :$SSH_PORT)"
}

start_device p1-vm-a 2223 "$P1_DIR/run/disk-a.qcow2" \
    52:54:00:12:34:56 52:54:00:a1:00:01 52:54:00:a2:00:01 4001 4101 4003 4103
start_device p1-vm-b 2323 "$P1_DIR/run/disk-b.qcow2" \
    52:54:00:12:34:66 52:54:00:b1:00:01 52:54:00:b2:00:01 4002 4102 4004 4104

# ---- 等待两台设备 SSH 就绪 ----
for PORT in 2223 2323; do
    for i in $(seq 1 120); do
        ssh -i ../p0/keys/id_ed25519 -p $PORT -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
            test@127.0.0.1 true 2>/dev/null && break
        sleep 3
    done
    echo "[cluster] device on :$PORT ready"
done

# ---- 每台设备置备 + 推送 AT 客户端 ----
for PORT in 2223 2323; do
    SSHP="ssh -i ../p0/keys/id_ed25519 -p $PORT -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR test@127.0.0.1"
    ssh -i ../p0/keys/id_ed25519 -p $PORT -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        test@127.0.0.1 "sudo tee /tmp/at_client.py > /dev/null" < scripts/at_client.py
    ssh -i ../p0/keys/id_ed25519 -p $PORT -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        test@127.0.0.1 "sudo tee /tmp/provision.sh > /dev/null" < scripts/provision.sh
    ssh -i ../p0/keys/id_ed25519 -p $PORT -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        test@127.0.0.1 "sudo bash /tmp/provision.sh" 2>/dev/null
    echo "[cluster] device on :$PORT provisioned"
done

# ---- 场景引擎（每设备一个）----
pkill -f "engine-a.sock" 2>/dev/null || true
pkill -f "engine-b.sock" 2>/dev/null || true
sleep 0.5
nohup python3 -u engine/wm_scenario_engine.py run/at0-a.sock run/engine-a.sock run/qmp-a.sock \
    > logs/engine-a.log 2>&1 &
nohup python3 -u engine/wm_scenario_engine.py run/at0-b.sock run/engine-b.sock run/qmp-b.sock \
    > logs/engine-b.log 2>&1 &
sleep 2

# ---- 链路静态 IP（按 MAC 定位接口）----
cfg_ip() {  # <ssh_port> <mac> <cidr>
    ssh -i ../p0/keys/id_ed25519 -p $1 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR test@127.0.0.1 "
    IF=\$(ip -o link | grep -i '$2' | cut -d: -f2 | tr -d ' ')
    sudo ip link set \$IF up
    sudo ip addr add $3 dev \$IF 2>/dev/null || true
    echo \"  \$IF -> $3\""
}
cfg_ip 2223 "a1:00:01" "10.0.100.1/24"
cfg_ip 2323 "b1:00:01" "10.0.100.2/24"
cfg_ip 2223 "a2:00:01" "10.0.200.1/24"
cfg_ip 2323 "b2:00:01" "10.0.200.2/24"

echo "[cluster] up: 设备A/B + 链路 link1(10.0.100.x) link2(10.0.200.x) 就绪"
