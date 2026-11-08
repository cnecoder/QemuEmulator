#!/usr/bin/env bash
# 下载 Ubuntu noble (24.04) arm64 云镜像并校验
set -euo pipefail
IMG_DIR="${1:-/work/images}"
BASE_URL="https://cloud-images.ubuntu.com/noble/current"
IMG="noble-server-cloudimg-arm64.img"

mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

echo "[fetch] downloading $IMG ..."
curl -fL --retry 3 -o "$IMG" "$BASE_URL/$IMG"
curl -fL --retry 3 -o SHA256SUMS "$BASE_URL/SHA256SUMS"
curl -fL --retry 3 -o SHA256SUMS.gpg "$BASE_URL/SHA256SUMS.gpg" || echo "[fetch] (gpg sig optional, skip)"

echo "[fetch] verifying checksum ..."
grep "$IMG" SHA256SUMS | sha256sum -c -
echo "[fetch] OK: $(du -h "$IMG" | cut -f1)"
