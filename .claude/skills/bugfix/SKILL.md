---
name: bugfix
description: 修 MarkMark 的缺陷：先在真实 app 上复现、二分定位根因、修掉、再在同一个 surface 上验证。Use when 修 bug、复现问题、排查异常行为，或说「这个 bug 修一下」。
---

# Bug fix

**你负责这条因果链。复现、根因、修复、验证都在你手上，不转交给用户。**

每一行改动的依据必须是运行时证据。「加一层判断可能有用」是假设，不是修复；证据否掉了假设，就把它带来的改动撤掉。

## 步骤

0. **确认包是当前代码构建的。**
   ```bash
   ./scripts/check-app-fresh.sh
   ```
   不是 `PASS` 就先 `./build-app.sh -s` 重建。
   **拿旧包验证新代码等于没验证**，而且结论会一直是「修好了」。

1. **在真实 surface 上复现。**`swift test` 测的是分支行为，不是 bug 不存在。

   常用手段：
   - 文件与窗口路由：`open -a MarkMark.app <file>`，再用 `defaults read com.ft07.markmark` 读落盘状态；窗口数量用 `pgrep -x MarkMark` + CGWindowList（`scripts/open-request-regression.sh` 里有现成实现）
   - 渲染 / 高亮 / 主题 / diff：`screencapture -x` 截图对比，必要时往 WKWebView 注 JS 读 DOM
   - Quick Look：`qlmanage -t -s 1200 -o /tmp <file>`（主 app 正常不代表扩展正常）
   - 启动 / 崩溃：`log show --predicate 'process == "MarkMark"' --last 5m`

   复现不了先怀疑自己：是不是没重建、是不是走了另一条渲染路径、是不是被记住的状态影响了（`defaults delete com.ft07.markmark` 后重试）。
   **只有确认控制面到不了目标，才回头问用户**，并且要说明已经试过什么。

2. **二分定位根因。**先列候选假设，再逐个排除；每次取能砍掉最多问题空间的那一刀。状态不清楚就加日志或断点读出来，不要猜。
   修的是第一个出错的地方，不是它下游的症状。guard 只在被处理的状态合法时才算修复。

3. **把复现变成可重跑的东西。**稳定复现之后，把它写成一条命令或脚本放进 `scripts/`。
   **靠手点两次得出的结论不算验证**，下次没人能重跑它。

4. **修。**最小改动。加 `if` 之前先问：这个状态本来合法吗？不合法就该在源头消灭，而不是在下游兜住。

5. **在同一个 surface 上验证。**原来的复现现在必须通过。
   **「不确定」「换了个 surface 试的」「单测过了」都不算通过。** 跨 surface 通过要明说，并说明另一个 surface 为什么测不到。

6. **提交顺序。**红灯的复现提交在前，修复在后。历史本身就证明了 bug 存在过。

7. 收尾走 `.claude/skills/release/SKILL.md`。

## 这个项目的验证盲区

- **Universal binary**：Apple Silicon 上跑通不等于 Intel 能跑。`lipo -archs` 必须同时含 `x86_64` 和 `arm64`，`check-app-fresh.sh` 会拦。
- **核心渲染在 WKWebView 里**：高亮、主题、diff、Mermaid、KaTeX 的改动 `swift test` 一个字都测不到，必须截图或读 DOM。
- **Quick Look 是独立进程**：主 app 正常不代表预览正常。
- **`.hiddenTitleBar` + 全屏**：红绿灯行为只在真窗口里暴露。
- **状态会串**：上次打开的目录、侧边栏显隐都存在 `UserDefaults` 里，复现前先确认是干净状态。

## Reply

现象、根因（一句话，指名具体文件和函数）、改法、复现脚本失败与通过的原文、`check-app-fresh.sh` 的输出。

没验证的 surface 明确写「未验证」，不要用「应该没问题」代替。
