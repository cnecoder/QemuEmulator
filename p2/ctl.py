#!/usr/bin/env python3
"""p2 独立集群统一入口（自含，不依赖 p0/p1）。

用法:
  python3 ctl.py init    # 构建编译镜像 + 生成 SSH 密钥 + 生成 seed ISO
  python3 ctl.py build   # 下载 QEMU 源码并编译（usb-wmodem 设备内建，约 10-15 分钟，一次性）
  python3 ctl.py image   # 下载 golden 云镜像并校验（约 600MB）
  python3 ctl.py up      # 拉起四容器集群（compose + 等待就绪）
  python3 ctl.py check   # 验收：连通 + 透传 + 损伤矩阵
  python3 ctl.py status  # 容器与损伤状态总览
  python3 ctl.py impair set --path link1 --delay 200     # 损伤控制透传
  python3 ctl.py impair clear --path link1
  python3 ctl.py down    # 回收
"""
import subprocess
import sys
from pathlib import Path

P2 = Path(__file__).resolve().parent
BUILD_IMG = "p2-qemu-build"


def sh(cmd, timeout=None):
    print(f"[ctl] $ {cmd}")
    r = subprocess.run(cmd, shell=True, cwd=str(P2), timeout=timeout)
    if r.returncode != 0:
        sys.exit(r.returncode)


def in_build_img(cmd, timeout=None):
    sh(f'docker run --rm --user "$(id -u):$(id -g)" -v "{P2}:/work" -w /work '
       f'{BUILD_IMG} bash {cmd}', timeout=timeout)


def cmd_init(_):
    sh(f"docker build -t {BUILD_IMG} -f docker/Dockerfile.build docker")
    in_build_img("/work/scripts/21_init_keys.sh /work/keys")
    in_build_img("/work/scripts/22_gen_seed.sh")


def cmd_build(_):
    in_build_img("/work/scripts/10_build.sh", timeout=3600)


def cmd_image(_):
    in_build_img("/work/scripts/20_fetch_image.sh /work/images", timeout=1200)


def cmd_up(_):
    sh("bash cluster/up.sh", timeout=3600)


def cmd_down(_):
    sh("bash cluster/down.sh")


def cmd_check(_):
    sh(f"{sys.executable} cluster/check.py", timeout=1800)


def cmd_status(_):
    sh("docker compose -p p2cluster ps", timeout=60)
    sh(f"{sys.executable} cluster/link_ctl.py status")


def cmd_impair(args):
    sh(f"{sys.executable} cluster/link_ctl.py " + " ".join(args))


COMMANDS = {"init": cmd_init, "build": cmd_build, "image": cmd_image,
            "up": cmd_up, "down": cmd_down, "check": cmd_check,
            "status": cmd_status, "impair": cmd_impair}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(1)
    COMMANDS[sys.argv[1]](sys.argv[2:])
