#!/usr/bin/env python3
"""场景引擎控制 CLI（宿主侧）
用法:
  engine_ctl.py status
  engine_ctl.py scenario <name>            # normal/no_sim/searching/denied/detached/offline
  engine_ctl.py set_signal <0-31>
  engine_ctl.py set_link <on|off>
  engine_ctl.py set_delay <ms>
  engine_ctl.py inject_urc '<URC 行>'
  engine_ctl.py raw '<json>'
"""
import json
import os
import socket
import sys

SOCK = os.path.join(os.path.dirname(__file__), "..", "run", "engine.sock")
SOCK = os.path.abspath(SOCK)


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
    a = sys.argv[1:]
    if not a:
        req = {"cmd": "status"}
    elif a[0] == "status":
        req = {"cmd": "status"}
    elif a[0] == "scenario":
        req = {"cmd": "scenario", "name": a[1]}
    elif a[0] == "set_signal":
        req = {"cmd": "set_signal", "rssi": int(a[1])}
    elif a[0] == "set_link":
        req = {"cmd": "set_link", "up": a[1] == "on"}
    elif a[0] == "set_delay":
        req = {"cmd": "set_delay", "ms": int(a[1])}
    elif a[0] == "inject_urc":
        req = {"cmd": "inject_urc", "line": a[1]}
    elif a[0] == "raw":
        req = json.loads(a[1])
    else:
        print(__doc__)
        sys.exit(1)
    print(json.dumps(call(req), ensure_ascii=False))


if __name__ == "__main__":
    main()
