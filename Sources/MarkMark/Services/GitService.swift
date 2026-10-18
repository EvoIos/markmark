import Foundation

/// 读取文件在 git HEAD 中的版本，作为 diff 模式的基线。
///
/// 不直接调用 `/usr/bin/git`：未安装 Command Line Tools 时它会弹出安装对话框。
/// 先找 Homebrew 等独立安装的 git，再确认 `xcode-select -p` 指向的开发者目录里确实有 git。
enum GitService {

    private static let executable: URL? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let developerDir = run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !developerDir.isEmpty,
           fm.isExecutableFile(atPath: developerDir + "/usr/bin/git") {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        return nil
    }()

    /// 文件在 HEAD 中的内容；不在仓库、未被跟踪、仓库无提交或找不到 git 时返回 nil。
    static func headText(of fileURL: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let git = executable else { return nil }
            let dir = fileURL.deletingLastPathComponent().path
            return run(git, ["-C", dir, "show", "HEAD:./" + fileURL.lastPathComponent])
        }.value
    }

    /// 同步执行命令，退出码非 0 返回 nil。
    private static func run(_ executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
