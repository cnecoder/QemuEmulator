"""pytest fixtures: ARM64 + USB 蜂窝模拟环境
前置：自定义 QEMU 已构建（p1/build/...）；golden 镜像存在。
用法：python3 p1/envctl.py test   （或直接 python3 -m pytest p1/tests）
"""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

P1 = Path(__file__).resolve().parent.parent
P0 = P1.parent / "p0"
ENVCTL = [sys.executable, str(P1 / "envctl.py")]
SSH = ["ssh", "-i", str(P0 / "keys" / "id_ed25519"),
       "-p", "2223", "-o", "StrictHostKeyChecking=no",
       "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
       "test@127.0.0.1"]
NETIF = "enx525400123457"


def sh(args, timeout=900):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def guest(cmd, timeout=120):
    r = subprocess.run(SSH + [cmd], capture_output=True, text=True, timeout=timeout)
    return r.stdout


def engine(req, timeout=15):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(str(P1 / "run" / "engine.sock"))
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        buf += s.recv(4096)
    s.close()
    return json.loads(buf.decode())


def at(cmd, timeout=45, retries=2):
    """AT 命令 + 重试（TCG 时序抖动用重试吸收；响应含终结符才算有效）"""
    last = ""
    for i in range(retries + 1):
        try:
            last = guest(f"sudo python3 /tmp/at_client.py cmd '{cmd}'", timeout)
            if any(k in last for k in ("OK", "ERROR", "+CME ERROR")):
                return last
        except subprocess.TimeoutExpired:
            last = f"[timeout on {cmd}]"
        time.sleep(2)
    return last


def curl_via_rndis(timeout=15):
    return guest(f"curl -4 --interface {NETIF} -s -m {timeout} "
                 f"-o /dev/null -w '%{{http_code}}' http://www.baidu.com").strip()


def rndis_netif():
    out = guest("for n in /sys/class/net/*; do readlink -f \"$n/device\" 2>/dev/null "
                "| grep -q '1-1:1.3' && basename $n; done")
    return out.strip()


@pytest.fixture(scope="session", autouse=True)
def lab():
    """环境拉起（幂等）：虚拟机在位 → 置备 → 场景引擎 → RNDIS 就绪"""
    if "Up" not in sh(["docker", "ps", "--filter", "name=p1-vm",
                       "--format", "{{.Status}}"]).stdout:
        r = sh(ENVCTL + ["up"], timeout=1800)
        assert r.returncode == 0, f"envctl up 失败: {r.stdout[-500:]}"
    r = sh(ENVCTL + ["provision"], timeout=300)
    assert r.returncode == 0, f"envctl provision 失败: {r.stderr[-500:]}"
    if not _engine_alive():
        sh(ENVCTL + ["engine", "on"], timeout=60)
    engine({"cmd": "scenario", "name": "normal"})
    # RNDIS 数据面就绪（DHCP）
    if rndis_netif():
        guest(f"sudo ip link set {NETIF} up; "
              f"sudo dhclient -1 {NETIF} 2>/dev/null", timeout=120)
    yield


def _engine_alive():
    try:
        engine({"cmd": "status"}, timeout=3)
        return True
    except OSError:
        return False


@pytest.fixture
def modem():
    """场景引擎句柄；用例结束自动恢复 normal 态"""
    yield _ModemCtl()
    engine({"cmd": "scenario", "name": "normal"})
    time.sleep(1)


class _ModemCtl:
    def scenario(self, name):
        return engine({"cmd": "scenario", "name": name})

    def set_signal(self, rssi):
        return engine({"cmd": "set_signal", "rssi": rssi})

    def set_link(self, up):
        return engine({"cmd": "set_link", "up": up})

    def set_delay(self, ms):
        return engine({"cmd": "set_delay", "ms": ms})

    def inject_urc(self, line):
        return engine({"cmd": "inject_urc", "line": line})

    def status(self):
        return engine({"cmd": "status"})["state"]
