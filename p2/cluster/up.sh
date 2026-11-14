#!/usr/bin/env bash
# p2 四容器集群拉起（自含，不依赖 p0/p1）
#
# 前置（ctl.py init/build/image 已完成）: QEMU 构建、golden 镜像、keys、seed ISO
# 流程: 新盘准备(含 +6G 扩容防填满) → compose up（路由/server 先行）→ 等设备直连 SSH 就绪
#
# 网络路线甲: docker 网段仅簿记（10.9.x），真实段 IP 由容器内手工配置 → 宿主防火墙零改动
set -euo pipefail
P2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export P2_DIR HOST_UID="$(id -u)" HOST_GID="$(id -g)"
KEY="$P2_DIR/keys/id_ed25519"
QEMU="$P2_DIR/build/qemu-custom/qemu-system-aarch64"
QIMG="$P2_DIR/build/qemu-custom/qemu-img"
GOLDEN="$P2_DIR/images/noble-server-cloudimg-arm64.img"
SSH_G() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=8 -o LogLevel=ERROR "test@$1" "$2"; }

[[ -x "$QEMU" ]] || { echo "ERROR: QEMU 未构建 → python3 ctl.py build"; exit 1; }
[[ -f "$GOLDEN" ]] || { echo "ERROR: golden 镜像未下载 → python3 ctl.py image"; exit 1; }
[[ -f "$KEY" ]] || { echo "ERROR: 密钥未生成 → python3 ctl.py init"; exit 1; }
for S in seed-a.iso seed-b.iso; do
    [[ -f "$P2_DIR/seed/$S" ]] || { echo "ERROR: seed/$S 未生成 → python3 ctl.py init"; exit 1; }
done

# ---- 新盘准备：golden-backed overlay，+6G 扩容（云镜像首启自动 growpart，防 guest 盘填满）----
for D in disk-a disk-b; do
    if [ ! -f "$P2_DIR/run/$D.qcow2" ]; then
        "$QIMG" create -f qcow2 -b "$GOLDEN" -F qcow2 "$P2_DIR/run/$D.qcow2"
        "$QIMG" resize "$P2_DIR/run/$D.qcow2" +6G
        echo "[up] created overlay run/$D.qcow2 (+6G)"
    fi
done
mkdir -p "$P2_DIR/logs"

# ---- compose 拉起 ----
cd "$P2_DIR/cluster"
docker compose -p p2cluster down --remove-orphans 2>/dev/null || true
docker compose -p p2cluster up -d --build
docker compose -p p2cluster ps

# ---- 宿主路由（路线甲收尾件）：真实段经各簿记网桥二层可达 ----
bash "$P2_DIR/cluster/host-routes.sh"

# ---- 等待设备就绪（直连 guest 链路 IP；seed netplan 开机自配置）----
for HOST_IP in 10.0.100.1 10.0.101.2; do
    printf "[up] waiting device $HOST_IP "
    for i in $(seq 1 200); do
        SSH_G "$HOST_IP" true 2>/dev/null && { echo " ready"; break; }
        printf "."; sleep 3
    done
    SSH_G "$HOST_IP" true 2>/dev/null || { echo "TIMEOUT"; exit 1; }
done

# ---- 损伤守护健康检查 ----
for i in $(seq 1 10); do
    python3 "$P2_DIR/cluster/link_ctl.py" status >/dev/null 2>&1 && break
    sleep 2
done
python3 "$P2_DIR/cluster/link_ctl.py" status >/dev/null 2>&1 \
    || { echo "ERROR: 损伤守护未就绪（logs/linkd.log）"; exit 1; }

echo "[up] 完成 → 验收: python3 $P2_DIR/cluster/check.py"
