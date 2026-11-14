#!/usr/bin/env python3
"""透传 relay 参考实现（一期）：字节级 TCP 跨转发，每条 path 一对固定角色端口。

  path1: A 角色 :9001 | B 角色 :9002    path2: A 角色 :9101 | B 角色 :9102

两侧连接到齐后互转字节流；任一侧断开即重置配对。设备经损伤链路连接本服务
（A/B 各连 server 同一 IP 的不同角色端口），实现"两设备通过 server 数据互传"。
"""
import asyncio

PAIRS = [("path1", 9001, 9002), ("path2", 9101, 9102)]


class Pair:
    def __init__(self, name, port_a, port_b):
        self.name = name
        self.ports = (port_a, port_b)
        self.sides = {}  # role(0=A,1=B) -> (reader, writer)

    async def handle(self, role, reader, writer):
        peer_role = 1 - role
        self.sides[role] = (reader, writer)
        state = "paired" if peer_role in self.sides else "waiting-peer"
        print(f"[relay:{self.name}] port{self.ports[role]} connected ({state})", flush=True)
        try:
            while peer_role not in self.sides:
                await asyncio.sleep(0.2)
            _, peer_writer = self.sides[peer_role]
            await self._pipe(reader, peer_writer)
        finally:
            self.sides.pop(role, None)
            other = self.sides.pop(peer_role, None)
            if other:
                try:
                    other[1].close()
                except OSError:
                    pass
            print(f"[relay:{self.name}] port{self.ports[role]} closed, pair reset", flush=True)

    @staticmethod
    async def _pipe(reader, writer):
        try:
            while chunk := await reader.read(4096):
                writer.write(chunk)
                await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                writer.close()
            except OSError:
                pass


async def main():
    for name, pa, pb in PAIRS:
        pair = Pair(name, pa, pb)
        for role, port in ((0, pa), (1, pb)):
            await asyncio.start_server(
                lambda r, w, pair=pair, role=role: pair.handle(role, r, w),
                "0.0.0.0", port)
            print(f"[relay:{name}] listening :{port}", flush=True)
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
