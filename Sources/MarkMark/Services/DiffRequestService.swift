import Foundation

/// `mdr diff <old> <new>` 投递的对比请求。
///
/// 命令行脚本把基线内容写成请求文件放进 `directory`，然后正常打开 new 文件；
/// 文档加载完成、或请求目录发生变化时，持有该文件的 DocumentViewModel 认领请求并进入对比模式。
/// 这样复用了现有的冷 / 热启动打开流程，无需注册 URL scheme。
enum DiffRequestService {

    struct Request {
        /// 基线显示名（旧文件名）
        let baselineName: String
        /// 基线全文
        let baselineText: String
    }

    /// 超过这个时间仍无人认领的请求视为过期并清理
    private static let maxAge: TimeInterval = 10 * 60

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkMark/DiffRequests", isDirectory: true)
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 认领指向 `fileURL` 的最新请求（读取后删除）。同一文件有多条时取最新一条，其余一并清掉。
    static func consumeRequest(for fileURL: URL) -> Request? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let target = fileURL.markMarkCanonicalFileURL.path
        var newest: (date: Date, request: Request)?
        for entry in entries where entry.pathExtension == "request" {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > maxAge {
                try? fm.removeItem(at: entry)
                continue
            }
            guard let request = parse(entry, matching: target) else { continue }
            try? fm.removeItem(at: entry)
            if newest == nil || date > newest!.date { newest = (date, request) }
        }
        return newest?.request
    }

    private static func parse(_ entry: URL, matching target: String) -> Request? {
        guard let data = try? Data(contentsOf: entry),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let path = URL(fileURLWithPath: String(parts[0])).markMarkCanonicalFileURL.path
        guard path == target else { return nil }
        return Request(baselineName: String(parts[1]), baselineText: parts.count > 2 ? String(parts[2]) : "")
    }
}
