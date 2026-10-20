---
description: 按 release 技能走完一次发版（版本号 → CHANGELOG → 测试 → 提交 → 推送 → tag）
argument-hint: "[版本号，例如 2.0.27]"
---

读取并执行 `.claude/skills/release/SKILL.md` 里的步骤，不要凭记忆走旧流程。那份文件里的「什么不算通过」是这套流程的全部价值。

本次版本号：$ARGUMENTS

版本号为空时，按 `CLAUDE.md` 的语义化版本规则从 `CHANGELOG.md` 首条推算，并在动手前说明你定的版本号和理由。

回复按该技能的 `## Reply` 小节给，两次校验的输出要贴原文。
