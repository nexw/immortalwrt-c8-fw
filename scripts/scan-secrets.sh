#!/usr/bin/env bash
# scan-secrets.sh — 推送前隐私扫描（在仓库根目录运行）
# 退出码: 0 = 无命中；1 = 有命中（不要推送）
set -uo pipefail
FOUND=0

# 结构性高危模式：身份证/IMEI(15位)/ICCID(19-20位)/MAC/手机号/私钥/PSK/token
PATTERNS=(
  '[0-9]{15}'                                   # IMEI / ICCID 片段
  '[0-9]{19,20}'                                # ICCID / 长数字 ID
  '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'          # MAC / 蓝牙地址
  '(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)'          # 中国大陆手机号
  'BEGIN [A-Z ]*PRIVATE KEY'                    # 私钥
  '(fac_key|fac_mac|pswd|passwd|password|preshared|psk|secret|token|api[_-]?key)[[:space:]]*[:=]' # 凭据键
  'gqaaa|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}'  # 云/CI 令牌
)

FILES=$(git ls-files --cached --others --exclude-standard | grep -vE '\.(png|jpg|jpeg|gif|ico|gz|zst|xz|dtb|bin|pcap)$' || true)
# 白名单：上游第三方参考文件 / 自检脚本 / 已脱敏文档（占位符 MAC、UCS2 抽样、GitHub 表达式等）
ALLOW_RE='docs/refs/(01_leds|02_network|platform|emmc)\.|docs/refs/modem-sms-design\.|scripts/scan-secrets\.sh|aa:bb:cc:dd:ee:ff|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff|github\.token|xx:xx:xx|XX:XX|已脱敏|xxxxxxxxxx|7c:xx|\$\{\{'
[ -z "$FILES" ] && { echo "无待检文件"; exit 0; }

for p in "${PATTERNS[@]}"; do
  hits=$(echo "$FILES" | xargs grep -InE -- "$p" 2>/dev/null | grep -vE "$ALLOW_RE" || true)
  if [ -n "$hits" ]; then
    echo "⚠️  命中模式: $p"
    echo "$hits" | head -10
    FOUND=1
  fi
done

# 白名单：允许出现的位置（文档里已脱敏的占位符）
echo "--- 其他命中（含文档，请人工确认是否已脱敏）---"
echo "$FILES" | xargs grep -InE -- '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}|[0-9]{15}|[0-9]{19,20}' 2>/dev/null | grep -vE "$ALLOW_RE" | head -20

if [ $FOUND -eq 1 ]; then
  echo; echo "❌ 存在疑似隐私/凭据，请脱敏后再推送。"
  exit 1
fi
echo; echo "✅ 扫描通过（仍建议人工复核上面的列表）"
