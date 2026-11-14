# p2 —— 独立四容器集群（终极版本）

> **自含实现**：不依赖 p0/p1 任何产物。克隆本仓库后按下方五步即可完整复现：
> QEMU 编译、云镜像、密钥、seed、四容器拉起全部由 `p2/` 内脚本完成。
> 后续 p0/p1 将被移除，仅保留本目录。

## 1. 五步复现

```bash
cd p2
python3 ctl.py init     # ① 编译镜像 + SSH 密钥 + 每设备 seed ISO（约 2 分钟）
python3 ctl.py build    # ② 下载 QEMU 11.1.3 源码并编译（usb-wmodem 内建，10-15 分钟，一次性）
python3 ctl.py image    # ③ 下载 noble arm64 云镜像并校验（约 600MB）
python3 ctl.py up       # ④ 拉起四容器集群（双设备首次启动含 cloud-init，约 3-6 分钟/台）
python3 ctl.py check    # ⑤ 验收：连通 + 透传 + 损伤矩阵 → MATRIX_GREEN
```

要求：x86_64 Linux / WSL2 + Docker；**无需 KVM**（全 TCG）；无需宿主 root。

## 2. 拓扑

```
p2-vm-a（设备A）        p2-router（损伤中心）         p2-server（原生服务）
VM-A arm64 ══tap══ seg-a1 ══ leg-a1 ══┐                ┌══ leg-s1 ══ seg-s1 ══ relay/业务
VM-A link2 ══tap══ seg-a2 ══ leg-a2 ──┤  ip_forward L3 ├── leg-s2 ══ seg-s2 ══ relay/业务
p2-vm-b（设备B）        │  tc netem ×6 腿  │
VM-B ══tap══ seg-b1 ── leg-b1 ────────┘
VM-B link2 ══ seg-b2 ── leg-b2
```

- **数据面**：透传路径 A→损伤a1→router→损伤s1→relay→损伤s1→router→损伤b1→B；另有 L3 直通 A→router→B（`STRICT_HUB=1` 可禁）
- **损伤面**：全部在路由容器内核（tc netem，六腿独立、每腿双向：egress + ifb 镜像）
- **控制面**：宿主 `link_ctl.py` → router 内 `wm_router_ctl.py`（unix socket `run/linkd.sock`）→ tc
- **网络路线甲**：docker 网段（10.9.x）仅簿记；真实段 IP（10.0.100~202.x）由容器内手工配置——宿主防火墙零改动，无需任何 fix 脚本
- **设备自配置**：每设备 seed ISO 携带 cloud-init（用户/密钥/netplan 静态链路配置/iperf3），新盘首次启动自动完成，无需手工置备

## 3. 损伤控制 API

```bash
# 按 path（三条腿同参，等价旧"对称双向"语义）
python3 ctl.py impair set --path link1 --delay 200 --jitter 20 --loss 5 --bw 1000
# 按单腿 / 单方向
python3 ctl.py impair set --leg a1 --delay 200
python3 ctl.py impair set --leg s2 --dir ingress --loss 30
# 清除与查看
python3 ctl.py impair clear --path link1
python3 ctl.py impair clear_all
python3 ctl.py impair status
```

协议：unix socket `p2/run/linkd.sock`，行 JSON（与 P1 linkd.sock 兼容，`path`/`leg`/`dir` 粒度增强）。
数据面语义：包每穿一腿受一次该方向损伤，端到端 RTT ≈ 所穿腿数 × 腿时延。

## 4. 验收矩阵（check.py）

基线连通（4 向）· 透传 relay 互转 · **path 独立性**（path1 损伤 path2 无感）· **leg 粒度**（单腿）·
**方向非对称**（仅 egress）· **丢包**（100% 全断/恢复）· **带宽**（限速 1Mbps → 解除）。
全绿输出 `MATRIX_GREEN`。

## 5. 目录

| 路径 | 内容 |
|---|---|
| `ctl.py` | 统一入口（init/build/image/up/check/status/impair/down） |
| `docker/Dockerfile.build` | QEMU 编译+运行镜像（ubuntu 26.04） |
| `device/dev-wmodem.c` | usb-wmodem 设备模型（蜂窝模块仿真，P2-B 接入集群设备） |
| `scripts/10~22_*.sh` | QEMU 编译（源码自动下载）/ 镜像下载校验 / 密钥 / 每设备 seed |
| `compat/QEMU_EFI.fd` | UEFI 固件（edk2 2024.02，实测 pin） |
| `cluster/` | compose + 三类容器 + 损伤控制（wm_router_ctl/link_ctl）+ check |
| `seed/user-data-*.tmpl` | 每设备 cloud-init 模板（公钥注入 + netplan 自配置） |

运行时产物（`images/ build/ run/ logs/ keys/ seed/*.iso`）全部可由上述命令重建，不入库。

## 6. 已知边界与路线

- 设备当前为最小形态（mgmt + 双链路网卡）；**P2-B**：usb-wmodem 蜂窝模块接入集群设备
  （AT 场景引擎 + RNDIS 蜂窝面 + 蜂窝损伤联动），QEMU 二进制已内建设备，届时仅改启动参数与置备
- TCG 性能约原生 1/5~1/15，吞吐类测试关注相对值
- `STRICT_HUB=1`（up.sh 环境变量）可强制 A↔B 互传只走 server
