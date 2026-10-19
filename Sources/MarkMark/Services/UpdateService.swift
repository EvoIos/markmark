import Foundation
import os

/// GitHub Release 信息
struct GitHubRelease: Sendable {
    let tagName: String      // e.g. "v1.0.3"
    let name: String         // e.g. "MarkMark 2.0.5"
    let body: String         // Release notes (Markdown)
    let htmlURL: URL         // GitHub Release 页面链接
    let zipDownloadURL: URL? // ZIP 下载链接（从 assets 中匹配）
    let dmgDownloadURL: URL? // DMG 下载链接（从 assets 中匹配）
    let publishedAt: Date?   // 发布时间
}

/// 自动更新服务：检查 GitHub Releases API，解析最新版本信息
final class UpdateService: Sendable {

    // MARK: - 功能开关

    /// 是否启用「检查更新」。
    ///
    /// 本仓库是 fork（`EvoIos/markmark`），而下面的 `owner`/`repo` 仍指向上游：自动检查会把上游
    /// Release 当成「新版本」，一路走到下载并替换 .app，等于用上游构建覆盖 fork 自己的包。
    /// 所以在改成自己的发布地址之前，先整个关掉：`isEnabled == false` 时菜单不显示入口、
    /// 启动不自动检查、也不发起任何网络请求。
    ///
    /// 日后恢复：把 `owner`/`repo` 改成承接发布的仓库（例如 `EvoIos` / `markmark`），
    /// 确认它真的产出 Release 资产后，再把这里改回 `true`。
    static let isEnabled = false

    // MARK: - 常量

    /// GitHub 仓库所有者（目前是上游；fork 后需改成自己的仓库，见 `isEnabled`）
    private static let owner = "easychen"

    /// GitHub 仓库名称
    private static let repo = "markmark"

    /// GitHub Releases API 端点
    private static let releasesURL = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"

    /// 本地版本号
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private let logger = Logger(subsystem: "com.ft07.markmark", category: "UpdateService")

    // MARK: - 自动安装可行性判断

    /// 判断当前环境是否支持自动安装（ZIP 方式）
    /// 条件：app 在可写位置、不在 DMG 挂载卷中运行
    static func canAutoInstall() -> Bool {
        let appURL = Bundle.main.bundleURL
        let appPath = appURL.path

        // 1. 不在 DMG 挂载卷中运行
        guard !appPath.contains("/Volumes/") else { return false }

        // 2. 在可写位置（/Applications/ 或用户目录下）
        let isInApplications = appPath.hasPrefix("/Applications/")
        let isInUserApplications = appPath.hasPrefix(NSHomeDirectory() + "/Applications/")
        let isInUserDir = appPath.hasPrefix(NSHomeDirectory() + "/")
        guard isInApplications || isInUserApplications || isInUserDir else { return false }

        // 3. 当前目录可写
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else { return false }

        return true
    }

    // MARK: - 检查更新

    /// 从 GitHub Releases API 获取最新版本信息
    /// - Returns: 最新 Release 信息，如果已是最新版则返回 nil
    func checkForUpdates() async throws -> GitHubRelease? {
        guard let url = URL(string: Self.releasesURL) else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MarkMark/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }

        if httpResponse.statusCode == 304 {
            return nil
        }

        if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
            throw UpdateError.rateLimited
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("GitHub API returned status \(httpResponse.statusCode)")
            throw UpdateError.apiError(statusCode: httpResponse.statusCode)
        }

        let release = try parseRelease(data: data)

        let latestVersion = stripVersionPrefix(release.tagName)
        guard isNewer(latest: latestVersion, current: Self.currentVersion) else {
            return nil
        }

        return release
    }

    // MARK: - 解析

    /// 解析 GitHub Release JSON
    private func parseRelease(data: Data) throws -> GitHubRelease {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.parseError
        }

        guard let tagName = json["tag_name"] as? String else {
            throw UpdateError.parseError
        }

        let name = json["name"] as? String ?? tagName
        let body = json["body"] as? String ?? ""
        let htmlURLString = json["html_url"] as? String ?? ""

        guard let htmlURL = URL(string: htmlURLString) else {
            throw UpdateError.parseError
        }

        // 从 assets 中查找 ZIP 和 DMG 下载链接
        var zipDownloadURL: URL?
        var dmgDownloadURL: URL?
        if let assets = json["assets"] as? [[String: Any]] {
            let currentArch = Architecture.current
            zipDownloadURL = findAsset(in: assets, extension: "zip", arch: currentArch)
            dmgDownloadURL = findAsset(in: assets, extension: "dmg", arch: currentArch)
        }

        // 解析发布时间
        var publishedAt: Date?
        if let dateString = json["published_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            publishedAt = formatter.date(from: dateString)
        }

        return GitHubRelease(
            tagName: tagName,
            name: name,
            body: body,
            htmlURL: htmlURL,
            zipDownloadURL: zipDownloadURL,
            dmgDownloadURL: dmgDownloadURL,
            publishedAt: publishedAt
        )
    }

    /// 从 assets 列表中查找指定扩展名的文件
    /// 优先匹配当前架构，若无匹配则取第一个
    private func findAsset(in assets: [[String: Any]], extension ext: String, arch: Architecture) -> URL? {
        var matchedAssets: [(url: URL, name: String)] = []
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString),
                  name.hasSuffix(".\(ext)") else {
                continue
            }
            matchedAssets.append((url: url, name: name))
        }

        // 优先匹配当前架构
        if let match = matchedAssets.first(where: { $0.name.contains(arch.rawValue) }) {
            return match.url
        }

        // Fallback：返回第一个匹配
        return matchedAssets.first?.url
    }

    // MARK: - 版本比较

    /// 去掉版本号前缀（"v1.0.3" → "1.0.3"）
    func stripVersionPrefix(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    /// 比较版本号：latest > current 则返回 true
    func isNewer(latest: String, current: String) -> Bool {
        let latestParts = parseVersion(latest)
        let currentParts = parseVersion(current)

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }

    /// 解析版本号为整数数组（"1.0.3" → [1, 0, 3]）
    /// 忽略预发布/构建后缀，只比较数字主版本（"2.0.12-beta.1" → [2, 0, 12]），
    /// 否则 "12-beta" 段会被 Int() 解析失败而丢弃，导致 beta 版被误判为旧版。
    private func parseVersion(_ version: String) -> [Int] {
        let clean = stripVersionPrefix(version)
        let core = clean.split(separator: "-", maxSplits: 1).first.map(String.init) ?? clean
        return core.split(separator: ".").compactMap { Int($0) }
    }
}

// MARK: - 架构枚举

/// CPU 架构标识，用于匹配下载文件
enum Architecture: String, Sendable {
    case arm64

    static var current: Architecture {
        .arm64
    }
}

// MARK: - 错误类型

enum UpdateError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case rateLimited
    case apiError(statusCode: Int)
    case parseError
    case networkError(Error)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid update URL"
        case .invalidResponse:
            return "Invalid server response"
        case .rateLimited:
            return "GitHub API rate limit exceeded. Please try again later."
        case .apiError(let code):
            return "Server returned error code \(code)"
        case .parseError:
            return "Failed to parse update information"
        case .networkError(let error):
            return error.localizedDescription
        case .installFailed(let reason):
            return "Installation failed: \(reason)"
        }
    }
}
