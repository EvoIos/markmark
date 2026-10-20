#!/usr/bin/env bash
# 技能自检：frontmatter 是否完整、名字是否与目录一致、引用的路径是否真的存在。
#
# 技能是会被反复改写的东西，改一个路径忘了同步另一处，agent 就会照着不存在的
# 命令跑。这条脚本把"技能还指向真实文件"变成一次命令。
#
# 用法: scripts/check-skills.sh
# 退出码: 0 全部通过 / 1 有失败

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SKILLS_DIR=".claude/skills"
failures=0
checked=0

fail() {
  printf '  ❌ %s\n' "$1"
  failures=$((failures + 1))
}

field() { # $1=file $2=key
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, key ":") == 1 {
      sub("^" key ":[ ]*", "")
      print
      exit
    }
  ' "$1"
}

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "SKILLS CHECK: PASS (没有 ${SKILLS_DIR}，跳过)"
  exit 0
fi

shopt -s nullglob
skill_files=("$SKILLS_DIR"/*/SKILL.md)
if (( ${#skill_files[@]} == 0 )); then
  echo "SKILLS CHECK: PASS (没有技能)"
  exit 0
fi

echo ""
echo "技能自检"
echo ""

for file in "${skill_files[@]}"; do
  dir="$(basename "$(dirname "$file")")"
  printf '  %s\n' "$dir"
  checked=$((checked + 1))
  before=$failures

  if [[ "$(head -1 "$file")" != "---" ]]; then
    fail "缺少 frontmatter（首行必须是 ---）"
    continue
  fi

  name="$(field "$file" name)"
  description="$(field "$file" description)"

  if [[ -z "$name" ]]; then
    fail "frontmatter 缺少 name"
  elif [[ "$name" != "$dir" ]]; then
    fail "name 是 ${name}，与目录名 $dir 不一致"
  fi

  if [[ -z "$description" ]]; then
    fail "frontmatter 缺少 description"
  else
    desc_len=${#description}
    if (( desc_len > 1024 )); then
      fail "description 过长（$desc_len 字符，上限 1024）"
    fi
    if [[ "$description" != *"Use when"* && "$description" != *"用于"* && "$description" != *"当"* ]]; then
      fail "description 没有写「什么时候该用」（Use when / 用于 / 当…）"
    fi
  fi

  # 引用完整性：技能里写出来的路径必须真实存在
  refs="$(grep -oE '\.claude/skills/[A-Za-z0-9._-]+/SKILL\.md|scripts/[A-Za-z0-9._-]+\.(sh|mjs)|docs/[A-Za-z0-9._/-]+\.md' "$file" | sort -u)"
  if [[ -n "$refs" ]]; then
    while IFS= read -r ref; do
      if [[ ! -e "$ref" ]]; then
        fail "引用了不存在的路径: $ref"
      elif [[ "$ref" == scripts/*.sh && ! -x "$ref" ]]; then
        fail "引用的脚本不可执行: $ref"
      fi
    done <<<"$refs"
  fi

  if (( failures == before )); then
    printf '     ✅ 引用与结构正常\n'
  fi
done

echo ""
if (( failures > 0 )); then
  printf 'SKILLS CHECK: FAIL (%d 项)\n' "$failures"
  exit 1
fi
printf 'SKILLS CHECK: PASS (%d 个技能)\n' "$checked"
