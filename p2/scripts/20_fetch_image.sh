#!/usr/bin/env bash
# 下载 Ubuntu noble (24.04) arm64 云镜像并校验 → p2/images/
set -euo pipefail
IMG_DIR="${1:-/work/images}"
BASE_URL="https://cloud-images.ubuntu.com/noble/current"
IMG="noble-server-cloudimg-arm64.img"

mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

if [ -f "$IMG" ] && grep "$IMG" SHA256SUMS 2>/dev/null | sha256sum -c - >/dev/null 2>&1; then
    echo "[fetch] 已存在且校验通过: $IMG"
    exit 0
fi

echo "[fetch] downloading $IMG ..."
curl -fL --retry 3 -o "$IMG" "$BASE_URL/$IMG"
curl -fL --retry 3 -o SHA256SUMS "$BASE_URL/SHA256SUMS"

echo "[fetch] verifying checksum ..."
grep "$IMG" SHA256SUMS | sha256sum -c -
echo "[fetch] OK: $(du -h "$IMG" | cut -f1)"
