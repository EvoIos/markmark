# 验证对照表

改了哪一类东西，就必须用哪一条命令验证。这张表是给 agent 查的，不是给人读的说明书：每一行都要能直接复制执行，并通过标准只有一个。

`swift test` 覆盖不到的 surface 占多数，所以「单测全绿」不能当作任何一行的通过标准。

## 改了这些，就跑这条

| 改动触及 | 验证什么 | 命令 | 通过标准 |
|---|---|---|---|
| `Sources/**/*.swift` | 分支行为 | `swift test --disable-sandbox --cache-path .build/swiftpm-cache` | 0 failures |
| Prism 语法、高亮、主题 token、`Resources/js/**` | 代码块真实产出什么 token | `node scripts/test-render.mjs` | `RENDER TEST: PASS` |
| 构建产物、架构、签名 | 包是不是当前源码构建的 | `./scripts/check-app-fresh.sh` | `APP FRESH: PASS` |
| 文件打开、窗口路由、Services、冷/热启动 | 真窗口行为 | `./scripts/open-request-regression.sh MarkMark.app` | 脚本内每条断言都 ✅ |
| 导出 HTML、自包含资源 | 无 `mr://` 残留 + 依赖顺序 | `swift test --disable-sandbox --filter HTMLExport` | 该 suite 全绿；再人工打开导出文件确认代码块有色 |
| Quick Look 扩展 | 预览真的生成图 | `qlmanage -t -s 1200 -o /tmp <file.md>` | `/tmp/<file.md>.png` 存在且不是空白 |
| 版本号、CHANGELOG、tag | 发布一致性 | `./scripts/check-release.sh` | `RELEASE CHECK: PASS` |
| `.claude/skills/**` | frontmatter 与引用路径 | `./scripts/check-skills.sh` | `SKILLS CHECK: PASS` |

⚠️ `open-request-regression.sh` 会 `pkill` 正在运行的 MarkMark。跑之前确认没有未保存的编辑。

⚠️ 受限沙箱的 agent 会话里 `qlmanage` 会报 `sandbox initialization failed: Operation not permitted`，它起的是一个沙箱子进程。Quick Look 这一行要在普通终端里跑，或者在真机上肉眼确认。

## 什么不算通过

- **单测绿了**。单元测试测的是分支行为，不是 bug 的缺席，也不是界面长什么样。
- **截图看着差不多**。看不出差异时常是因为两块都是灰的；要断言 token 类别，不是看颜色。
- **只在 Apple Silicon 上跑通**。`lipo -archs` 必须同时含 `x86_64` 和 `arm64`。
- **改了 Swift 但没重建 `.app`**。`open -a MarkMark.app` 跑的是上一次的二进制，结论会一直是「修好了」。
- **「应该没问题」**。没验就写「未验证」，五个字比一句推测诚实。

## surface 清单（改这个功能时看这里）

| surface | 入口文件 | 已知的坑 |
|---|---|---|
| 渲染管线 | `MarkdownHTMLService.swift`、`Resources/js/markdown-reader.js` | 预览与导出是两条路径，只修一条会漏 |
| 代码高亮 | `Resources/js/prism-*.min.js`、`prism-objectivec-extra.js` | 组件顺序与 `markup-templating` 依赖，缺了会整页失效 |
| 编辑器 | `SyntaxHighlightedEditor.swift` | ObjC runtime swizzling，改动需谨慎 |
| 导出 | `HTMLExportService` | 内联顺序与 `core` 重复加载 |
| Quick Look | `MarkdownReaderQL` | 独立进程，主 app 正常不代表扩展正常 |
| 命令行工具 | `CommandLineService.swift` | 已安装的旧 `mdr` 不会自动更新 |
| 窗口与路由 | `AppDelegate.swift`、`OpenRequestCoordinator` | 冷启动/热启动两条路，状态存 `UserDefaults` |
