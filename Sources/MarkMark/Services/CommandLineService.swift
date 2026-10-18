import Foundation
import os

@MainActor
final class CommandLineService {

    private static let commandName = "mdr"
    private static let installPath = "/usr/local/bin/\(commandName)"

    private let logger = Logger(subsystem: "com.ft07.markmark", category: "CommandLineService")

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.installPath)
    }

    /// 已安装的脚本是旧版本（例如不支持 `mdr diff`），需要重新安装覆盖。
    var isOutdated: Bool {
        guard let installed = try? String(contentsOfFile: Self.installPath, encoding: .utf8) else { return false }
        return installed != Self.scriptContent
    }

    /// `mdr` 脚本：
    /// - `mdr <file>…`：用 MarkMark 打开文件；
    /// - `mdr diff <old.md> <new.md>`：以 old 为基线、对比显示 new 的改动。
    ///   做法是把「基线内容」写成一个请求文件放进 DiffRequestService 的目录（复制内容，调用方随后
    ///   删掉临时旧文件也没关系），再正常打开 new；App 加载该文件（或已打开时监听到请求）后进入对比模式。
    ///   请求文件格式：第 1 行 new 的绝对路径，第 2 行基线显示名，其后为基线全文。
    static let scriptContent = #"""
    #!/bin/bash
    # MarkMark command line tool (installed by MarkMark Settings)
    if [ "$1" = "diff" ]; then
      shift
      if [ $# -ne 2 ]; then
        echo "usage: mdr diff <old.md> <new.md>" >&2
        exit 1
      fi
      old="$1"; new="$2"
      for f in "$old" "$new"; do
        if [ ! -f "$f" ]; then echo "mdr: no such file: $f" >&2; exit 1; fi
      done
      new_abs="$(cd "$(dirname "$new")" && pwd -P)/$(basename "$new")"
      dir="$HOME/Library/Application Support/MarkMark/DiffRequests"
      mkdir -p "$dir" || exit 1
      id="$(printf '%s' "$new_abs" | shasum | cut -c1-16)-$$"
      { printf '%s\n%s\n' "$new_abs" "$(basename "$old")"; cat "$old"; } > "$dir/$id.tmp" || exit 1
      mv "$dir/$id.tmp" "$dir/$id.request" || exit 1
      exec open -b com.ft07.markmark "$new_abs"
    fi
    exec open -b com.ft07.markmark "$@"
    """# + "\n"

    func install(completion: @MainActor @escaping (Bool) -> Void = { _ in }) {
        let scriptContent = Self.scriptContent

        let tempDir = NSTemporaryDirectory()
        let tempPath = (tempDir as NSString).appendingPathComponent(Self.commandName)

        do {
            try scriptContent.write(toFile: tempPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempPath)
        } catch {
            logger.error("Failed to write temp script: \(error.localizedDescription)")
            completion(false)
            return
        }

        let appleScript = """
        do shell script "cp -f '\(tempPath)' '\(Self.installPath)' && chmod 755 '\(Self.installPath)'" with administrator privileges
        """

        runAppleScript(appleScript) { [weak self] success in
            try? FileManager.default.removeItem(atPath: tempPath)
            if success {
                self?.logger.info("mdr command installed successfully")
            } else {
                self?.logger.error("Failed to install mdr command")
            }
            completion(success)
        }
    }

    func uninstall(completion: @MainActor @escaping (Bool) -> Void = { _ in }) {
        guard isInstalled else {
            completion(true)
            return
        }

        let appleScript = """
        do shell script "rm -f '\(Self.installPath)'" with administrator privileges
        """

        runAppleScript(appleScript) { [weak self] success in
            if success {
                self?.logger.info("mdr command uninstalled successfully")
            } else {
                self?.logger.error("Failed to uninstall mdr command")
            }
            completion(success)
        }
    }

    private func runAppleScript(_ source: String, completion: @MainActor @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", source]

            let pipe = Pipe()
            task.standardError = pipe

            do {
                try task.run()
                task.waitUntilExit()
                let success = task.terminationStatus == 0
                DispatchQueue.main.async {
                    completion(success)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
}
