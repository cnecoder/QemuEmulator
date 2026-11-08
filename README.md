# QemuEmulator —— ARM64 + USB 蜂窝模块模拟环境

> 在 x64 宿主（含无 KVM 的容器）上，用 QEMU 模拟一台 ARM64 Linux 设备，并虚拟出一个
> **USB 蜂窝模块**（单设备复合枚举：3×串口走 AT + RNDIS 网卡走网络），供软件测试与
> **AI 自闭环开发**使用。全程纯软件模拟（TCG），零内核依赖、零特权要求。

- 当前状态：**P0/P1/P2/P3 全部完成并验证**（P1 15/15、快照 6/6、P2 22/22、pytest 32/32 全绿）
- 验证环境：Windows 11 WSL2（Ubuntu 24.04）+ Docker，AMD Ryzen 9 5950X
- 详细设计决策与验证记录：见 [`ARM64-USB-模拟环境调研方案.md`](ARM64-USB-模拟环境调研方案.md)（v3.6，附录 A-E）

---

## 1. 一分钟理解本项目

```
┌────────────── x64 宿主（WSL2 / Linux / 无 KVM 容器均可）──────────────┐
│                                                                      │
│  场景引擎 wm_scenario_engine.py（运营商大脑）                          │
│   · 状态机：SIM/注册/附着/飞行模式四轴，切换自动发 URC                  │
│   · 控制 API：JSON over unix socket（AI/测试调用）                     │
│        ▲ AT 应答（unix socket）      ▲ 数据面联动（QMP）               │
│        │                             │ set_link 真断网 / 弱网注入      │
│  ┌─────┴──────── QEMU（自定义构建）────────┴─────┐                     │
│  │  usb-wmodem 复合 USB 设备模型（~1000 行 C）     │                     │
│  │   in00/01/02 = option 串口 (VID 1234:5678)     │                     │
│  │   in03/04    = RNDIS 网卡                      │                     │
│  │  + ARM64 虚拟机（TCG，Ubuntu 24.04）            │                     │
│  └────────────────┬───────────────────────────────┘                     │
│                   ▼                                                    │
│  guest：option 驱动 → ttyUSB0/1/2；rndis_host → 网卡；                  │
│         被测软件经 UEvent(MODALIAS in 字段) 识别、AT 交互、真实联网      │
└──────────────────────────────────────────────────────────────────────┘
```

为什么这么做（三条硬需求 → 路线 C）：

1. 软件依赖 **ARM64 + USB 蜂窝硬件** → QEMU 全系统模拟（TCG）+ 自写 USB 设备模型；
2. 无 KVM、要在**无特权容器/CI** 里跑 → 全部用户态实现，宿主只需能运行普通进程；
3. 软件**按 UEvent 的 MODALIAS `in` 字段识别设备**，用通用 option/RNDIS 驱动，VID/PID 定制 →
   设备模型精确复刻该身份（比改宿主内核造真设备的路线 G 更可移植）。

新手概念（TCG/golden+overlay/cloud-init/QMP 等）见
[`ARM64-USB-模拟环境-工作详解.md`](ARM64-USB-模拟环境-工作详解.md) 第 1 章。

---

## 2. 仓库结构

```
QemuEmulator/
├── README.md                          ← 本文档（使用/复现/FAQ/限制）
├── ARM64-USB-模拟环境调研方案.md        ← 设计决策 + P0~P3 验证记录（附录 A-E）
├── ARM64-USB-模拟环境-工作详解.md       ← 面向 QEMU 小白的工作原理详解
├── ci/
│   ├── Dockerfile                     ← 多阶段：编译自定义 QEMU → 打包运行时（CI 用）
│   └── run_ci.sh                      ← CI 容器入口（镜像获取→置备→全量回归）
├── .github/workflows/ci.yml           ← GitHub Actions（workflow_dispatch，实验性）
├── p0/                                # 阶段0：ARM64 虚拟机基座
│   ├── docker/Dockerfile              #   QEMU 运行时镜像（QEMU 8.2 + UEFI 固件）
│   ├── scripts/
│   │   ├── 01_fetch_image.sh          #   下载 Ubuntu ARM64 云镜像 + SHA256 校验
│   │   ├── 02_make_seed.sh            #   生成 cloud-init seed ISO
│   │   ├── 03_run_vm.sh               #   （早期版本，现用 p1 的 20 号脚本）
│   │   ├── 04_wait_ssh.sh             #   等待虚拟机 SSH 就绪
│   │   ├── 05_snapshot_test.sh        #   快照复位验证（P0 验收）
│   │   ├── docker-run.sh              #   统一容器入口
│   │   └── qmp_savevm.py              #   QMP 快照客户端（snapshot-save job）
│   ├── seed/user-data + meta-data     #   cloud-init 配置（用户/公钥/软件包/置备 runcmd）
│   ├── images/                        #   golden 镜像（gitignore，脚本下载）
│   └── keys/                          #   测试 SSH 密钥（私钥 gitignore）
└── p1/                                # 阶段1+：USB 蜂窝模块 + 场景引擎 + 测试
    ├── device/dev-wmodem.c            # ★ usb-wmodem 复合 USB 设备模型（核心产物）
    ├── engine/wm_scenario_engine.py   # ★ 场景引擎（运营商状态机 + AT 服务 + 控制 API）
    ├── docker/Dockerfile.build        #   QEMU 9.2.0 编译环境镜像
    ├── envctl.py                      # ★ 统一控制台（日常操作入口）
    ├── scripts/
    │   ├── 10_build.sh + 11_apply_device.sh   # 编译自定义 QEMU（容器内执行）
    │   ├── 20_run_vm.sh               #   启动虚拟机（容器模式 / QEMU_DIRECT 直跑模式）
    │   ├── vm_stop.sh                 #   停机（模式自适应）
    │   ├── provision.sh               #   guest 内置备（驱动绑定/节点防护，幂等）
    │   ├── 23_wait_ssh.sh             #   等待 SSH
    │   ├── 24_poc_check.sh            #   （历史）单串口 PoC 验收
    │   ├── 25_verify_all.sh           #   设备级全量验收（15 断言）
    │   ├── 26_snapshot_check.sh       #   快照兼容验证（6 断言）
    │   ├── 27_scenario_check.sh       #   P2 场景验收（22 断言）
    │   ├── 21_at_responder.py         #   简单 AT 应答器（设备级验收用）
    │   ├── at_client.py               #   guest 侧 AT 客户端（cmd/monitor）
    │   └── engine_ctl.py              #   场景引擎控制 CLI
    ├── tests/                         # ★ pytest 回归（32 例，四组）
    │   ├── conftest.py                #   fixtures：lab（环境拉起）/modem/at/guest
    │   ├── test_device.py             #   枚举/in字段/多串口/RNDIS 网口
    │   ├── test_at_basic.py           #   AT 命令流程 + 错误路径
    │   ├── test_scenarios.py          #   场景矩阵 + URC + 注入
    │   └── test_data_plane.py         #   DHCP/网关/真实联网/流量计数
    ├── build/                         #   QEMU 源码+编译产物（gitignore，脚本重建）
    ├── run/ + logs/ + reports/        #   运行时状态（gitignore）
    └── .venv 等
```

---

## 3. 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 宿主 | x86_64 Linux（WSL2 亦可）| **不需要 KVM**（ARM64 模拟本来就用 TCG） |
| Docker | 任意近期版本 | 承载 QEMU（运行时/编译镜像）；CI 直跑模式除外 |
| 资源 | ≥8 核、≥8GB 内存、≥15GB 磁盘 | 推荐 16 核+（多核 TCG 更快） |
| 网络 | 可访问 github / clouds-images.ubuntu.com / download.qemu.org | 首次搭建需下载约 850MB |
| Python | 3.10+（宿主） | 回归测试用；pytest 自动安装到用户目录 |

**已验证**：WSL2 + Ubuntu 24.04 + Docker（本文档所有数据来自该环境）。
**未验证但理论可行**：纯 Linux 宿主、无 KVM 的 CI 容器（`QEMU_DIRECT=1` 模式）。

---

## 4. 快速开始（从零复现）

> 全程约 40-60 分钟（其中编译 QEMU 10-15 分钟、guest 首次置备 15-30 分钟视网络）。

```bash
# 0) 克隆
git clone git@github.com:cnecoder/QemuEmulator.git && cd QemuEmulator

# 1) 构建两个容器镜像（QEMU 编译环境 + QEMU 运行时）
docker build -t p1-qemu-build -f p1/docker/Dockerfile.build p1/docker
docker build -t p0-qemu      -f p0/docker/Dockerfile      p0/docker

# 2) 下载 Ubuntu ARM64 云镜像（588MB，含 SHA256 校验）
mkdir -p p0/images && bash p0/scripts/01_fetch_image.sh p0/images

# 3) 编译带 usb-wmodem 设备的自定义 QEMU（容器内，产物落 p1/build/）
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/p1":/work -w /work \
    p1-qemu-build bash scripts/10_build.sh

# 4) 拉起环境（启动虚拟机 + 等待 + 置备；首次置备含 guest 内安装，见 FAQ-9）
python3 p1/envctl.py up --fresh

# 5) 设备级验收（15 断言）
python3 p1/envctl.py verify

# 6) 全量回归（32 例 pytest + junit 报告）
python3 p1/envctl.py test
```

成功标志：`25` 输出 `P1_ALL_GREEN`、pytest 输出 `32 passed`、
报告落 `p1/reports/junit.xml`。

**强烈建议**：验收全绿后立刻打一个稳定快照，之后所有工作都从快照秒级起步：

```bash
python3 p1/envctl.py snap stable      # 存档（约 2 秒）
python3 p1/envctl.py restore stable   # 读档（约 8 秒，替代 5 分钟冷启动）
```

---

## 5. 日常使用手册（envctl）

| 命令 | 作用 | 典型耗时 |
|---|---|---|
| `envctl.py up [--fresh]` | 启动虚拟机 + 等待 + 置备 | 冷启 5min / 快照路径秒级 |
| `envctl.py status` | 环境总览（VM/引擎/modem 状态） | 秒 |
| `envctl.py provision` | 置备（驱动绑定+节点防护，幂等） | 5-60s |
| `envctl.py verify` | 设备级验收 15 断言 | 1-2min |
| `envctl.py snap <tag>` / `restore <tag>` | 整机存档 / 读档 | 2s / 8s |
| `envctl.py engine on\|off` | 场景引擎启停 | 秒 |
| `envctl.py scenario <name>` | 场景切换 | 秒 |
| `envctl.py set_signal <0-31>` | 信号强度注入 | 秒 |
| `envctl.py set_link on\|off` | 数据面链路真通断 | 秒 |
| `envctl.py set_delay <ms>` | 弱网延迟注入（0=清除） | 秒 |
| `envctl.py inject_urc '<行>'` | URC 注入 | 秒 |
| `envctl.py at '<AT 命令>'` | 向 guest 发 AT 打印应答 | 秒 |
| `envctl.py test [pytest 参数]` | 全量回归（junit 报告） | 约 8min |
| `envctl.py stop` | 停虚拟机与引擎 | 秒 |

场景名：`normal`（正常注册+附着）/ `no_sim`（拔卡）/ `searching`（搜网）/
`denied`（注册拒绝）/ `detached`（去附着+真断链路）/ `offline`（飞行模式）。

登录虚拟机手动排查：`ssh -i p0/keys/id_ed25519 -p 2223 test@127.0.0.1`。

---

## 6. 场景引擎与控制 API

引擎 = 虚拟蜂窝模块的"运营商大脑"：AT 命令服务（TS 27.007 子集）+ 四轴状态机
（SIM × 注册 × 数据附着 × 飞行模式）+ URC 自动上报 + 数据面联动。

**AI / 测试程序调用方式**（unix socket，行 JSON，位于 `p1/run/engine.sock`）：

```bash
python3 p1/scripts/engine_ctl.py status                 # 读状态
python3 p1/scripts/engine_ctl.py scenario no_sim        # 拔卡
python3 p1/scripts/engine_ctl.py set_signal 5           # 弱信号
python3 p1/scripts/engine_ctl.py set_link off           # 真断数据链路
python3 p1/scripts/engine_ctl.py set_delay 500          # 注入 500ms 弱网
python3 p1/scripts/engine_ctl.py inject_urc '+CEREG: 5' # 手工注入 URC
```

或 Python 内直接：

```python
import socket, json
def engine(req):
    s = socket.socket(socket.AF_UNIX); s.connect("p1/run/engine.sock")
    s.sendall(json.dumps(req).encode()+b"\n")
    buf=b""
    while b"\n" not in buf: buf += s.recv(4096)
    return json.loads(buf)

engine({"cmd":"scenario","name":"no_sim"})   # → {"ok":true,"state":{...}}
```

AT 侧行为示例（guest 内 ttyUSB0）：

| 触发 | guest 观测 |
|---|---|
| 场景 `normal` | `AT+CPIN?`→`+CPIN: READY`；`AT+CEREG?`→`+CEREG: 0,1`；`AT+CGATT?`→`+CGATT: 1` |
| 场景 `no_sim` | `AT+CPIN?`→`+CME ERROR: 10`；URC `+CEREG: 0`（已订阅时） |
| 场景 `detached` | `AT+CGATT?`→`+CGATT: 0`；URC `+CGEV: ME DETACH`；**RNDIS 链路真断**（ping/curl 失败） |
| `set_signal 5` | `AT+CSQ`→`+CSQ: 5,99` |
| `set_delay 500` | 经蜂窝口的流量时延 +0.5s 量级 |

URC 需要 guest 侧订阅：`AT+CEREG=1`（注册 URC）、`AT+CGEREP=1`（+CGEV URC）——与真机一致。

---

## 7. 测试套件（pytest，32 例）

```bash
python3 p1/envctl.py test                     # 全量，junit 报告
python3 p1/envctl.py test tests/test_scenarios.py -k no_sim   # 子集
```

| 文件 | 覆盖 | 例数 |
|---|---|---|
| `test_device.py` | VID/PID 枚举、MODALIAS in 字段布局、ttyUSB0-2 option 绑定、RNDIS 网口 | 4 |
| `test_at_basic.py` | CPIN/CGMI/CGMM/CGMR/CGSN/CSQ/CEREG/CGATT/COPS/CGDCONT/CGPADDR/WMSTAT、未知命令 ERROR、ATE 回显 | 13 |
| `test_scenarios.py` | no_sim 及恢复、searching、denied、detached（真断链）、offline、URC 投递、信号注入、弱网注入与回落 | 10 |
| `test_data_plane.py` | RNDIS 网口、DHCP 租约（10.0.3.15）、网关可达、经蜂窝口真实联网 200、USB 流量计数增长 | 5 |

**写新用例**：继承现有模式——`at(cmd)` 发命令并断言应答、`modem.scenario(...)` 切场景、
`guest(shell命令)` 在虚拟机内执行、`curl_via_rndis()` 走蜂窝口连通性。
conftest 的 `lab` fixture 自动保证环境就绪（虚拟机没起会自动拉起）。

---

## 8. 在无 KVM 的 CI 容器里复现

```bash
# 构建 CI 镜像（多阶段：容器内编译自定义 QEMU）
docker build -t qemuemulator-ci -f ci/Dockerfile .
# 全量回归（容器内直跑 QEMU，QEMU_DIRECT=1）
docker run --rm --network host -v "$PWD":/lab qemuemulator-ci bash /lab/ci/run_ci.sh
```

`.github/workflows/ci.yml` 已提供（workflow_dispatch 手动触发，junit 产物上传）。
**注**：该 workflow 尚未在真实 GitHub Actions 上跑过（见 §11 限制），首次运行约 40-60 分钟，
建议先配 `actions/cache` 缓存 `p0/images` 与 `p1/run`。

---

## 9. 常见问题（FAQ：症状 → 根因 → 处理）

以下全部来自实际踩坑，多数已固化在脚本里自动处理；列出供手动排查。

| # | 症状 | 根因 | 处理 |
|---|---|---|---|
| 1 | USB 接口枚举正常但 option 驱动不绑定 | **usbtouchscreen 抢答**：内核该驱动按接口类整类认领（0xff/0xEF/0x0A 都抢），定制 VID/PID 不在它的忽略清单 | 已固化：置备脚本 `blacklist usbtouchscreen` + `rmmod`。不要手工往接口上绑 |
| 2 | 驱动正常但读写 ttyUSB 无任何 USB 流量，甚至读回自己写的内容 | **假文件遮蔽**：bash 重定向（`>`/`<>`）在节点缺失时创建同名普通文件 | 置备脚本自动清理。手动检查：`ls -l /dev/ttyUSB*` 必须是 `crw`；脚本里操作设备节点前用 `[ -c ]` 判断 |
| 3 | `echo VID PID > new_id` 报 No such file | 新内核 usb-serial 驱动 sysfs 目录名是 **`option1`**（不是 `option`） | 脚本已做 `option1`/`option` 兼容回退 |
| 4 | RNDIS 网口不出、`bind: No such device` | RNDIS 控制接口类必须匹配 **`rndis_host` 的通用匹配 `0xEF/0x04/0x01`**（各内核版本查 `modules.alias` 确认）；且 option 的 new_id 是设备级匹配会连 RNDIS 接口一起抢 | 设备描述符按 0xEF/0x04/0x01 设计；置备顺序：先 rndis_host 后 option，中间 authorized=0/1 重枚举并**等待枚举完成再写 new_id** |
| 5 | loadvm 后第一个 USB 包触发 QEMU 断言崩溃（`dev->state == USB_STATE_DEFAULT`） | 自定义 USB 设备的 vmsd 未包含 **`VMSTATE_USB_DEVICE`**（USB 核心状态不自动迁移） | 已加入 dev-wmodem 的 vmstate。自写 USB 设备做快照的通用必修项 |
| 6 | `savevm` 报 `Device 'pflash1' ... does not support snapshots` | UEFI 变量存储（pflash）不支持内部快照 | 虚拟机改用 `-bios` 直载固件（当前配置）；或用 QMP `snapshot-save` 指定设备列表 |
| 7 | guest 双网口 IP 相同（都是 10.0.2.15）、ARP FAILED、出站 EHOSTUNREACH | **双 slirp 同网段冲突**（管理网与蜂窝网都是 10.0.2.0/24） | 蜂窝网 netdev 已独立：`net=10.0.3.0/24,dhcpstart=10.0.3.15` |
| 8 | `ping 公网IP` 经蜂窝口 100% 丢 | **slirp 无 raw socket 权限，不支持 ICMP 出站**（架构限制，见 §10） | 连通性用 TCP 验证（curl），不要用公网 ping；网关 10.0.3.2 的 ping 可用 |
| 9 | 全新虚拟机里 dhclient 不存在 / 模块装不上 | noble 云镜像精简，无 isc-dhcp-client；modules-extra 安装在 TCG+slirp 下很慢（24 分钟量级） | seed 已固化 `packages: [linux-modules-extra-generic, isc-dhcp-client]`（首启自动装）；建议：置备成功后立即 `envctl snap stable`，之后从快照起步 |
| 10 | USB 设备启动即退出：`No 'usb-bus' bus found` | QEMU 参数漏了 USB 控制器 | `-M virt` 默认无 USB，需 `-device qemu-xhci`（已固化） |
| 11 | 场景引擎/responder 连不上 AT 通道或数据串到别人 | **QEMU chardev socket 单客户端**：两个使用者互相挤占 | 谁用谁先杀对方（各验收脚本入口已统一处理）；手动使用时 `pkill -f wm_scenario_engine` 后再起 responder |
| 12 | URC 注入后 guest 没收到 | at_client 打开端口时 tcflush 把已缓冲 URC 清掉；或 URC 订阅未开启 | 已修（打开端口后先收残留）；确认 `AT+CEREG=1`/`AT+CGEREP=1` 已订阅 |
| 13 | pytest 里 AT 命令偶发超时/空响应 | TCG 时序抖动（重枚举窗口、python 启动慢） | conftest 已内置无效响应重试；`at_client` 写路径非阻塞重试 |
| 14 | 弱网延迟不生效 | ①流量没走被测口（路由/断言假阳性）；②QEMU **没有 filter-delay 对象**（只有 filter-buffer） | 断言用 `curl --interface <蜂窝口>`；延迟用 `filter-buffer,interval=<µs>`（已固化） |
| 15 | 容器里启动的 QEMU 随脚本退出被杀 | 容器主进程退出连带杀进程 | 已固化：QEMU 作为分离容器的前台进程（容器存活=VM 存活）；CI 用 QEMU_DIRECT=1 直跑 |
| 16 | `git push` 端口 22 被拦（Connection closed by 198.18.x.x） | 代理/防火墙拦 SSH 22 端口 | `~/.ssh/config` 走 `ssh.github.com:443`（仓库已配置，代理开/关均可用） |
| 17 | overlay 换机器/换路径后启动失败（Could not open backing file） | overlay 记录的 backing 绝对路径失效 | `qemu-img rebase -u -b <新golden路径> -F qcow2 <overlay>` 无损改写 |
| 18 | 网络慢导致 cloud-init 卡 20 分钟+ | TCG+slirp 出站带宽有限（实测 ~28KB/s 低谷） | 避免在 guest 里大面积 apt；依赖固化进 seed packages；用快照跳过置备 |

---

## 10. 已知限制

| 类别 | 限制 | 影响 / 对策 |
|---|---|---|
| 性能 | TCG 指令翻译，约原生 1/5~1/15；冷启动约 5 分钟；guest 内 apt 大流量安装可达 20 分钟+ | 功能/集成测试无碍；**性能类测试请用真机**；用快照跳过置备 |
| 网络 | slirp 不支持 ICMP 出站（公网 ping 不通）；DNS/DHCP/TCP/UDP 均正常 | 连通性断言用 TCP（curl） |
| 数据面吞吐 | RNDIS 收包为单包缓冲（in_buf 一次一包），未做高吞吐优化 | AT 交互与常规 HTTP 验证足够；大流量压测不适用 |
| AT 通道 | QEMU chardev 单客户端：引擎与应答器**互斥**，同一时刻只能一个接入 | 已由脚本统一管理；手动使用注意切换 |
| 快照 | loadvm 后宿主侧 AT 引擎需重连（socket 对端不在快照内）——引擎已内置自动重连 | 恢复后 2 秒内自动就绪 |
| 并发 | 单 VM 实例（容器名/端口固定），无多实例并行 | 需要 sharding 时复制目录改端口/名字 |
| 客户机 | 已验证通用发行版（Ubuntu 24.04 ARM64）；嵌入式定制内核（Yocto/Buildroot）架构上支持但未接入；Android 未实现 | 嵌入式阶段把产物（Image+rootfs）替换 golden 即可；Android 见调研方案 §8 |
| CI | `ci/Dockerfile` 与 GitHub Actions workflow 已提供但**未在真实 Actions 上验证** | 首跑预计 40-60 分钟；建议配 cache |
| 合规 | 设备默认使用测试 VID/PID（1234:5678）；改成产品真实 VID/PID 仅限内部测试环境 | 避免测试机流入产线/外网 |
| 识别依据 | 设备身份以 MODALIAS `in` 字段为准（in00-02 串口、in03/04 RNDIS）——**接口序号是硬契约**，改布局需同步被测软件 | 改布局时改 dev-wmodem.c 的接口数组顺序 |

---

## 11. 给 AI 代理的使用指引（自闭环配方）

```bash
# ① 状态自检（先看再动）
python3 p1/envctl.py status

# ② 环境不在位就拉起（幂等，可重复执行）
python3 p1/envctl.py up            # 已运行则快速返回
python3 p1/envctl.py verify        # 设备级 15 断言

# ③ 跑回归并读报告
python3 p1/envctl.py test          # junit: p1/reports/junit.xml

# ④ 失败复现与实验（场景注入 → AT 验证 → 状态核对 → 恢复）
python3 p1/envctl.py scenario detached
python3 p1/envctl.py at "AT+CGATT?"          # 期望 +CGATT: 0
python3 p1/envctl.py status                  # 引擎状态 data=detached, link=down
python3 p1/envctl.py scenario normal         # 用例结束必须恢复（或依赖 fixture 兜底）

# ⑤ 秒级复位重跑
python3 p1/envctl.py restore stable
```

AI 注意事项：
1. **改被测软件后**只需重跑 `envctl test`；**改设备模型（dev-wmodem.c）后**需重编译
   （`docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/p1":/work -w /work p1-qemu-build bash scripts/10_build.sh`）
   并重启虚拟机；
2. AT 通道同一时刻只有一个使用者——先 `engine off` 再用 responder，反之亦然；
3. 场景实验结束务必恢复 `normal`（或整轮测试从 `restore stable` 起步）；
4. 网络断言必须绑定蜂窝口（`curl --interface enx525400123457`），不要用公网 ping。

---

## 12. 文档地图

| 文档 | 内容 | 读者 |
|---|---|---|
| **README.md**（本文） | 使用/复现/FAQ/限制 | 所有人与 AI 的入口 |
| `ARM64-USB-模拟环境调研方案.md`（v3.6） | 架构选型演进、三路线对比、P0-P3 验证记录（附录 A-E）、参考资料 | 想知道"为什么这么设计" |
| `ARM64-USB-模拟环境-工作详解.md` | 面向 QEMU 小白的工作原理逐层讲解 | 想系统理解原理的新人 |
| `p1/tests/` | 32 例回归（可执行的规格说明） | 想知道"系统应有什么行为" |
