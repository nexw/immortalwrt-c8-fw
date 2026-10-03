# RFC-003：网关侧服务补强（NTP Server / mDNS(DNS-SD) / DAWN）

- 状态：**Draft，待评审**
- 作者：Johnny（+ AI 协作）
- 日期：2026-10-04（v2，按"更轻量 → 弃 avahi、保留 umdns；移除 ttyd"修订）
- 关联：`docs/RFC-nradio-c8-native-firmware.md`（RFC-001）、`docs/RFC-002-led-fan-packaging.md`（RFC-002）、`docs/operations.md`
- 施工对象：`nexw/immortalwrt-c8-fw`
- 变更面：`.config`（+`dawn`/`luci-app-dawn`/`umdns`）、`files/etc/uci-defaults/99-nradio-c8-defaults`

---

## 1. 背景

C8 作为内网网关，除组网外想补齐 **mDNS(DNS-SD)、NTP Server、UPnP** 三类能力，
并评估 **无线漫游（DAWN）**。中途的两个修订把方案收敛到"最小包集"：

1. **DNS-SD 用轻量实现**：`avahi` 全栈（含 dbus）约 485 KB，还要和 `dawn` 依赖的
   `umdns` 抢 `udp/5353`；而 `umdns` 只有约 17 KB，且本身就是 `dawn` 的依赖 —— 改为**保留 umdns、弃 avahi**。
2. **移除 ttyd**：ttyd 在内网走**明文 HTTP** 传 root 登录密码与整段会话，是比 jail 更本质的风险；
   有了 SSH + LuCI，浏览器内 root 终端不是必需品 —— **移除 `ttyd` / `luci-app-ttyd`**。

盘点现状（2026-10-04，真机 `root@192.168.66.1`，ImmortalWrt 25.12.2 + 仓库 HEAD）：

| 能力 | 折扣前状态 | 实机证据 |
|---|---|---|
| UPnP | `miniupnpd-nftables` + `luci-app-upnp` **已在包集** | `upnpd.config.enabled='0'`、`secure_mode='1'`、`enable_natpmp='1'`、`igdv1='1'`、`ipv6_disable='1'` |
| NTP | 只有客户端 | `system.ntp.enabled='1'`、`enable_server='0'`、server 已配国内源 |
| mDNS | 无 | 无 `avahi`/`umdns` 包，5353 无人监听 |
| 漫游 | 无（`wpad-openssl` 已具备 802.11k/v/r 能力） | 无 `dawn` |
| ttyd | **局域网内明文 HTTP root web shell** | `ttyd.@ttyd[0].interface='@lan'`、`command='/bin/login'`、无 `credential`、无 TLS |

## 2. 目标 / 非目标

**目标**
- G1 LAN 侧有稳定时间源，且**不**把 NTP 服务暴露到 WAN。
- G2 有 DNS-SD/mDNS 能力，且**尽量小**、不引入 dbus。
- G3 引入 DAWN（先把包与基本配置就位；多 AP 组网由后续决定）。
- G4 消除"内网明文 root 会话"这一危险面。
- G5 默认值走 `files/`（首启生效），不在 CI 里做运行时魔改。

**非目标**
- 不改 UPnP 默认值（见 §3.1）。
- 不做跨 VLAN 的 mDNS reflector（当前单网段，方案见 §3.3）。
- 不给 NTP 上 `chrony`（busybox 已能当 server，精度诉求另议）。
- 不做 LuCI HTTPS（与本 RFC 并列的"明文凭据"面，见 §3.4 备注）。

## 3. 关键设计决策

### 3.1 UPnP：装而不开（保持现状）

包已在，真机 `enabled=0` 是上游默认。**不建议改成默认开**：

- 当前 WAN 是运营商 CGNAT（`10.65.x.x/8`），端口映射对外不可达，开了也没有实际入站价值；
- 入站需求侧已由原生 IPv6 覆盖（LAN 客户端直接用上游 `/64`），那是 firewall pinhole 的事，不是 UPnP；
- 若默认开，任意 LAN 设备（含被攻陷的 IoT）可自助开洞，而 miniupnpd 历史上有过 CVE。

结论：维持 `enabled=0` + `secure_mode=1`，需要时在 LuCI 一键开。**本条不改任何文件**。

### 3.2 NTP Server：复用 busybox `sysntpd`，零新增包

真机 `/etc/init.d/sysntpd` 已内建 server 能力（`enable_server:bool:0` + `interface:string` →
`ntpd -l -I <ifname>`），因此只改两行 UCI 即可对 LAN 提供 NTP：

```
system.ntp.enable_server='1'
system.ntp.interface='lan'      # 关键：只在 br-lan 监听，避免成为 UDP/123 放大器
```

- 无需新增包、无需改防火墙（lan zone 是 `input ACCEPT`）。
- 不设 `interface` 会全接口监听（含 WAN），必须显式限定。

### 3.3 DNS-SD：选 `umdns`（弃 avahi）

候选实现对比（体积为 aarch64_cortex-a53 索引值，量级参考）：

| 方案 | 体积（含依赖） | 能力 | 管理/工具 | 结论 |
|---|---|---|---|---|
| **`umdns`** | **≈ 17 KB** | 应答本机通过 ubus 注册的服务；`ubus call umdns browse` 可查 LAN 上已发现的 mDNS 服务；不解析他机 `.local`、不做跨接口反射 | UCI（`/etc/config/umdns`，默认 `jail 1` + `network lan`）+ `ubus call umdns {browse,update,set_config}`；**无 LuCI 页** | **选它** |
| `avahi-dbus-daemon` + `avahi-utils` + `dbus` | ≈ 485 KB | 完整 DNS-SD + reflector/enable-reflector | `avahi-browse/-resolve` | 弃：重、且与 umdns 抢 5353 |
| `avahi-nodbus-daemon` | ≈ 165 KB | avahi 去 dbus；但**没有** avahi-utils（工具依赖 libavahi-client → dbus） | 无 CLI | 弃：省得不多、工具没了 |
| `mdnsd`（Apple mDNSResponder） | ≈ 220 KB（`mdnsd`）+ 工具 `mdns-utils` ≈ 897 KB | 功能最全 | `dns-sd` CLI | 弃：功能超出需要、工具包过大 |
| `mdns-repeater` | **≈ 6 KB** | 仅跨接口转发 5353 组播 | 无 | 备选：将来跨 VLAN 时再加 |

决策：**用 `umdns`**，并因此**不再需要**之前 v1 里"停用 umdns + 让 DAWN 改广播"的绕路：

- `umdns` 出厂配置即 `option jail 1` + `list network lan`，只在 LAN 应答，无需额外改动；
- `dawn` 保持默认 `network_option='2'`（TCP + umdns 发现），两者天然配套；
- 不再安装 `avahi-dbus-daemon` / `avahi-utils` / `dbus`，也不再有 5353 端口互斥问题。

> 诚实边界：`umdns` **不是**完整 DNS-SD 栈 —— 它不替客户端解析别的设备的 `.local`，
> 也不做跨网段反射。它提供的是"路由器自身服务 + DAWN 实例发现 + 一个 ubus 查询入口"。
> 同网段里 macOS/iOS/Windows/Linux 本来就走各自的 mDNS，网关再当 responder 的边际收益有限；
> 真正需要反射时，`mdns-repeater`（6 KB）比 avahi 轻得多。

### 3.4 ttyd：移除

| 方案 | 凭据/会话是否明文 | 代价 | 结论 |
|---|---|---|---|
| 现状：`ttyd + /bin/login` over HTTP | **是**（basic/登录密码与整段 root 会话都在明文 HTTP/WS 里） | — | 否 |
| `ttyd` + TLS + `credential` | 否 | 需管证书（自签证书一般由 uhttpd 生成，不保证存在）；多一套 TLS 面 | 否 |
| `ttyd` 加 ujail 沙箱（v1 方案） | **仍是明文**，jail 不解决传输安全 | 代码量 + 整文件覆盖上游 init | 否 |
| **移除，用 SSH + LuCI + `luci-app-commands`** | SSH 加密 | 失去浏览器内终端 | **是** |

决策：**从包集移除 `ttyd` / `luci-app-ttyd`（含 `luci-i18n-ttyd-zh-cn`）**，并同时删掉 v1 加的
`files/etc/init.d/ttyd` 覆盖与相关 uci-defaults。日常运维仍可用：

- **SSH**（dropbear，加密）——交互式 shell 的正解；
- **LuCI**（含 `luci-app-commands`）——常用操作的按钮化；
- 确有临时需要时可在设备上 `apk add ttyd` 按需装（仓库不再预置）。

> 附注（并列问题，不在本 RFC 范围）：LuCI 本身默认也是 **HTTP**，登录密码同样是明文。
> 若信任边界是"LAN 也不可信"，下一步应给 `uhttpd` 开 HTTPS（自签证书）并考虑只留 HTTPS。
> 这会作为独立改动评估。

## 4. 实施清单

| 路径 | 改动 |
|---|---|
| `.config` | `+luci-app-dawn`、`+dawn`、`+umdns`；`ttyd` / `luci-app-ttyd` / `luci-i18n-ttyd-zh-cn`、`avahi-dbus-daemon` / `avahi-utils` / `dbus` 保持 **not set** |
| `files/etc/uci-defaults/99-nradio-c8-defaults` | 追加 NTP Server 两行 + 一段 mDNS/DAWN 说明；**不再**包含 ttyd / avahi / DAWN 广播覆盖 |
| `README.md` / `docs/operations.md` / 本文 | 文档 |

（v1 曾引入的 `files/etc/avahi/avahi-daemon.conf` 与 `files/etc/init.d/ttyd` 已删除。）

## 5. 验证

- `umdns` 是上游既有包，`.config` 只新增 `umdns`/`dawn` 符号；运行时行为由出厂配置决定（`jail 1` + `network lan`）。
- NTP Server 的两行 UCI 与真机 `/etc/init.d/sysntpd` 已核对（`enable_server:bool:0`、`interface:string`）。
- v1 期间对 ttyd + ujail 做过真机非破坏性验证（jail 内 HTTP 200、WebSocket 收到 `C8 login:`、`jail=0` 可关闭），
  结论是"jail 能做但**不解决明文**"，据此改为移除；该验证记录保留在 §3.4。（相关文件已删。）

**上线后仍需在 CI 产物上验收**：

- `apk list --installed | grep -E 'dawn|umdns'` 命中，且**无** `ttyd`/`avahi`/`dbus`；
- `ps w | grep -E '[u]mdns|[d]awn'` 两者在跑；`ss -lnup | grep 5353` 只有 umdns；
- `uci show dawn | grep network_option` = `2`；`ubus call umdns browse` 无报错（多 AP 时应能看到 `dawn` 公告的服务）；
- `ss -lnup | grep ':123'` 只在 `br-lan` 地址上监听。

## 6. 已知限制 / 取舍

- **升级保留配置时 `uci-defaults` 不会重跑**：NTP 的默认值只在"首启 / 恢复出厂 / `sysupgrade -n`"时生效。存量设备升级后需手工执行（`uci set system.ntp.enable_server=1; uci set system.ntp.interface=lan; uci commit system; /etc/init.d/sysntpd restart`）。
- **`/etc/**` 与 overlay 的覆盖语义**：`files/etc/**` 在 sysupgrade 时会被 overlay 里的旧文件遮住。
- **umdns 能力有限**：不解析他机 `.local`、不跨网段反射；需要时加 `mdns-repeater`。
- **DAWN 单 AP 价值有限**：本机目前单 AP，DAWN 主要做 2.4G/5G 同机 band-steering；多 AP 场景才有完整意义。
- **NTP 精度**：busybox `ntpd` 作为 server 精度一般；有严格需求再换 `chrony`（+132 KB）。
- **移除 ttyd 后没有浏览器终端**：用 SSH / LuCI；设备上仍可 `apk add ttyd` 临时装。
- **LuCI 仍是 HTTP**：登录密码明文，属独立待办。

## 7. 回滚

- DNS-SD：改回 avahi 的话，`.config` 加回 `avahi-dbus-daemon`/`avahi-utils`/`dbus`，
  并停用 umdns、把 `dawn.@network[0].network_option` 设为 `0`（广播）或 `3`（指定 peer）。
- ttyd：`.config` 加回 `ttyd`/`luci-app-ttyd`/`luci-i18n-ttyd-zh-cn` 即可（仓库不再带 init 覆盖）。
- NTP：`system.ntp.enable_server='0'`。
- DAWN：从 `.config` 删 `dawn`/`luci-app-dawn`（`umdns` 可一并删，或留给别的用途）。
