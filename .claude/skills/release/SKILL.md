---
name: release
description: MarkMark 的版本发布流程：定版本号、写 CHANGELOG、同步版本号、跑测试、提交推送、打 annotated tag。Use when 发版、打 tag、改版本号，或说「按流程收尾」「提交并打 tag」。
---

# Release

**你负责这次发布。判断留在 `CLAUDE.md`，步骤在这里。**

发布是单向门：tag 推上去再改就得升版本。所以每做完一步就校验一次，不要攒到最后。

## 步骤

1. **定版本号。** 递增规则和本项目的历史习惯见 `CLAUDE.md` 的「版本与发布流程」，这里不重复。拿不准就停下来问，不要自行沿用旧习惯。

2. **改 `CHANGELOG.md`。** 在顶部新增 `## [X.Y.Z] - YYYY-MM-DD`，按 `新增` / `修复` / `变更` 分类。写清现象、根因、改法。
   **只列出改了哪些文件不算写完**，下一个维护者要能从这里看懂为什么改。

3. **同步 `CLAUDE.md` 的「当前版本」。** 其他文件不要手改版本号：`scripts/Info.plist` 里的 `__VERSION__` 由 `build-app.sh` 构建时填充。

4. **跑测试。**
   ```bash
   swift test --disable-sandbox --cache-path .build/swiftpm-cache
   ```
   `MarkdownReaderKitTests` 和 `MarkMarkTests` 两个 target 全绿才继续。
   **沙箱化的 agent 会话里不带 `--disable-sandbox` 会报 `sandbox_apply: Operation not permitted`**，那是「测试没跑起来」，不是「测试失败」，更不算通过。只跑了一个 target 也不算通过。

5. **先校验一次。**
   ```bash
   ./scripts/check-release.sh X.Y.Z --allow-dirty
   ```
   它会把 CHANGELOG 没写、版本号没同步、tag 状态、身份问题一次列全。起草阶段允许工作区脏，其他项必须绿。

6. **提交。** `git add -A`，Conventional Commits 前缀（`feat:` / `fix:` / `docs:` / `refactor:` / `test:` / `chore:`），标题带版本号，正文用中文说明原因。

7. **推送分支。** `git push origin main`。

8. **打 annotated tag 并推送。**
   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```
   **`git tag vX.Y.Z`（不带 `-a`）不算**：lightweight tag 没有 tagger，校验脚本会拦。

9. **再校验一次，这就是完成证据。**
   ```bash
   ./scripts/check-release.sh
   ```
   必须输出 `RELEASE CHECK: PASS`。
   **PASS 以外的任何结果都不算发布完成**，包括「应该没问题」「刚才跑过了」。

## 不做

对外发布（创建 GitHub Release、上传 `MarkMark.dmg` / `MarkMark.zip`、跑 `release-local.sh`）必须先问。改写已推送历史、删除已推送 tag、`push --force` 一律禁止。详见 `CLAUDE.md` 的「三条硬性约束」和「不做的事」。

## Reply

版本号、CHANGELOG 新增条目的标题、`swift test` 的通过情况、两次校验各自最后一行原文。

跳过的步骤逐条写明原因，不要静默省略。
