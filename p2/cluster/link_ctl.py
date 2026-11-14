#!/usr/bin/env python3
"""p2 链路损伤控制 CLI（宿主侧，经 unix socket 与路由容器内 wm_router_ctl.py 通信）。

用法:
  link_ctl.py set  [--path link1|link2] [--leg a1|b1|s1|a2|b2|s2] [--dir egress|ingress]
                   [--delay MS] [--jitter MS] [--loss PCT] [--bw KBPS]
  link_ctl.py clear [--path link1|link2] [--leg ...] [--dir ...]
  link_ctl.py clear_all
  link_ctl.py status

省略的损伤参数保持原值；--path 展开为该 path 三条腿（a1/b1/s1 或 a2/b2/s2）。
"""
import argparse
import json
import socket
import sys
from pathlib import Path

SOCK = Path(__file__).resolve().parent.parent / "run" / "linkd.sock"


def send(req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect(str(SOCK))
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        buf += s.recv(65536)
    s.close()
    return json.loads(buf.decode())


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_set = sub.add_parser("set")
    p_set.add_argument("--path", choices=["link1", "link2"])
    p_set.add_argument("--leg", choices=["a1", "b1", "s1", "a2", "b2", "s2"])
    p_set.add_argument("--dir", choices=["egress", "ingress"])
    p_set.add_argument("--delay", type=int, help="时延 ms")
    p_set.add_argument("--jitter", type=int, help="抖动 ms")
    p_set.add_argument("--loss", type=float, help="丢包 %%")
    p_set.add_argument("--bw", type=int, help="带宽 kbps")

    p_clr = sub.add_parser("clear")
    p_clr.add_argument("--path", choices=["link1", "link2"])
    p_clr.add_argument("--leg", choices=["a1", "b1", "s1", "a2", "b2", "s2"])
    p_clr.add_argument("--dir", choices=["egress", "ingress"])

    sub.add_parser("clear_all")
    sub.add_parser("status")

    args = ap.parse_args()
    if args.cmd == "set":
        if not args.path and not args.leg:
            ap.error("set 需要 --path 或 --leg")
        req = {"cmd": "set", "path": args.path, "leg": args.leg, "dir": args.dir,
               "delay_ms": args.delay, "jitter_ms": args.jitter,
               "loss_pct": args.loss, "bw_kbps": args.bw}
    elif args.cmd == "clear":
        req = {"cmd": "clear", "path": args.path, "leg": args.leg, "dir": args.dir}
    elif args.cmd == "clear_all":
        req = {"cmd": "clear_all"}
    else:
        req = {"cmd": "status"}

    resp = send(req)
    print(json.dumps(resp, ensure_ascii=False, indent=2))
    if not resp.get("ok"):
        sys.exit(1)


if __name__ == "__main__":
    main()
