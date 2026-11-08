# ARM64 + USB 蜂窝模块 模拟验证环境 —— 调研与方案（v3）

> 状态：调研阶段，未实施。
> v2 变更：① 确认目标 USB 设备画像（单设备复合拓扑 / 定制 VID/PID / option + RNDIS / UEvent 识别），**基线路线由 U 切换为 G**；② 补充"无 KVM 的 x86 容器"可移植性要求；③ 更新 WSL2 内核 config 清单与路线图。
> v3 变更：新增**部署形态二：Ubuntu 20.04 容器（AMD 服务器）**——注入方式改为 usb-redir over TCP、gadget 服务与数据面上移物理宿主、QEMU 需自建新版本、新增物理宿主前置检查清单。
> v3.1 变更：新增**形态三：完全无内核改动**（USB appliance VM + usb-redir）——在 WSL2 换内核或宿主装模块均不可行时的 G 路线完整替代；澄清"重编译 WSL2 内核 ≠ 改宿主机内核"。
> v3.2 变更：**路线 C 重估并升级为 P1 首选**（新增设计草图与四级验收阶梯）；G/形态三转为备选与对冲。
> v3.3 变更：**P1 路线 C 骨架 PoC 全绿**（附录 B）——定制 VID/PID 复合设备枚举、option 驱动绑定、AT 经 USB 串口往返全部打通；路线 C 的可行性得到实测证实。
> v3.4 变更：**P1续 全部完成（附录 C）**——复合设备 v2（3×option 串口 + RNDIS，in00-04 固定编号）、RNDIS 真实 DHCP + 互联网、置备自动化（黑名单+顺序置备）、快照兼容（VMSTATE_USB_DEVICE）。P1 全量 15/15 全绿 + 快照 6/6 全绿。P3 AI 闭环的全部前置条件就绪。
> v3.5 变更：**P2 场景引擎落地（附录 D）**——AT 引擎升级为运营商状态机（SIM/注册/附着三轴 + URC），控制 API（JSON over unix socket），数据面联动（QMP set_link 真断网 + filter-buffer 弱网注入）；修复双 slirp 同网段冲突（wnet 独立 10.0.3.0/24）。**P2 验收 22/22 全绿。**

---

## 1. 需求与约束

### 1.1 需求
- x64 宿主上模拟 ARM64 目标设备，运行被测软件，服务 AI 自闭环测试。
- 虚拟 USB 蜂窝模块：USB 串口走 AT 交互 + USB 网卡走网络；支持场景注入（断网/弱网/无 SIM 等）。
- 客户机演进：通用 Linux 发行版 → 嵌入式定制内核（含不同内核版本）→ 远期 Android（native/framework）。
- 可移植：WSL2 起步 → Linux CI → **无 KVM 的 x86 容器**。

### 1.2 目标 USB 设备画像（v2 确认）
| 属性 | 取值 |
|---|---|
| 拓扑 | **单一 USB 设备**，复合枚举：串口 + 网口 |
| VID/PID | **定制**（与产品一致） |
| 串口驱动 | **option**（需在 option 驱动 ID 表加 VID/PID） |
| 网口驱动 | 通用 **RNDIS** 驱动 |
| 设备识别 | 被测软件通过 **UEvent** 识别设备 |

### 1.3 宿主环境体检（WSL2, Ryzen 9 5950X / 30 核 / 54GB）
| 检查项 | 结果 | 结论 |
|---|---|---|
| CPU / 内存 | 30 逻辑核，54GB RAM | TCG 模拟 ARM64 资源充足 |
| 嵌套 KVM | ❌ 无 `/dev/kvm`，未暴露 svm 标志 | 纯软件模拟（TCG），无实质影响 |
| WSL2 内核 6.6.87 | ✅ `USBIP_HOST=m`、`USBIP_VHCI_HCD=m` | USBIP 中转备用路线内核态现成 |
| WSL2 内核 6.6.87 | ❌ `CONFIG_USB_GADGET is not set`（无 dummy_hcd / configfs gadget / UDC） | **G 路线需自定义 WSL2 内核**（成熟做法，30-60min） |
| 已装工具 | Docker ✅；QEMU / usbip / usbredir ❌ | 需安装基础件 |

---

## 2. 结论速览（TL;DR）

1. **CPU/系统层**：QEMU `qemu-system-aarch64` + TCG（MTTCG），唯一同时满足"系统级完整 + 无 KVM + 容器可移植"的方案。性能预期原生 1/5~1/15，功能/集成验证够用。
2. **USB 层：基线 = 路线 G（configfs gadget）**——目标设备画像（复合拓扑 + 定制 VID/PID + option + RNDIS）只有 G 能覆盖；U（QEMU 内置 usb-serial/usb-net）降级为 AT 引擎的降级冒烟模式；C（自写 QEMU 设备模型）为容器完全受限时的远期兜底。
3. **AT/网络仿真**：自研 AT 场景引擎（参考开源 AT-Emulator），G 模式下承载于 functionfs 批量端点；运营商状态机 + 控制 API 支撑场景注入。
4. **AI 自闭环**：无头 QEMU + 全 socket 化 + savevm/loadvm 秒级复位 + pytest + 场景引擎控制 API，统一容器化。

---

## 3. 目标设备画像 → 路线 G 精确映射

| 需求 | G 路线实现 | 说明 |
|---|---|---|
| 单 USB 设备枚举串口+网口 | configfs 复合设备：一个 configuration 挂 `ffs.0` + `f_rndis.0` | 客户机枚举为一个设备多 interface，与真机一致 |
| 定制 VID/PID | configfs `idVendor`/`idProduct` 任意设置 | 可直接使用产品真实 ID |
| 串口 = option 驱动 | **functionfs（ffs）** 定义 0xFF vendor-specific 接口 + 批量端点 | option 只认 0xFF 类接口 + VID/PID 表；f_acm 出 cdc_acm 不符合，必须 ffs |
| option 加 VID/PID | 客户机运行时 `echo "VID PID" > /sys/bus/usb-serial/drivers/option/new_id` | 免重编内核，等价于产品内改 `option.c`；嵌入式阶段换自带内核后编译期内置 |
| 网口 = 通用 RNDIS | configfs **`f_rndis`** → 客户机 `rndis_host` | rndis_host 按接口类（0xEF/0x02/0x01）通用绑定，不依赖 VID/PID |
| UEvent 识别 | 经 QEMU `usb-host` 注入的是真实 USB 设备，客户机内核完整枚举 | uevent 序列：USB 设备(带定制 VID/PID) → ttyUSB0 → rndis0 网卡，与真机一致 |

工程要点：
- **ffs 守护进程**是 G 路线主要新开发件：打开 `/dev/ffs-at0` → 写接口/端点描述符 → 在批量端点收发 AT 流。内核源码有现成示例；AT 引擎业务逻辑与传输底座分离，可复用。
- **时序**：先在客户机加载 option 并写 new_id（cloud-init 保证），再注入设备，ttyUSB uevent 才即时出现。
- **RNDIS 数据面**：宿主侧 dummy_hcd 总线上出现对应 rndis 网口 → dnsmasq(DHCP) + NAT 真实联网；`tc netem` 作用其上注入弱网。

---

## 4. 总体架构

```
┌────────────────────────── x64 宿主（WSL2 / CI / 容器，均无 KVM 要求）──────────────────────────┐
│                                                                                              │
│  ┌─────────────── 场景引擎 / AT 守护进程（Python，纯用户态）────────────────┐                  │
│  │  运营商状态机（无SIM/搜网/注册/数据附着/断网）  AT 应答  URC 注入           │                  │
│  │  控制 API（unix socket JSON-RPC）                                        │                  │
│  │  传输后端双模： ① ffs 批量端点（G 路线，保真）  ② chardev socket（U 冒烟）   │                  │
│  └──────▲──────────────────────────────────────────────────▲──────────────┘                  │
│         │ /dev/ffs-at0                                      │                                 │
│  ┌──────┴──── configfs 复合 gadget（dummy_hcd UDC "dummy.0"）───────┐                         │
│  │   ffs.0  → 0xFF 接口×N（AT 串口）   f_rndis.0 → RNDIS 网卡         │                         │
│  │   idVendor/idProduct = 产品定制值                                  │                         │
│  └──────▲──────────────────────────────────────────────────────────┘                         │
│         │ USB 总线（宿主侧为一根"真实"USB 设备）                                               │
│  ┌──────┴──── QEMU usb-host (libusb) ───────────────────────────────┐                         │
│  │  qemu-system-aarch64 -M virt -cpu max -accel tcg,thread=multi     │                         │
│  │  -device qemu-xhci -device usb-host,vendorid=…,productid=…        │                         │
│  └──────▲──────────────────────────────────────────────────────────┘                         │
│         │ 客户机：ARM64 Linux（可插拔镜像）                                                     │
│  ┌──────┴───────────────────────────────────────────────────────────┐                        │
│  │  guest 内核：option(+new_id)→ttyUSB0；rndis_host→rndis0            │                        │
│  │  被测软件：UEvent 识别设备 → AT 交互 → RNDIS 数据面(DHCP→NAT 上网)    │                        │
│  └──────────────────────────────────────────────────────────────────┘                        │
│                                                                                              │
│  自动化层：CLI(envctl up/snap/reset/test) · QMP · savevm/loadvm · pytest · cloud-init           │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

三层解耦：**客户机层**（镜像可插拔）、**USB 仿真层**（G 基线 / U 冒烟 / C 远期）、**场景·自动化层**（稳定控制 API）。

---

## 5. USB 仿真路线对比与选择

| 维度 | G：configfs gadget（**基线**） | U：QEMU 内置设备（降级冒烟） | C：QEMU 设备模型（远期兜底） |
|---|---|---|---|
| 复合拓扑（单设备串口+网口） | ✅ | ❌ 两个独立设备 | ✅ |
| 定制 VID/PID | ✅ 任意 | ❌ 基本锁死 FTDI/QEMU | ✅ |
| option 驱动串口（0xFF 接口） | ✅ ffs | ❌ 只有 FTDI 类 | ✅ |
| RNDIS | ✅ f_rndis | ❌（usb-net 是 CDC ECM） | ✅ |
| UEvent 身份一致 | ✅ 真实 USB 设备枚举 | ⚠️ 身份不符 | ✅ |
| 内核依赖 | 宿主需 GADGET+DUMMY_HCD+CONFIGFS+F_FS+F_RNDIS | 无 | 无 |
| 特权要求 | 需加载模块/configfs（特权容器或宿主直跑） | 无 | 无 |
| 容器/CI 可移植性 | ★★★（取决于宿主内核） | ★★★★★ | ★★★★★ |
| 保真度 | ★★★★ | ★★ | ★★★★★ |
| 开发量 | 中（gadget 脚本 + ffs 守护进程） | 零 | 大（C，1-2k 行） |

### 路线 C 重估与设计草图（v3.2，升级为推荐路径）

**重估依据**：原"C 开发量大、私有分发难"的两条理由在当前画像下不成立——① 形态二本就需自建 QEMU 8/9，设备模型搭在已有构建流水线上是边际成本；② QEMU 现有设备模型已覆盖难点：`hw/usb/dev-network.c` 内置 RNDIS（`-device usb-net,rndis=on`），option 式串口接口只是无协议 bulk 管道（比 FTDI 更简单）；③ 实际新增逻辑估 600-1200 行（大半改编自现有模型），AI 辅助开发估 3-5 天到"枚举+AT+DHCP"全通。

**设计草图**（新设备 `usb-wmodem`，命名待定）：

```
hw/usb/dev-wmodem.c  (新设备模型, 复合设备)
├─ 描述符: 定制 idVendor/idProduct/iManufacturer/iSerial (属性可配)
│          复合配置 = N×(0xFF vendor-specific 接口, bulk IN/OUT)  +  RNDIS 接口组(含 IAD)
├─ 串口×N: bulk ↔ chardev 后端（AT 口接 AT 场景引擎; 预留 diag/nmea 口）
│          └── 改编自 dev-serial.c 的端点处理, 去掉 FTDI 协议（option 口无协议）
├─ 网口:   RNDIS 状态机 + bulk 数据面 ── 改编自 dev-network.c (rndis=on 路径) ── netdev 后端
└─ guest:  option(+new_id)→ttyUSB0/ttyUSB1…  +  rndis_host→rndis0；UEvent 正常
```

**四级验收阶梯**：`lsusb` 枚举出定制 VID/PID 复合设备 → `dmesg` 中 option/rndis_host 绑定出 ttyUSB0+rndis0 → AT 引擎经 chardev 应答 AT → rndis0 DHCP 上网。

**相对形态三的优势**：单进程单 VM（无第二 QEMU、无 TCP 中跳）；设备状态全在进程内 → savevm/loadvm 零外部状态问题；保真天花板最高（串口数/布局/QMI 均可在同框架扩展）；所有环境零内核零特权。
**真实代价**：一次性开发期（AI 辅助 3-5 天）+ QEMU 版本锁定（升级需重新适配，设备模型 API 多年稳定）。
**风险对冲**：若 C 开发受阻，形态三（零 C 代码）可随时顶上，上层（AT 引擎/场景库/pytest）完全共用。

**选择逻辑（v3.2 更新）**：
- **C 升级为 P1 首选**：单进程、全环境零依赖、保真最高、契合团队 C 能力与 AI 开发目标。
- G（configfs gadget）转为备选：适用于"希望用现成组件、当天可用、且环境内核可控"的场景（含形态一/二）。
- U 保留为 AT 引擎冒烟模式；形态三（appliance VM）为 C 受阻时的对冲。

---

## 6. 部署形态适配

### 形态一：WSL2 开发机（当前环境）

#### 方案 A（推荐）：自定义 WSL2 内核，开启 gadget
1. `git clone microsoft/WSL2-Linux-Kernel`，切匹配 `uname -r` 的 `linux-msft-wsl-6.6.y`。
2. 基于 `Microsoft/config-wsl` 开启（建议 =y，WSL2 无 /lib/modules 惯例）：
   `CONFIG_USB_GADGET`、`CONFIG_USB_CONFIGFS`、`CONFIG_USB_F_FS`、`CONFIG_USB_F_RNDIS`、`CONFIG_USB_DUMMY_HCD`
3. `make -j$(nproc)` → `bzImage` → `.wslconfig` 中 `kernel=C:\...\bzImage` → `wsl --shutdown`。
4. `modprobe dummy_hcd && mount configfs` → `/sys/kernel/config/usb_gadget` 组装复合设备 → 绑定 `dummy.0` → QEMU `usb-host` 抓取。

#### 方案 B（免内核重编译）：USBIP 中转
极小 x86 TCG "USB appliance" VM（Alpine/Debian，内核自带 dummy_hcd + usbip-host，负载极轻）：
```
appliance VM(内跑复合 gadget) ──usbip(TCP)──► WSL2: modprobe vhci_hcd(已有) + usbip attach
                                            ──► 设备上 WSL2 USB 总线 ──► QEMU usb-host 抓取
```
内核组件当前 WSL2 均已具备；代价是多一层 VM 与一次转发（该负载轻，性能无虞）。**同样适合 CI 宿主缺 dummy_hcd 时的兜底。**

### 形态三：完全无内核改动（USB appliance VM + usb-redir）

适用：WSL2 不允许换自定义内核，或服务器容器形态无法协调宿主装模块。

**原理**：usb-redir 是纯用户态 TCP 协议——QEMU 侧不需要任何内核模块/特权。"内核需支持 gadget"被隔离进一个自带内核的微型 x86 TCG appliance VM：

```
┌ WSL2 / 服务器容器（零内核改动、零特权）──────────────────────┐
│  ┌ appliance VM (x86 TCG, Alpine/Debian mini, 自带内核) ──┐  │
│  │  dummy_hcd + ffs/f_rndis 复合 gadget（定制 VID/PID）     │  │
│  │  ffs AT 引擎 + dnsmasq/NAT/netem                        │  │
│  │  usbredirserver ──hostfwd──► 宿主 127.0.0.1:3990        │  │
│  └────────────────────────┬────────────────────────────────┘  │
│                           │ usb-redir TCP                     │
│  ┌ ARM64 VM (QEMU TCG) ───┴────────────────────────────────┐  │
│  │  -device usb-redir,chardev=host=127.0.0.1,port=3990     │  │
│  │  guest: option(+new_id)→ttyUSB0 + rndis_host→rndis0     │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

- appliance VM 负载极轻（gadget 转发 + AT 文本流），TCG 足够；两个 VM 是宿主上并列进程，无嵌套。
- 设备画像完整保留：复合拓扑 / 定制 VID/PID / option / RNDIS / UEvent 全部不变，仅"USB 服务所在地"变化。
- 附带收益：形态二不再依赖宿主管员装 modules-extra；全方案内核依赖收敛进自有镜像，可移植性最强。
- 对比备选：USBIP 链（appliance VM usbip 导出 → WSL2 现成 `vhci_hcd` 接收 → usb-host）也可行且内核模块原生齐备，但需 usbip 用户态工具且链路更长，usb-redir 更干净。

### 通用三级探测策略（CI / 服务器容器共用）
1. 宿主内核有 dummy_hcd（Ubuntu 装 `linux-modules-extra` 即有；privileged 容器挂载 /lib/modules 可用）→ 直跑 G；
2. 无 → **USB appliance VM（usb-redir，形态三，首选）/ USBIP appliance（备选）**；
3. 容器完全受限且必须全保真 → 评估 C。

### 形态二：Ubuntu 20.04 容器（AMD 服务器）

**关键认知**：容器只隔离用户态，**内核是物理宿主的**——Ubuntu 20.04 用户态（Python 3.8/dnsmasq/iptables）不影响方案；G 路线可行性取决于物理宿主内核（版本/模块/容器特权）。AMD EPYC 对方案零影响（x86_64 + TCG，核多利于并行多实例）。

**四项调整**：

| # | 调整 | 原因 |
|---|---|---|
| 1 | 注入方式：`usb-host` 直连 → **`usb-redir` over TCP** | gadget 在物理宿主 dummy_hcd 总线上，容器内 QEMU 摸不到 /dev/bus/usb；宿主侧 `usbredirserver` 导出 TCP，QEMU 经 `-device usb-redir` 连入，**QEMU 容器保持零特权** |
| 2 | gadget 服务 / AT 引擎 / 数据面上移物理宿主 | modprobe/configfs 依赖宿主内核；RNDIS"运营商侧"网口（f_rndis gadget 侧 usb0）+ dnsmasq + NAT + netem 均随 gadget 走；AT 控制 API 改 TCP socket |
| 3 | **QEMU 自建 8.x/9.x** 固化进 OCI 镜像 | Ubuntu 20.04 源内 QEMU 4.2（2019）过老；20.04 构建依赖可满足 |
| 4 | 物理宿主前置检查（一次性） | 见下表 |

**物理宿主前置检查清单**：

| 检查项 | 命令 | 期望 |
|---|---|---|
| 宿主内核版本 | `uname -r` | ≥5.4 |
| dummy_hcd 模块 | `find /lib/modules/$(uname -r) -name 'dummy_hcd*'` | 存在（缺则宿主装 `linux-modules-extra-$(uname -r)`） |
| ffs/rndis gadget 模块 | `grep -E 'CONFIG_USB_F_FS\|CONFIG_USB_F_RNDIS' /boot/config-$(uname -r)` | =m/y |
| 容器特权 | 容器内 `capsh --print` | 含 `sys_admin`（modprobe/mount configfs 用） |
| 模块挂载 | 容器内 `ls /lib/modules/$(uname -r)` | 启动加 `-v /lib/modules:/lib/modules:ro` |
| 网络连通 | 容器 → 宿主 TCP | usbredir / 控制 API 端口放行 |

**两种容器拓扑**：

```
拓扑 2a（推荐，QEMU 容器零特权）                      拓扑 2b（单特权容器，备选）
┌─ Ubuntu 物理宿主 (EPYC) ─────────┐                ┌─ privileged 容器 ───────────┐
│  configfs gadget(ffs+rndis)      │  usbredir TCP  │  /lib/modules + /dev/bus/usb │
│  ffs AT 引擎 + dnsmasq/NAT/netem │◄──────────────►│  gadget + QEMU 同容器        │
│  usbredirserver :4000            │                │  usb-host 直连               │
└──────────────▲───────────────────┘                └─────────────────────────────┘
               │
┌─ Ubuntu 20.04 容器（无特权）─────┐
│  QEMU 8/9 (TCG, usb-redir)      │
│  ARM64 guest + 被测软件 + pytest │
└─────────────────────────────────┘
```

数据通路（拓扑 2a）：guest rndis0 → USB → usbredir → 宿主 gadget 侧 usb0 → dnsmasq/NAT → 互联网；AT 流：guest ttyUSB0 → USB → 宿主 ffs 守护进程。

若物理宿主无法满足模块条件：按三级探测降级；长期兜底 C。WSL2 的自定义内核步骤在本形态完全不适用，**架构三层与 G 路线实现不变，仅"注入方式 + 服务位置"变化**。

---

## 7. AT 引擎与数据面

### 7.1 AT 场景引擎（自研核心件，~300-500 行 Python + ffs 守护）
- 传输后端双模：G 模式 = ffs 批量端点；冒烟模式 = chardev socket。协议内核复用。
- 应答集覆盖标准命令（`AT/ATE/ATI/AT+CPIN?/AT+CSQ/AT+CREG?/AT+CEREG?/AT+CGATT/AT+CGDCONT/AT+CGACT/ATD/…`）+ 厂商私有 AT 可扩展。
- **运营商状态机**：`NO_SIM → SEARCHING → REGISTERED(no data) → ATTACHED(data) → DETACHED/OUT_OF_SERVICE`，切换自动发 URC（`+CEREG`、`+CGEV`…）。
- **控制 API**（unix socket JSON-RPC）：`set_signal/remove_sim/drop_network/inject_urc/set_error_rate/...`，供测试与 AI 调用。
- 参考：[celersms/AT-Emulator]。

### 7.2 数据面
| 项 | 实现 |
|---|---|
| 真实联网 | 宿主侧 rndis 网口 → dnsmasq(DHCP) + iptables NAT → WSL2 eth0 |
| 弱网/断网 | AT 层状态机（业务视角主注入点）+ 宿主侧 `tc netem` 作用于 rndis 口（链路视角）|
| 丢包/限速（netem 不可用时） | guest 内 `tc netem` 或用户态 proxy |

---

## 8. 客户机层演进

1. **现阶段**：Debian `genericcloud` arm64 / Ubuntu cloud image，`-M virt` + UEFI 直启；cloud-init 自动装载 option 模块 + 写 new_id、装被测软件、SSH。发行版内核自带 `option/rndis_host`。
2. **嵌入式定制**：Yocto/Buildroot 产物（Image + rootfs + 自定内核）直接喂 QEMU（`-kernel`/`-drive`）；确认内核 config 含 `USB_SERIAL_OPTION`、`USB_NET_RNDIS_HOST`、`USB_XHCI_HCD`。
3. **Android（远期决策点）**：无 KVM 下 arm64 cuttlefish+TCG 极慢；届时评估 cuttlefish-TCG 可忍受度或为 Android 阶段单独配 ARM64 实机；x86_64 镜像 ABI 不符。本架构保留客户机可插拔接口，不提前投入。

---

## 9. AI 自闭环设计

| 能力 | 实现 |
|---|---|
| 无头运行 | `-nographic`；console → unix socket；SSH hostfwd |
| 秒级复位 | golden `savevm` → 每轮 `loadvm`；**顺序：先 loadvm，后 QMP `device_add` 热插 USB**（规避 usb-host 外部设备状态问题） |
| 程序化控制 | QMP socket；场景引擎控制 API；可选 guest agent |
| 测试即代码 | pytest + pexpect：拉起 → 复位 → 注入设备 → 执行 → 断言（uevent 序列 / AT 流程 / rndis 连通 / 日志） |
| 双速开发环 | 快层：binfmt qemu-aarch64-static 跑单测（秒级）；慢层：全系统 VM（分钟级） |
| 可移植打包 | 单一 OCI 镜像：QEMU + 镜像 + gadget 脚本 + 场景引擎 + 测试套件；环境探测自动选 G/U |
| CI 兼容 | 无 KVM（TCG）、按 §6 三级探测决定 G/U |

---

## 10. 路线图

| 阶段 | 内容 | 验收标准 | 预估 |
|---|---|---|---|
| **P0 冒烟** ✅ 已完成（2026-11-08，WSL2，Ubuntu arm64，见附录 A） | 装 QEMU；arm64 无头跑通；cloud-init；savevm/loadvm | 冷启可用，快照复位秒级，SSH 可达 | 0.5-1d |
| **P1 gadget 服务 + 复合设备** | 形态一：WSL2 自定义内核（GADGET/CONFIGFS/F_FS/F_RNDIS/DUMMY_HCD）+ usb-host 注入；形态二：宿主 modules-extra + gadget 服务 + usbredirserver + 容器内 QEMU(usb-redir)。共同：configfs 组装 ffs+f_rndis 复合设备（定制 VID/PID）；guest option+new_id → ttyUSB0 | guest 内 `lsusb` 出定制 VID/PID；uevent 序列正确；AT 引擎经 ffs 收发 | 1.5-2d |
| **P2 RNDIS 数据面** | f_rndis 宿主侧 dnsmasq+NAT；rndis0 DHCP 上网；断网/弱网注入 v1 | guest 经 rndis0 真实联网；drop_network 场景生效 | 1-1.5d |
| **P3 AI 闭环** | envctl CLI + pytest 套件 + 场景库（正常/断网/弱网/无SIM）+ OCI 镜像 + CI 三级探测 | 一条命令完整回归出报告；CI（无 KVM）绿 | 2-3d |
| **P4 可选增强** | raw-gadget 描述符复刻；多串口（ffs.1/2…）；QMI/MBIM 评估；Android 决策 | 按需 | 按需 |

---

## 11. 风险与限制

| 风险 | 影响 | 对策 |
|---|---|---|
| TCG 性能（1/5~1/15 原生） | 长用例耗时 | MTTCG + 多实例并行；性能测试留真机 |
| WSL2 无 gadget 内核支持 | G 路线前置条件 | 方案 A 自定义内核（一次性）；方案 B USBIP 兜底 |
| 发行版 dummy_hcd 不一（Ubuntu modules-extra 多有；Debian 部分缺） | CI 上 G 不可用 | §6 三级探测；自动降级 U 冒烟并标注 |
| 容器 /lib/modules 与宿主内核版本不匹配 | modprobe 失败 | 挂载宿主 `/lib/modules:ro`；宿主装 modules-extra |
| Ubuntu 20.04 源 QEMU 4.2 过老（2019） | 新客户机镜像/机型兼容风险 | 镜像构建期自建 QEMU 8/9 固化进 OCI 镜像 |
| loadvm 与 usb-host 外部状态 | 快照恢复异常 | 先 loadvm 后 device_add 热插 |
| ffs 守护进程是新代码 | 初期稳定性 | 内核示例起步；AT 业务与传输层分离便于复用/回退 |
| QMI/MBIM 未覆盖 | 若软件改走 QMI 拨号 | P4 评估 ffs/raw-gadget 或 C |
| Android 无 KVM | 安卓阶段可行性 | 架构预留；届时单独决策 |
| 模仿产品 VID/PID | 仅内部测试环境使用，注意隔离 | 用 product 真实 ID 但限定测试网段/环境 |
| uevent 时序 | 先枚举后写 new_id 会导致 ttyUSB 延迟出现 | cloud-init 固化顺序：载模块→写 new_id→注入设备 |

---

## 12. 参考资料

- [QEMU USB 仿真官方文档](https://qemu-project.gitlab.io/qemu/system/devices/usb.html)
- [Linux 内核 configfs gadget 文档](https://docs.kernel.org/usb/gadget_configfs.html) · [gadget-testing（各 function 用法）](https://docs.kernel.org/usb/gadget-testing.html) · [Collabora: Modern USB gadget](https://www.collabora.com/news-and-blog/blog/2019/02/18/modern-usb-gadget-on-linux-and-how-to-integrate-it-with-systemd-part-1) · [Collabora: Using dummy_hcd](https://www.collabora.com/news-and-blog/blog/2019/06/24/using-dummy-hcd)
- [WSL2 自定义内核构建指南（2026）](https://www.boxofcables.dev/build-a-custom-wsl-2-kernel-in-2026) · [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
- [raw-gadget + dummy_hcd](https://github.com/xairy/raw-gadget/blob/master/dummy_hcd/README.md)
- [celersms/AT-Emulator](https://github.com/celersms/AT-Emulator)
- [kernelconfig.io: CONFIG_USB_DUMMY_HCD 发行版开关情况](https://www.kernelconfig.io/CONFIG_USB_DUMMY_HCD)

---

## 附录 A：P0 冒烟验证记录（WSL2，2026-11-08）

**形态**：QEMU 全部运行在 `p0-qemu` 容器内（Ubuntu 24.04 基础镜像 + qemu-system-arm 8.2.2 + qemu-efi-aarch64），QEMU 为分离容器的前台进程；客户机为 Ubuntu 24.04 (noble) arm64 cloud image，golden + overlay 模式；4 vCPU TCG / 2GB RAM / slirp 用户网络（hostfwd 2222→22）；cloud-init NoCloud seed 注入用户与密钥。产物在 `p0/`（scripts/01~05 + qmp_savevm.py + Dockerfile）。

**验收结果**：

| 项 | 结果 | 实测 |
|---|---|---|
| 冷启动到 SSH 可达 | ✅ | 291~366s（4 vCPU TCG，首次 boot 约 5min） |
| SSH 连通 | ✅ | `SSH_OK from arm64-p0 aarch64` |
| savevm（QMP snapshot-save） | ✅ | 1.0~1.7s |
| 停机→loadvm→SSH 可达 | ✅ | 全程 ~6s wall |
| 状态还原断言 | ✅ | 快照前标记文件还原；uptime 从快照点继续（非冷启动） |

**关键踩坑与对策（已固化到脚本）**：

| 坑 | 现象 | 对策 |
|---|---|---|
| 容器内 daemonize | QEMU 随容器主进程退出被杀 | QEMU 作为分离容器的前台进程（exec），容器存活=VM 存活 |
| pflash 不支持内部快照 | HMP `savevm` 报 `Device 'pflash1' is writable but does not support snapshots`；CLI `-loadvm` 同样拒绝启动 | 测试 VM 改用 `-bios` 直载固件（无 pflash 设备）；若需持久 UEFI 变量，用 QMP `snapshot-save` 指定设备列表做快照 |
| virtio 网卡 ROM 缺失 | `failed to find romfile "efi-virtio.rom"` | `-device virtio-net-pci,...,romfile=` 禁用（UEFI 网络启动用不到） |
| pflash 尺寸 | `-M virt` 的 pflash 要求精确 64MB，QEMU_EFI.fd 只有 2MB | （已随 -bios 方案消除；若回退 pflash 方案需填充） |
| overlay backing 路径 | qemu-img 的 `-b` 相对 overlay 自身目录解析 | backing 用容器内绝对路径 `/work/...` |
| HMP 错误静默 | human-monitor-command 的错误在 return 字符串里，非 error 键 | QMP 客户端检查 return 内容 + job 的 error 字段；savevm 前 delvm 同名 tag |

**对方案的修正认知**：
- 快照复位原语确定采用：**QMP `snapshot-save`（写）+ CLI `-loadvm`（读）+ `-bios`（免 pflash）**；`savevm/loadvm` 与 golden+overlay 双复位机制均可用（后者重建 overlay 即得全新实例）。
- WSL2 的 Ubuntu 24.04 源内 QEMU 8.2 即满足需求；"Ubuntu 20.04 容器需自建 QEMU 8/9"的结论不变，P0 脚本可直接复用。
- 性能预估修正：冷启动 ~5min（比预估 2min 长，TCG 下 cloud-init 阶段占比大）——AI 闭环里冷启动仅用于首次置备，常规迭代全靠 loadvm 复位（~6s），符合设计预期。

---

## 附录 B：P1 路线 C 骨架 PoC 记录（WSL2，2026-11-08）

**内容**：自建 QEMU 9.2.0（容器内源码编译，aarch64-softmmu），新增 `usb-wmodem` 设备模型（~330 行，基于 dev-serial.c 改编：定制 VID/PID + option 式 0xff bulk 串口 + chardev 后端），接入 P0 的 ARM64 Ubuntu VM 完成四级验收。

**验收结果（POC_ALL_GREEN，6/6）**：

| 级别 | 结果 | 证据 |
|---|---|---|
| ① 定制 VID/PID 枚举 | ✅ | guest sysfs: `1234:5678 1-1` |
| ② option 驱动绑定 → ttyUSB0 | ✅ | `crw-r--r-- 188,0 /dev/ttyUSB0`，接口驱动=option |
| ③ AT 引擎经 chardev 收到 AT | ✅ | `[RX] b'ATI\r'`、`[RX] b'AT+CSQ\r'` |
| ④ 应答经 USB 回到 guest | ✅ | `ATI`→`WModem PoC 1.0 + OK`；`AT+CSQ`→`+CSQ: 18,99 + OK` |

**关键发现（已固化到脚本/文档）**：

| # | 发现 | 对策 |
|---|---|---|
| 1 | **usbtouchscreen 驱动按"接口类 0xff"整类抢占**定制 VID/PID 设备（开机枚举即绑定，option 后到绑不上）——真实模块厂商靠内核忽略清单豁免 | guest 置备时 `unbind usbtouchscreen` → 再 option `new_id`；长期方案：产品 VID 提交上游忽略清单，或置备脚本固化为 cloud-init runcmd |
| 2 | bash 重定向（`<>`/`>`）在设备节点缺失时会**创建同名普通文件**遮蔽设备节点，读写全部落到文件（大坑，症状是"驱动正常但无任何 USB 流量"） | 脚本检查 `[ -c /dev/ttyUSB0 ]`，异常时 `rm` + `mknod c 188 0` |
| 3 | 新内核 option 驱动 sysfs 目录名为 **`option1`**（非 `option`） | 脚本做 `option1`/`option` 兼容回退 |
| 4 | chardev 无对端时 `qemu_chr_fe_write_all` 返回 -1、数据丢弃（符合"模块在但无人应答"语义） | AT 引擎/应答器需先于测试常连；设备侧可加"无对端缓存"策略（后续优化） |
| 5 | guest tty 回显与杂散字节会**粘包污染** AT 行（"WMoAT+CSQ"） | guest `stty -echo raw`；AT 引擎行内定位 `AT`（真实 modem 同款容错） |

**工作量实绩**：设备模型一次编译通过；主要调试耗在发现 #1/#2（驱动抢占与文件遮蔽的症状都伪装成"设备正常但数据不通"）。**证实了 v3.2 的判断：AI 辅助下路线 C 完全可行，且单进程、零内核依赖、全环境可移植的优势成立。**

**工件**：`p1/`（docker/Dockerfile.build、device/dev-wmodem.c、scripts/10~24：接入/编译/启动/等待/应答器/验收）、自定义 QEMU 二进制（build/qemu-9.2.0/build/qemu-system-aarch64）。

**下一步（P1 续）**：① 复合设备扩展——追加 RNDIS 接口（改编 dev-network.c，`rndis=on` 路径）+ 多串口（ffs 式多接口，diag/nmea 预留）；② 数据面：RNDIS → netdev → slirp NAT 联网；③ 把解绑 usbtouchscreen + new_id 固化进 cloud-init；④ savevm/loadvm 与 usb-wmodem 的快照兼容验证（vmstate 已实现，待实测）。

---

## 附录 C：P1续 验证记录（WSL2，2026-11-08）

**完成内容**：usb-wmodem 升级为复合设备 v2（约 1000 行 C）：接口 0/1/2 = option 式串口（AT/diag/nmea，in00/01/02），接口 3/4 = RNDIS（控制 0xEF/0x04/0x01 + 数据 0x0A，in03/04），数据面接 netdev → slirp NAT；置备自动化脚本（幂等）；快照兼容验证。

**最终验收（P1_ALL_GREEN 15/15 + SNAPSHOT_ALL_GREEN 6/6）**：

| 项 | 结果 | 证据 |
|---|---|---|
| 定制 VID/PID 复合枚举 | ✅ | `1234:5678 1-1` |
| **in 字段（软件识别依据）** | ✅ 5/5 | in00/02=`icFF`（串口）、in03=`icEFisc04ip01`（RNDIS 控制）、in04=`ic0A`（RNDIS 数据） |
| 多串口 ttyUSB0/1/2 + option 绑定 | ✅ | 三个字符设备节点，驱动=option |
| RNDIS 网口 | ✅ | `enx525400123457`（usbnet 命名） |
| **RNDIS 真实 DHCP + 互联网** | ✅ | DHCP 获 10.0.2.15 → HTTP 200（经 RNDIS 口） |
| savevm/loadvm × USB 设备 | ✅ | savevm 1.3-1.5s、loadvm 8s、标记/串口/绑定/**AT 会话**全部恢复 |

**本轮关键发现（比附录 B 更深一层）**：

| # | 发现 | 对策（已固化） |
|---|---|---|
| 1 | **usbtouchscreen 抢占范围极宽**：实测认领 0xff、0xEF/0x04/0x01、0x0A 全部接口（远超"0xff 整类"） | 置备改为 `blacklist + rmmod usbtouchscreen`——黑名单阻断 modalias 自动加载，比逐接口解绑稳 |
| 2 | **rndis_host 的 0xEF 通用匹配是 0xEF/0x04/0x01**（非 0x02）——各发行版以 `modules.alias` 实际内容为准 | 设备描述符按 0xEF/0x04/0x01 设计；换内核时先查 alias |
| 3 | **option 的 new_id 是设备级匹配**（动态 ID 不做接口类检查）→ 会连 RNDIS 接口一起认领 | 绑定顺序控制：先 rndis_host 后 option，中间用 authorized=0/1 重新枚举 |
| 4 | **loadvm × USB 设备：设备 vmsd 必须包含 `VMSTATE_USB_DEVICE`**（USB 核心状态 dev->state 不自动迁移）——缺失则恢复后第一个 USB 包触发 QEMU 断言崩溃 | 已加入 vmstate；自定义 USB 设备做快照的通用必修项 |
| 5 | RNDIS 收包门控：rndis_host 设置 packet filter 后才进入 DATA_INITIALIZED；DHCP 验证需真实 dhclient（noble 云镜像精简无 dhclient，曾造成"假阳性"） | 置备后轮询就绪（60s 上限）；数据面验证用真实 DHCP |
| 6 | **双 slirp 同网段冲突**：n0 与 wnet 都是 10.0.2.0/24 → guest 双接口重复 IP 10.0.2.15 → ARP/路由互相污染（neighbor FAILED、出站 EHOSTUNREACH） | wnet 独立网段 `net=10.0.3.0/24,dhcpstart=10.0.3.15` |
| 7 | **authorized 重枚举未完成时写 new_id 会丢失绑定**（TCG 下重枚举 >10s）；多 AT 通道使用方（responder/引擎）互相挤占 QEMU chardev 单客户端 | 置备先等 `1-1:1.4` 回归再写 new_id，就绪轮询内重试；各验收脚本开头显式杀掉上一位 AT 通道占用者 |

---

## 附录 D：P2 场景引擎记录（WSL2，2026-11-08）

**交付**：`p1/engine/wm_scenario_engine.py`（约 500 行 Python）——虚拟蜂窝模块的"运营商大脑"：

- **运营商状态机**：SIM（absent/ready/pin）× 注册（none/searching/denied/home/roaming）× 数据附着（attached/detached）× 飞行模式四轴，状态切换自动发 URC（+CEREG / +CGEV，按 AT+CEREG/AT+CGEREP 订阅生效）
- **AT 命令服务**：TS 27.007 子集（CPIN/CSQ/CESQ/CREG/CEREG/CGREG/COPS/CGATT/CGDCONT/CGACT/CGPADDR/CFUN/CGMI/CGMM/CGMR/CGSN/CIMI/ATE/ATI）+ 厂商扩展 AT+WMSTAT；SIM 缺失时按规范返回 +CME ERROR: 10
- **场景控制 API**（unix socket，行 JSON）：`scenario(normal/no_sim/searching/denied/detached/offline)`、`set_signal`、`inject_urc`、`set_link`、`set_delay`、`status`
- **数据面真联动**：detached/offline 场景经 QMP `set_link wnet off` 真断链路（不只改 AT 状态）；弱网经 QEMU `filter-buffer`（interval 定时冲刷）运行时注入延迟
- **配套**：`engine_ctl.py`（控制 CLI）、`at_client.py`（guest 侧 AT 客户端，cmd/monitor 两模式）、`27_scenario_check.sh`（7 步验收）

**验收场景**：normal 注册态 → 拔卡（CME ERROR:10 + URC +CEREG:0 + 引擎状态）→ 恢复 → detached（CGATT:0 + URC +CGEV: ME DETACH + QMP 真断链路 + HTTP 不可达）→ 恢复 + 弱网注入（filter-buffer 500ms：基线 0.071s → 弱网 1.86s → 清除回落 0.071s）→ 信号注入（set_signal→CSQ 联动）。**最终 P2_ALL_GREEN 22/22。**

**本阶段新增经验（续）**：
5. **QEMU 无 `filter-delay` 对象**（只有 filter-buffer/mirror/replay/rewriter）——弱网延迟用 `filter-buffer,interval=<µs>` 定时冲刷等效实现；写方案时的"记忆组件"必须对照源码树实测
6. 控制面与数据面的断网要分层验证：`set_link off` 只影响指定 netdev——**默认路由必须真正指向被测接口**（curl --interface + 指向该网段网关的 default 路由），否则连通性断言全是假阳性

**本阶段新增经验**：
1. 双 slirp 同网段导致 guest 双接口 IP 冲突（见上表 #6）——多网卡虚拟机各 netdev 必须独立网段
2. guest 侧并发读 tty 会互抢数据（URC 监听 vs 命令应答）——URC 捕获用限时监听窗口，与命令收发分时
3. QEMU chardev socket 单客户端：responder 与引擎切换时必须先杀后连（各脚本入口统一处理）
4. 场景引擎的 QMP 连接采用**按需连接**模式，不长期占用 qmp.sock（快照脚本需要它）

**产物更新**：`p1/device/dev-wmodem.c`（v2 复合设备）、`p1/scripts/25_verify_all.sh`（全量验收：置备+枚举+in字段+多串口+RNDIS联网+AT）、`p1/scripts/26_snapshot_check.sh`（快照兼容全流程）、seed（置备脚本 runcmd 化）。

**里程碑**：虚拟蜂窝模块在 USB 层面已达到**与真机同构的完整形态**——单设备、复合五接口、定制 VID/PID、option+RNDIS 标准驱动、UEvent/MODALIAS in 字段可识别、真实 DHCP 上网、支持秒级快照复位。**P3（AI 闭环：场景引擎 + pytest + CI 容器）的全部前置条件已就绪。**
