import Foundation
import CoreGraphics
import MarkdownReaderKit
import os.log

/// 导出为「自包含单文件 HTML」。
///
/// 与 PDF 导出不同，导出的 HTML 需要能脱离 app 在任意浏览器离线打开，因此把阅读视图
/// 依赖的全部资源内联进同一个 .html 文件：
/// - 正文图片 → base64 data URL（复用 `MarkdownHTMLService.renderWithInlineImages`）
/// - markdown.css / scroll.css / 主题 CSS → 内联 `<style>`
/// - KaTeX：`katex.min.css`（字体 `url(fonts/*.woff2)` 改写为 base64）+ `katex.min.js`
/// - Mermaid：`mermaid.min.js`
/// - 代码高亮：`prism-core` + 全部 `prism-<lang>` 语言组件（取代联网的 autoloader）
/// - `markdown-reader.js` 负责在浏览器里复用 app 同一套 prism/katex/mermaid 初始化逻辑
///
/// mermaid.min.js / katex 体积较大，仅在文档实际用到时才内联，避免普通文档导出动辄数 MB。
enum HTMLExportService {

    private static let logger = Logger(subsystem: "com.ft07.markmark", category: "HTMLExportService")

    /// 构建自包含 HTML 字符串。
    static func buildSelfContainedHTML(
        content: String,
        title: String,
        themeCSS: String,
        contentPadding: CGFloat,
        maxContentWidthFollowsWindow: Bool,
        baseURL: URL?,
        isDark: Bool,
        mathEnabled: Bool = true
    ) -> String {
        // 1. 正文：图片以 base64 内联，使导出文件不依赖原始图片路径
        let bodyHTML = MarkdownHTMLService.renderWithInlineImages(content, baseURL: baseURL, mathEnabled: mathEnabled).html

        // 2. 特性探测：按需内联体积较大的库
        let hasMermaid = detectMermaid(content)
        let hasMath = mathEnabled && detectMath(content)

        // 3. 样式（顺序与阅读视图一致：基础样式 → KaTeX → 主题 → 内容变量）
        var styleBlock = ""
        styleBlock += wrapStyle(inlineResourceText("css/markdown.css"))
        styleBlock += wrapStyle(inlineResourceText("css/scroll.css"))
        if hasMath {
            styleBlock += wrapStyle(katexCSSWithInlinedFonts())
        }
        styleBlock += "<style id=\"mr-theme-style\">\(themeCSS)</style>\n"
        let maxWidth = maxContentWidthFollowsWindow ? "none" : "980px"
        styleBlock += "<style>:root { --content-padding: \(Int(contentPadding))px; --content-max-width: \(maxWidth); }</style>\n"

        // 4. 脚本（库需在 markdown-reader.js 之前）
        var scriptBlock = ""
        if hasMermaid {
            scriptBlock += wrapScript(inlineResourceText("js/mermaid.min.js"))
        }
        if hasMath {
            scriptBlock += wrapScript(inlineResourceText("js/katex.min.js"))
        }
        // Prism：内联 core + 全部语言组件，取代需要联网的 autoloader，保证离线高亮
        scriptBlock += wrapScript(inlineResourceText("js/prism-core.min.js"))
        for langPath in prismLanguageResourcePaths() {
            scriptBlock += wrapScript(inlineResourceText(langPath))
        }
        // markdown-reader.js：复用 app 的 prism/katex/mermaid 初始化（webkit 桥接均有守卫，浏览器安全）。
        // - data-mr-config：脚本内联无 src，用此标记让 markdown-reader.js 找到配置
        // - data-readonly：静态导出无法保存标注，关闭选词工具条与评论编辑/删除入口
        scriptBlock += "<script data-mr-config data-is-dark=\"\(isDark)\" data-readonly=\"true\">\n\(inlineResourceText("js/markdown-reader.js"))\n</script>\n"

        let safeTitle = title.isEmpty ? "MarkMark" : escapeHTML(title)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(safeTitle)</title>
            <meta name="generator" content="MarkMark">
        \(styleBlock)</head>
        <body>
            <div class="markdown-preview">
                <div id="mr-content">
        \(bodyHTML)
                </div>
            </div>
        \(scriptBlock)</body>
        </html>
        """
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 资源内联

    /// 读取 bundle 文本资源；缺失时记录并返回空串（导出降级而非崩溃）。
    private static func inlineResourceText(_ path: String) -> String {
        guard let text = MarkdownURLSchemeHandler.bundleResourceString(forPath: path) else {
            logger.warning("HTMLExport: missing bundle resource \(path, privacy: .public)")
            return ""
        }
        return text
    }

    private static func wrapStyle(_ css: String) -> String {
        css.isEmpty ? "" : "<style>\n\(css)\n</style>\n"
    }

    private static func wrapScript(_ js: String) -> String {
        js.isEmpty ? "" : "<script>\n\(js)\n</script>\n"
    }

    /// 读取 katex.min.css，并把其中 `url(fonts/NAME.woff2)` 改写为 base64 data URL，
    /// 使数学字体随文件一起离线渲染。woff/ttf 回退项保持原样（现代浏览器优先选用 woff2）。
    private static func katexCSSWithInlinedFonts() -> String {
        let css = inlineResourceText("css/katex.min.css")
        guard !css.isEmpty else { return css }

        let pattern = #"url\(fonts/([A-Za-z0-9_\-]+\.woff2)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return css }

        var result = css
        let matches = regex.matches(in: css, range: NSRange(css.startIndex..., in: css))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else { continue }
            let fileName = String(result[nameRange])
            guard let data = MarkdownURLSchemeHandler.bundleResourceData(forPath: "css/fonts/\(fileName)") else { continue }
            let base64 = data.base64EncodedString()
            result.replaceSubrange(fullRange, with: "url(data:font/woff2;base64,\(base64))")
        }
        return result
    }

    /// 目录里以 `prism-` 开头、但不是语言组件的文件。
    ///
    /// `core` 必须排除：重复内联会重建整个 `Prism` 对象、把先加载的语言全部抹掉，
    /// 之后 `Prism.languages.extend('c', …)` 这类组件随之抛错。
    static let nonLanguageComponents: Set<String> = ["core", "autoloader"]

    /// Prism 语言组件的依赖表（只列非核心依赖；`markup` / `css` / `clike` / `javascript`
    /// 由 prism-core 提供）。与随包组件同源：prismjs@1.29.0 的 components.json。
    static let prismDependencies: [String: [String]] = [
        "cpp": ["c"],
        "django": ["markup-templating"],
        "ejs": ["markup-templating"],
        "erb": ["ruby", "markup-templating"],
        "glsl": ["c"],
        "handlebars": ["markup-templating"],
        "json5": ["json"],
        "liquid": ["markup-templating"],
        "objectivec": ["c"],
        "opencl": ["c"],
        "php": ["markup-templating"],
        "plsql": ["sql"],
        "scala": ["java"],
        "shell-session": ["bash"],
        "tsx": ["jsx", "typescript"],
        "twig": ["markup-templating"],
        "vbnet": ["basic"],
    ]

    /// prism-<lang> 语言组件资源路径，按依赖顺序排列。
    ///
    /// 导出不使用 autoloader（它按需取文件），改为把语言组件全部内联，因此顺序必须自己保证。
    /// 顺序错了不只是那个语言不高亮：`prism-django` 之类组件在**加载时**就捕获
    /// `Prism.languages["markup-templating"]` 并注册无守卫的 tokenize 钩子，一旦依赖还没加载，
    /// 它会让整页每一次高亮都抛 TypeError——表现为所有代码块都是灰的。
    private static func prismLanguageResourcePaths() -> [String] {
        guard let jsDir = MarkdownURLSchemeHandler.bundleResourceURL(forPath: "js") else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: jsDir.path)) ?? []
        let available = Set(
            files.filter { $0.hasPrefix("prism-") && $0.hasSuffix(".min.js") }
                .map { String($0.dropFirst("prism-".count).dropLast(".min.js".count)) }
                .filter { !nonLanguageComponents.contains($0) }
        )
        return orderedPrismLanguages(available: available).map { "js/prism-\($0).min.js" }
    }

    /// 纯逻辑：给定可用的 prism 语言组件名集合，返回应内联的语言（依赖优先、剔除依赖缺失者）。
    /// 抽出便于单元测试（运行 swift test 时取不到 bundle 资源）。
    static func orderedPrismLanguages(available: Set<String>) -> [String] {
        let core: Set<String> = ["markup", "css", "clike", "javascript"]
        var ordered: [String] = []
        var resolved: Set<String> = []
        var visiting: Set<String> = []
        var unusable: [String: [String]] = [:]

        /// 该语言能否安全内联；可以则按依赖优先追加进 `ordered`。
        func resolve(_ language: String) -> Bool {
            if core.contains(language) || resolved.contains(language) { return true }
            guard available.contains(language) else { return false }
            guard !visiting.contains(language) else { return false }  // 成环（Prism 里不存在，防御）
            visiting.insert(language)
            defer { visiting.remove(language) }
            for dependency in prismDependencies[language] ?? [] {
                guard resolve(dependency) else {
                    unusable[language, default: []].append(dependency)
                    return false
                }
            }
            resolved.insert(language)
            ordered.append(language)
            return true
        }

        for language in available.subtracting(nonLanguageComponents).sorted() {
            _ = resolve(language)
        }
        for (language, dependencies) in unusable.sorted(by: { $0.key < $1.key }) {
            logger.warning("HTMLExport: prism-\(language) skipped, missing dependency: \(dependencies.joined(separator: ", "))")
        }
        return ordered
    }

    // MARK: - 特性探测

    private static func detectMermaid(_ content: String) -> Bool {
        content.contains("```mermaid") || content.contains("~~~mermaid")
    }

    /// 探测文档是否含 KaTeX 数学：块级 ```math / 围栏，或行内/块级 `$...$` `$$...$$`。
    private static func detectMath(_ content: String) -> Bool {
        if content.contains("```math") || content.contains("```latex") || content.contains("```katex") {
            return true
        }
        if content.contains("$$") { return true }
        // 行内 $...$（要求成对、同一行、结尾不跟数字），与渲染管线的判定保持一致
        if let regex = try? NSRegularExpression(pattern: #"(?<!\$)\$(?![\s$])([^\n\x{0000}$]+?)(?<!\s)\$(?![\d$])"#, options: []) {
            let range = NSRange(content.startIndex..., in: content)
            if regex.firstMatch(in: content, range: range) != nil { return true }
        }
        return false
    }
}
