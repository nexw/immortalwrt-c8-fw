#!/usr/bin/env bash
# 在发行版工作树里打开 menuconfig，退出后自动 defconfig 并把 .config 同步回本仓库。
#
# 用法:
#   scripts/menuconfig.sh            # 打开 menuconfig（默认工作树 ~/workspace/immortalwrt-rel）
#   IWRT_DIR=/path/to/tree scripts/menuconfig.sh
#
# 退出 menuconfig 后会自动:
#   1) make defconfig            （把依赖关系规整，清理重复/失效项）
#   2) 把新 .config 复制回仓库根目录
#   3) 用 git diff --stat 显示变化，并列出新增/移除的 CONFIG_PACKAGE_* 项
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IWRT_DIR="${IWRT_DIR:-$HOME/workspace/immortalwrt-rel}"

[ -d "$IWRT_DIR" ] || { echo "找不到工作树: $IWRT_DIR（可用 IWRT_DIR=... 指定）"; exit 1; }
[ -d "$IWRT_DIR/feeds" ] || echo "⚠️  $IWRT_DIR/feeds 不存在，可能还没 ./scripts/feeds update -a"

export PATH="/opt/homebrew/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/gtar/libexec/gnubin:/opt/homebrew/opt/gsed/libexec/gnubin:$PATH"

cd "$IWRT_DIR"

# 用仓库里的 .config 作为起点（避免两边不一致）
if [ -f "$REPO_DIR/.config" ]; then
    cp "$REPO_DIR/.config" "$IWRT_DIR/.config"
    echo "==> 已用仓库 .config 覆盖工作树（$(grep -c '^CONFIG_PACKAGE_.*=y' .config) 个包）"
fi

echo "==> 打开 menuconfig（在菜单里用 / 搜索包名；退出后自动 defconfig + 同步）"
make menuconfig

echo "==> make defconfig"
make defconfig

echo "==> 同步回仓库"
cp "$IWRT_DIR/.config" "$REPO_DIR/.config"
cd "$REPO_DIR"
echo "--- .config 变化统计"
git diff --stat -- .config || true
echo "--- 新增/移除的包（左=旧 右=新）"
git diff -U0 -- .config | grep -E '^[-+]CONFIG_PACKAGE_[A-Za-z0-9_.-]+=y' | sed 's/^-/  - /;s/^+/  + /' | head -80 || true
echo
echo "==> 确认后提交并触发构建:"
echo "    git -C $REPO_DIR add .config && git -C $REPO_DIR commit -m 'build(config): 调整软件包'"
echo "    git -C $REPO_DIR push"
echo "    gh workflow run 'OpenWrt Builder' --ref main -R nexw/immortalwrt-c8-fw"
