import SwiftUI
import MarkdownReaderKit
import os

/// 更新检查状态
enum UpdateCheckState: Sendable {
    case idle
    case checking
    case updateAvailable(GitHubRelease)
    case upToDate
    case error(String)

    /// 是否允许发起新的检查
    var canCheck: Bool {
        switch self {
        case .idle, .upToDate, .error: return true
        case .checking, .updateAvailable: return false
        }
    }

    /// 如果状态为 updateAvailable，提取关联的 release
    var release: GitHubRelease? {
        if case .updateAvailable(let release) = self { return release }
        return nil
    }

    /// 如果状态为 updateAvailable，提取去前缀的版本号
    var availableVersion: String? {
        guard let release = release else { return nil }
        let tag = release.tagName
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}

/// 安装模式
enum InstallMode: Sendable {
    case zip   // 自动安装：下载 zip → 守夜人脚本替换 → 重启
    case dmg   // 手动安装：下载 DMG → open DMG → 用户拖拽
}

/// 自动更新 ViewModel：管理更新状态、下载进度、安装流程
@MainActor
@Observable
final class UpdateViewModel {

    // MARK: - 状态

    /// 当前更新检查状态
    var checkState: UpdateCheckState = .idle

    /// 是否显示更新弹窗
    var isShowingUpdateSheet = false

    /// 下载进度（0.0 ~ 1.0），nil 表示未在下载
    var downloadProgress: Double?

    /// 安装模式
    var installMode: InstallMode = .zip

    /// 是否正在安装（守夜人脚本执行中）
    var isInstalling = false

    // MARK: - 依赖

    private let updateService = UpdateService()
    private let settings = SettingsModel.shared
    private let logger = Logger(subsystem: "com.ft07.markmark", category: "UpdateViewModel")

    /// 下载任务
    private var downloadTask: Task<Void, Never>?

    /// ZIP 解压后的新 .app 路径（实例属性，避免遍历 /tmp）
    private var extractedAppURL: URL?

    /// 临时工作目录
    private var tempWorkDir: URL?

    // MARK: - 检查更新

    /// 检查更新（自动检查，遵守 24h 间隔和跳过版本逻辑）
    func checkForUpdatesAutomatically() {
        if let lastCheck = settings.lastUpdateCheckTime {
            let hoursSinceLastCheck = Date().timeIntervalSince(lastCheck) / 3600
            if hoursSinceLastCheck < 24 {
                logger.info("Skipping auto-update check: last checked \(String(format: "%.1f", hoursSinceLastCheck))h ago")
                return
            }
        }
        performCheck(isManual: false)
    }

    /// 手动检查更新（无视 24h 间隔和跳过版本）
    func checkForUpdatesManually() {
        performCheck(isManual: true)
    }

    private func performCheck(isManual: Bool) {
        // 功能已关闭（fork 期间不连上游 Releases，见 UpdateService.isEnabled）
        guard UpdateService.isEnabled else { return }
        guard checkState.canCheck else { return }

        checkState = .checking

        Task {
            do {
                guard let release = try await updateService.checkForUpdates() else {
                    settings.lastUpdateCheckTime = Date()
                    checkState = .upToDate
                    if isManual {
                        isShowingUpdateSheet = true
                    }
                    return
                }

                let latestVersion = updateService.stripVersionPrefix(release.tagName)

                if !isManual, settings.skippedVersion == latestVersion {
                    logger.info("Skipping auto-update notification for version \(latestVersion): user skipped")
                    checkState = .idle
                    settings.lastUpdateCheckTime = Date()
                    return
                }

                checkState = .updateAvailable(release)
                settings.lastUpdateCheckTime = Date()

                // 根据环境选择安装模式
                installMode = UpdateService.canAutoInstall() && release.zipDownloadURL != nil ? .zip : .dmg

                isShowingUpdateSheet = true

            } catch {
                logger.error("Update check failed: \(error.localizedDescription)")
                checkState = .error(error.localizedDescription)
                if isManual {
                    isShowingUpdateSheet = true
                }
            }
        }
    }

    // MARK: - 用户操作

    /// 跳过此版本
    func skipVersion() {
        if case .updateAvailable(let release) = checkState {
            let version = updateService.stripVersionPrefix(release.tagName)
            settings.skippedVersion = version
            logger.info("User skipped version \(version)")
        }
        isShowingUpdateSheet = false
        checkState = .idle
    }

    /// 稍后提醒
    func remindLater() {
        isShowingUpdateSheet = false
        checkState = .idle
    }

    /// 下载并安装更新
    func downloadAndInstall() {
        guard case .updateAvailable(let release) = checkState else { return }

        switch installMode {
        case .zip:
            if let zipURL = release.zipDownloadURL {
                downloadAndInstallZIP(from: zipURL, releasePageURL: release.htmlURL)
            } else {
                installMode = .dmg
                fallthrough
            }
        case .dmg:
            if let dmgURL = release.dmgDownloadURL {
                downloadAndOpenDMG(from: dmgURL, releasePageURL: release.htmlURL)
            } else {
                openReleasePage(release.htmlURL)
                isShowingUpdateSheet = false
                checkState = .idle
            }
        }
    }

    /// 安装并重启（ZIP 下载完成后调用）
    func installAndRestart() {
        isInstalling = true

        // 先关闭 sheet，避免 SwiftUI sheet 干扰进程退出
        isShowingUpdateSheet = false

        Task {
            do {
                try await performZIPInstall()
                // 使用 exit(0) 而非 NSApplication.shared.terminate(nil)：
                // terminate() 会被 NSWindowDelegate.windowShouldClose 拦截
                // （当有未保存的临时新建文件时返回 false），
                // 导致 app 无法退出，守夜人脚本永远等不到进程结束，
                // UI 卡在 isInstalling = true 状态。
                // exit(0) 直接终止进程，守夜人脚本可立即继续替换文件。
                exit(0)
            } catch {
                logger.error("ZIP install failed: \(error.localizedDescription)")
                isInstalling = false

                // 降级到 DMG
                if case .updateAvailable(let release) = checkState, let dmgURL = release.dmgDownloadURL {
                    installMode = .dmg
                    downloadAndOpenDMG(from: dmgURL, releasePageURL: release.htmlURL)
                } else if case .updateAvailable(let release) = checkState {
                    openReleasePage(release.htmlURL)
                    isShowingUpdateSheet = false
                    checkState = .idle
                }
            }
        }
    }

    /// 取消下载
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = nil
        cleanupTempFiles()
        isShowingUpdateSheet = false
        checkState = .idle
    }

    // MARK: - ZIP 下载与安装

    /// 下载 ZIP 文件并解压
    private func downloadAndInstallZIP(from url: URL, releasePageURL: URL) {
        downloadProgress = 0.0
        extractedAppURL = nil

        downloadTask = Task {
            do {
                // 创建临时工作目录
                let workDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MarkdownReader-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                tempWorkDir = workDir

                let zipDestination = workDir.appendingPathComponent(url.lastPathComponent)

                // 下载 ZIP（带进度追踪）
                let (tempURL, response) = try await self.downloadWithProgress(from: url)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw UpdateError.invalidResponse
                }

                try FileManager.default.moveItem(at: tempURL, to: zipDestination)
                logger.info("ZIP downloaded to \(zipDestination.path)")

                // 解压 ZIP
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", zipDestination.path, "-d", workDir.path]
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    throw UpdateError.installFailed("Failed to extract ZIP (exit code \(process.terminationStatus))")
                }

                // 删除 zip 文件，只保留解压后的 .app
                try? FileManager.default.removeItem(at: zipDestination)

                // 查找解压后的 .app
                let contents = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
                    throw UpdateError.installFailed("No .app found in extracted ZIP")
                }

                // 验证新 .app 包含可执行文件
                let executableName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "MarkMark"
                let executablePath = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
                guard FileManager.default.fileExists(atPath: executablePath.path) else {
                    throw UpdateError.installFailed("New .app is missing executable")
                }

                // 存储解压后的 .app 路径到实例属性
                extractedAppURL = appURL

                // 标记下载完成，UI 显示安装按钮
                downloadProgress = 1.0

            } catch is CancellationError {
                downloadProgress = nil
                cleanupTempFiles()
            } catch {
                downloadProgress = nil
                cleanupTempFiles()
                logger.error("ZIP download/extract failed: \(error.localizedDescription)")

                // 降级到 DMG
                if case .updateAvailable(let release) = checkState {
                    if let dmgURL = release.dmgDownloadURL {
                        installMode = .dmg
                        downloadAndOpenDMG(from: dmgURL, releasePageURL: release.htmlURL)
                    } else {
                        openReleasePage(releasePageURL)
                        isShowingUpdateSheet = false
                        checkState = .idle
                    }
                }
            }
        }
    }

    /// 带进度回调的下载
    /// 使用 URLSession downloadTask + 自定义 delegate 实现进度追踪
    private func downloadWithProgress(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = ProgressDownloadDelegate { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }

            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )

            let task = session.downloadTask(with: url) { tempURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let tempURL, let response {
                    continuation.resume(returning: (tempURL, response))
                } else {
                    continuation.resume(throwing: UpdateError.invalidResponse)
                }
            }
            task.resume()
        }
    }

    /// 执行 ZIP 安装：启动守夜人脚本替换 .app → 重启
    private func performZIPInstall() async throws {
        guard let newAppURL = extractedAppURL else {
            throw UpdateError.installFailed("Extracted app not found")
        }

        let appURL = Bundle.main.bundleURL
        let appPath = appURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let workDirPath = tempWorkDir?.path ?? ""
        // 可执行文件名（产品由 MarkdownReader 改名为 MarkMark；不可硬编码，否则验证恒失败 → 误回滚到旧版本）
        let executableName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "MarkMark"

        // 验证新 .app 仍然存在
        guard FileManager.default.fileExists(atPath: newAppURL.path) else {
            throw UpdateError.installFailed("New .app disappeared")
        }

        // 创建守夜人脚本
        // 策略：cp 成功 + 可执行文件存在即为成功，失败则回滚
        // 不使用 codesign --verify，因为 ad-hoc 签名总是返回非零
        let scriptContent = """
        #!/bin/bash
        # MarkdownReader 守夜人脚本：等待旧进程退出 → 原子替换 → 重启

        # 等待旧进程退出
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.5
        done

        # 额外等待确保资源释放
        sleep 1

        # 原子替换：先备份，再替换
        if ! mv "\(appPath)/Contents" "\(appPath)/Contents.old" 2>/dev/null; then
            # 备份失败（权限问题等），放弃替换，启动旧版本
            open "\(appPath)"
            exit 1
        fi

        # 复制新 Contents
        if ! cp -R "\(newAppURL.path)/Contents" "\(appPath)/Contents" 2>/dev/null; then
            # 复制失败，立即回滚
            rm -rf "\(appPath)/Contents" 2>/dev/null
            mv "\(appPath)/Contents.old" "\(appPath)/Contents" 2>/dev/null
            open "\(appPath)"
            exit 1
        fi

        # 清除隔离属性（关键：让 macOS 不拦截新版本启动）
        /usr/bin/xattr -cr "\(appPath)" 2>/dev/null

        # 重新 ad-hoc 签名（cp -R 替换后签名断裂，macOS 可能限制 AppKit 功能）
        # 不使用 --deep（Apple 已弃用）：它递归签名嵌套代码时可能破坏 SwiftUI 颜色目录签名，
        # 导致 NSColor(SwiftUI.Color) 在运行时解析失败，使 NSTextView 文字不可见
        # 改为分别签名 bundle 和主 app
        find "\(appPath)/Contents/Resources" -name "*.bundle" -exec /usr/bin/codesign --force --sign - {} \\; 2>/dev/null
        /usr/bin/codesign --force --sign - "\(appPath)" 2>/dev/null

        # 验证新 app 可执行文件存在
        if [ -x "\(appPath)/Contents/MacOS/\(executableName)" ]; then
            # 清理备份和临时文件
            rm -rf "\(appPath)/Contents.old" 2>/dev/null
            \(workDirPath.isEmpty ? "" : "rm -rf \"\(workDirPath)\" 2>/dev/null")
            # 启动新版本
            open "\(appPath)"
        else
            # 可执行文件缺失，回滚
            rm -rf "\(appPath)/Contents" 2>/dev/null
            mv "\(appPath)/Contents.old" "\(appPath)/Contents" 2>/dev/null
            \(workDirPath.isEmpty ? "" : "rm -rf \"\(workDirPath)\" 2>/dev/null")
            # 启动旧版本
            open "\(appPath)"
        fi
        """

        // 写入脚本到临时文件
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownReader-nightwatch-\(UUID().uuidString).sh")
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

        // 设置可执行权限
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        // 启动守夜人脚本（detached，不随 app 退出而终止）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        // 重定向 stdout/stderr 到日志文件，避免管道在父进程退出时关闭导致子进程收到 SIGPIPE
        // 同时保留安装日志，便于排查问题
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownReader-update-\(UUID().uuidString).log")
        if let logHandle = FileHandle(forWritingAtPath: logURL.path) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        try process.run()

        logger.info("Nightwatchman script launched, app will terminate for update. Log: \(logURL.path)")
    }

    // MARK: - DMG 下载与安装

    /// 下载 DMG 文件并打开
    private func downloadAndOpenDMG(from url: URL, releasePageURL: URL) {
        downloadProgress = 0.0

        downloadTask = Task {
            do {
                let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let destinationURL = downloadsDir.appendingPathComponent(url.lastPathComponent)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                let (tempURL, response) = try await URLSession.shared.download(from: url)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw UpdateError.invalidResponse
                }

                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                downloadProgress = nil

                // 用 open 命令打开 DMG（触发 Gatekeeper 票据注入）
                NSWorkspace.shared.open(destinationURL)
                isShowingUpdateSheet = false
                checkState = .idle

                logger.info("DMG downloaded and opened: \(destinationURL.path)")

            } catch {
                downloadProgress = nil
                logger.error("DMG download failed: \(error.localizedDescription)")

                openReleasePage(releasePageURL)
                isShowingUpdateSheet = false
                checkState = .idle
            }
        }
    }

    // MARK: - 工具方法

    /// 清理临时文件
    private func cleanupTempFiles() {
        if let workDir = tempWorkDir {
            try? FileManager.default.removeItem(at: workDir)
        }
        tempWorkDir = nil
        extractedAppURL = nil
    }

    /// 打开 GitHub Release 页面
    private func openReleasePage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 下载进度委托

/// URLSession 下载进度追踪
/// 通过闭包回调实时报告下载进度
private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 文件由 URLSession 临时存储，调用方负责移动
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(progress)
    }
}
