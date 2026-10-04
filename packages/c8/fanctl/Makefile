#
# fanctl —— NRadio C8 (WT9104 / C8-688) PWM 风扇温控（userspace 兜底实现）
#
# 为什么做成 apk 包，而不是继续放 files/ 覆盖：
#   * files/ 里的内容不被 apk 记账（实机：apk info -W /usr/bin/fanctl →
#     "Could not find owner package"）：没有版本、无法单独升级、无法声明依赖；
#   * 依赖项（kmod-hwmon-pwmfan / kmod-gpio-pwm）只能靠包声明，否则只能人肉写进 .config；
#   * /etc/config/fancontrol 需要在包内声明为 conffile。
#
# 配置生效路径（procd 触发器，非重启）：
#   LuCI / `/sbin/reload_config`（md5 比对后发 config.change）→ procd 触发 reload
#   （命令行 `uci commit` 自身不发事件：该构建的 uci/libuci 未链 libubus，已实测）
#   → /etc/init.d/fancontrol reload → reload_service() → procd_send_signal
#   → fanctl daemon 收到 SIGHUP（实例的 reload_signal=HUP）→ 原地重读配置
#
include $(TOPDIR)/rules.mk

PKG_NAME:=fanctl
PKG_VERSION:=1.1.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=JohnnyLo <johnny@nexwy.me>

include $(INCLUDE_DIR)/package.mk

define Package/fanctl
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=PWM 风扇温控（NRadio C8，userspace 兜底 + procd 托管）
  URL:=https://github.com/nexw/immortalwrt-c8-fw
  DEPENDS:=+kmod-hwmon-pwmfan +kmod-gpio-pwm
  # 纯 shell，目标无关。必须写在 Package 块内：写在块外的全局 PKGARCH
  # 会被 include/package-defaults.mk 里 Package/Default 的
  # `PKGARCH:=$(ARCH_PACKAGES)` 覆盖掉（树里 103 个包都写在块内，只有 1 个写在外面）。
  PKGARCH:=all
endef

define Package/fanctl/description
 NRadio C8 (WT9104 / C8-688) 的 PWM 风扇闭环温控。

 DTS 里已有 pwm-fan 节点（pwmchip0/pwm0，25 kHz），但 cpu-thermal 的 cooling-maps
 只绑了 WiFi、没绑风扇，内核 governor 不会驱动风扇，所以用 userspace 补上这一段：
 读 thermal_zone0 → 查温度-转速曲线（线性插值）→ 写 PWM。

 kernel_driver='hwmon'（默认）时，若内核 pwmfan 驱动接管了 pwm0，则改走
 /sys/class/hwmon/*/pwm1（0-255）继续控温；'yield' 则让位给内核 governor。

 由 procd 托管：崩溃 5 s 后重启、1 h 内最多 5 次；uci 变更通过触发器原地重载配置。
endef

define Package/fanctl/conffiles
/etc/config/fancontrol
endef

# 纯文件包：没有源码、没有自己的 Makefile，必须屏蔽默认的 Build/Compile。
# 否则会执行 include/package.mk:396 的
#   Build/Compile = $(call Build/Compile/Default,)
# 即 `make -C $(PKG_BUILD_DIR)`，而 $(PKG_BUILD_DIR) 是空目录，报
#   make[4]: *** No targets specified and no makefile found.  Stop.
#   ERROR: package/feeds/nrlocal/fanctl failed to build.
# 于 world 末尾整包失败（实测 2026-10-03 run 37092979877）。
# 同树正例：package/emortal/cpufreq/Makefile
# 注：Build/Install 不用管 —— package.mk:397 是
#   Build/Install = $(if $(PKG_INSTALL),$(call Build/Install/Default,))
# 本包没设 PKG_INSTALL，所以它是空的。
define Build/Compile
endef

define Package/fanctl/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) ./files/usr/bin/fanctl $(1)/usr/bin/fanctl
	$(INSTALL_BIN) ./files/etc/init.d/fancontrol $(1)/etc/init.d/fancontrol
	$(INSTALL_CONF) ./files/etc/config/fancontrol $(1)/etc/config/fancontrol
endef

$(eval $(call BuildPackage,fanctl))

# call BuildPackage - OpenWrt buildroot signature
#
# ⚠️ 上面这行注释不是装饰，必须有：include/scan.mk 生成包列表时用的是
#   find -L <dir> -name Makefile | xargs grep -aHE 'call (Build/DefaultTargets|BuildPackage|KernelPackage)'
# 即在 Makefile 文本里 grep "call BuildPackage" 字样。本包的包定义写在自己的
# $(eval $(call BuildPackage,...)) 里，所以本来就命中；但**不要删掉**这行注释，
# 它与 packages/luci/* 保持同一约定（那边定义在 luci.mk 里，删了就整包消失）。
