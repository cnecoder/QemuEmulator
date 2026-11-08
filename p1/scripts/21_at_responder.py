#!/usr/bin/env python3
"""AT 应答器: 连接 usb-wmodem 的 chardev unix socket, 按行应答 AT 命令
用法: 21_at_responder.py <sock_path> [duration_sec]
输出 [RX]/[TX] 日志, 供 PoC 断言。"""
import socket
import sys
import time

def main():
    path = sys.argv[1]
    duration = float(sys.argv[2]) if len(sys.argv) > 2 else 3600
    deadline = time.time() + duration

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.settimeout(0.5)
    print("[at-responder] connected", flush=True)

    buf = b""
    while time.time() < deadline:
        try:
            data = s.recv(4096)
            if not data:
                print("[at-responder] peer closed", flush=True)
                break
            buf += data
            print(f"[RX] {data!r}", flush=True)
            while b"\r" in buf:
                line, _, buf = buf.partition(b"\r")
                line = line.strip()
                if not line:
                    continue
                up = line.decode(errors="replace").upper()
                # tty 回显/杂讯可能粘在前缀上（如 "WMoAT+CSQ"），定位行内 AT
                idx = up.find("AT")
                if idx >= 0:
                    up = up[idx:]
                if up.startswith("AT"):
                    if up == "ATI":
                        resp = b"WModem PoC 1.0\r\nOK\r\n"
                    elif up == "AT+CGMI":
                        resp = b"WModem\r\nOK\r\n"
                    elif up == "AT+CSQ":
                        resp = b"+CSQ: 18,99\r\nOK\r\n"
                    else:
                        resp = b"OK\r\n"
                    s.sendall(resp)
                    print(f"[TX] {resp!r}", flush=True)
        except socket.timeout:
            continue
    print("[at-responder] exit", flush=True)

if __name__ == "__main__":
    main()
