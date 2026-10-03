# immortalwrt-c8-fw — NRadio C8（WT9104 / C8-688）5G CPE 固件

为 **NRadio C8** 配置并构建 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 固件。
本仓库保存构建所需的一切：构建配置（`.config`）、机型补丁（`patches/`）、
首启默认值（`files/`）与本地软件包（`packages/`）。产物是可直接 `sysupgrade` 的整机固件。

## 设备

| 项 | 值 |
|---|---|
| 整机 | NRadio C8（ODM 板名 `WT9104`，SKU `C8-688`，UI 型号 `C8-668GL`） |
| 机型代号 | `nradio,c8-668gl`（`mediatek/filogic` target） |
| SoC | MediaTek MT7981（2× Cortex-A53） |
| 内存 / 存储 | 1 GB DDR + 8 GB eMMC（GPT，A/B 双槽） |
| 交换 | MT7531（lan1/2/3 + lan4=2.5G）+ gmac1 2.5G（WAN，接 5G 模组） |
| WiFi | MT7981 内置 2×2 双频（2.4G + 5G），mt76 驱动 |
| 5G 模组 | **TD Tech MT5700M-CN**（USB `3466:3301`，UNISOC 体系） |
| 模组接口 | 2× cdc_ncm（`eth2`，备用数据面）+ 5× usbserial（`ttyUSB0..4`，**AT = ttyUSB1 @115200**） |
| 模组控制 | 串口 AT，或模块自带 **AT-over-TCP `192.168.8.1:20249`**（数据面 `eth1` 可达） |
| 按键 / LED | `reset`(pio1) + `wps`(pio9)；面板 LED：status(10)/cmode5(11)/cmode4(12)/wifi(34) |
| 其它 GPIO | cpe-pwr(31)、cpe-sel0(29)、cpe-sel1(30)、fan-hw(27)、fan-fg(28)、PWM 风扇(25 kHz) |
| 默认网络 | LAN `192.168.66.1`，hostname `C8`，时区 CST-8 |

> ⚠️ 该模块**只有 NCM / 私有串口两种 USB 组合，没有 QMI/MBIM/ECM**，因此不能走 `uqmi/umbim`
> 原生拨号；数据面走模块侧的 IP 直通（见下）。更详细的硬件基线与勘探记录见 `docs/refs/`。

## 固件基线

- 源码：`immortalwrt/immortalwrt` **发行版 tag `v25.12.2`**（openwrt-25.12 的发行点；feeds 按 commit 固定，可复现）
- 机型：`CONFIG_TARGET_PROFILE="DEVICE_nradio_c8-668gl"`（上游已收录该机型）
- **中文界面**：`default-settings-chn` + `luci-i18n-*-zh-cn`，并在 `files/` 固定 `luci.main.lang=zh_cn`、时区 CST-8、国内 NTP
- **IPv6**：odhcpd RA/NDP 中继（`dhcp.{wan,lan}.{ra,dhcpv6,ndp}=relay` + `wan.master=1`）——
  模组只下发运营商的 /64、**无 DHCPv6-PD**，LAN 客户端直接使用上游 `2409:…/64`
- **无线**：首启固定 `country=CN`、2.4G `ch11/HE20`、5G `ch149/HE80`（实测环境最优）；
  出厂 eeprom 的 WiFi MAC 非法（驱动每次启动随机 BSSID），按 label MAC 派生固定 BSSID（lan=label，wan=label+2，wifi 取 +1/+3）
- **数据面**：默认 5G **IP 直通**（模组 `AT^TDCFG` mode 3），路由器 WAN 直接持有运营商 IP，全网单层 NAT
- **明确不含**：Docker / 容器、Samba4 / KSMBD、aria2、minidlna、smartdns 等 NAS / 娱乐组件

## 预置软件包

按用途分组（完整清单一 `.config` 为准）：

| 用途 | 代表包 |
|---|---|
| 系统 / LuCI | `luci`（`luci-mod-*`）、`luci-theme-argon` + `luci-app-argon-config`、`luci-app-commands`、`luci-app-package-manager` |
| 网络 | `dnsmasq-full`、`odhcpd-ipv6only`、`firewall4` + `nftables-json`、`kmod-nft-fullcone`、`kmod-nf-flow`、`sqm-scripts`、`miniupnpd-nftables`（默认关）、`ddns-scripts-{aliyun,cloudflare,dnspod}` |
| 局域网服务 | `umdns`（mDNS/DNS-SD，仅 `lan`；与 DAWN 配套）、NTP Server（busybox `sysntpd`，仅 `br-lan`） |
| 5G / 模组 | `kmod-usb-serial-option`、`kmod-usb-net-cdc-ncm`、`kmod-usb-net-qmi-wwan`、`usbutils`、`picocom`、`python3-light` + `python3-pyserial`、`socat` |
| 无线 | `kmod-mt7915e`、`wpad-openssl`、`iw`、`wireless-regdb`、`wifischedule`、`luci-app-dawn`（802.11k/v 漫游；其依赖 `umdns` 同时充当 mDNS/DNS-SD，见 RFC-003） |
| 风扇 / LED | `kmod-hwmon-pwmfan`、`kmod-gpio-pwm`、`kmod-leds-gpio`、`kmod-ledtrig-network`，加本地包 `fanctl` / `ledctl` |
| 存储 / overlay | `f2fs-tools`、`kmod-fs-f2fs`、`kmod-fs-ext4`、`block-mount`、`e2fsprogs` |
| 设备面板 | `luci-app-wtmodem`（模组状态 / 信号 / SIM）、`luci-app-cellscan`（邻区扫描） |
| 监控 / 运维 | `collectd` + `luci-app-statistics`、`nlbwmon`、`lldpd`、`watchcat`、`luci-app-wol` + `etherwake`、`htop`、`tmux`、`iperf3`、`tcpdump` |

## 本仓库对上游的改动

| 路径 | 内容 |
|---|---|
| `patches/` | 机型 DTS 修正（WiFi LED pio13→**34**、`cpe-sel1`、`fan-hw`/`fan-fg`、`pwm-fan`）与 `bdinfo fac_mac` 修复 |
| `files/` | 首启默认值；MT5700M 工具链（`mt5700-at` / `-status` / `-simsel` / `-sms` / `-passthrough` / `-wan-check` 等）与自写 init/hotplug；`wifi-survey` 无线实测 |
| `packages/` | 本地 apk 包：`fanctl`（风扇温控）、`ledctl`（夜间熄灯）、`luci-app-wtmodem`、`luci-app-cellscan` |
| `.config` | 裁剪后的软件包集合 + 机型 profile |
| `.github/` | 构建 workflow 与宿主 apt 依赖清单（`apt-deps.txt`） |

补丁与包的设计依据见 `docs/RFC-nradio-c8-native-firmware.md`（RFC-001）与
`docs/RFC-002-led-fan-packaging.md`（RFC-002）、`docs/RFC-003-gateway-services.md`（RFC-003，
mDNS(DNS-SD) / NTP Server / DAWN）。
`patches/` 里两条补丁均已实机验证（2026-10-01 首刷）：
`board_name=nradio,c8-668gl`，DTS 的按键 / LED / `gpio-export` 全部按预期注册。

## 构建

触发 CI 构建（**OpenWrt Builder** workflow），完成后从 Releases 取
`openwrt-mediatek-filogic-nradio_c8-668gl-squashfs-sysupgrade.bin`。
Release 说明里会给出本次提交内容、构建信息与产物校验和。

本地调整包集：用 `scripts/menuconfig.sh` 在 immortalwrt 工作树里开 menuconfig，
退出后自动 `defconfig` 并把 `.config` 同步回本仓库。
刷机与回滚方式见 [`docs/operations.md`](docs/operations.md)。

## 目录结构

```
.config                 构建配置（机型 + 软件包集合）
patches/                机型补丁（对 immortalwrt 源码）
files/                  首启默认值 / 模组工具链（进 rootfs）
packages/               本地 apk 包（经 src-link nrlocal feed 进构建）
scripts/                本机与设备端运维脚本（见下）
docs/                   RFC、实机基线参考（refs/）、设备运维手册
.github/                CI（构建 / 只读环境探针 / tmate 调试）与 apt 依赖清单
```

`scripts/` 只放需要独立运行的工具：`menuconfig.sh`（本机调包集）、
`c8-hw-inventory.sh` / `c8-backup.sh`（只读清点与备份）、`mt5700-at.py`（只读 AT 探针）、
`scan-secrets.sh`（推送前隐私扫描）；另有两个**会写设备**的脚本
（`c8-deploy-ctl.sh` 推控制脚本、`mt5700-fw-update.sh` 刷模组固件），风险自担。

## 来源与致谢

- [immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt)（GPL-2.0）—— 固件基座
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)（MIT）—— 本仓库的构建
  workflow 骨架演化自该项目的模板，特此感谢
- [jerrykuku/luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)、
  [newton-miku/luci-app-cellscan](https://github.com/newton-miku/luci-app-cellscan)（GPL-3.0）、
  `luci-app-WTModem`（Manper rebuild，Apache-2.0）—— 主题与 LuCI 应用

## 许可

本仓库自身以 **MIT** 发布，见 [`LICENSE`](LICENSE)（保留上游 P3TERX 的 MIT 声明）。
`packages/` 下各组件按其自身 LICENSE（`fanctl` / `ledctl` 为 MIT、`luci-app-cellscan` 为 GPL-3.0、
`luci-app-wtmodem` 为 Apache-2.0）；`patches/` 是对 GPL-2.0 的 immortalwrt 源码的改动。
