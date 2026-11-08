#!/usr/bin/env python3
"""guest 侧 AT 客户端（运行于虚拟机内）
用法:
  at_client.py cmd   <AT 命令>              # 单命令收发，打印全部应答
  at_client.py monitor <秒>                 # 持续监听端口 N 秒（捕获 URC）
"""
import os
import select
import sys
import termios
import time

TTY = "/dev/ttyUSB0"


def open_tty():
    fd = os.open(TTY, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attr = termios.tcgetattr(fd)
    attr[0] = 0          # iflag: raw
    attr[1] = 0          # oflag: raw
    attr[3] = 0          # lflag: 关 echo/行缓冲
    attr[6][termios.VMIN] = 0
    attr[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    return fd


def cmd_roundtrip(cmd, timeout=5.0):
    fd = open_tty()
    try:
        # 非阻塞写 + 重试（USB 重枚举窗口内 tty 缓冲可能瞬时满）
        payload = cmd.encode() + b"\r"
        end = time.time() + timeout
        while payload and time.time() < end:
            try:
                payload = payload[os.write(fd, payload):]
            except BlockingIOError:
                time.sleep(0.05)
        buf = b""
        # 先收掉已缓冲的数据（URC 等），避免被当作下一命令响应的一部分
        end = time.time() + timeout
        last_len = 0
        quiet = 0.0
        drain_end = time.time() + 0.6
        while time.time() < drain_end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                buf += os.read(fd, 4096)
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                buf += os.read(fd, 4096)
                quiet = 0.0
            else:
                quiet += 0.1
            # 收到 OK/ERROR 且短暂静默 -> 完成
            tail = buf[-64:]
            if (b"OK" in tail or b"ERROR" in tail) and quiet >= 0.3:
                break
            if len(buf) == last_len and quiet >= 1.0 and buf:
                break
            last_len = len(buf)
        return buf.decode(errors="replace")
    except OSError as e:
        return f"[at_client error: {e}]"
    finally:
        os.close(fd)


def monitor(seconds):
    fd = open_tty()
    try:
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                sys.stdout.write(os.read(fd, 4096).decode(errors="replace"))
                sys.stdout.flush()
    finally:
        os.close(fd)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "monitor":
        monitor(float(sys.argv[2]))
    elif sys.argv[1] == "cmd":
        out = cmd_roundtrip(" ".join(sys.argv[2:]))
        print(out)
    else:
        out = cmd_roundtrip(" ".join(sys.argv[1:]))
        print(out)


if __name__ == "__main__":
    main()
