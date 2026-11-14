#!/usr/bin/env python3
"""p2 四容器集群验收（连通 + 损伤矩阵）。

前置: bash cluster/up.sh 已执行
用法: python3 cluster/check.py    → MATRIX_GREEN / MATRIX_HAS_FAILURES

损伤矩阵（全部经 link_ctl.py CLI 走 linkd.sock 控制面，端到端验证）:
  [5] path 独立性   : path1 三腿 +200ms → A↔B 时延叠加，path2 路径不受影响
  [6] leg 粒度      : 仅 leg-a1 +200ms → 跨 a1 的路径受影响，path2 不受影响
  [7] 方向非对称    : leg-a1 仅 egress +200ms → A↔B RTT≈200（非 400），证明方向级控制
  [8] 丢包          : leg-b1 100% 丢包 → A↔B 全断，path2 不受影响，清除恢复
  [9] 带宽          : path1 限速 1Mbps → iperf3 吞吐受限，清除后恢复
"""
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

P2 = Path(__file__).resolve().parent.parent
KEY = str(P2 / "keys" / "id_ed25519")
GUEST_A, GUEST_B = "10.0.100.1", "10.0.101.2"
SRV1, SRV2 = "10.0.102.2", "10.0.202.2"
LINK_CTL = [sys.executable, str(P2 / "cluster" / "link_ctl.py")]
PASS, FAIL = 0, 0


def ssh(host, cmd, timeout=60, stdin_text=None):
    r = subprocess.run(
        ["ssh", "-i", KEY, "-o", "StrictHostKeyChecking=no",
         "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
         f"test@{host}", cmd],
        input=stdin_text, capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr


def sh(cmd, timeout=120):
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


def ping(host, target, count=4):
    """返回 (loss%, avg_rtt_ms)"""
    out = ssh(host, f"ping -c {count} -W 2 {target} 2>&1", timeout=90)
    loss, rtt = 100.0, -1.0
    for ln in out.splitlines():
        if "packet loss" in ln:
            for tok in ln.split():
                if tok.endswith("%"):
                    loss = float(tok.strip("%"))
        if "rtt" in ln:
            rtt = float(ln.split("=")[1].split("/")[1])
    return loss, rtt


def impair(req):
    """经 link_ctl.py CLI（argparse 列表参数，无 shell 引号风险）执行损伤控制"""
    args = [sys.executable, str(P2 / "cluster" / "link_ctl.py")]
    cmd = req.get("cmd")
    if cmd == "set":
        args.append("set")
        for flag, key in (("--path", "path"), ("--leg", "leg"), ("--dir", "dir")):
            if req.get(key):
                args += [flag, req[key]]
        for flag, key in (("--delay", "delay_ms"), ("--jitter", "jitter_ms"),
                          ("--loss", "loss_pct"), ("--bw", "bw_kbps")):
            if req.get(key) is not None:
                args += [flag, str(req[key])]
    elif cmd == "clear":
        args.append("clear")
        for flag, key in (("--path", "path"), ("--leg", "leg"), ("--dir", "dir")):
            if req.get(key):
                args += [flag, req[key]]
    elif cmd == "clear_all":
        args.append("clear_all")
    else:
        args.append("status")
    r = subprocess.run(args, capture_output=True, text=True, timeout=90)
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "raw": (r.stdout + r.stderr)[-400:]}


def check_rtt(host, target, lo, hi, label):
    loss, rtt = ping(host, target)
    good = loss == 0 and lo <= rtt < hi
    (ok if good else bad)(f"{label}: loss={loss}% rtt={rtt}ms (期望 [{lo},{hi})ms)")
    return good


def main():
    # [1] 四容器运行
    step("[1/9] 四容器运行")
    names = set(sh("docker ps --format '{{.Names}}'").split())
    need = {"p2-vm-a", "p2-vm-b", "p2-router", "p2-server"}
    (ok if need <= names else bad)(f"容器就位: {sorted(need & names)}")

    # [2] 损伤控制面就绪
    step("[2/9] 损伤控制面")
    st = impair({"cmd": "status"})
    legs_ready = st.get("ok") and len(st.get("legs", {})) == 12
    (ok if legs_ready else bad)(f"linkd 守护就绪, 损伤点={len(st.get('legs', {}))}/12")

    # [3] 基线连通
    step("[3/9] 基线连通（无损伤）")
    for host, target, label in ((GUEST_A, SRV1, "A→server"), (GUEST_B, SRV1, "B→server"),
                                (GUEST_A, GUEST_B, "A→B"), (GUEST_B, GUEST_A, "B→A"),
                                (GUEST_A, SRV2, "A→server(path2)")):
        loss, rtt = ping(host, target)
        (ok if loss == 0 and 0 < rtt < 20 else bad)(f"{label}: loss={loss}% rtt={rtt}ms")

    # [4] 透传 relay
    step("[4/9] 透传 relay（A↔server↔B）")
    client = (P2 / "cluster" / "relay_client.py").read_text()
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

    # [5] path 独立性: path1 三腿 +200ms
    step("[5/9] path 独立性（path1 +200ms，path2 不受影响）")
    impair({"cmd": "set", "path": "link1", "delay_ms": 200})
    time.sleep(1)
    check_rtt(GUEST_A, GUEST_B, 500, 1200, "A→B（跨 4 个损伤点，期望≈800）")
    check_rtt(GUEST_A, SRV2, 0, 20, "A→server path2（独立性）")
    impair({"cmd": "clear", "path": "link1"})
    time.sleep(1)
    loss, rtt = ping(GUEST_A, GUEST_B)
    (ok if loss == 0 and rtt < 20 else bad)(f"清除后恢复: loss={loss}% rtt={rtt}ms")

    # [6] leg 粒度: 仅 leg-a1 +200ms
    step("[6/9] leg 粒度（仅 leg-a1 +200ms）")
    impair({"cmd": "set", "leg": "a1", "delay_ms": 200})
    time.sleep(1)
    check_rtt(GUEST_A, GUEST_B, 300, 600, "A→B（跨 a1 上下行，期望≈400）")
    check_rtt(GUEST_A, SRV1, 300, 600, "A→server path1（跨 a1，期望≈400）")
    check_rtt(GUEST_A, SRV2, 0, 20, "A→server path2（a2 未损）")
    impair({"cmd": "clear", "leg": "a1"})
    time.sleep(1)

    # [7] 方向非对称: 仅 leg-a1 egress（router→A 方向）
    step("[7/9] 方向非对称（leg-a1 仅 egress +200ms）")
    impair({"cmd": "set", "leg": "a1", "dir": "egress", "delay_ms": 200})
    time.sleep(1)
    check_rtt(GUEST_A, GUEST_B, 150, 350, "A→B（仅回程受损伤，期望≈200）")
    impair({"cmd": "clear", "leg": "a1"})
    time.sleep(1)
    loss, rtt = ping(GUEST_A, GUEST_B)
    (ok if loss == 0 and rtt < 20 else bad)(f"清除后恢复: loss={loss}% rtt={rtt}ms")

    # [8] 丢包: leg-b1 100%
    step("[8/9] 丢包（leg-b1 100%）")
    impair({"cmd": "set", "leg": "b1", "loss_pct": 100})
    time.sleep(1)
    loss, _ = ping(GUEST_A, GUEST_B)
    (ok if loss == 100 else bad)(f"A→B 全断: loss={loss}%")
    loss, _ = ping(GUEST_A, SRV2)
    (ok if loss == 0 else bad)(f"A→server path2 不受影响: loss={loss}%")
    impair({"cmd": "clear", "leg": "b1"})
    time.sleep(1)
    loss, _ = ping(GUEST_A, GUEST_B)
    (ok if loss == 0 else bad)(f"清除后恢复: loss={loss}%")

    # [9] 带宽: path1 限速 1Mbps（iperf3 A→B）
    step("[9/9] 带宽（path1 限速 1024kbps）")
    ssh(GUEST_B, "pkill iperf3 2>/dev/null; true")

    def iperf_once():
        ssh(GUEST_B, "nohup iperf3 -s -1 >/dev/null 2>&1 & sleep 1; true")
        out = ssh(GUEST_A, "iperf3 -c 10.0.101.2 -t 5 -f k 2>&1 | tail -3", timeout=90)
        for ln in out.splitlines():
            if "sender" in ln or "receiver" in ln:
                return float(ln.split()[6])
        return -1.0

    impair({"cmd": "set", "path": "link1", "bw_kbps": 1024})
    time.sleep(1)
    capped = iperf_once()
    (ok if 400 <= capped <= 1800 else bad)(f"限速吞吐: {capped:.0f} kbps（期望≈1024）")
    impair({"cmd": "clear", "path": "link1"})
    time.sleep(1)
    cleared = iperf_once()
    (ok if cleared >= max(3 * capped, 2000) else bad)(f"解除限速吞吐: {cleared:.0f} kbps（≥3×限速值）")

    print(f"\n=== 集群验收: PASS={PASS} FAIL={FAIL} ===")
    print("MATRIX_GREEN" if FAIL == 0 else "MATRIX_HAS_FAILURES")
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
