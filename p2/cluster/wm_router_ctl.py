#!/usr/bin/env python3
"""p2 损伤控制守护（路由容器内，NET_ADMIN）。

监听 unix socket（默认 <P2>/run/linkd.sock），行 JSON 请求 → tc netem 操作。
六腿独立损伤（a1/b1/s1/a2/b2/s2），每腿双向：egress（物理口，router→对端）
+ ingress（ifb 镜像，对端→router）。

请求（与 P1 linkd.sock 协议兼容，path/leg 粒度增强）：
  {"cmd":"set", "path":"link1"|"link2", "leg":"a1|b1|s1|a2|b2|s2"(可选),
   "dir":"egress"|"ingress"(可选，缺省双向), "delay_ms":0, "jitter_ms":0,
   "loss_pct":0, "bw_kbps":0}
  {"cmd":"clear", "path":..., "leg":...(可选)}   /  {"cmd":"clear_all"}
  {"cmd":"status"}
说明：path 展开为该 path 的三条腿；leg 给定则只作用单腿；省略的损伤参数保持原值。
"""
import json
import os
import socket
import subprocess
import sys
import threading

PATH_LEGS = {"link1": ["a1", "b1", "s1"], "link2": ["a2", "b2", "s2"]}
PARAM_KEYS = ("delay_ms", "jitter_ms", "loss_pct", "bw_kbps")


def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


class Impairment:
    def __init__(self, legs_cfg):
        # legs_cfg: {"a1": {"if": "ethX", "ifb": "ifb-a1"}, ...}
        self.legs = legs_cfg
        self.state = {}  # (leg, dir) -> {"delay_ms":..,"jitter_ms":..,"loss_pct":..,"bw_kbps":..}

    @staticmethod
    def _netem_args(p):
        args = []
        if p.get("delay_ms"):
            args.append(f"delay {p['delay_ms']}ms")
            if p.get("jitter_ms"):
                args.append(f"{p['jitter_ms']}ms distribution normal")
        if p.get("loss_pct"):
            args.append(f"loss {p['loss_pct']}%")
        if p.get("bw_kbps"):
            args.append(f"rate {p['bw_kbps']}kbit")
        return " ".join(args)

    def _target(self, leg, direction):
        cfg = self.legs[leg]
        return cfg["if"] if direction == "egress" else cfg["ifb"]

    def apply(self, leg, direction, params):
        dev = self._target(leg, direction)
        merged = dict(self.state.get((leg, direction), {}))
        merged.update({k: v for k, v in params.items() if k in PARAM_KEYS and v is not None})
        args = self._netem_args(merged)
        if args:
            run(f"tc qdisc replace dev {dev} root handle 1: netem {args}")
            self.state[(leg, direction)] = merged
        else:
            self.clear(leg, direction)
        return merged

    def clear(self, leg, direction):
        dev = self._target(leg, direction)
        run(f"tc qdisc del dev {dev} root 2>/dev/null")
        self.state.pop((leg, direction), None)

    def _tc_stats(self, dev):
        out = run(f"tc -s qdisc show dev {dev}").stdout
        sent = dropped = 0
        for ln in out.splitlines():
            if "Sent" in ln:
                parts = ln.split()
                try:
                    sent += int(parts[1])
                    dropped += int(parts[parts.index("dropped,") + 1]) if "dropped," in ln else 0
                except (ValueError, IndexError):
                    pass
        return {"sent_pkts": sent, "dropped_pkts": dropped}

    def status(self):
        out = {}
        for leg in self.legs:
            for direction in ("egress", "ingress"):
                st = self.state.get((leg, direction))
                entry = {"params": st or {}, "dev": self._target(leg, direction),
                         "stats": self._tc_stats(self._target(leg, direction))}
                out[f"{leg}.{direction}"] = entry
        return out

    def resolve_legs(self, req):
        if req.get("leg"):
            leg = req["leg"]
            if leg not in self.legs:
                raise ValueError(f"unknown leg: {leg}")
            return [leg]
        path = req.get("path") or req.get("link")
        if not path:
            raise ValueError("need 'path' (link1/link2) or 'leg'")
        legs = PATH_LEGS.get(path)
        if not legs:
            raise ValueError(f"unknown path: {path}")
        return legs


class Handler:
    def __init__(self, imp):
        self.imp = imp

    def handle(self, req):
        cmd = req.get("cmd")
        if cmd == "set":
            direction = req.get("dir") or "both"
            dirs = ("egress", "ingress") if direction == "both" else (direction,)
            applied = {}
            for leg in self.imp.resolve_legs(req):
                for d in dirs:
                    applied[f"{leg}.{d}"] = self.imp.apply(leg, d, req)
            return {"ok": True, "applied": applied}
        if cmd == "clear":
            direction = req.get("dir") or "both"
            dirs = ("egress", "ingress") if direction == "both" else (direction,)
            for leg in self.imp.resolve_legs(req):
                for d in dirs:
                    self.imp.clear(leg, d)
            return {"ok": True}
        if cmd == "clear_all":
            for leg in self.imp.legs:
                for d in ("egress", "ingress"):
                    self.imp.clear(leg, d)
            return {"ok": True}
        if cmd == "status":
            return {"ok": True, "legs": self.imp.status()}
        return {"ok": False, "error": f"unknown cmd: {cmd}"}


def serve(sock_path, legs_cfg):
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    imp = Impairment(legs_cfg)
    handler = Handler(imp)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    os.chmod(sock_path, 0o666)  # 宿主普通用户经共享卷也要能连接（容器内 root 创建）
    srv.listen(8)
    print(f"[linkd] listening {sock_path}", flush=True)

    def client(conn):
        buf = b""
        try:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        resp = handler.handle(json.loads(line.decode()))
                    except Exception as e:  # noqa: BLE001
                        resp = {"ok": False, "error": str(e)}
                    conn.sendall(json.dumps(resp).encode() + b"\n")
        except OSError:
            pass
        finally:
            conn.close()

    while True:
        conn, _ = srv.accept()
        threading.Thread(target=client, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    sock_path, legs_path = sys.argv[1], sys.argv[2]
    with open(legs_path) as f:
        legs_cfg = json.load(f)
    serve(sock_path, legs_cfg)
