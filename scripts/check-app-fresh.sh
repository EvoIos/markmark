#!/usr/bin/env bash
# 判断 MarkMark.app 是不是由当前源码构建的。
#
# 验证真实 app 之前先跑它。拿旧包验证新代码，结论会一直是「修好了」。
#
# 用法:
#   scripts/check-app-fresh.sh                  检查仓库根的 MarkMark.app
#   scripts/check-app-fresh.sh path/to/MarkMark.app
#
# 退出码: 0 新鲜 / 1 过期或缺失 / 2 无法判断

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/MarkMark.app}"
BIN_PATH="$APP_PATH/Contents/MacOS/MarkMark"
PLIST="$APP_PATH/Contents/Info.plist"

fail() {
  printf '  ❌ %s\n' "$1"
  printf '\nAPP FRESH: STALE\n'
  exit 1
}

echo ""
echo "构建新鲜度检查"
echo "  app: $APP_PATH"
echo ""

if [[ ! -d "$APP_PATH" ]]; then
  fail "没有这个 .app，先跑 ./build-app.sh -s"
fi
if [[ ! -x "$BIN_PATH" ]]; then
  fail "找不到可执行文件 $BIN_PATH"
fi

# 1. 架构：Intel 是已知盲区，只构建 arm64 的包在 Intel 上打不开
archs="$(lipo -archs "$BIN_PATH" 2>/dev/null || echo unknown)"
missing=""
for want in arm64 x86_64; do
  [[ "$archs" == *"$want"* ]] || missing="$missing $want"
done
if [[ -n "$missing" ]]; then
  fail "架构不全，缺:$missing（当前: $archs）。Intel 与 Apple Silicon 都要能跑"
fi
printf '  ✅ 架构: %s\n' "$archs"

# 2. 新鲜度：可执行文件必须晚于它应该包含的源码
newer_files="$(find "$ROOT_DIR/Sources" "$ROOT_DIR/Package.swift" "$ROOT_DIR/scripts/Info.plist" \
  -type f -newer "$BIN_PATH" -print 2>/dev/null | head -5)"
if [[ -n "$newer_files" ]]; then
  printf '  ❌ 这些文件比 app 新，说明包是旧的:\n'
  while IFS= read -r f; do
    printf '       %s\n' "${f#"$ROOT_DIR"/}"
  done <<<"$newer_files"
  printf '\nAPP FRESH: STALE\n'
  printf '  重新构建: ./build-app.sh -s\n'
  exit 1
fi
printf '  ✅ 可执行文件不早于 Sources/ 与 Package.swift\n'

# 3. 版本只做提示：跨版本构建不影响 bug 验证
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo '?')"
changelog_version="$(grep -m1 -o '\[[0-9][0-9.]*\]' "$ROOT_DIR/CHANGELOG.md" 2>/dev/null | tr -d '[]')"
if [[ -n "$changelog_version" && "$app_version" != "$changelog_version" ]]; then
  printf '  ℹ️  包内版本 %s，CHANGELOG 首条 %s（不影响验证，发版前会对齐）\n' "$app_version" "$changelog_version"
else
  printf '  ✅ 版本: %s\n' "$app_version"
fi

printf '\nAPP FRESH: PASS\n'
