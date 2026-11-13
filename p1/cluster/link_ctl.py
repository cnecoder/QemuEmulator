#!/usr/bin/env python3
"""链路损伤控制 CLI
用法:
  link_ctl.py status
  link_ctl.py set <link> [--delay <ms>] [--jitter <ms>] [--loss <pct>] [--bw <kbps>]
  link_ctl.py clear <link>
  link_ctl.py clear_all
"""
import argparse
import json
import os
import socket
import sys

SOCK = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "run", "linkd.sock"))


def call(req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(SOCK)
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        buf += s.recv(4096)
    s.close()
    return json.loads(buf.decode())


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("status")
    p = sp.add_parser("set"); p.add_argument("link")
    p.add_argument("--delay", type=float, default=None)
    p.add_argument("--jitter", type=float, default=None)
    p.add_argument("--loss", type=float, default=None)
    p.add_argument("--bw", type=int, default=None)
    p = sp.add_parser("clear"); p.add_argument("link")
    sp.add_parser("clear_all")
    a = ap.parse_args()

    if a.cmd == "status":
        req = {"cmd": "status"}
    elif a.cmd == "set":
        req = {"cmd": "set", "link": a.link}
        if a.delay is not None: req["delay_ms"] = a.delay
        if a.jitter is not None: req["jitter_ms"] = a.jitter
        if a.loss is not None: req["loss_pct"] = a.loss
        if a.bw is not None: req["bw_kbps"] = a.bw
    elif a.cmd == "clear":
        req = {"cmd": "clear", "link": a.link}
    else:
        req = {"cmd": "clear_all"}
    print(json.dumps(call(req), ensure_ascii=False))


if __name__ == "__main__":
    main()
