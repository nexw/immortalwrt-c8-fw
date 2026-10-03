# RFC-002：风扇 / 指示灯控制收敛到 OpenWrt 新范式（procd 触发器 + apk 包）

- 状态：**Draft，待评审**
- 作者：Johnny（+ AI 协作）
- 日期：2026-10-03
- 关联：`docs/RFC-nradio-c8-native-firmware.md`（RFC-001）、`docs/operations.md` 的「风扇温控」「指示灯控制」两节
- 施工对象：`nexw/immortalwrt-c8-fw`（2026-10-03 起为独立仓库）

---

## 1. 背景

`fanctl`（PWM 风扇温控）与 `ledctl`（夜间定时熄灯）是 RFC-001 落地后新加的两项功能，
**procd/UCI 骨架本身是对的**（`/etc/rc.common` + `USE_PROCD=1` + `procd_open_instance` +
`procd_set_param respawn`，参数全部走 `/etc/config/*`），但有三处不符合 25.12 的新范式：

| # | 问题 | 证据（2026-10-03 实机 / 仓库核对） |
|---|---|---|
| A | **没有任何 procd 触发器** | `grep -rn "service_triggers\|procd_set_param file\|procd_add_reload" files/ packages/` → 0 命中。结果：`uci commit fancontrol` 后必须手动 `/etc/init.d/fancontrol restart`（README 也是这么教用户的） |
| B | **用轮询代替事件** | `ledschedule` 每 60 s 醒一次（`option interval '60'`），只为兜住"时段边界 / NTP 校时跳变 / 手动覆盖到期"。每天 1440 次无谓唤醒 + 每次重解析 UCI |
| C | **游离在 apk 之外** | `apk info -W /usr/bin/fanctl` → `ERROR: /usr/bin/fanctl: Could not find owner package`（`ledctl`、`/etc/init.d/fancontrol` 同）。无版本、无依赖、无 conffile，`kmod-hwmon-pwmfan`/`kmod-gpio-pwm` 只能靠人肉加进 `.config` |

顺带修正两处文档漂移（见 §6）。

## 2. 目标 / 非目标

**目标**
- G1 配置生效走 procd 触发器：`uci commit` → 服务原地重载，**不重启进程、不打断控制**。
- G2 `ledschedule` 改为事件驱动：只在「时段边界 / 手动覆盖到期 / 配置变更 / NTP 校时」醒来，取消固定轮询。
- G3 两项功能各做成 apk 包（本地 feed `nrlocal`），声明 `DEPENDS`、声明 conffile。
- G4 行为对用户可见面**零变化**：命令用法、UCI 选项名（除一个）、日志含义、LED/风扇的最终状态全部保持一致。

**非目标**
- 不动 `files/` 下的 `mt5700-*`、`wifi-survey`（另有 RFC，见 §8）。
- 不改 DTS / 不绑 `cooling-map`（P7 遗留问题，见 §8）。
- 不改 LuCI 交互形态（仍是 luci-app-commands 的快捷命令，不做 CBI 配置页）。

## 3. 关键设计决策

### 3.1 用触发器还是用文件监视？

procd 提供两条路，都能实现"配置改了要生效"：

| 方案 | 机制 | 结果 |
|---|---|---|
| `procd_set_param file /etc/config/x` | procd 监视文件 mtime，变更即**重启实例** | 简单，但重启 = 一次 `stop_service` |
| `service_triggers()` + `reload_signal` | `uci commit` 触发 `/etc/init.d/x reload` → `procd_send_signal` 发 HUP → 进程**原地重载** | 无中断、无 `stop_service` 副作用 |

**选后者。** 理由是 `stop_service` 有副作用：`ledschedule` 的 `stop_service` 会把灯交还给"开"
（原设计意图：停服务不要留一屋黑灯）。若采用"重启"路线，用户在 10:00 手动 `ledctl off` 时
会看到 **熄灯 → 亮一下 → 再熄灯** 的闪烁，且手动状态被清掉。原地重载没有这个问题。

代价：需要守护进程能处理 `SIGHUP`。**busybox ash 的 `sleep` 是不可中断的**——前台 `sleep 3600`
遇到 HUP 会等睡满才执行 trap。必须改成「后台 sleep + `wait`」：

```sh
sleep "$d" & _spid=$!
wait "$_spid"        # ash 中 wait 会被带 trap 的信号打断（实机已验，rc=129）
```

实机验证（2026-10-03，只读、无写盘）：

```
START-at-…977   SENDING-HUP-at-…979   WAIT-RETURNED-at-…979 rc=129
```

### 3.2 「事件驱动」是否彻底取消兜底？

时段边界是**绝对时间**，而 `sleep` 是**单调时间**。NTP 把时钟往回跳时，正在睡的 `sleep`
不会提前醒，理论上最多错过一个周期。

处理：新增 `/etc/hotplug.d/ntp/30-ledschedule`，在 procd 广播 `ACTION=stratum`（时间首次可信）
时 `reload` 服务——这是上游自己的做法（对照 `/etc/hotplug.d/ntp/25-dnsmasqsec` 与
`/etc/hotplug.d/iface/20-firewall`）。

在此基础上保留一个**可配置的最长休眠上限** `option max_sleep`（默认 3600 s，`0` = 完全不限）：

- 默认 3600 s ⇒ 每小时最多醒 1 次（原来是每分钟 1 次，**降 60 倍**），且醒来只做一次 `date` 比较；
- 设 `0` ⇒ 纯事件驱动，正确性完全押在 ntp 热插拔上。

**这是一个有意识的取舍**：不把固件的时段正确性押在单一外部事件上。写进文档，交给使用者决定。

### 3.3 手动覆盖（`ledctl off/on`）如何通知守护进程？

被拒绝的方案：

| 方案 | 否决理由 |
|---|---|
| 守护进程轮询状态文件 | 就是我们要消掉的轮询 |
| 把状态写进 UCI，靠 `config.change` 触发 | 每次手动切灯都写 flash（eMMC overlay），且 60 min 内可反复写 |
| 重启服务 | 触发 `stop_service`，见 §3.1 的闪烁问题 |

**采用：`ledctl` 手动改完状态后调 `/etc/init.d/ledschedule reload`**，与 `uci commit` 走同一条
（已经是唯一一条）通知路径。守护进程收到 HUP 后重读配置与状态文件、重算下一次唤醒时刻。

守护进程自身不调用这条路径，避免自激。

### 3.4 命名与兼容

`option interval` 语义已变（不再是"轮询间隔"），改名 `option max_sleep`。
残留 `interval` 不会影响功能（新代码不读它），仅在重载时打一条迁移提示。

## 4. 改动清单（文件级）

### 4.1 新增：apk 包

```
packages/c8/fanctl/Makefile                              # PKGARCH:=all, DEPENDS:=+kmod-hwmon-pwmfan +kmod-gpio-pwm
packages/c8/fanctl/LICENSE
packages/c8/fanctl/files/usr/bin/fanctl                   # 由 files/ 迁入 + 加 SIGHUP 原地重载
packages/c8/fanctl/files/etc/init.d/fancontrol            # 由 files/ 迁入 + service_triggers/reload_service
packages/c8/fanctl/files/etc/config/fancontrol            # 由 files/ 迁入（conffile）

packages/c8/ledctl/Makefile                              # PKGARCH:=all, DEPENDS:=+kmod-leds-gpio +kmod-ledtrig-network
packages/c8/ledctl/LICENSE
packages/c8/ledctl/files/usr/bin/ledctl                   # 由 files/ 迁入 + 事件驱动 + SIGHUP 原地重载
packages/c8/ledctl/files/etc/init.d/ledschedule           # 由 files/ 迁入 + service_triggers/reload_service
packages/c8/ledctl/files/etc/config/ledschedule           # 由 files/ 迁入 + interval→max_sleep（conffile）
packages/c8/ledctl/files/etc/hotplug.d/ntp/30-ledschedule # 新增：NTP 校时后 reload
```

feed 注册现在写在 workflow 的 `Load custom feeds` 步骤里（`src-link nrlocal
$GITHUB_WORKSPACE/packages`，原 `diy-part1.sh` 已于 2026-10-03 内联）；`Load custom
configuration` 步骤（原 `diy-part2.sh` 内联而来）里已有的「本地包是否真的就位」校验
会自动覆盖新包，不用改任何东西。

### 4.2 删除

`files/usr/bin/{fanctl,ledctl}`、`files/etc/init.d/{fancontrol,ledschedule}`、
`files/etc/config/{fancontrol,ledschedule}` —— 全部 `git mv` 到包内，`files/` 不再保留副本
（两处同时存在会导致 rootfs 重复安装告警）。

### 4.3 修改

| 文件 | 改动 |
|---|---|
| `.config` | `CONFIG_PACKAGE_fanctl=y`、`CONFIG_PACKAGE_ledctl=y`（挨着既有的 `CONFIG_PACKAGE_luci-app-wtmodem` 注释块放） |
| `README.md` | 「风扇温控」补触发器说明与依赖；「指示灯控制」把"每 60 s 轮询"改写为事件驱动 + `max_sleep`；修正 §6 两处漂移 |

## 5. 验收标准

构建侧（不刷机即可验证）：

1. `make defconfig` 后 `tmp/.config-package.in` 里出现 `config PACKAGE_fanctl` / `config PACKAGE_ledctl`；
2. `ls package/feeds/nrlocal/` 能看到两个包（`Load custom configuration` 步骤的就位校验通过）；
3. 产物中 `apk list --installed` 含 `fanctl`、`ledctl`，且 `/lib/apk/db/installed` 里能查到
   `/usr/bin/fanctl`、`/etc/init.d/fancontrol` 的属主。

刷机侧：

| # | 动作 | 期望 |
|---|---|---|
| 1 | `fanctl status` | 与改造前一致（`mode: hwmon-pwmfan`，占空比跟随温度） |
| 2 | `uci set fancontrol.main.interval='5' && uci commit fancontrol` | `logread` 出现 fanctl 的"配置已重载"，**没有**实例重启日志（`ps` 里 pid 不变） |
| 3 | `ledctl status` / `ledctl schedule` | 输出与改造前一致 |
| 4 | `uci set ledschedule.main.off_start='22:30' && uci commit` | `ledctl status` 立即可见新时段（无需等 60 s） |
| 5 | 跨过 `off_start` | 灯按时熄，`logread` 只有一条 "关灯（定时）" |
| 6 | `ledctl off` 后 `ledctl status` | `manual` 且立刻生效；`logread` 无"开灯→关灯"抖动 |
| 7 | `date -s` 模拟（或等 NTP） | 热插拔触发 reload，下一次唤醒时刻被重算 |
| 8 | `/etc/init.d/ledschedule stop` | 与改造前一致：灯交还给"开"，无残留 |

## 6. 顺带修正的文档漂移

| # | README / 代码注释的说法 | 实机事实 |
|---|---|---|
| 1 | `README.md` 称 `blue:power` 在 `/etc/config/system` 里 **0 条**，只能靠 `ledschedule` 补缺口 | `uci show system` 有 `system.@led[2].sysfs='blue:power'` / `trigger='default-on'`；`ledctl status` 报 `恢复来源=uci`。且这条是**设备端手工加的、未回到仓库**（`/etc/board.json` 只生成 wifi/5g 两条，`files/etc/uci-defaults/99-nradio-c8-defaults` 无 led 行） |
| 2 | `README.md` 与 `fanctl` 头注释称"现网镜像未带 `kmod-hwmon-pwmfan`、`pwm-fan.ko` 不是 builtin" | 驱动已在镜像且已接管：`hwmon3: pwmfan`，`fanctl status` → `mode: hwmon-pwmfan`，`170/255 = 66% @ 73.0C`。`lsmod` 看不到是 builtin 的正常现象。**`kernel_driver='hwmon'` 的默认值把这个变化兜住了，属于有惊无险** |

第 1 条在本 RFC 中一并把 `blue:power` 的 led 段补进 `files/etc/uci-defaults/99-nradio-c8-defaults`，
让它不再只活在设备上。

## 7. 风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| 守护进程 SIGHUP 处理不当导致进程被杀 | 中 | `trap` 必须在进入循环前设置；`reload_signal HUP` 只发给实例 pid |
| 事件驱动漏掉边界（时钟跳变） | 中 | ntp 热插拔 hook + `max_sleep` 兜底（默认 1 h） |
| 包化后路径/权限变化导致刷机后不可执行 | 低 | 用 `$(INSTALL_BIN)`（0755）；对照 RFC-001 已踩过的"files/ 可执行位丢失"坑 |
| **纯文件包漏写 `define Build/Compile`** | **高（已发生）** | 实测 run `37092979877`：`fanctl` 挂在 world 末尾——`make[4]: *** No targets specified and no makefile found.`，因为 `include/package.mk:396` 默认 `Build/Compile=$(call Build/Compile/Default,)`＝`make -C $(PKG_BUILD_DIR)`，而空目录里没有 Makefile。**必须写空的 `define Build/Compile`**（同树正例 `package/emortal/cpufreq/Makefile`）。`Build/Install` 不用管：`package.mk:397` 是 `$(if $(PKG_INSTALL),…)`，本包未设 |
| `PKGARCH:=all` 写在 Package 块外 | 中 | 块外会被 `include/package-defaults.mk` 里 `Package/Default` 的 `PKGARCH:=$(ARCH_PACKAGES)` 覆盖，包会变成目标架构相关（不失败但不符合本意）。树里 103 个包写在块内、只有 1 个写在外面，跟着多数写 |
| 非 luci 包用 `root/` 当文件目录 | 低 | `root/` 是 `luci.mk` 的魔法目录名，非 luci 包里容易被误读（若将来引入 luci.mk 还会重复安装）。改用 OpenWrt 通用的 `files/`（树里 996 处） |
| `/etc/config/*` 变 conffile 后与旧 overlay 内容冲突 | 低 | apk 保留本地修改；`interval` 残留已做向后兼容处理 |
| 两个包与 `files/` 重复安装同一路径 | 低 | 本 RFC 已 `git mv`，`files/` 不再有副本 |

## 8. 遗留 / 后续

- **P7（内核侧）**：`patches/0001` 已把 `fan: pwm-fan` 写成内核热框架范式
  （`#cooling-cells`/`cooling-levels`/`pwms`），但 `cpu-thermal.cooling-maps` 未绑风扇，
  所以 `fanctl` 仍是必需的 userspace 兜底。绑上之后 `fanctl` 可退化为可选。
- **`mt5700-*` / `wifi-survey` 仍在 `files/`**，同样不被 apk 记账、无依赖声明
  （如 `mt5700-sms` 依赖 `python3-light`+`python3-pyserial`，现在是靠 `.config` 人肉保证的）。
  建议另开 RFC-003 统一收口。
- **网口（RJ45）LED**：MT7531 无软件通路，`ledctl` 的 `auto_eth_leds` 现在是空操作，
  将来 DTS + 内核补齐后自动纳入（无需改本 RFC 的实现）。
