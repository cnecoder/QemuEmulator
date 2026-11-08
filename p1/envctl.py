#!/usr/bin/env python3
"""envctl —— ARM64 + USB 蜂窝模拟环境的统一控制台

一条命令完成 拉起/置备/验收/快照/场景/回归：
  envctl.py up [--fresh]        启动虚拟机（--fresh 全新实例）并等待 SSH
  envctl.py provision           置备（驱动绑定/节点防护，幂等）+ 推送 AT 客户端
  envctl.py verify              设备级验收（原 25 号脚本）
  envctl.py snap <tag>          整机快照（QMP savevm）
  envctl.py restore <tag>       快照复位（loadvm，秒级）
  envctl.py engine on|off       场景引擎 启/停
  envctl.py scenario <name>     场景切换（normal/no_sim/searching/denied/detached/offline）
  envctl.py set_signal <0-31>   信号强度注入
  envctl.py set_link <on|off>   数据面链路通断
  envctl.py set_delay <ms>      弱网延迟注入（0=清除）
  envctl.py inject_urc '<行>'   URC 注入
  envctl.py at '<AT 命令>'      向 guest 发 AT 并打印应答
  envctl.py status              环境总览
  envctl.py stop                停虚拟机与引擎
  envctl.py test [pytest 参数]  回归测试（junit 报告落 reports/）
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

P1 = Path(__file__).resolve().parent
P0 = P1.parent / "p0"
KEY = P0 / "keys" / "id_ed25519"
SSH_BASE = ["ssh", "-i", str(KEY), "-p", "2223", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "test@127.0.0.1"]
ENGINE_SOCK = P1 / "run" / "engine.sock"
QMP_SOCK = P1 / "run" / "qmp.sock"
AT_SOCK = P1 / "run" / "at0.sock"
NETIF = "enx525400123457"


def sh(args, check=False, timeout=600, quiet=False):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if not quiet and r.stdout.strip():
        print(r.stdout.strip())
    if check and r.returncode != 0:
        sys.exit(f"envctl: command failed: {' '.join(map(str, args))}\n{r.stderr}")
    return r


def engine_req(req, timeout=15):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(str(ENGINE_SOCK))
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        buf += s.recv(4096)
    s.close()
    return json.loads(buf.decode())


def vm_running():
    r = subprocess.run(["docker", "ps", "--filter", "name=p1-vm",
                        "--format", "{{.Status}}"], capture_output=True, text=True)
    return "Up" in r.stdout


def wait_ssh(timeout=900):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = subprocess.run(SSH_BASE + ["true"], capture_output=True)
        if r.returncode == 0:
            print(f"envctl: VM ready ({int(time.time()-t0)}s)")
            return
        time.sleep(5)
    sys.exit("envctl: VM did not become reachable in time")


def cmd_up(a):
    args = ["bash", str(P1 / "scripts" / "20_run_vm.sh")] + \
           (["--fresh"] if a.fresh else [])
    sh(args, check=True)
    wait_ssh()
    cmd_provision(None)
    print("envctl: up ✔")


def cmd_provision(_):
    # 推送 AT 客户端 + 置备（幂等）
    with open(P1 / "scripts" / "at_client.py", "rb") as f:
        subprocess.run(SSH_BASE + ["sudo", "tee", "/tmp/at_client.py"],
                       stdin=f, check=True, capture_output=True)
    with open(P1 / "scripts" / "provision.sh", "rb") as f:
        subprocess.run(SSH_BASE + ["sudo", "bash", "-s"],
                       stdin=f, check=True, capture_output=True)
    print("envctl: provisioned ✔")


def cmd_verify(_):
    sh(["bash", str(P1 / "scripts" / "25_verify_all.sh")], check=True)


def cmd_snap(a):
    r = subprocess.run([sys.executable, str(P0 / "scripts" / "qmp_savevm.py"),
                        str(QMP_SOCK), a.tag], capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr.strip())
    if "SAVEVM_OK" not in r.stdout:
        sys.exit(1)


def cmd_restore(a):
    sh(["bash", str(P1 / "scripts" / "20_run_vm.sh"), "--loadvm", a.tag], check=True)
    time.sleep(8)
    wait_ssh(timeout=300)
    print(f"envctl: restored to '{a.tag}' ✔")


def cmd_engine(a):
    if a.action == "on":
        subprocess.run(["pkill", "-f", "21_at_responder"], capture_output=True)
        logf = open(P1 / "logs" / "engine.log", "a")
        subprocess.Popen([sys.executable, str(P1 / "engine" / "wm_scenario_engine.py"),
                          str(AT_SOCK), str(ENGINE_SOCK), str(QMP_SOCK)],
                         stdout=logf, stderr=logf)
        for _ in range(20):
            try:
                engine_req({"cmd": "status"}, timeout=3)
                print("envctl: engine on ✔")
                return
            except OSError:
                time.sleep(1)
        sys.exit("envctl: engine failed to start")
    else:
        subprocess.run(["pkill", "-f", "wm_scenario_engine.py"], capture_output=True)
        print("envctl: engine off")


def cmd_scenario(a):
    print(json.dumps(engine_req({"cmd": "scenario", "name": a.name}),
                     ensure_ascii=False))


def cmd_set_signal(a):
    print(json.dumps(engine_req({"cmd": "set_signal", "rssi": a.value})))


def cmd_set_link(a):
    print(json.dumps(engine_req({"cmd": "set_link", "up": a.state == "on"})))


def cmd_set_delay(a):
    print(json.dumps(engine_req({"cmd": "set_delay", "ms": a.ms})))


def cmd_inject_urc(a):
    print(json.dumps(engine_req({"cmd": "inject_urc", "line": a.line})))


def cmd_at(a):
    r = subprocess.run(SSH_BASE + ["sudo", "python3", "/tmp/at_client.py",
                                   "cmd", a.command], capture_output=True, text=True)
    print(r.stdout)


def cmd_status(_):
    print(f"VM      : {'running' if vm_running() else 'stopped'}")
    print(f"engine  : {'on' if ENGINE_SOCK.exists() and _engine_alive() else 'off'}")
    if _engine_alive():
        print("modem   :", json.dumps(engine_req({"cmd": "status"})["state"],
                                     ensure_ascii=False))
    r = subprocess.run(["docker", "ps", "--filter", "name=p1-vm", "--format", "{{.Status}}"],
                       capture_output=True, text=True)
    print("docker  :", r.stdout.strip() or "-")


def _engine_alive():
    try:
        engine_req({"cmd": "status"}, timeout=3)
        return True
    except OSError:
        return False


def cmd_stop(_):
    subprocess.run(["pkill", "-f", "wm_scenario_engine.py"], capture_output=True)
    subprocess.run(["pkill", "-f", "21_at_responder"], capture_output=True)
    subprocess.run(["bash", str(P1 / "scripts" / "vm_stop.sh")], capture_output=True)
    print("envctl: stopped")


def cmd_test(a):
    reports = P1 / "reports"
    reports.mkdir(exist_ok=True)
    junit = reports / "junit.xml"
    args = [sys.executable, "-m", "pytest", str(P1 / "tests"), "-v",
            f"--junitxml={junit}"] + a.pytest_args
    r = subprocess.run(args)
    print(f"\nenvctl: report -> {junit}")
    sys.exit(r.returncode)


def main():
    ap = argparse.ArgumentParser(prog="envctl", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)

    p = sp.add_parser("up"); p.add_argument("--fresh", action="store_true")
    sp.add_parser("provision")
    sp.add_parser("verify")
    p = sp.add_parser("snap"); p.add_argument("tag")
    p = sp.add_parser("restore"); p.add_argument("tag")
    p = sp.add_parser("engine"); p.add_argument("action", choices=["on", "off"])
    p = sp.add_parser("scenario"); p.add_argument("name")
    p = sp.add_parser("set_signal"); p.add_argument("value", type=int)
    p = sp.add_parser("set_link"); p.add_argument("state", choices=["on", "off"])
    p = sp.add_parser("set_delay"); p.add_argument("ms", type=int)
    p = sp.add_parser("inject_urc"); p.add_argument("line")
    p = sp.add_parser("at"); p.add_argument("command")
    sp.add_parser("status")
    sp.add_parser("stop")
    p = sp.add_parser("test"); p.add_argument("pytest_args", nargs="*")

    a = ap.parse_args()
    {"up": cmd_up, "provision": cmd_provision, "verify": cmd_verify,
     "snap": cmd_snap, "restore": cmd_restore, "engine": cmd_engine,
     "scenario": cmd_scenario, "set_signal": cmd_set_signal,
     "set_link": cmd_set_link, "set_delay": cmd_set_delay,
     "inject_urc": cmd_inject_urc, "at": cmd_at, "status": cmd_status,
     "stop": cmd_stop, "test": cmd_test}[a.cmd](a)


if __name__ == "__main__":
    main()
