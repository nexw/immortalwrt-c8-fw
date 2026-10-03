# RFC-001：NRadio C8（WT9104 / C8-688）整机固件重建 —— 走"原生 OpenWrt 栈"

- 状态：**Draft，待评审**
- 作者：Johnny（+ AI 协作）
- 日期：2026-10-01
- 关联：`docs/refs/device-baseline.md`（实机基线）、`docs/refs/mt7981b-nradio-c8-668gl.immortalwrt.dts`、`docs/refs/platform.filogic.immortalwrt.sh`、`docs/refs/02_network.immortalwrt.sh`、`docs/refs/01_leds.immortalwrt.sh`、`docs/refs/emmc.sh`
- 施工仓库：`nexw/immortalwrt-c8-fw`（2026-10-03 独立建库，不再是对 P3TERX 模板的 fork；构建 workflow 仍源自该模板）

---

## 1. 背景

现机跑的是厂商 `Mwrt @Manper-5.1.0`（immortalwrt-21.02 血统 + MTK SDK 5.4.255 内核 + 私有用户态）。实测问题：

1. **数据面不原生**：5G 模块（TD Tech MT5700M-CN）自己做 NAT+DHCP（`192.168.8.1`），路由器 `eth1` 只是它的下游 DHCP client → **双层 NAT**；模块的 USB NCM 口（`eth2`）自开机 0 字节，完全闲置；拨号依赖厂商脚本 + 模块内部状态。
2. **驱动面不原生**：WiFi 走厂商 `mt_wifi/mtk_warp`，Offload 走 `mtkhnat`，交换机被厂商驱动托管，DHCP/DNS 被塞进私有 netns（`dhns`）。
3. **私有件多且不可控**：`quickstart`、`at-server`（`:8765` 的 AT WebSocket **无鉴权**）、`httpapi`、`timecontrol/webrestriction/weburl/ddnsto/...`、`docker`（vfs 驱动、0 容器）、垃圾静态路由。
4. 好消息：**immortalwrt master / openwrt main 已官方收录本机**（`nradio_c8-668gl`），DTS/分区/刷机逻辑都齐；本机 A/B 双槽 + U-Boot env `boot_system` 天然支持安全回滚。

## 2. 目标 / 非目标

**目标**
- G1 系统层原生化：immortalwrt 主线栈（netifd/uci/LuCI/fw4/dnsmasq/mt76），清掉私有件。
- G2 数据面原生化：5G 数据路径"可控、可观测、单层 NAT（或明确的双层 NAT 且可解释）"。
- G3 保留厂商 U-Boot / GPT / fip / factory / bdinfo / A-B 槽，**不刷引导**，任何时刻可一键回滚。
- G4 出厂身份可保留：`fac_mac`（`FC:83:C6:xx:xx:xx`）、WiFi EEPROM（`factory`）、module IMEI（`bdinfo`）。
- G5 可重复构建：CI 产物可复现（pin commit + git 化补丁）。

**非目标（本期）**
- 不动 U-Boot/fip/GPT 分区表；不追 MT7981 主线 kernel 6.12 的新特性（可作后续 RFC）。
- 不做模块固件升级/降级（TD Tech 固件不在本期范围）。
- 不迁移无关业务（Docker/alist 等按需在 P5 决定）。

## 3. "更原生"的定义：三层阶梯

| 层 | 现状 | 目标态 | 收益 | 风险 |
|---|---|---|---|---|
| **L1 系统层** | 私有 Mwrt + 私有用户态 | immortalwrt master 主线（mt76 + fw4 + dnsmasq + netifd） | 可维护、可升级、行为可预期 | 低（有 A/B 回滚） |
| **L2 驱动层** | `mt_wifi`/`mtkhnat`/厂商 switch | `kmod-mt7915e`(mt76) + DSA(mt7531) + flow-offload | 上游修复、WiFi 稳定、调试工具齐全 | 中（WiFi 校准/吞吐需回归） |
| **L3 数据面** | 模块 NAT + 双层 NAT，USB NCM 闲置 | 见下方 4 选项 | 单层 NAT / 原生 IPv6 / 端口映射可用 | 中~高（依赖模块能力，部分需写操作） |

### L3 数据面 4 个选项

| 选项 | 做法 | 结果 | 风险 | 需要写操作？ |
|---|---|---|---|---|
| **D0** 保持现状拓扑 | 模块继续 NAT，路由器 `eth1` 标准 `proto dhcp`；只做 L1/L2 替换 | 双层 NAT 仍在，但叠加层全清、可观测 | 最低 | 否 |
| **D1** 模块 IP Passthrough / DMZ | 模块侧把 WAN IP/端口直通给路由器 WAN MAC | **单层 NAT**，端口映射/UPnP 可用 | 中：模块侧参数需勘探（`AT+CEUS`/`^TDPCIELANCFG`/`^TDPMCFG` 或模块 Web/协议）；写错需回滚 | 是（需授权） |
| **D2** 走 USB 数据面 | 让模块的 `cdc_ncm`（`eth2`）成为 WAN（标准 usbnet + dhcp） | 数据面回到"标准 USB 网卡"，与板载 GE 解耦 | 中：当前 NCM 无载波/0 流量，需查明模块侧为何不启用（可能与 `AT^SETMODE`/`CEUS` 有关） | 是（需授权） |
| **D3** 切 USB 组合到 ECM/MBIM/QMI | 模块 `bNumConfigurations=2`，尝试切到 ECM/MBIM/QMI，用 `uqmi`/`umbim` 原生拨号 | 最"原生"：路由器自己做 IP/NAT/ND，模块退化为纯 Modem | **高**：TD Tech/UNISOC 平台 QMI 支持未知（现 5 个 `ff/06` 口全是串口，无 QMI 特征）；组合切换失败可能需重插/串口恢复 | 是（需授权） |

**建议路线：D0 先落地（把整机换成原生栈并稳定运行）→ 在同一固件上做 D1/D2 可行性实验 → 通过再切 D1（首推）或 D2/D3。** 理由：D0 零模块风险且立刻消除 90% 的"不优雅"；D1 用最小改动拿到单层 NAT；D3 收益最大但不确定性也最大，不应作为首刷前提。

## 4. 阶段计划

> 约定：**P0 之前不对整机做任何写操作**；所有需要写整机/模块的动作都单独列出并等你逐条批准。

### P0 基线与回滚准备（只读 + 本地备份，0.5 天）
- 固化基线：把 `docs/refs/device-baseline.md` 的采集命令整理成 `scripts/c8-baseline.sh`（只读），CI 与本地都可跑。
- 备份：`u-boot-env`(p2)、`factory`(p3)、`bdinfo`(p4)、`fip`(p5)、A 槽 `kernel/rootfs`(p6/p7) 的头部校验、GPT 表 → 落到本地/私有存储（**只读 dd**）。
- 确认引导语义：A/B 槽切换方式（`fw_setenv boot_system 0/1`）、串口救砖可用性、U-Boot tftp 是否可用。
- 待核实项（见 §9）：`rootfs_data` vs `app_data`、LAN DHCP/DNS 归属（`192.168.66.251` 是谁）、模块数据面物理链路。
- 产出：`docs/refs/rollback-plan.md`（一页纸的回滚 SOP）。

### P1 仓库改造 + 首版产物（不刷机，1~2 天）
见 §5 的文件级清单。产出：GitHub Actions 里 3 个 release 资产（`*-squashfs-sysupgrade.bin`、`*-initramfs-kernel.bin`、manifest），**先不刷**。
验收：
- `openwrt/bin/targets/mediatek/filogic/` 里出现 `nradio_c8-668gl` 产物；
- `sysupgrade.bin` 解包后：`sysupgrade-nradio_c8-668gl/` 含 `CONTROL`/`kernel`(FIT)/`rootfs`(squashfs)；
- DTS 与本机实测 GPIO/分区一致（对照 §6 表）。

### P2 首刷 + 网络可用性（0.5 天，需授权写操作）
- 用厂商 U-Boot 现成的 A/B 机制：**写 B 槽（`kernel_2nd`+`rootfs_2nd`）**（与上游 `platform.sh` 的 `nradio,c8-668gl` 分支一致）→ 保留 A 槽出厂固件作为回滚。
- 先接串口（115200）在场，确认 `sysupgrade` 正常；验收：能起来、能上网（D0 方式）、`lan1-3/eth1` 链路正确、WiFi 双频可连、LED 合理、风扇可控、温度正常。
- 回滚演练：`fw_setenv boot_system` 切回 A 槽，确认能回到出厂固件。

### P3 数据面实验（1~2 天，需逐条授权写操作）
- 在**不重刷固件**的前提下做：
  1. 只读勘探：模块 USB 全套描述符（两个 configuration）、`AT^SETMODE=?/^TDPCIELANCFG=?/CEUS=?` 的能力面、模块侧是否有 passthrough/DMZ 概念；
  2. D2 实验：让 `eth2` 起来（`ip link set eth2 up` + dhcp 探测）看模块是否给 NCM 侧载波与租约；
  3. D1 实验：按勘探结果改模块参数，验证路由器 WAN 是否拿到 `10.6.223.136` 级别地址；
  4. 失败即回滚到 §基线表里记录的模块参数（`SETMODE=4 / TDPCIELANCFG=2 / TDPMCFG=1,0,0,0 / CEUS=0`）。
- 产出：`docs/refs/l3-dataplane-findings.md` + 固化后的最终方案（D1 或 D2 或 D3 或保持 D0）。

### P4 落地与业务迁移（1 天 + 观察期）
- 按 P3 结论固化 WAN 配置（uci 模板进 `files/`）、DNS/DHCP 接管（标准 dnsmasq）、防火墙/fw4、IPv6（原生 PD/RA）、UPnP/端口映射策略。
- 业务：`ttyd`（若要）、`samba4`、`docker`（建议改 `overlay2`，或明确不用）、5G 状态监控（只读轮询 TCP 20249 的 AT，脚本化，不装厂商私有件）。
- 安全收口：删掉无鉴权 AT WebSocket；SSH 仅 LAN；关闭不需要的 21/445/8888 等。

### P5 稳定性验收（7 天观察）
- 指标见 §8；产出验收报告 + 是否回滚的结论。

## 5. 仓库改造清单（文件级）

### 5.1 `.github/workflows/openwrt-builder.yml`
```diff
-  REPO_URL: https://github.com/openwrt/openwrt.git
-  REPO_BRANCH: main
-  BUILD_BRANCH: v24.10.2
-  COMMIT_ID: 594da824a4f2f9582941e612f1a912773d43ff1d
+  REPO_URL: https://github.com/immortalwrt/immortalwrt.git
+  REPO_BRANCH: master
+  # 可复现：pin 到 tag/commit（评审时确定，例：openwrt-24.10 分支或某个 commit）
+  BUILD_BRANCH: <pin>
+  COMMIT_ID: ""            # 不再 cherry-pick
```
- 理由：`v24.10.2` 里**没有** `nradio_c8-668gl`；immortalwrt master 有，且其 `platform.sh/02_network/01_leds` 已覆盖本机（含 `bdinfo fac_mac` 读取路径），维护成本最低。
- 备选：openwrt main（也有该机型），但 `platform.sh` 的 `CI_DATAPART` 等细节需另行核对；本机 DTS 与 immortalwrt 版差异更小。
- 建议同时加：`actions/cache` 缓存 `ccache`，把每轮构建从 ~2.5h 压到 ~1h（Actions 免费额度 2000 min/月，构建轮次敏感）。

#### 5.1.1 CI 环境加固（2026-10-03 落地）

对 `openwrt-builder.yml` 环境面的评审结论与处置：

| 项 | 评审发现 | 处置 |
|---|---|---|
| ccache 写回 | cache key 固定（`hashFiles('.config')`），而 `actions/cache` 条目不可变 → 命中后不再写回，ccache 自首次保存起停止增长 | key 追加 `github.run_id`，`restore-keys` 保留「精确 .config → 分支」两级前缀 |
| `dl/` 缓存 | 每轮 `make download -j8` 重下 GB 级源码，是编译外最大固定开销 | 新增 dl 缓存；路径用真实路径 `/workdir/openwrt/dl`（工作区里的 `openwrt` 是软链，tar 不跟随） |
| 编译重试 | `make -j$(nproc) \|\| make -j1 \|\| make -j1 V=s`，并行失败后串行续跑多数跑不完；撞 timeout 算 cancelled，`failure()` 不触发，日志留不下 | 单次 `make -j$(nproc)` + 子 shell 内 `set -o pipefail` + `tee $GITHUB_WORKSPACE/build.log`（openwrt 是软链，artifact 上传不跟软链）；新增失败时的 build-log artifact |
| Release 清理 | `dev-drprasad/delete-older-releases` 缺 `env.GITHUB_TOKEN`（该 action 无默认值），失败又被 `continue-on-error` 吞掉 → 旧 Release 从未被清 | 补 `GITHUB_TOKEN`，pin 到 `v0.3.3` |
| token 权限 | 无 `permissions:`，依赖仓库默认（收紧后 Release/清理才报错） | 显式 `contents: write` + `actions: write` |
| 并发 / 超时 | 无 `concurrency`、无 `timeout-minutes`（默认 6h）；Release tag 为分钟精度，并发会抢同一 tag | `group: openwrt-builder`；`timeout-minutes: 300` |
| action 版本 | `@main` / `@master` 可变 ref（checkout、upload-artifact、gh-release、两个清理 action） | 全部 pin 并升到 **node24** 运行时：checkout@v5、upload-artifact@v6、cache@v5、gh-release@v3、Mattraks@v2、repository-dispatch@v4；删旧 Release 改用官方 `gh release delete`，彻底去掉 `dev-drprasad` |
| 死变量 | `REPO_BRANCH`（clone 未带 `-b`，从未生效）、`FEEDS_CONF`（仓库根无此文件） | 删除；feeds 覆盖改为显式 `[ -f ]` 判断（原写法变量为空时 `mv` 只剩一个参数会失败） |
| update-checker | 仍指向 `coolsnowwolf/lede`，且未限定 dispatch 事件类型 | 改为 immortalwrt master；builder 侧 `repository_dispatch: types: [Source Code Update]` |
| 磁盘 | `Check space usage` 只在编译后打印 | 新增 `Pre-build environment check`（编译前 `df -hT` + `ccache -s` 留档） |

评估过但未做：
- **浅克隆**（`git clone --depth 1 --branch <tag>`）：省 1~2 min，但浅克隆对 OpenWrt 里 `git describe` 系脚本有历史报错记录，不值得拿 2.5h 构建验证。
- **argon 主题 pin tag**（`luci-theme-argon` / `luci-app-argon-config` 仍 `--depth 1` 取默认分支，版本会漂移）：需联网确认 tag 名，留待后续。
- **apt 源清理**（`rm -rf /etc/apt/sources.list.d/*`）：已在 §5.1.3 改为“只删非 `ubuntu.sources` 的文件”，两边都安全。

#### 5.1.2 `runs-on` 的 pin 与 24.04 迁移评估（2026-10-03）

先纠一个错：`python2.7` **不是** 24.04 的阻塞点。

**python2.7 在本项目无任何实际依赖**（证据）：
- 仓库内 `python2` / `py2` 只出现在 workflow 的 apt 安装行；`scripts/`、`patches/`、`packages/`、`files/` 无引用，`.config` 也无 `CONFIG_PACKAGE_python2*`。
- `.config` 只产出目标端 python3（`Python-3.13.9`、`libpython3`、`python3-*`）。
- 完整成功构建日志（`local/run-36901272322.log`）：`python2` 命中 17 行，**全部是 apt 安装记录，零次执行**；对照 `/usr/bin/python3.13` 出现 19 次。
- immortalwrt master 的 host 依赖自检（同日志 1553–1587 行）要的是 **python3**：`Checking 'python'... updated`、`'python3'... updated`、`'python3-distutils'... ok`、`'python3-stdlib'... ok`，全程无 `Please install ...`。
- **探针实拍**（`env-probe` 37094804605，`runner-layout.txt`）：两个 runner 上 `/usr/bin/python` 都存在且**都是 Python 3**（22.04 → 3.10.12，24.04 → 3.12.3）——`Checking 'python'` 那项拿到的本来就是 python3，与 `python2.7` 无关。
- 这一行是 P3TERX/lede 时代模板的遗留，删掉无成本。

**换 24.04（noble）的真实问题**（已由 `env-probe` 实测校正）：

| 级别 | 问题 | 实测结论 |
|---|---|---|
| P0 | `rm -rf /etc/apt/sources.list.d/*` 会删掉唯一的 apt 源 | **已证实**：24.04 上 `/etc/apt/sources.list` 只剩一句“sources have moved to …”的注释，真源在 `/etc/apt/sources.list.d/ubuntu.sources`（deb822）。旧写法会把它删掉。已改为 `find … ! -name 'ubuntu.sources' -delete`（22.04 行为等价，24.04 保留主源、只删 `microsoft-prod.list`） |
| P0 | 列表里不存在的包会让 `apt-get -qq install` 返回 100 | **已排除**：79 个包（官方 77 + 2）在 22.04/24.04 上逐个 `apt-get -s install` 全部可用（run 37105891296），全量 simulate 也通过。原先担心的 `libncurses5-dev`/`libncursesw5-dev`/`antlr3`/`fastjar`/`upx-ucl`/`intltool`/`mkisofs`/`uglifyjs` 在 noble 里都存在；虽然后来按官方清单把 ncurses 收敛成 `libncurses-dev`，但也验证过旧名可用 |
| P1 | `python3-distutils` 自检能否过 | **已排除**：24.04 上 `python3 -c import distutils` → ok（setuptools 的 distutils shim 兜住了） |
| P1 | 宿主工具链换代：gcc 11→13、binutils 2.38→2.42、glibc 2.35→2.39 | 仍未验证（探针不编译），只能靠一轮真构建 |
| P2 | 镜像内容差异 / 磁盘 | **不需担心**：两边磁盘均 `87G avail`；`/opt/ghc`、`/usr/share/dotnet`、`CodeQL` 在 24.04 本就不存在，`rm -rf` 容错 |

**建议路径**（已实施）：`env-probe.yml`（只读探针，手动触发）跑 `ubuntu-22.04` / `ubuntu-24.04` 矩阵：打印 apt 源布局 + host python + 对 `.github/apt-deps.txt` 逐个 `apt-cache show` + 全量 `apt-get -s install`，1 分钟出“哪些包在 noble 不存在”。不要拿 2.5h 构建当探针。

#### 5.1.3 APT 依赖收敛与环境阶段流程（2026-10-03 落地）

**单一来源**：新增 `.github/apt-deps.txt`（一行一个包，带分组注释）。
`openwrt-builder.yml` 的 `Initialization environment` 与 `env-probe.yml` 都读它，
不再把 70+ 个包名抄在 workflow 里。解析方式是「去掉 `#` 注释 + 按空白切词」，
所以文件里可以自由分组、写行内注释。

**清单来源（2026-10-03 改为对齐官方）**：不再以 P3TERX 模板的列表为基准，
而以下面两份官方来源为准：

1. `immortalwrt/immortalwrt` `README.md` @ **v25.12.2**（本仓库 `BUILD_BRANCH` 所 pin 的 tag）
   的 “Development > Requirements > Setup dependencies via APT”。
2. `immortalwrt/build-scripts` 的 `init_build_environment.sh`（官方一键环境脚本，更权威）：
   `apt install -y $BPO_FLAG ack antlr3 asciidoc … zlib1g-dev zstd xxd $VERSION_PACKAGE`，
   再用版本化包安装 `gcc-$V` / `g++-$V` / `*-multilib`、`clang-$LLVM` / `lld-$LLVM` / `llvm-$LLVM`。

两份清单基本一致；脚本给 **noble 指定 `GCC_VERSION=13` / `LLVM_VERSION=18`**，
而 ubuntu-24.04 的默认 gcc 就是 13、默认 clang/llvm 就是 18——**升到 24.04 反而与官方脚本
的版本选择对齐**（22.04 默认 gcc 11 ≠ 脚本给 jammy 要的 gcc 10）。
脚本中 `VERSION_PACKAGE`（python2）只给 bionic/buster/focal/bullseye/jammy 配，
`noble` / `bookworm` / `trixie` 均为空——从官方侧再次印证 python2 不是必需品。

**当前清单 = 官方 77 项 + 2 项 CI 附加**（`tar`：Debian essential，官方因此不写；
`python3-setuptools`：24.04 起 distutils 移出 stdlib，靠它兜住
`Checking 'python3-distutils'` 自检）。

相对上一版（自 P3TERX 列表精简得到的 65 项）的调整：

| 动作 | 包 | 依据 |
|---|---|---|
| **回补** | `ack` `lrzsz` `msmtp` `vim` `qemu-utils` | 上一轮按「CI 无交互 / 无串口 / 无邮件」删的，但官方清单里都有；以官方为准 |
| **新增** | `clang` `lld` `llvm` `ecj` `gnutls-dev` `lib32gcc-s1` `libyaml-dev` `libz-dev` `re2c` `zstd` `nano` `python3-pip` `python3-ply` `python3-docutils` | 官方清单成员，上一版漏了 |
| **改名** | `libncurses5-dev` + `libncursesw5-dev` → `libncurses-dev` | 官方的现代包名 |
| **剔除** | `libev-dev` `libtirpc-dev` `liblzma-dev` `libfuse-dev` | 官方 README 与 init 脚本两处都没有；官方 CI 长期不用它们也能构建 |
| 不动 | `python2.7` | 官方两处清单都没有（noble 的 `VERSION_PACKAGE` 为空），且已证实零使用 |

**环境阶段流程优化**：

| 原状 | 现在 |
|---|---|
| `rm -rf /etc/apt/sources.list.d/*`（在 24.04 会删掉主源） | `find … -type f ! -name 'ubuntu.sources' -delete`（22.04 行为等价，24.04 安全） |
| 只清 `dotnet/android/ghc/CodeQL` | 追加 `boost /opt/az /opt/microsoft /usr/share/swift`（不存在则 `rm -rf` 容错） |
| `apt-get update` 无重试 | 加 `-o Acquire::Retries=3` |
| `apt-get install <长列表>` 无防升级 | 加 `-y --no-upgrade`（不顺手升级 runner 既有包） |
| 包名内联 | 读 `.github/apt-deps.txt`，并回显实际包数 |

#### 5.1.4 验证记录（2026-10-03）

**A. Env Probe 实跑**（`env-probe.yml`，手动 dispatch；每轮 2 个 job）：

| 项 | ubuntu-22.04 | ubuntu-24.04 |
|---|---|---|
| 旧清单 65 个包（run 37094804605） | 65/65 可用 | 65/65 可用 |
| **官方 77 + 2 项 = 79 个包**（run **37105891296**） | **79/79 可用** | **79/79 可用** |
| 全量 `apt-get -s install` | 通过 | 通过 |
| `/etc/apt/sources.list` | 真源（`mirror+file:/etc/apt/apt-mirrors.txt`） | 只有“源已迁到 sources.list.d/ubuntu.sources”的注释 |
| `sources.list.d/` | `microsoft-prod.list` | `microsoft-prod.list` + `ubuntu.sources` |
| `/usr/bin/python` | Python 3.10.12 | Python 3.12.3 |
| `import distutils` | ok | ok |
| 根分区可用 | 87G | 87G |

结论：24.04 的**包层面障碍为零**，唯一的真障碍是 deb822 源路径（已修）。
剩下的不确定项只有宿主工具链换代（gcc 13 / binutils 2.42 / glibc 2.39），需一轮真构建。

**B. Action ref 审计** —— 逐个读 `action.yml` 的 `runs.using`，确认 pin 的 ref 都存在、
且都落在 node24 上（GitHub 已强制 node20 action 跑在 node24，弃用警告就来自这个错配）：

| action | pin | 运行时 | 备注 |
|---|---|---|---|
| actions/checkout | v5 | node24 | v4 是 node20；最新 v7 |
| actions/upload-artifact | v6 | node24 | v5 仍是 node20；最新 v7 |
| actions/cache | v5 | node24 | v4 是 node20；最新 v6 |
| softprops/action-gh-release | v3 | node24 | v2 是 node20；`token` 输入默认 `github.token` |
| Mattraks/delete-workflow-runs | v2 | node24 | 文件名是 `action.yaml` |
| peter-evans/repository-dispatch | v4 | node24 | v2 是 node16 |
| mxschmitt/action-tmate | v3 | node24 | 未改 |
| ~~dev-drprasad/delete-older-releases~~ | — | ~~node20~~ | 最新 v0.3.4 仍是 node20 ⇒ 换成官方 `gh release delete`（`keep_latest: 3` 语义保持，另加“只删 `YYYY.MM.DD-HHMM` 自动标签”的保险） |

统一取「第一个 node24 的 major」而不是最新版，少跳几个 major、少引入行为变量。

#### 5.1.5 runner 迁移到 ubuntu-24.04（2026-10-03）

`.github/workflows/openwrt-builder.yml` 的 `runs-on` 已从 `ubuntu-22.04` 改为
`ubuntu-24.04`。

依据（§5.1.4 的探针实测）：65 个依赖 65/65 在 noble 可用、全量 `apt-get -s install`
通过；deb822 源路径已适配（`! -name 'ubuntu.sources'`）；host python 为 3.12 且
`distutils` 自检通过；磁盘同样 ~87G。

**唯一未验证项**：宿主工具链换代（gcc 11→13、binutils 2.38→2.42、glibc 2.35→2.39）。
本轮构建若失败在 host tool 编译阶段，优先怀疑这里，而不是包缺失。

**回滚**：一行 —— `runs-on` 改回 `ubuntu-22.04`。其余改动（`.github/apt-deps.txt`、
源路径写法、缓存、权限）在 22.04/24.04 上行为一致，不需要跟着回滚。

`env-probe.yml` 保留 22.04/24.04 双矩阵：以后改动依赖清单时，先用它当 1 分钟探针。

### 5.2 补丁管理
- 现状：`patch.tar.gz` / `patch2.tar.gz`（不透明）。
- 改为：`patches/` 目录下 git 可 diff 的补丁 + workflow 的 `Load custom configuration` 步骤里 `git apply`（原 `diy-part2.sh` 已于 2026-10-03 内联进 workflow，见其文件头注释）。**这是我目前评审的第一步收益**：别人/未来的你能看到"改了什么"。

### 5.3 `.config`
- `CONFIG_TARGET_mediatek_filogic_DEVICE_nradio_c8-668gl=y`（替换 `cudy_tr3000-256mb-v1`）
- 追加（数据面与调试）：
  - `kmod-usb-net-cdc-ncm`、`kmod-usb-net-cdc-ether`、`kmod-usb-net-cdc-mbim`、`kmod-usb-net-qmi-wwan`、`kmod-usb-serial-option`、`kmod-usb-net-rndis`（D2/D3 实验与兜底）
  - `uqmi`、`umbim`（若 D3 成立）、`picocom` 或 `socat`（AT 实验）
  - `kmod-usb3`、`automount`（上游默认已带）
  - 可视化：`luci-app-commands`/`luci-app-ttyd`（可选）
- 移除（本机无用且体积大）：OpenClash 相关（除非你要在 C8 上跑）、`cudy` 专属包。
- 明确选择：是否保留 `docker/dockerd`（厂商版是 vfs + 0 容器；如要跑容器，建议 24.10 的 `dockerd` + `overlay2`，但 A 槽 256MB 不够，必须用 B 槽 6.7GB）。

### 5.4 DTS：`target/linux/mediatek/dts/mt7981b-nradio-c8-668gl.dts`
以 immortalwrt 版为基线（已在 `docs/refs/`），按本机实测修正：

| 改动点 | 内容 |
|---|---|
| WiFi LED | `wlan` 从 `&pio 13` 改为 **`&pio 34`**（实测） |
| CPE 选择 | `cpe-sel0` 从 `&pio 30` 改为 **`&pio 29`**，新增 `cpe-sel1 = &pio 30` |
| 风扇 | 新增 `fan-hw = &pio 27`、`fan-fg = &pio 28` gpio-export；新增 `pwm-fan`（`pwms=<&pwm 0 40000 0>`、`cooling-levels=<64 128 192 255>`）+ `cpu-thermal` 冷却映射（厂商是脚本控风扇，我们改成内核 thermal 控） |
| 按键 | 去掉 `wps`（本机 DT 无此键），保留 `reset = &pio 1` |
| LED 命名 | 采用上游 `blue:power / blue:indicator-0 / blue:indicator-1 / blue:wlan`（与 `01_leds` 的 `blue:wlan`、`blue:indicator-0` 对齐） |
| nvmem | 确认/补齐 `bdinfo` 文本分区（fac_mac/imei），供 `mmc_get_mac_ascii` 使用 |
| 分区 | 不改 GPT；仅在 DTS 里声明 nvmem 解析（`u-boot-env`/`factory`/`bdinfo`） |

### 5.5 `board.d` / 刷机逻辑
- `02_network`：本机 board_name（`HCMT7981-emmc`）**不在**上游 case 里 → 要么把 DTS 的 compatible 对齐为 `nradio,c8-668gl`（推荐，兼容上游全部逻辑），要么给上游文件加一条本机 board_name 分支（补丁）。**推荐前者**：DTS 里 `compatible = "nradio,c8-668gl", "mediatek,mt7981"`，同时保留实际硬件差异（LED/GPIO）——但这会影响 `board_name` 判定与回滚时的识别，需要评审决定（见 §9-Q1）。
- `01_leds`：本机 LED 名称/含义按实测确认后微调。
- `platform.sh`：核实 `CI_DATAPART="rootfs_data"` 在本机 GPT（只有 `app_data`）下的行为；若 `emmc_do_upgrade` 强依赖该分区，则加兼容分支（`nradio_c8-688`）或在 DTS/GPT 层面把 `app_data` 视作 data 位。

## 6. 刷机与回滚（关键安全设计）

- **只刷 B 槽**（`kernel_2nd` p8 + `rootfs_2nd` p9），与上游 `platform.sh` 的 `nradio,c8-668gl` 分支一致 → A 槽出厂固件保持原样。
- 回滚：`fw_setenv boot_system 0`（或反向）后重启，走 A 槽出厂固件。串口 115200 常接。
- 刷前必做：`sha256` 记录 A 槽 kernel/rootfs 头部 + GPT 表；确认 `sysupgrade` 产物是 `ustar`（上游 check 逻辑要求）。
- 不做：不写 `fip`/`u-boot-env`（除切换 `boot_system` 这一条）、不重建 GPT、不动 `factory`/`bdinfo`。
- 模块侧写操作：只在 P3 进行，逐条授权，且每条都记录旧值（§基线表）。

## 7. 风险矩阵

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 首刷变砖 | 低 | 高 | 只写 B 槽 + 串口到场 + A 槽回滚 |
| DTS 差异导致外设不可用（LED/按键/风扇/交换机口） | 中 | 中 | P1 静态比对 §6 表；P2 逐项验收 |
| WiFi 由 `mt_wifi` 换 `mt76` 后校准/吞吐异常 | 中 | 中 | 保留 `factory` 分区与 `nvmem eeprom` 引用；准备 WiFi 回归测试 |
| 模块参数写入后不可恢复 | 中 | 高 | 先记录基线值；只用 `=0/1/2` 这类已声明的取值；必要时串口/重插恢复 |
| D3（ECM/MBIM/QMI）不成立 | 中高 | 低（仅浪费实验） | 先 D1/D2；D3 作为可选加分项 |
| `app_data` vs `rootfs_data` 不匹配导致配置写入失败 | 中 | 中 | P0 读 `emmc.sh`/`emmc_do_upgrade` 实现，必要时打分支补丁 |
| Actions 额度/构建时长 | 高 | 低 | pin commit + ccache 缓存 + 减少重跑 |

## 8. 验收指标（P5）

1. **数据面**：`traceroute 223.5.5.5` 首跳是否只在模块内网一次；若走 D1，路由器 WAN 直接持有 `10.6.223.136`（或公网 v6）且 `nft list ruleset` 里只剩一层 masquerade。
2. **IPv6**：LAN 拿到原生 `240a:` 前缀（PD）或明确说明为何仍走模块 NAT66。
3. **性能基线对比**（与现状同点测）：`iperf3` 上下行、`ping` 平均/抖动、WiFi 2.4/5G 吞吐。
4. **稳定性**：7 天无重启、无 `No response from modem` 类噪音、内存无泄漏、SoC 温度与风扇曲线正常。
5. **纯净度**：`ps` 无 quickstart/at-server/httpapi/dhns；`uci show` 无私有配置；`nft` 暴露面仅剩必需端口。
6. **可回滚**：从新固件一键回 A 槽出厂固件（演练记录留档）。

## 9. 待确认 / 待授权

- **Q1（需你决定）**：目标机型标识用上游 `nradio,c8-668gl`（改 DTS compatible，吃上游全部逻辑）还是新增 `nradio,c8-688`（保留本机真实 SKU，但需要给上游文件打多处小补丁）？
- **Q2（需你确认）**：源码树选 **immortalwrt master**（推荐）还是 openwrt main？是否接受 pin 到某个 tag/commit 牺牲"最新"换可复现？
- **Q3（需你确认）**：整机 WAN 口是否有插网线？我需要用它判定"模块数据面走板载 GE（推断）还是外部上联"，也影响 D1/D2 方案。
- **Q4（需你授权，写操作）**：P2 首刷（写 B 槽）。
- **Q5（需你授权，写操作）**：P3 模块参数实验（`AT+CEUS` / `AT^TDPCIELANCFG` / USB 组合切换），每次单条、可回滚。
- **Q6（需你确认）**：是否需要在这台 C8 上继续跑 Docker / alist / samba 等业务（决定 B 槽容量与包选择）。
- **Q7（需你确认）**：LAN 的 DHCP/DNS 现在到底谁在服务（`dhcp.lan.ignore=1`、leases 为空、DNS 指向 `192.168.66.251`）。接管方式需按现状定。

## 10. 成本与里程碑

| 阶段 | 工作量 | CI 成本 |
|---|---|---|
| P0 基线/回滚准备 | 0.5 天 | 0 |
| P1 仓库改造 + 首版产物 | 1~2 天 | 2~4 轮构建（每轮 1~2.5h） |
| P2 首刷 + 网络验收 | 0.5 天 | — |
| P3 数据面实验 | 1~2 天 | 0~2 轮（如需改 dts/包） |
| P4 落地 + 业务迁移 | 1 天 | 1~2 轮 |
| P5 稳定性观察 | 7 天（被动） | 0 |

合计**约 4~6 个工作日**（不含观察期）；Actions 额度约需 6~10 轮构建，建议开 ccache 缓存。

## 11. 最小下一步（等你一句话即可开工）

1. 答复 Q1/Q2/Q3/Q6/Q7；
2. 我随后提交 P1 的第一批改动（`.config` + workflow 变量 + 把 patch.tar.gz 换成文本补丁 + DTS 基线文件入库），**不动整机**；
3. P1 产物出来后，再单独向你申请 P2 的首刷窗口。
