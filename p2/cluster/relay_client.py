#!/usr/bin/env python3
"""透传 relay 客户端（验收用）: python3 relay_client.py <port> <message>
连接 server 的角色端口，发送自身消息，等待对端消息（经 server 跨转发）到达。
"""
import socket
import sys

port, msg = int(sys.argv[1]), sys.argv[2].encode()
s = socket.create_connection(("10.0.102.2", port), timeout=10)
s.sendall(msg + b"\n")
s.settimeout(15)
got = b""
try:
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        got += chunk
        if b"\n" in got:
            break
except socket.timeout:
    pass
s.close()
print("SENT:", msg.decode())
print("RECV:", got.decode(errors="replace").strip() or "(none)")
