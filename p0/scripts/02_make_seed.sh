#!/usr/bin/env bash
# 生成 cloud-init NoCloud seed ISO
set -euo pipefail
cd /work/seed
genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data 2>/dev/null
echo "[seed] OK: $(ls -l seed.iso | awk '{print $5}') bytes"
