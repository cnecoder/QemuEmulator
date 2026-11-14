#!/usr/bin/env bash
# [一期·可行性] 四容器集群拉起: p1-vm-a / p1-vm-b / p1-router / p1-server
#
# 拓扑: 设备A/B --tap--> router(L3 转发, 损伤点) --> server(透传 relay)
# 地址: path1 10.0.100(A)/101(B)/102(server), path2 10.0.200/201/202
# 验收: python3 cluster/check_p1.py
set -euo pipefail
P1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P0_DIR="$(cd "$P1_DIR/.." && pwd)/p0"
export P1_DIR P0_DIR HOST_UID="$(id -u)" HOST_GID="$(id -g)"
SSH_KEY="$P0_DIR/keys/id_ed25519"
QIMG="$P1_DIR/build/qemu-custom/qemu-img"
SSH() { ssh -i "$SSH_KEY" -p "$1" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR test@127.0.0.1 "$2"; }

[[ -x "$P1_DIR/build/qemu-custom/qemu-system-aarch64" ]] || { echo "ERROR: 自定义 QEMU 未构建"; exit 1; }

# ---- 让出端口/容器名（单机环境与旧集群沿用 2223/2323 与同名容器）----
for C in p1-vm p1-vm-a p1-vm-b; do
    docker rm -f "$C" >/dev/null 2>&1 || true
done
pkill -f wm_linkd.py 2>/dev/null || true
pkill -f wm_scenario_engine 2>/dev/null || true

# ---- overlay（克隆已置备主 overlay，秒级；无主 overlay 则回退 golden 慢路径）----
for D in disk-a disk-b; do
    if [ ! -f "$P1_DIR/run/$D.qcow2" ]; then
        if [ -f "$P1_DIR/run/disk.qcow2" ]; then
            cp "$P1_DIR/run/disk.qcow2" "$P1_DIR/run/$D.qcow2"
        else
            "$QIMG" create -f qcow2 -b "$P0_DIR/images/golden-noble-arm64.img" \
                -F qcow2 "$P1_DIR/run/$D.qcow2"
        fi
    fi
done

mkdir -p "$P1_DIR/logs"
cd "$P1_DIR/cluster"
docker compose -p p1cluster down --remove-orphans 2>/dev/null || true
docker compose -p p1cluster up -d --build
docker compose -p p1cluster ps

# ---- 防火墙放行（docker 28 raw 表会拦桥内互访，须在 compose up 后修复）----
bash "$P1_DIR/cluster/fix-firewall.sh"

# ---- 等待设备 SSH（guest 直连链路 IP；netplan 已烘入盘中，开机自配置）----
SSH_G() { ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=8 -o LogLevel=ERROR "test@$1" "$2"; }
printf "[up] waiting device A (10.0.100.1) "
for i in $(seq 1 200); do
    SSH_G 10.0.100.1 true 2>/dev/null && { echo " ready"; break; }
    printf "."; sleep 3
done
printf "[up] waiting device B (10.0.101.2) "
for i in $(seq 1 200); do
    SSH_G 10.0.101.2 true 2>/dev/null && { echo " ready"; break; }
    printf "."; sleep 3
done

# ---- guest 置备兜底（正常情况下 netplan 已烘入盘中自动生效；仅旧盘需要）----
echo "[up] guest 链路置备（兜底）:"
SSH 2223 "
    for MAC_IP in 'a1:00:01 10.0.100.1/24' 'a2:00:01 10.0.200.1/24'; do
        set -- \$MAC_IP
        IF=\$(ip -o link | grep -i '\$1' | cut -d: -f2 | tr -d ' ')
        sudo ip link set \$IF up
        sudo ip addr add \$2 dev \$IF 2>/dev/null || true
    done
    sudo ip route replace 10.0.101.0/24 via 10.0.100.3 2>/dev/null || true
    sudo ip route replace 10.0.102.0/24 via 10.0.100.3 2>/dev/null || true
    sudo ip route replace 10.0.201.0/24 via 10.0.200.3 2>/dev/null || true
    sudo ip route replace 10.0.202.0/24 via 10.0.200.3 2>/dev/null || true
    echo '  A: 10.0.100.1 / 10.0.200.1'" || echo "  (A 置备走 slirp 通道失败/跳过——netplan 烘入盘时无需此步)"
SSH 2323 "
    for MAC_IP in 'b1:00:01 10.0.101.2/24' 'b2:00:01 10.0.201.2/24'; do
        set -- \$MAC_IP
        IF=\$(ip -o link | grep -i '\$1' | cut -d: -f2 | tr -d ' ')
        sudo ip link set \$IF up
        sudo ip addr add \$2 dev \$IF 2>/dev/null || true
    done
    sudo ip route replace 10.0.100.0/24 via 10.0.101.3 2>/dev/null || true
    sudo ip route replace 10.0.102.0/24 via 10.0.101.3 2>/dev/null || true
    sudo ip route replace 10.0.200.0/24 via 10.0.201.3 2>/dev/null || true
    sudo ip route replace 10.0.202.0/24 via 10.0.201.3 2>/dev/null || true
    echo '  B: 10.0.101.2 / 10.0.201.2'" || echo "  (B 置备跳过——同上)"

# ---- server 路由：按 path 指向 router 对应腿（保证回程对称）----
echo "[up] server 路由:"
docker exec p1-server ip route replace 10.0.100.0/24 via 10.0.102.1
docker exec p1-server ip route replace 10.0.101.0/24 via 10.0.102.1
docker exec p1-server ip route replace 10.0.200.0/24 via 10.0.202.1
docker exec p1-server ip route replace 10.0.201.0/24 via 10.0.202.1

echo "[up] 完成 → 验收: python3 $P1_DIR/cluster/check_p1.py"
