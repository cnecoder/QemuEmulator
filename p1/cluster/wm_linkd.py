#!/usr/bin/env python3
"""wm_linkd —— 设备间链路损伤代理（用户态 netem）

在多个 QEMU 虚拟机的 socket netdev（UDP 模式）之间透明转发以太网帧，
对每条链路独立施加：时延 / 抖动 / 丢包率 / 带宽限制。

链路布局（QEMU 侧，以 link1 为例）:
  设备A: -netdev socket,id=l1,udp=127.0.0.1:4001,localaddr=127.0.0.1:4101
  设备B: -netdev socket,id=l1,udp=127.0.0.1:4002,localaddr=127.0.0.1:4102
  → A 发包到 4001、B 发包到 4002；本代理把 A 的帧转给 B 的 4102、
    B 的帧转给 A 的 4101，转发前按链路参数施加损伤（对称作用于双向）。

控制 API（unix socket，行 JSON）:
  {"cmd":"set","link":"link1","delay_ms":200,"jitter_ms":10,"loss_pct":5,"bw_kbps":1000}
  {"cmd":"clear","link":"link1"}      # 清除单条链路损伤
  {"cmd":"clear_all"}
  {"cmd":"status"}

用法: wm_linkd.py <links.json> <control.sock>
links.json: {"links": {"link1": {"a_listen":[host,port],"b_listen":[host,port],
                                 "a_dest":[host,port],"b_dest":[host,port]}, ...}}
"""
import asyncio
import json
import os
import random
import sys
import time

LINKS_FILE = sys.argv[1] if len(sys.argv) > 1 else "links.json"
CTL_SOCK = sys.argv[2] if len(sys.argv) > 2 else "run/linkd.sock"


def ts():
    return time.strftime("%H:%M:%S")


def log(msg):
    print(f"[{ts()}] {msg}", flush=True)


class TokenBucket:
    """令牌桶：rate=0 表示不限速"""

    def __init__(self):
        self.rate = 0.0
        self.burst = 0.0
        self.tokens = 0.0
        self.last = time.monotonic()

    def set_rate(self, kbps):
        self.rate = kbps * 125.0  # bytes/s
        self.burst = max(self.rate * 0.5, 1500 * 4)
        self.tokens = self.burst
        self.last = time.monotonic()

    async def take(self, size):
        if self.rate <= 0:
            return
        while True:
            now = time.monotonic()
            self.tokens = min(self.burst, self.tokens + (now - self.last) * self.rate)
            self.last = now
            if self.tokens >= size:
                self.tokens -= size
                return
            deficit = (size - self.tokens) / self.rate
            await asyncio.sleep(min(deficit, 0.5))


class Link:
    def __init__(self, name, cfg):
        self.name = name
        self.a_listen = tuple(cfg["a_listen"])   # 收 A 的帧
        self.b_listen = tuple(cfg["b_listen"])   # 收 B 的帧
        self.a_dest = tuple(cfg["a_dest"])       # A 的接收地址（B→A 方向转发目的地）
        self.b_dest = tuple(cfg["b_dest"])       # B 的接收地址（A→B 方向转发目的地）
        self.delay_ms = 0.0
        self.jitter_ms = 0.0
        self.loss_pct = 0.0
        self.bw_kbps = 0
        self.transport_a = None
        self.transport_b = None
        self.stats = {"a2b_in": 0, "a2b_out": 0, "a2b_drop": 0,
                      "b2a_in": 0, "b2a_out": 0, "b2a_drop": 0}

    def params(self):
        return {"delay_ms": self.delay_ms, "jitter_ms": self.jitter_ms,
                "loss_pct": self.loss_pct, "bw_kbps": self.bw_kbps}

    def snapshot(self):
        return {"params": self.params(), "stats": dict(self.stats)}


class LinkDaemon:
    def __init__(self, links_cfg):
        self.links = {n: Link(n, c) for n, c in links_cfg.items()}
        self.buckets = {}   # (name, direction) -> TokenBucket

    def bucket(self, link, direction):
        key = (link.name, direction)
        if key not in self.buckets:
            b = TokenBucket()
            b.set_rate(link.bw_kbps)
            self.buckets[key] = b
        return self.buckets[key]

    async def forward(self, link, direction, data):
        """direction='a2b': 帧 from A，经损伤后发往 B 的接收地址"""
        stat_in = f"{direction}_in"
        stat_out = f"{direction}_out"
        stat_drop = f"{direction}_drop"
        link.stats[stat_in] += 1

        if link.loss_pct > 0 and random.random() * 100 < link.loss_pct:
            link.stats[stat_drop] += 1
            return
        delay = link.delay_ms
        if link.jitter_ms > 0:
            delay = max(0.0, delay + random.uniform(-link.jitter_ms, link.jitter_ms))
        if delay > 0:
            await asyncio.sleep(delay / 1000.0)
        await self.bucket(link, direction).take(len(data))

        out_sock = link.transport_b if direction == "a2b" else link.transport_a
        dest = link.b_dest if direction == "a2b" else link.a_dest
        if out_sock is None:
            link.stats[stat_drop] += 1
            return
        out_sock.sendto(data, dest)
        link.stats[stat_out] += 1

    async def bind(self, link, side):
        direction = "a2b" if side == "a" else "b2a"
        listen = link.a_listen if side == "a" else link.b_listen
        daemon = self

        class Proto(asyncio.DatagramProtocol):
            def connection_made(self, transport):
                if side == "a":
                    link.transport_a = transport
                else:
                    link.transport_b = transport

            def datagram_received(self, data, addr):
                asyncio.get_running_loop().create_task(
                    daemon.forward(link, direction, data))

        loop = asyncio.get_running_loop()
        await loop.create_datagram_endpoint(Proto, local_addr=listen)
        log(f"link {link.name}: {side} listening udp://"
            f"{listen[0]}:{listen[1]} (direction {direction})")

    def handle(self, req):
        cmd = req.get("cmd")
        if cmd == "status":
            return {"ok": True,
                    "links": {n: l.snapshot() for n, l in self.links.items()}}
        if cmd == "set":
            link = self.links.get(req.get("link", ""))
            if not link:
                return {"ok": False, "error": "unknown link"}
            link.delay_ms = float(req.get("delay_ms", link.delay_ms))
            link.jitter_ms = float(req.get("jitter_ms", link.jitter_ms))
            link.loss_pct = float(req.get("loss_pct", link.loss_pct))
            link.bw_kbps = int(req.get("bw_kbps", link.bw_kbps))
            for d in ("a2b", "b2a"):
                self.bucket(link, d).set_rate(link.bw_kbps)
            log(f"link {link.name} -> {link.params()}")
            return {"ok": True, "link": link.name, "params": link.params()}
        if cmd == "clear":
            link = self.links.get(req.get("link", ""))
            if not link:
                return {"ok": False, "error": "unknown link"}
            link.delay_ms = link.jitter_ms = 0.0
            link.loss_pct = 0.0
            link.bw_kbps = 0
            for d in ("a2b", "b2a"):
                self.bucket(link, d).set_rate(0)
            log(f"link {link.name} -> clear")
            return {"ok": True, "link": link.name, "params": link.params()}
        if cmd == "clear_all":
            for n in self.links:
                self.handle({"cmd": "clear", "link": n})
            return {"ok": True}
        return {"ok": False, "error": f"unknown cmd {cmd}"}

    async def control_server(self):
        if os.path.exists(CTL_SOCK):
            os.unlink(CTL_SOCK)

        async def serve(reader, writer):
            try:
                while True:
                    line = await reader.readline()
                    if not line:
                        break
                    try:
                        resp = self.handle(json.loads(line.decode()))
                    except Exception as e:
                        resp = {"ok": False, "error": str(e)}
                    writer.write(json.dumps(resp).encode() + b"\n")
                    await writer.drain()
            except (ConnectionError, asyncio.IncompleteReadError):
                pass
            finally:
                writer.close()

        server = await asyncio.start_unix_server(serve, path=CTL_SOCK)
        log("control api listening: " + CTL_SOCK)
        async with server:
            await server.serve_forever()


async def main():
    cfg = json.load(open(LINKS_FILE))
    daemon = LinkDaemon(cfg["links"])
    for link in daemon.links.values():
        await daemon.bind(link, "a")
        await daemon.bind(link, "b")
    log(f"linkd started, links: {list(daemon.links)}")
    await daemon.control_server()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
