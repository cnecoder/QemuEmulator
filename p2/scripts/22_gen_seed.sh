#!/usr/bin/env bash
# [容器内] 生成每设备 cloud-init NoCloud seed ISO（注入本机公钥）
# 注意: ISO 内文件名必须是 user-data / meta-data（cloud-init NoCloud 硬性要求，
#       文件名不对会导致 DataSourceNone 回退，实测坑）
set -euo pipefail
cd /work/seed

[ -f /work/keys/id_ed25519.pub ] || { echo "ERROR: 先生成密钥（21_init_keys.sh）"; exit 1; }
PUBKEY=$(cat /work/keys/id_ed25519.pub)

gen() {  # <模板> <meta> <设备名> <输出ISO>
    local dir="/tmp/seed-$3"
    rm -rf "$dir" && mkdir -p "$dir"
    sed "s|__PUBKEY__|${PUBKEY}|g" "$1" > "$dir/user-data"
    cp "$2" "$dir/meta-data"
    genisoimage -output "$4" -volid cidata -joliet -rock "$dir" 2>/dev/null
    echo "[seed] $4: $(stat -c %s "$4") bytes"
}

gen user-data-a.tmpl meta-data-a a seed-a.iso
gen user-data-b.tmpl meta-data-b b seed-b.iso
echo "[seed] OK"
