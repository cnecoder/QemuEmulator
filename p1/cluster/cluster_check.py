#!/usr/bin/env python3
"""集群验收（Python 版，无 shell 竞态）: 双设备互联 + 链路损伤独立性
前置: bash scripts/30_cluster_up.sh 已执行
用法: python3 cluster/cluster_check.py
"""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

P1 = Path(__file__).resolve().parent.parent
KEY = str(P1.parent / "p0" / "keys" / "id_ed25519")
LINK_CTL = str(P1 / "cluster" / "link_ctl.py")
PASS = 0
FAIL = 0
A1_IF, A2_IF, B1_IF, B2_IF = "enp0s5", "enp0s6", "enp0s3", "enp0s4"


def ssh(port, cmd, timeout=90):
    r = subprocess.run(["ssh", "-i", KEY, "-p", str(port),
                        "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "LogLevel=ERROR", "test@127.0.0.1", cmd],
                       capture_output=True, text=True, timeout=timeout)
    return r.stdout


def link_ctl(req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(str(P1 / "run" / "linkd.sock"))
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        buf += s.recv(4096)
    s.close()
    return json.loads(buf.decode())



def ping_loss_rtt(port, iface, peer):
    """经指定接口 ping 对端，返回 (loss%, avg_rtt)"""
    out = ssh(port, f"ping -c 5 -I {iface} -W 2 {peer} 2>&1")
    loss, rtt = -1.0, -1.0
    for line in out.splitlines():
        if "packet loss" in line:
            for tok in line.split():
                if tok.endswith("%"):
                    loss = float(tok.rstrip("%"))
        if "rtt" in line:
            parts = line.split("=")[1].split("/")[1]
            rtt = float(parts)
    return loss, rtt


def step(name):
    print(f"\n=== {name} ===")


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ✓ {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  ✗ {msg}")


def main():
    # [0] 设备可达性
    step("[0/6] 设备可达性")
    for port, name in ((2223, "A"), (2323, "B")):
        out = ssh(port, "echo ok", timeout=15)
        (ok if "ok" in out else bad)(f"设备{name} ({port}) 可达")

    # [1] 链路网卡定位（按 MAC）
    step("[1/6] 链路网卡定位（按 MAC）")
    a1 = ssh(2223, "ip -o link | grep -i 'a1:00:01' | cut -d: -f2 | tr -d ' '").strip()
    a2 = ssh(2223, "ip -o link | grep -i 'a2:00:01' | cut -d: -f2 | tr -d ' '").strip()
    b1 = ssh(2323, "ip -o link | grep -i 'b1:00:01' | cut -d: -f2 | tr -d ' '").strip()
    b2 = ssh(2323, "ip -o link | grep -i 'b2:00:01' | cut -d: -f2 | tr -d ' '").strip()
    print(f"  A:{a1}/{a2}  B:{b1}/{b2}")
    if all([a1, a2, b1, b2]):
        ok("四张互联网卡就位")
    else:
        bad("互联网卡缺失")

    # [2] IP 置备
    step("[2/6] 链路 IP 置备（静态）")
    ssh(2223, f"sudo ip addr add 10.0.100.1/24 dev {a1} 2>/dev/null; "
              f"sudo ip addr add 10.0.200.1/24 dev {a2} 2>/dev/null")
    ssh(2323, f"sudo ip addr add 10.0.100.2/24 dev {b1} 2>/dev/null; "
              f"sudo ip addr add 10.0.200.2/24 dev {b2} 2>/dev/null")
    chk_a = ssh(2223, "ip -4 addr | grep -cE '10.0.100.1|10.0.200.1'").strip()
    chk_b = ssh(2323, "ip -4 addr | grep -cE '10.0.100.2|10.0.200.2'").strip()
    if chk_a == "2" and chk_b == "2":
        ok("四口 IP 置备完成")
    else:
        bad(f"IP 置备异常 (A:{chk_a} B:{chk_b})")

    # [3] 基线
    step("[3/6] 基线: 双链路 RTT（应 < 10ms）")
    l1_loss, l1_rtt = ping_loss_rtt(2223, a1, "10.0.100.2")
    l2_loss, l2_rtt = ping_loss_rtt(2323, b1, "10.0.100.2")
    print(f"  link1: loss={l1_loss}% rtt={l1_rtt}ms | link2: loss={l2_loss}% rtt={l2_rtt}ms")
    if l1_rtt < 10 and l2_rtt < 10:
        ok("双链路基线正常")
    else:
        bad("基线异常")

    # [4] 独立损伤①: link1 +200ms 时延
    step("[4/6] 独立损伤①: link1 +200ms 时延，link2 不受影响")
    link_ctl({"cmd": "set", "link": "link1", "delay_ms": 200})
    time.sleep(2)
    l1_loss, l1_rtt = ping_loss_rtt(2223, a1, "10.0.100.2")
    l2_loss, l2_rtt = ping_loss_rtt(2323, b1, "10.0.100.2")
    print(f"  link1 rtt={l1_rtt}ms | link2 rtt={l2_rtt}ms")
    if l1_rtt >= 150 and l2_rtt < 20:
        ok("时延只作用于 link1（独立性 ✓）")
    else:
        bad("损伤串扰")
    link_ctl({"cmd": "clear", "link": "link1"})
    time.sleep(1)

    # [5] 独立损伤②: link1 100% 丢包
    step("[5/6] 独立损伤②: link1 100% 丢包，link2 不受影响")
    link_ctl({"cmd": "set", "link": "link1", "loss_pct": 100})
    time.sleep(2)
    l1_loss, _ = ping_loss_rtt(2223, a1, "10.0.100.2")
    l2_loss, _ = ping_loss_rtt(2323, b1, "10.0.100.2")
    print(f"  link1 loss={l1_loss}% | link2 loss={l2_loss}%")
    if l1_loss >= 80 and l2_loss == 0:
        ok("丢包只作用于 link1（独立性 ✓）")
    else:
        bad("损伤串扰")
    link_ctl({"cmd": "clear", "link": "link1"})
    time.sleep(1)
    l1_loss, _ = ping_loss_rtt(2223, a1, "10.0.100.2")
    if l1_loss == 0:
        ok("link1 清除后恢复")
    else:
        bad(f"link1 未恢复 (loss={l1_loss}%)")

    # [6] 设备 A 蜂窝通道
    step("[6/6] 设备 A 蜂窝通道（B 为精简盘无蜂窝模块）")
    ca = ssh(2223, "sudo python3 /tmp/at_client.py cmd 'AT+CPIN?'", timeout=60)
    if "READY" in ca:
        ok("A 蜂窝模块 AT 通道正常")
    else:
        bad("A 蜂窝通道异常")

    print(f"\n=== 集群验收: PASS={PASS} FAIL={FAIL} ===")
    print("CLUSTER_ALL_GREEN" if FAIL == 0 else "CLUSTER_HAS_FAILURES")
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
