# Markdown Reader — 自动更新设计文档

> 版本: 1.0 | 最后更新: 2026-06-04

> ⚠️ **当前状态（2026-10-19）：fork 期间已整体关闭。**
> 本仓库是 `EvoIos/markmark` 的 fork，而实现查询的是上游 `easychen/markmark` 的 Release
> （`UpdateService` 的 `owner` / `repo`），会把上游包当成新版本一路下载并替换掉 fork 自己的构建。
> 现由 `UpdateService.isEnabled = false` 统一关闭：设置菜单没有入口、启动不自动检查、不发起任何网络请求。
> 恢复步骤：① 把 `owner` / `repo` 改为本仓库；② 让本仓库产出 Release（资产名 `MarkMark.dmg` /
> `MarkMark.zip`，见 `release-local.sh` 与 `.github/workflows/release.yml`）；③ 把 `isEnabled` 改回 `true`。

## 1. 概述

Markdown Reader 通过 GitHub Releases 分发，当前为 ad-hoc 签名（无 Apple Developer ID 公证）。本文档描述自动更新功能的设计方案：利用 GitHub Releases API 检测新版本，支持 ZIP 自动安装和 DMG 手动安装两种模式。

### 目标

- 利用 GitHub Releases 自动发现新版本并提示用户
- 点击更新后下载新版本，提示安装并重启
- 自动重启后即运行新版本
- 降级策略：无法自动安装时引导用户手动安装

### 非目标

- 增量更新（app < 6MB，无需）
- 多架构匹配（当前 CI 只产 arm64）
- Apple Developer ID 签名 / 公证（Phase 2）
- Sparkle 集成（Phase 2，获得 Developer ID 后）

---

## 2. 整体架构

```
┌─────────────────────────────────────────────────────────┐
│                    MarkdownReaderApp                      │
│  ┌─────────────┐  ┌──────────────────────────────────┐  │
│  │ 菜单「检查更新」│  │ .task { checkForUpdatesAuto() }   │  │
│  └──────┬──────┘  └──────────────┬───────────────────┘  │
│         │ Notification            │ 24h 间隔              │
│         ▼                         ▼                       │
│  ┌─────────────────────────────────────────────────────┐ │
│  │                  UpdateViewModel                      │ │
│  │  状态: idle → checking → updateAvailable → installing │ │
│  │  模式: .zip (自动) / .dmg (手动)                      │ │
│  └──────────┬────────────────────────┬─────────────────┘ │
│             │                        │                    │
│             ▼                        ▼                    │
│  ┌──────────────────┐   ┌──────────────────────────┐    │
│  │   UpdateService   │   │      UpdateView (Sheet)   │    │
│  │  GitHub API 查询   │   │  版本信息 / 下载进度 / 按钮 │    │
│  │  Semver 比较       │   └──────────────────────────┘    │
│  │  canAutoInstall()  │                                    │
│  └──────────────────┘                                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 核心流程

### 3.1 检查更新

```
启动 / 菜单触发
    ↓
判断是否需要检查
    ├─ 自动：距上次检查 < 24h → 跳过
    ├─ 自动：最新版 = skippedVersion → 跳过
    └─ 手动：无视间隔和跳过
    ↓
调用 GitHub Releases API
GET https://api.github.com/repos/davidhoo/MarkdownReader/releases/latest
Headers: Accept: application/vnd.github+json
         User-Agent: MarkdownReader/{version}
    ↓
解析 tag_name、body、assets
    ↓
Semver 比较：latest > current?
    ├─ 否 → upToDate
    └─ 是 → updateAvailable
    ↓
判断安装模式
    ├─ canAutoInstall() && zipDownloadURL != nil → .zip
    └─ 否 → .dmg
    ↓
显示 UpdateView Sheet
```

### 3.2 ZIP 自动安装

```
用户点击「下载」
    ↓
URLSession downloadTask（带进度回调）下载 ZIP
    ↓
解压到临时目录
    ↓
验证 .app 完整性（可执行文件存在）
    ↓
UI 显示「安装并重启」按钮
    ↓
用户点击「安装并重启」
    ↓
生成守夜人 shell 脚本
    ↓
Process.launchedProcess 启动脚本（detached）
    ↓
NSApplication.shared.terminate(nil)
    ↓
[守夜人脚本]
    ├─ 等待旧进程退出 (kill -0 PID)
    ├─ mv Contents → Contents.old（备份）
    ├─ cp -R new/Contents → Contents（替换）
    ├─ 验证可执行文件存在
    │   ├─ 成功 → xattr -cr → 清理备份 → open app
    │   └─ 失败 → 回滚 Contents.old → open app
    └─ 失败处理：mv 失败 → 放弃替换，启动旧版本
```

### 3.3 DMG 手动安装（降级）

```
用户点击「下载」
    ↓
下载 DMG 到 ~/Downloads/
    ↓
NSWorkspace.shared.open(dmgURL)
    ↓
用户手动拖拽替换（Finder 弹窗）
```

---

## 4. 模块设计

### 4.1 UpdateService

**职责**: GitHub API 交互、版本比较、环境判断

**关键方法**:
- `checkForUpdates() async throws -> GitHubRelease?` — 查询 GitHub API，返回比当前版本新的 Release
- `canAutoInstall() -> Bool` — 判断当前环境是否支持 ZIP 自动安装
- `isNewer(latest:current:) -> Bool` — Semver 比较
- `stripVersionPrefix(_:) -> String` — "v1.0.3" → "1.0.3"

**canAutoInstall() 判断条件**:
1. 不在 DMG 挂载卷中运行 (`/Volumes/`)
2. 在可写位置 (`/Applications/` 或用户目录下)
3. 当前目录可写 (`FileManager.isWritableFile`)

**GitHubRelease 数据结构**:
```swift
struct GitHubRelease: Sendable {
    let tagName: String        // "v1.0.3"
    let name: String           // "MarkdownReader 1.0.3"
    let body: String           // Release notes (Markdown)
    let htmlURL: URL           // Release 页面链接
    let zipDownloadURL: URL?   // ZIP 下载链接
    let dmgDownloadURL: URL?   // DMG 下载链接
    let publishedAt: Date?     // 发布时间
}
```

### 4.2 UpdateViewModel

**职责**: 状态管理、下载流程、安装协调

**状态枚举**:
```swift
enum UpdateCheckState: Sendable {
    case idle
    case checking
    case updateAvailable(GitHubRelease)
    case upToDate
    case error(String)
}
```

**安装模式**:
```swift
enum InstallMode: Sendable {
    case zip   // 自动安装
    case dmg   // 手动安装
}
```

**关键属性**:
- `checkState: UpdateCheckState` — 当前检查状态
- `downloadProgress: Double?` — 下载进度 (0.0~1.0)，nil 表示未在下载
- `installMode: InstallMode` — 安装模式
- `isInstalling: Bool` — 是否正在执行安装
- `extractedAppURL: URL?` — 解压后的 .app 路径（实例属性，避免遍历 /tmp）
- `tempWorkDir: URL?` — 临时工作目录

**关键方法**:
- `checkForUpdatesAutomatically()` — 自动检查（遵守 24h 间隔 + 跳过版本）
- `checkForUpdatesManually()` — 手动检查（无视间隔和跳过）
- `downloadAndInstall()` — 根据安装模式下载
- `installAndRestart()` — 执行守夜人脚本安装
- `skipVersion()` — 跳过此版本
- `remindLater()` — 稍后提醒
- `cancelDownload()` — 取消下载

**下载进度**: 使用 `URLSession.downloadTask` + `URLSessionDownloadDelegate` 实现实时进度回调，而非 `URLSession.shared.download(from:)`（后者无进度回调）。

### 4.3 UpdateView

**职责**: 更新弹窗 UI

**布局**:
1. 头部：图标 + 版本号
2. 安装模式提示：「自动安装并重启」/ 「需手动安装」
3. Release Notes（可滚动，支持文本选择）
4. 下载进度条（仅下载中显示）
5. 操作按钮区：
   - 未下载：跳过此版本 / 稍后 / 下载
   - 下载中：取消
   - 下载完成（ZIP）：稍后 / 安装并重启
   - 下载完成（DMG）：已打开 DMG，手动拖拽
   - 安装中：进度指示器

### 4.4 守夜人脚本

**设计原则**: 原子替换 + 回滚保护，不依赖 `codesign --verify`（ad-hoc 签名总返回非零）

**脚本逻辑**:
```bash
#!/bin/bash
# 1. 等待旧进程退出
while kill -0 $PID 2>/dev/null; do sleep 0.5; done
sleep 1  # 确保资源释放

# 2. 备份当前 Contents
if ! mv "$APP_PATH/Contents" "$APP_PATH/Contents.old" 2>/dev/null; then
    open "$APP_PATH"  # 备份失败，启动旧版本
    exit 1
fi

# 3. 复制新 Contents
if ! cp -R "$NEW_APP/Contents" "$APP_PATH/Contents" 2>/dev/null; then
    # 复制失败，回滚
    rm -rf "$APP_PATH/Contents" 2>/dev/null
    mv "$APP_PATH/Contents.old" "$APP_PATH/Contents" 2>/dev/null
    open "$APP_PATH"
    exit 1
fi

# 4. 清除隔离属性
xattr -cr "$APP_PATH" 2>/dev/null

# 5. 验证可执行文件
if [ -x "$APP_PATH/Contents/MacOS/MarkdownReader" ]; then
    rm -rf "$APP_PATH/Contents.old" 2>/dev/null
    rm -rf "$WORK_DIR" 2>/dev/null
    open "$APP_PATH"
else
    # 回滚
    rm -rf "$APP_PATH/Contents" 2>/dev/null
    mv "$APP_PATH/Contents.old" "$APP_PATH/Contents" 2>/dev/null
    rm -rf "$WORK_DIR" 2>/dev/null
    open "$APP_PATH"
fi
```

**路径传递**: 通过 Swift 字符串插值直接嵌入脚本。所有路径用双引号包裹。`Bundle.main.bundleURL.path` 提供当前 app 路径。

**进程分离**: 使用 `Process()` + `/bin/bash` 启动脚本，脚本独立于 app 进程运行。app 退出后脚本继续执行。

---

## 5. CI 改动

### release.yml 新增步骤

在 `Create DMG` 步骤后新增：

```yaml
- name: Create ZIP
  run: |
    VERSION="${{ steps.version.outputs.version }}"
    ZIP_NAME="${{ env.PRODUCT_NAME }}-$VERSION.zip"
    zip -r "$ZIP_NAME" "${{ env.PRODUCT_NAME }}.app"
    echo "✅ ZIP created: $ZIP_NAME"
```

`gh release create` 命令同时上传 DMG + ZIP：
```yaml
gh release create "$TAG" \
    --title "$TAG" \
    --notes-file /tmp/release-body.md \
    "$DMG_NAME" \
    "$ZIP_NAME"
```

### Release Assets 命名

| 文件 | 格式 | 用途 |
|------|------|------|
| `MarkdownReader-{version}.dmg` | DMG | 首次安装 / 手动安装降级 |
| `MarkdownReader-{version}.zip` | ZIP | 自动更新安装 |

---

## 6. 菜单集成

在 `MarkdownReaderApp.swift` 的 `CommandGroup(replacing: .appSettings)` 中追加：

```swift
CommandGroup(replacing: .appSettings) {
    Button("Settings…") { /* 现有 */ }
        .keyboardShortcut(",", modifiers: .command)

    // 新增
    Button("Check for Updates…") {
        NotificationCenter.default.post(name: .checkForUpdates, object: nil)
    }
}
```

macOS 惯例：app 菜单中 Settings 下面就是 Check for Updates。

---

## 7. 设置持久化

### SettingsModel 新增属性

| 属性 | 类型 | UserDefaults Key | 默认值 | 说明 |
|------|------|-----------------|--------|------|
| `skippedVersion` | `String?` | `com.markdownreader.skippedVersion` | nil | 用户跳过的版本号 |
| `lastUpdateCheckTime` | `Date?` | `com.markdownreader.lastUpdateCheckTime` | nil | 上次自动检查时间 |

### 忽略版本行为

| 场景 | 是否弹窗 |
|------|---------|
| 自动检查，最新版 = skippedVersion | 否（静默跳过） |
| 自动检查，发布了更新版本 | 是 |
| 手动检查，最新版 = skippedVersion | 是（始终提示） |

---

## 8. 本地化

### 新增 L10n 键（16 个）

| Key | en | zh-CN | zh-TW |
|-----|-----|-------|-------|
| `updateAvailableTitle` | Update Available | 发现新版本 | 發現新版本 |
| `updateAvailableVersion` | Version {version} | 版本 {version} | 版本 {version} |
| `updateChecking` | Checking for updates… | 正在检查更新… | 正在檢查更新… |
| `updateUpToDate` | Markdown Reader is up to date. | Markdown Reader 已是最新版本。 | Markdown Reader 已是最新版本。 |
| `updateDownload` | Download | 下载 | 下載 |
| `updateDownloading` | Downloading update… | 正在下载更新… | 正在下載更新… |
| `updateDownloadComplete` | Download complete. Click Install to continue. | 下载完成，点击「安装」继续。 | 下載完成，點擊「安裝」繼續。 |
| `updateInstall` | Install | 安装 | 安裝 |
| `updateInstallAndRestart` | Install & Restart | 安装并重启 | 安裝並重新啟動 |
| `updateInstalling` | Installing update… | 正在安装更新… | 正在安裝更新… |
| `updateLater` | Later | 稍后 | 稍後 |
| `updateSkipVersion` | Skip This Version | 跳过此版本 | 跳過此版本 |
| `updateCancel` | Cancel | 取消 | 取消 |
| `updateError` | Update check failed. | 检查更新失败。 | 檢查更新失敗。 |
| `updateModeAuto` | Auto install & restart | 自动安装并重启 | 自動安裝並重新啟動 |
| `updateModeManual` | Manual install required | 需手动安装 | 需手動安裝 |
| `checkForUpdates` | Check for Updates… | 检查更新… | 檢查更新… |

---

## 9. 文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `Services/UpdateService.swift` | 新增 | GitHub API + semver + canAutoInstall |
| `ViewModels/UpdateViewModel.swift` | 新增 | 状态管理 + 下载/安装流程 |
| `Views/UpdateView.swift` | 新增 | 更新弹窗 UI |
| `App/MarkdownReaderApp.swift` | 修改 | 菜单项 + 启动检查 + sheet |
| `Models/SettingsModel.swift` | 修改 | skippedVersion + lastUpdateCheckTime |
| `Services/LocalizationService.swift` | 修改 | 新增 17 个 L10n 键 |
| `.github/workflows/release.yml` | 修改 | 新增 Create ZIP 步骤 |

---

## 10. 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| Gatekeeper 拦截新版启动 | 用户无法启动更新后的 app | 守夜人脚本执行 `xattr -cr` 清除隔离属性 |
| cp -R 中途失败 | app 损坏无法启动 | 原子替换 + 回滚保护（备份 Contents.old） |
| app 不在 /Applications | 无法替换 Contents | canAutoInstall() 判断，降级到 DMG |
| 从 DMG 挂载卷运行 | 无法替换自身 | canAutoInstall() 检测 /Volumes/，降级到 DMG |
| GitHub API rate limit | 无法检查更新 | 每天 1 次检查，60 次/小时限额足够 |
| 网络中断 | 下载失败 | 错误提示，可重试 |
| 路径含特殊字符 | 守夜人脚本解析错误 | 路径用双引号包裹；极端情况降级到 DMG |

---

## 11. Phase 2 展望

当获得 Apple Developer ID 证书后：

1. **签名 + 公证**: CI 中使用 Developer ID 签名 + notarytool 公证 + stapling
2. **Sparkle 2 集成**: 替换自建方案，获得行业标准更新体验
3. **EdDSA 签名验证**: appcast.xml + Ed25519 签名确保更新包完整性
4. **多架构支持**: CI 同时构建 arm64 + x86_64 DMG
5. **latest.json / appcast.xml**: 结构化版本元数据，避免依赖 GitHub API

---

## 12. 参考实现

| 项目 | 方案 | 链接 |
|------|------|------|
| Sparkle 2 | macOS 标准更新框架 | https://github.com/sparkle-project/Sparkle |
| Electron updater | ZIP + 守夜人脚本 | Chromium 源码 |
| mxcl/AppUpdater | 轻量 GitHub 更新 | https://github.com/mxcl/AppUpdater |
| Aayush9029/twinkle | Swift 6 + @Observable | https://github.com/Aayush9029/twinkle |
| Peter Steinberger 指南 | 签名+公证+Sparkle | https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears |
