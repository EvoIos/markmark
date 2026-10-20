#!/usr/bin/env bash
# 发布一致性校验：可重复运行，输出即证据。
#
# 用法:
#   scripts/check-release.sh                 校验 HEAD 对应的版本
#   scripts/check-release.sh 2.0.23          校验指定版本
#   scripts/check-release.sh --allow-dirty   起草阶段，允许工作区有改动
#
# 退出码: 0 全部通过 / 1 有阻断项 / 2 用法错误
#
# 检查: 版本格式、CHANGELOG 首条、CLAUDE.md 当前版本、tag 存在与类型与指向、
#       版本递增且不重号、提交与 tag 身份、工作区是否干净、是否有未推送提交。
# 不检查: 远端 tag 是否已推送（需要网络，这里只读本地仓库）。

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

EXPECTED_EMAIL="${EXPECTED_EMAIL:-zlc@gmail.com}"

failures=0
warnings=0

pass() { printf '  ✅ %s\n' "$1"; }
fail() { printf '  ❌ %s\n' "$1"; failures=$((failures + 1)); }
warn() { printf '  ⚠️  %s\n' "$1"; warnings=$((warnings + 1)); }
info() { printf '  ℹ️  %s\n' "$1"; }

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

# $1 > $2 时返回 0。避开 sort -V 的平台差异。
version_gt() {
  local IFS=.
  local -a a b
  a=($1)
  b=($2)
  local i
  for ((i = 0; i < 3; i++)); do
    if ((10#${a[i]:-0} > 10#${b[i]:-0})); then return 0; fi
    if ((10#${a[i]:-0} < 10#${b[i]:-0})); then return 1; fi
  done
  return 1
}

VERSION_ARG=""
ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "未知参数: $arg" >&2; exit 2 ;;
    *) VERSION_ARG="$arg" ;;
  esac
done

changelog_version="$(grep -m1 -o '\[[0-9][0-9.]*\]' CHANGELOG.md 2>/dev/null | tr -d '[]')"
head_tag_version="$(git tag --points-at HEAD --sort=-v:refname 2>/dev/null | head -1)"
head_tag_version="${head_tag_version#v}"

version="${VERSION_ARG:-${head_tag_version:-$changelog_version}}"
version="${version#v}"
tag="v${version}"

echo ""
echo "发布校验 · ${tag}"
echo "  HEAD: $(git rev-parse --short HEAD 2>/dev/null) $(git log -1 --format='%s' 2>/dev/null | cut -c1-70)"
echo ""

if [[ -z "$version" ]]; then
  fail "无法解析版本号：tag、CHANGELOG.md 都没有给出 X.Y.Z"
  printf '\nRELEASE CHECK: FAIL (1 项阻断)\n'
  exit 1
fi

# 1. 版本格式
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "版本号格式: $version"
else
  fail "版本号不是 X.Y.Z 形式: $version"
fi

# 2. CHANGELOG 首条
if [[ "$changelog_version" == "$version" ]]; then
  pass "CHANGELOG 首条 = $version"
else
  fail "CHANGELOG 首条是 ${changelog_version:-<空>}，应为 $version"
fi

# 3. CLAUDE.md 当前版本
claude_version="$(grep -m1 '当前版本' CLAUDE.md 2>/dev/null | sed 's/.*: *//' | tr -d ' *`')"
if [[ "$claude_version" == "$version" ]]; then
  pass "CLAUDE.md 当前版本 = $version"
else
  fail "CLAUDE.md 当前版本是 ${claude_version:-<空>}，应为 $version"
fi

# 4. tag 状态
tagger=""
head_sha="$(git rev-parse HEAD)"
if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
  tag_type="$(git cat-file -t "$tag")"
  if [[ "$tag_type" == "tag" ]]; then
    pass "tag $tag 是 annotated"
  else
    fail "tag $tag 是 lightweight（应为 annotated，用 git tag -a）"
  fi
  tag_commit="$(git rev-parse "${tag}^{commit}")"
  if [[ "$tag_commit" == "$head_sha" ]]; then
    pass "tag $tag 指向 HEAD"
  else
    fail "tag $tag 指向 ${tag_commit:0:7}，不是 HEAD ${head_sha:0:7}"
  fi
  # lightweight tag 没有 tagger 字段，别把它当成身份错误报出来
  tagger_email="$(git for-each-ref "refs/tags/${tag}" --format='%(taggeremail)')"
  tagger="$(git for-each-ref "refs/tags/${tag}" --format='%(taggername) %(taggeremail)')"
else
  info "tag $tag 尚未创建（起草阶段正常）"
fi

# 5. 版本递增且不重号
prev_tag="$(git tag --sort=-v:refname | grep -vx "$tag" | head -1)"
if [[ -n "$prev_tag" ]]; then
  prev_version="${prev_tag#v}"
  if [[ "$prev_version" == "$version" ]]; then
    fail "版本号与已有 tag 重号: $tag"
  elif version_gt "$version" "$prev_version"; then
    pass "版本递增: $prev_version → $version"
  else
    fail "版本没有递增: 上一个 tag 是 ${prev_tag}，当前 $version"
  fi
else
  info "没有更早的 tag，跳过递增检查"
fi

# 6. 身份
last_ident="$(git log -1 --format='%an <%ae>' 2>/dev/null)"
if [[ "$last_ident" == *"$EXPECTED_EMAIL"* ]]; then
  pass "HEAD 提交身份: $last_ident"
else
  fail "HEAD 提交身份是 ${last_ident:-<空>}，应为 <$EXPECTED_EMAIL>"
fi
if [[ -n "${tagger_email:-}" ]]; then
  if [[ "$tagger" == *"$EXPECTED_EMAIL"* ]]; then
    pass "tag 身份: $tagger"
  else
    fail "tag 身份是 ${tagger}，应为 <$EXPECTED_EMAIL>"
  fi
fi
if git log --all --format='%an <%ae>|%cn <%ce>' 2>/dev/null | grep -qi 'itiger'; then
  fail "历史里存在 itiger（公司邮箱）身份"
else
  pass "历史无 itiger 身份"
fi

# 7. 工作区
dirty_count="$(git status --porcelain | wc -l | tr -d ' ')"
if [[ "$dirty_count" == "0" ]]; then
  pass "工作区干净"
elif [[ $ALLOW_DIRTY -eq 1 ]]; then
  info "工作区有 $dirty_count 处改动（--allow-dirty，起草阶段允许）"
else
  fail "工作区有 $dirty_count 处未提交改动"
fi

# 8. 未推送提交
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [[ -n "$upstream" ]]; then
  ahead="$(git rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)"
  if [[ "$ahead" == "0" ]]; then
    pass "HEAD 已推送（${upstream}）"
  else
    fail "有 $ahead 个提交未推送到 $upstream"
  fi
else
  warn "没有上游分支，跳过推送检查"
fi

echo ""
if [[ $failures -eq 0 ]]; then
  printf 'RELEASE CHECK: PASS (%s)\n' "$tag"
  [[ $warnings -gt 0 ]] && printf '  %d 项警告\n' "$warnings"
  exit 0
fi
printf 'RELEASE CHECK: FAIL (%d 项阻断)\n' "$failures"
exit 1
