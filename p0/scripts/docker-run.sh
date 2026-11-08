#!/usr/bin/env bash
# P0 统一容器入口: 以 host 网络 + 宿主用户身份在 p0-qemu 容器内执行命令
# 用法: scripts/docker-run.sh <command...>
set -euo pipefail
P0_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec docker run --rm --network host --user "$(id -u):$(id -g)" \
    -v "$P0_DIR":/work -w /work p0-qemu "$@"
