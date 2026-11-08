#!/usr/bin/env python3
"""wm 场景引擎: 虚拟蜂窝模块的运营商状态机 + AT 命令服务 + 场景控制 API

用法: wm_scenario_engine.py <at_sock> <engine_sock> <qmp_sock>
  at_sock     usb-wmodem 的 AT chardev (unix socket, QEMU 为 server)
  engine_sock 控制 API (unix socket, 行分隔 JSON)
  qmp_sock    QEMU QMP (按需连接: set_link / filter-delay)

控制 API (每行一个 JSON 请求 -> 应答一行 JSON):
  {"cmd":"status"}
  {"cmd":"scenario","name":"normal|no_sim|searching|denied|detached|offline"}
  {"cmd":"set_signal","rssi":0-31}
  {"cmd":"inject_urc","line":"+CEREG: 5"}
  {"cmd":"set_link","up":true|false}
  {"cmd":"set_delay","ms":200}        # 0 = 移除弱网
"""
import json
import os
import select
import socket
import sys
import threading
import time

QMP_WNET = "wnet"
QMP_DELAY_ID = "wm-delay"

# 注册状态 -> 3GPP stat 值
REG_STAT = {"none": 0, "searching": 2, "denied": 3, "home": 1, "roaming": 5}


def ts():
    return time.strftime("%H:%M:%S")


def log(msg):
    print(f"[{ts()}] {msg}", flush=True)


class Qmp:
    """按需连接的 QMP 客户端（避免独占 qmp.sock 影响快照脚本）"""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def _call(self, obj):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(self.path)
        f = s.makefile("rw")
        try:
            while True:
                line = f.readline()
                if not line:
                    raise RuntimeError("qmp closed")
                if "event" not in json.loads(line):
                    break
            f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    raise RuntimeError("qmp closed")
                if "event" not in json.loads(line):
                    break
            f.write(json.dumps(obj) + "\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    raise RuntimeError("qmp closed")
                m = json.loads(line)
                if "event" not in m:
                    return m
        finally:
            s.close()

    def hmp(self, cmdline):
        with self.lock:
            return self._call({"execute": "human-monitor-command",
                               "arguments": {"command-line": cmdline}})

    def object_add(self, args):
        with self.lock:
            return self._call({"execute": "object-add", "arguments": args})

    def object_del(self, oid):
        with self.lock:
            return self._call({"execute": "object-del", "arguments": {"id": oid}})


class Engine:
    def __init__(self, at_path, engine_path, qmp_path):
        self.at_path = at_path
        self.engine_path = engine_path
        self.qmp = Qmp(qmp_path)

        self.lock = threading.RLock()
        self.echo = False
        self.fun = 1              # 1=全功能 0=飞行模式
        self.sim = "ready"        # ready | absent | pin
        self.reg = "home"         # none | searching | denied | home | roaming
        self.data = "attached"    # attached | detached
        self.rssi = 20
        self.cereg_urc = False    # AT+CEREG=<n>=1/2 时开启
        self.cgerep_urc = False   # AT+CGEREP=1 时开启
        self.link = "up"
        self.delay_ms = 0

        self.dev = None           # 到 usb-wmodem chardev 的 socket
        self.rx_buf = b""

    # ---------------- 设备侧（AT 串口） ----------------

    def device_send(self, data: bytes):
        with self.lock:
            d = self.dev
        if d is None:
            return
        try:
            d.sendall(data)
        except OSError:
            pass

    def device_connect_loop(self):
        """断线自动重连（QEMU 重启后 at0.sock 会重建）"""
        while True:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.at_path)
                s.settimeout(None)
                with self.lock:
                    self.dev = s
                    self.rx_buf = b""
                log("device connected: " + self.at_path)
                self._device_read_loop(s)
            except OSError as e:
                log(f"device disconnected ({e}), retry in 2s")
                with self.lock:
                    self.dev = None
                time.sleep(2)

    def _device_read_loop(self, s):
        while True:
            data = s.recv(4096)
            if not data:
                raise OSError("peer closed")
            with self.lock:
                self.rx_buf += data
                # 按行切分（命令以 CR/LF 结尾）
                while b"\r" in self.rx_buf or b"\n" in self.rx_buf:
                    # 找最早的行结束符
                    i_cr = self.rx_buf.find(b"\r")
                    i_lf = self.rx_buf.find(b"\n")
                    idx = min(x for x in (i_cr, i_lf) if x >= 0)
                    line = self.rx_buf[:idx]
                    self.rx_buf = self.rx_buf[idx + 1:]
                    text = line.decode("ascii", errors="replace").strip()
                    if text:
                        self._on_device_line(text)

    def _on_device_line(self, line: str):
        log(f"AT> {line}")
        with self.lock:
            if self.echo:
                self.device_send((line + "\r\n").encode())
            out = self._dispatch(line)
        if out:
            payload = ("\r\n".join(out) + "\r\n").encode()
            self.device_send(payload)
            log(f"AT< {' | '.join(out)}")

    # ---------------- AT 命令分发（TS 27.007 子集 + 场景控制） ----------------

    @staticmethod
    def _norm(line: str):
        return line.upper().replace(" ", "")

    def _reg_stat(self):
        """当前注册状态 stat 值"""
        if self.fun == 0 or self.sim != "ready":
            return REG_STAT["none"]
        return REG_STAT[self.reg]

    def _data_attached(self):
        return (self.fun == 1 and self.sim == "ready"
                and self.reg in ("home", "roaming") and self.data == "attached")

    def _set_reg(self, new_reg):
        if self.reg == new_reg:
            return
        self.reg = new_reg
        if self.cereg_urc:
            self.device_send(f"\r\n+CEREG: {self._reg_stat()}\r\n".encode())
            log(f"URC +CEREG: {self._reg_stat()}")

    def _set_sim(self, new_sim):
        self.sim = new_sim
        if new_sim != "ready":
            self._set_reg("none" if self.fun == 1 else self.reg)

    def _set_data(self, new_data):
        if self.data == new_data:
            return
        self.data = new_data
        if self.cgerep_urc:
            ev = "ME DETACH" if new_data == "detached" else "ME ATTACH"
            self.device_send(f"\r\n+CGEV: {ev}\r\n".encode())
            log(f"URC +CGEV: {ev}")

    def _dispatch(self, line: str):
        L = self._norm(line)

        if not L.startswith("AT"):
            return ["ERROR"] if line else None
        if L == "AT":
            return ["OK"]
        if L == "ATE0":
            self.echo = False
            return ["OK"]
        if L == "ATE1":
            self.echo = True
            return ["OK"]
        if L == "ATI":
            return ["WModem ScenarioEngine 1.0", "OK"]
        if L in ("AT+CGMI", "AT+CGM?"):
            return ["WModem", "OK"]
        if L == "AT+CGMM":
            return ["WM650-GL", "OK"]
        if L == "AT+CGMR":
            return ["WModem Engine 2.0.0", "OK"]
        if L == "AT+CGSN" or L == "AT+GSN":
            return ["860000000000001", "OK"]
        if L == "AT+CIMI":
            if self.sim != "ready":
                return ["+CME ERROR: 10"]
            return ["460000000000001", "OK"]

        # --- SIM ---
        if L == "AT+CPIN?":
            if self.sim == "absent":
                return ["+CME ERROR: 10"]
            if self.sim == "pin":
                return ["+CPIN: SIM PIN", "OK"]
            return ["+CPIN: READY", "OK"]
        if L.startswith("AT+CPIN="):
            if self.sim == "pin":
                self.sim = "ready"
                return ["OK"]
            return ["+CME ERROR: 3"]  # operation not allowed

        # --- 信号 ---
        if L == "AT+CSQ":
            if self.fun == 0:
                return ["+CSQ: 99,99", "OK"]
            return [f"+CSQ: {self.rssi},99", "OK"]
        if L == "AT+CESQ":
            return ["+CESQ: 99,99,99,99,30,60", "OK"]

        # --- 网络注册 ---
        if L == "AT+CREG?":
            return [f"+CREG: 0,{self._reg_stat()}", "OK"]
        if L == "AT+CEREG?":
            return [f"+CEREG: {1 if self.cereg_urc else 0},{self._reg_stat()}", "OK"]
        if L == "AT+CGREG?":
            return [f"+CGREG: 0,{self._reg_stat()}", "OK"]
        if L in ("AT+CEREG=0", "AT+CEREG"):
            self.cereg_urc = False
            return ["OK"]
        if L.startswith("AT+CEREG="):
            n = L[len("AT+CEREG="):]
            self.cereg_urc = n in ("1", "2")
            return ["OK"]
        if L == "AT+COPS?":
            if self._reg_stat() in (1, 5):
                return ['+COPS: 0,0,"CMCC",7', "OK"]
            return ["+CME ERROR: 3"]
        if L == "AT+COPS=?":
            return ['+COPS: (2,"CMCC","CMCC","46000",7),'
                    '(2,"CUCC","CUCC","46001",7),'
                    '(2,"CTCC","CTCC","46011",7),'
                    '(0,1,2,7),,(0,1,2),(0,1,2)', "OK"]

        # --- 分组数据 ---
        if L == "AT+CGATT?":
            return [f"+CGATT: {1 if self._data_attached() else 0}", "OK"]
        if L.startswith("AT+CGATT="):
            want = L[len("AT+CGATT="):]
            if self.sim != "ready" or self.fun == 0 \
                    or self._reg_stat() not in (1, 5):
                return ["+CME ERROR: 3"]
            if want == "1":
                self._set_data("attached")
            elif want == "0":
                self._set_data("detached")
            return ["OK"]
        if L == "AT+CGDCONT?":
            return ['+CGDCONT: 1,"IP","wmnet","0.0.0.0",0,0', "OK"]
        if L.startswith("AT+CGDCONT="):
            return ["OK"]
        if L == "AT+CGACT?":
            return [f"+CGACT: 1,{1 if self._data_attached() else 0}", "OK"]
        if L.startswith("AT+CGACT="):
            if not self._data_attached():
                return ["+CME ERROR: 3"]
            return ["OK"]
        if L == "AT+CGPADDR":
            if not self._data_attached():
                return ["+CME ERROR: 3"]
            return ["+CGPADDR: 1,10.0.3.15", "OK"]

        # --- 终端功能（飞行模式） ---
        if L == "AT+CFUN?":
            return [f"+CFUN: {self.fun}", "OK"]
        if L.startswith("AT+CFUN="):
            mode = L[len("AT+CFUN="):].split(",")[0]
            if mode == "0":
                self.fun = 0
                self._set_reg("none")
                self._set_data("detached")
                self._qmp_set_link(False)
                return ["OK"]
            if mode == "1":
                self.fun = 1
                self._set_reg("home")
                self._set_data("attached")
                self._qmp_set_link(True)
                return ["OK"]
            return ["ERROR"]

        # --- URC 订阅 ---
        if L == "AT+CGEREP?":
            return [f"+CGEREP: {1 if self.cgerep_urc else 0}", "OK"]
        if L.startswith("AT+CGEREP="):
            self.cgerep_urc = L[len("AT+CGEREP="):].startswith("1")
            return ["OK"]

        # --- WM 厂商扩展（引擎直通查询） ---
        if L == "AT+WMSTAT":
            st = self.snapshot()
            return [f"+WMSTAT: {st['sim']},{st['reg']},{st['data']},"
                    f"{st['rssi']},{st['link']}", "OK"]

        return ["ERROR"]

    # ---------------- 数据面联动（QMP） ----------------

    def _qmp_set_link(self, up: bool):
        try:
            self.qmp.hmp(f"set_link {QMP_WNET} {'on' if up else 'off'}")
            with self.lock:
                self.link = "up" if up else "down"
            log(f"data plane link -> {self.link}")
        except Exception as e:
            log(f"qmp set_link failed: {e}")

    def _qmp_set_delay(self, ms: int):
        try:
            if ms > 0:
                self.qmp.object_del(QMP_DELAY_ID)  # 幂等：不存在时报错忽略
                self.qmp.object_add({"qom-type": "filter-buffer",
                                     "id": QMP_DELAY_ID, "netdev": QMP_WNET,
                                     "interval": ms * 1000})
            else:
                self.qmp.object_del(QMP_DELAY_ID)
        except Exception:
            pass  # object_del 不存在时的报错属正常
        with self.lock:
            self.delay_ms = ms
        log(f"data plane delay -> {ms}ms")

    # ---------------- 场景 ----------------

    def scenario(self, name):
        with self.lock:
            if name == "normal":
                self.fun = 1
                self._set_sim("ready")
                self._set_reg("home")
                self._set_data("attached")
                self.rssi = 20
                self._qmp_set_link(True)
                self._qmp_set_delay(0)
            elif name == "no_sim":
                self._set_sim("absent")
                self._set_reg("none")
                self._set_data("detached")
            elif name == "searching":
                self._set_sim("ready")
                self._set_reg("searching")
                self._set_data("detached")
            elif name == "denied":
                self._set_sim("ready")
                self._set_reg("denied")
                self._set_data("detached")
            elif name == "detached":
                self._set_data("detached")
                self._qmp_set_link(False)
            elif name == "offline":
                self.fun = 0
                self._set_reg("none")
                self._set_data("detached")
                self._qmp_set_link(False)
            else:
                return False
        log(f"scenario -> {name}")
        return True

    def snapshot(self):
        with self.lock:
            return {"sim": self.sim, "reg": self.reg, "data": self.data,
                    "rssi": self.rssi, "fun": self.fun, "echo": self.echo,
                    "link": self.link, "delay_ms": self.delay_ms,
                    "cereg_urc": self.cereg_urc, "cgerep_urc": self.cgerep_urc}

    # ---------------- 控制 API ----------------

    def control_loop(self):
        if os.path.exists(self.engine_path):
            os.unlink(self.engine_path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.engine_path)
        srv.listen(8)
        log("control api listening: " + self.engine_path)
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self._control_serve, args=(conn,),
                             daemon=True).start()

    def _control_serve(self, conn):
        f = conn.makefile("rw")
        while True:
            try:
                line = f.readline()
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line)
                    resp = self._control_handle(req)
                except Exception as e:
                    resp = {"ok": False, "error": str(e)}
                f.write(json.dumps(resp, ensure_ascii=False) + "\n")
                f.flush()
            except OSError:
                break
        conn.close()

    def _control_handle(self, req: dict):
        cmd = req.get("cmd")
        with self.lock:
            if cmd == "status":
                return {"ok": True, "state": self.snapshot()}
            if cmd == "scenario":
                ok = self.scenario(req.get("name", ""))
                return {"ok": ok, "state": self.snapshot()}
            if cmd == "set_signal":
                self.rssi = max(0, min(31, int(req.get("rssi", 20))))
                return {"ok": True, "state": self.snapshot()}
            if cmd == "inject_urc":
                line = req.get("line", "")
                self.device_send(f"\r\n{line}\r\n".encode())
                log(f"URC (injected) {line}")
                return {"ok": True}
            if cmd == "set_link":
                self._qmp_set_link(bool(req.get("up", True)))
                return {"ok": True, "state": self.snapshot()}
            if cmd == "set_delay":
                self._qmp_set_delay(int(req.get("ms", 0)))
                return {"ok": True, "state": self.snapshot()}
            return {"ok": False, "error": f"unknown cmd {cmd}"}


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    at_path, engine_path, qmp_path = sys.argv[1:4]
    eng = Engine(at_path, engine_path, qmp_path)
    threading.Thread(target=eng.device_connect_loop, daemon=True).start()
    try:
        eng.control_loop()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
