---
description: 按 bugfix 技能修一个缺陷（真实 surface 复现 → 根因 → 修 → 同 surface 验证）
argument-hint: "[现象或 issue 描述]"
---

读取并执行 `.claude/skills/bugfix/SKILL.md`，从第 0 步（确认包不是旧的）开始，不要跳步。

要修的问题：$ARGUMENTS

动手前先查 `docs/verification.md`：这次改动属于哪一类，就该跑哪一条验证命令。不知道该跑哪条时，先问，不要用「应该没问题」代替。

复现不了不要直接回头问人：先确认是否重建过、是否走了另一条渲染路径、是否被 `UserDefaults` 里记住的状态影响。
