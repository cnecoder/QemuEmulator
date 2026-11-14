#!/usr/bin/env python3
"""四容器集群可行性验收（一期，7 断言，损伤仅最小冒烟）。

前置: bash cluster/up.sh 已执行（含 fix-firewall）
用法: python3 cluster/check_p1.py     → FEASIBILITY_GREEN / FEASIBILITY_HAS_FAILURES

设备管理走 guest 链路 IP 直连（10.0.100.1 / 10.0.101.2，真 L2/L3 路径），
不依赖 QEMU slirp hostfwd 发布端口（slirp 对外部连接存在数据中继缺陷，见 README）。
"""
import subprocess
import sys
import threading
import time
from pathlib import Path

P1 = Path(__file__).resolve().parent.parent
KEY = str(P1.parent / "p0" / "keys" / "id_ed25519")
GUEST_A, GUEST_B = "10.0.100.1", "10.0.101.2"
SRV1, SRV2 = "10.0.102.2", "10.0.202.2"
PASS, FAIL = 0, 0


def ssh(host, cmd, timeout=60, stdin_text=None):
    r = subprocess.run(
        ["ssh", "-i", KEY, "-o", "StrictHostKeyChecking=no",
         "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
         f"test@{host}", cmd],
        input=stdin_text, capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr


def sh(cmd, timeout=60):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout


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


def ping_rtt(host, target):
    out = ssh(host, f"ping -c 4 -W 2 {target} 2>&1")
    loss = 100.0
    rtt = -1.0
    for ln in out.splitlines():
        if "packet loss" in ln:
            for tok in ln.split():
                if tok.endswith("%"):
                    loss = float(tok.strip("%"))
        if "rtt" in ln:
            rtt = float(ln.split("=")[1].split("/")[1])
    return loss, rtt


def main():
    # [1] 四容器运行
    step("[1/7] 四容器运行")
    names = set(sh("docker ps --format '{{.Names}}'").split())
    need = {"p1-vm-a", "p1-vm-b", "p1-router", "p1-server"}
    (ok if need <= names else bad)(f"容器就位: {sorted(need & names)}")

    # [2] router 自检（ip_forward + 六腿接口）
    step("[2/7] router 自检")
    fwd = sh("docker exec p1-router cat /proc/sys/net/ipv4/ip_forward").strip()
    addr = sh("docker exec p1-router ip -o -4 addr show")
    six = all(f"{ip}/24" in addr for ip in
              ["10.0.100.3", "10.0.101.3", "10.0.102.1", "10.0.200.3", "10.0.201.3", "10.0.202.1"])
    (ok if fwd == "1" and six else bad)(f"ip_forward={fwd}, 六腿接口就位={six}")

    # [3] 设备→server 双路径连通
    step("[3/7] 设备→server 连通（双路径）")
    for host, dev, target, path in ((GUEST_A, "A", SRV1, "path1"), (GUEST_A, "A", SRV2, "path2"),
                                    (GUEST_B, "B", SRV1, "path1")):
        loss, rtt = ping_rtt(host, target)
        (ok if loss == 0 else bad)(f"{dev}→{target} ({path}) loss={loss}% rtt={rtt}ms")

    # [4] A→B L3 直通（经 router，不经 server）
    step("[4/7] A→B L3 直通（经 router）")
    loss, rtt = ping_rtt(GUEST_A, GUEST_B)
    (ok if loss == 0 else bad)(f"A→{GUEST_B} loss={loss}% rtt={rtt}ms")

    # [5] 透传 relay: A↔server↔B 数据互转
    step("[5/7] 透传 relay（A↔server↔B）")
    client = (P1 / "cluster" / "relay_client.py").read_text()
    ssh(GUEST_A, "sudo tee /tmp/relay_client.py >/dev/null && sudo chmod 644 /tmp/relay_client.py",
        stdin_text=client)
    ssh(GUEST_B, "sudo tee /tmp/relay_client.py >/dev/null && sudo chmod 644 /tmp/relay_client.py",
        stdin_text=client)
    res_a, res_b = {}, {}

    def run(host, port_srv, msg, box):
        box["out"] = ssh(host, f"timeout 25 python3 /tmp/relay_client.py {port_srv} {msg} 2>&1",
                         timeout=40)

    ta = threading.Thread(target=run, args=(GUEST_A, 9001, "msg-from-A", res_a))
    tb = threading.Thread(target=run, args=(GUEST_B, 9002, "msg-from-B", res_b))
    ta.start(); tb.start(); ta.join(); tb.join()
    got_a = "msg-from-B" in res_a.get("out", "")
    got_b = "msg-from-A" in res_b.get("out", "")
    (ok if got_a and got_b else bad)(f"A 收到 B 数据={got_a} / B 收到 A 数据={got_b}")

    # [6] netem 冒烟: router leg-a1 egress +200ms（损伤机制可用性，非用例矩阵）
    step("[6/7] netem 冒烟（leg-a1 egress +200ms）")
    ifa1 = next((ln.split()[1] for ln in sh("docker exec p1-router ip -o -4 addr show").splitlines()
                 if "10.0.100.3/24" in ln), "")
    if not ifa1:
        bad("leg-a1 接口未定位")
    else:
        _, base = ping_rtt(GUEST_A, SRV1)
        sh(f"docker exec p1-router tc qdisc add dev {ifa1} root netem delay 200ms")
        time.sleep(1)
        _, impaired = ping_rtt(GUEST_A, SRV1)
        sh(f"docker exec p1-router tc qdisc del dev {ifa1} root")
        time.sleep(1)
        _, restored = ping_rtt(GUEST_A, SRV1)
        print(f"  基线 rtt={base}ms | 加伤后 rtt={impaired}ms | 清除后 rtt={restored}ms")
        (ok if base < 20 and impaired >= 200 and restored < 20 else bad)("netem 生效且可清除")

    # [7] relay 双路径端口监听
    step("[7/7] relay 端口监听")
    srv_out = sh("docker logs p1-server 2>&1")
    listeners = all(f"listening :{p}" in srv_out for p in (9001, 9002, 9101, 9102))
    (ok if listeners else bad)("4 个角色端口监听中（9001/9002/9101/9102）")

    print(f"\n=== 可行性验收: PASS={PASS} FAIL={FAIL} ===")
    print("FEASIBILITY_GREEN" if FAIL == 0 else "FEASIBILITY_HAS_FAILURES")
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
