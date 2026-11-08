#!/usr/bin/env bash
# CI 容器入口：在无 KVM 的容器内完成 镜像获取→冷启动置备→全量回归
# 前置: 容器已含自定义 QEMU(ci/Dockerfile 构建) + pytest；工作目录 /lab/p1
set -euo pipefail
cd /lab/p1
export QEMU_DIRECT=1

# 1) 云镜像（CI 缓存卷挂载到 /lab/p0/images 可跳过下载）
if [ ! -f ../p0/images/golden-noble-arm64.img ]; then
  mkdir -p ../p0/images
  bash ../p0/scripts/01_fetch_image.sh ../p0/images
fi

# 2) 拉起 + 置备 + 快照基线
python3 envctl.py up --fresh

# 3) 全量回归（设备/AT/场景/数据面 32 例）
python3 envctl.py test "$@"

# 4) 回收
python3 envctl.py stop
echo "CI: ALL DONE"
