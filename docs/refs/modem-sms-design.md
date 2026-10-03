# 5G 模组短信（SMS）管理方案

> 2026-10-02。目标：给 NRadio C8 / MT5700M 补上短信管理（查看/发送/删除/新短信通知）。
> 结论：**模块能力齐全，可用纯 Python + LuCI 自研，不需要厂商那个闭源 ELF。**

## 1. 厂商/Manper 是怎么做的

| 来源 | 组件 | 说明 |
|---|---|---|
| 原厂 1.9.4.n1.c6（A 槽） | `/usr/sbin/smsd` | **45 KB ELF，闭源**。`/etc/init.d/smsd` 按 `cpecfg.cpesim` 规则给每个 SIM 起一个 `smsd -i <iface>`（procd 托管），`/etc/config/smsd` 只有一行 `config sms 'all'` |
| 原厂 | `luci-app-nradio-sms` → `view/nradio_sms/index.htm` | 前端页面 |
| 原厂 | `/usr/sbin/cimd` | 接口监控/抓包相关，**与短信无关**（别被名字误导） |
| Manper（Mwrt） | `smstrun.py`、`sms_tool2`、`setsmstitle.sh`、`smstrun-title.conf` | 转发脚本 + 一个 ELF + 标题配置；`smstrun.py` **无 LICENSE** |

结论：**没有可用的公开源码**。厂商 `smsd` 还绑定了他们的 `cpecfg/cpesim` 配置结构，
并会拉起一串厂商组件，不适合搬进我们的树。Manper 那套只能当参考。

## 2. 模块能力实测（MT5700M-CN / V200R001C20B024，AT 口 `/dev/ttyUSB1`）

| AT | 实测结果 | 含义 |
|---|---|---|
| `AT+CSMS?` | `+CSMS: 1,1,1,1` | 支持 SMS（含广播/状态报告） |
| `AT+CPMS?` | `+CPMS: "SM",2,50,"SM",2,50,"SM",2,50` | SIM 存储 **2/50 条**；`AT+CPMS=?` 还支持 `"ME"` |
| `AT+CMGF?` | `+CMGF: 0` | 当前 PDU 模式，可切 `1` = 文本模式 |
| `AT+CSCS=?` | `("IRA","UCS2","GSM")` | 支持 UCS2 → **中文可收发** |
| `AT+CMGL=?` | `(0-4)` | 按状态列短信 |
| `AT+CMGD=?` | `(0,1),(0-4)` | 按 index 删，或按 flag(0/1/4) 批量删 |
| `AT+CNMI?` | `0,0,0,0,0` → 可设 `2,1,0,0,0` | 能拿到 `+CMTI: "SM",<idx>` 新短信通知 |
| `AT+CSCA?` | `+8613800760500,145` | SMSC 已由运营商写入，直接能发 |

## 3. 可行性验证（真机跑过，非推测）

切到 `AT+CMGF=1` + `AT+CSCS="UCS2"` 后：

```
AT+CMGL="ALL"
+CMGL: 0,"REC READ","00310030003600390030003000300030003000300030",,"26/10/02,12:32:32+32"
4E2D56FD79FB52A8
+CMGL: 1,"REC READ","00310030003600390030003000300030003000300030",,"26/10/02,12:32:32+32"
30104E2D56FD79FB52A8...
```

- 号码 `0031...0030` → `10690000000`（UCS2 hex；示例已脱敏）
- 正文 hex 解出中文正常（`4E2D56FD79FB52A8` = 中国移动）
- `AT+CMGR=0` 单条读取正常；`AT+CNMI=2,1,0,0,0` 设置成功
- 验证后已还原现场（`CMGF=0`/`CNMI=0`/`CSCS=IRA`），**短信内容未改动**

> 上例的号码与正文已脱敏为示例值（UCS2 编码格式与实际 AT 输出一致）。

结论：**收发/列表/删除/通知四条路都通，全部是标准 3GPP AT，无需 PDU 手写**。

## 4. 方案对比

| 方案 | 做法 | 评价 |
|---|---|---|
| A. 搬厂商 `smsd` | 复制 45 KB ELF + 依样画葫芦的 init.d | ❌ 无源码、绑厂商配置结构、要拉起其它厂商组件；ABI/维护都不可控 |
| B. 移植 Manper `smstrun.py` + `sms_tool2` | 只做转发 | ❌ `sms_tool2` 是 ELF 无源码；`smstrun.py` 无 LICENSE（法务风险） |
| C. **自研 `mt5700-sms`（推荐）** | 复用仓库现有 `files/usr/lib/mt5700/serialport.py`（纯 fd，无 pyserial），实现 CLI + 可选守护 + LuCI 页 | ✅ 零新增依赖（python3 已在固件里）、可控、可测、License 干净 |

## 5. 推荐实现（方案 C）

### 5.1 CLI：`/usr/bin/mt5700-sms`

```
mt5700-sms list [all|unread|read|sent]      # 列表：index/状态/号码/时间/摘要
mt5700-sms read <index>                     # 单条完整内容
mt5700-sms send <号码> <正文>               # 发送（UCS2，中文OK）
mt5700-sms delete <index>|read|all          # 删除（read=flag0, all=flag4）
mt5700-sms count                            # 未读数（给 LED/通知用）
mt5700-sms watch                            # 常驻：AT+CNMI=2,1 收 +CMTI，可挂钩子
```

实现要点：
- **统一走 UCS2**：`AT+CMGF=1` + `AT+CSCS="UCS2"`，号码与正文都 `bytes.fromhex(...).decode('utf-16-be')` / 反向编码。ASCII 也这么走，省得两套分支
- **AT 口是共享资源**：与面板 `zinfo_mt5700.sh`、`mt5700-at`、`mt5700-wan-check` 抢 `/dev/ttyUSB1` → 加 `/var/run/mt5700-at.lock` 互斥（用一个 mkdir 锁，busybox 兼容）
- **发送流程**：`AT+CMGS="<num>"` → 等 `>` → 发 hex 正文 + `\x1a` → 读 `+CMGS: <n>` / `+CMS ERROR`
- **watch 守护**：procd 托管，`AT+CNMI=2,1,0,0,0`，读 `+CMTI:` → `logger` + 可选钩子脚本 `/etc/mt5700-sms.hook`（转发/通知都挂这里，保持内核干净）
- **容量**：SIM 只有 50 条。建议提供 `mt5700-sms trim <N>`（保留最近 N 条），**默认关闭**，由用户显式开启
- 只读优先：`list/read/count` 不改任何模块状态之外的东西；不改短信内容、不动网络

### 5.2 前端两种做法

1. **先用 `luci-app-commands` 挂钩子**（零代码）：把 `list` / `count` 挂成快捷命令，立刻能用
2. **再补一个小 LuCI 页**（推荐最终态）：仓库现在已经打开了 `lua` + `luci-compat` + `luci-lua-runtime`
   （因为 luci-app-WTModem/cellscan 需要），所以可以直接写个轻量 Lua 模板页
   （收件箱列表 + 详情 + 发送表单 + 删除），挂在 `admin → 内置蜂窝 → 短信`

### 5.3 与现有组件的边界

- 数据面/AT 口归属：`mt5700-*` 仍是唯一"写"AT 的组件；`mt5700-sms` 只做短信域的命令，且加锁
- LED：可用现有 `ledctl` 在收到未读短信时闪 `blue:indicator-1`（由 hook 触发）
- 不改 `/etc/config/network`、不碰 `cpe-pwr`/SIM 选择

## 6. 需要你决定的两点

1. **新短信要不要通知/转发？**
   - 只记日志 + 闪灯（最简）
   - 转发到 HTTP（如企业微信机器人 / 自建 webhook）—— 需要在 hook 里带 URL/token，注意别入库
2. **要不要自动清理旧短信？**（SIM 仅 50 条）
   - 不清理，满了由用户手动删
   - 保留最近 N 条自动清理

确认后我可以按 5.1 + 5.2(1) 先落地 CLI 与快捷命令，再补 LuCI 页面。
