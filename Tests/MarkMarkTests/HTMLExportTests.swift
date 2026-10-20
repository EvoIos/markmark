import Foundation
import Testing
@testable import MarkMark

@Suite("HTML export")
struct HTMLExportTests {

    private func build(_ content: String, baseURL: URL? = nil) -> String {
        HTMLExportService.buildSelfContainedHTML(
            content: content,
            title: "Sample",
            themeCSS: ":root { --accent: #f00; }",
            contentPadding: 24,
            maxContentWidthFollowsWindow: false,
            baseURL: baseURL,
            isDark: false
        )
    }

    @Test("produces a complete, titled HTML document with the rendered body")
    func producesCompleteDocument() {
        let html = build("# Hello\n\nWorld **bold**.")
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<title>Sample</title>"))
        #expect(html.contains("id=\"mr-content\""))
        #expect(html.contains("class=\"markdown-preview\""))
        // 正文已渲染
        #expect(html.contains(">Hello</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        // 主题 CSS 被内联
        #expect(html.contains("--accent: #f00;"))
        // 内容变量
        #expect(html.contains("--content-padding: 24px"))
    }

    @Test("export is self-contained: no mr:// scheme references remain")
    func selfContainedNoSchemeRefs() {
        let html = build("# Title\n\n```swift\nlet x = 1\n```\n")
        #expect(!html.contains("mr://"))
    }

    // 注意：导出时 prism 组件/增强层是从 bundle 里读出来内联的，单元测试进程里
    // `MarkdownURLSchemeHandler.bundleResourceString` 取不到 app 资源（返回空串），
    // 所以「增强层是否真的被内联」只能在运行时验证，不在这里断言。


    @Test("local images are inlined as base64 data URLs")
    func inlinesLocalImages() throws {        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-html-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 最小合法 1x1 PNG
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let pngData = Data(base64Encoded: pngBase64)!
        try pngData.write(to: dir.appendingPathComponent("pic.png"))

        let html = build("![alt](pic.png)\n", baseURL: dir)
        #expect(html.contains("data:image/png;base64,"))
        #expect(!html.contains("src=\"pic.png\""))
    }

    // MARK: - Prism 语言组件排序（离线内联，无 autoloader）

    @Test("php is inlined, after the markup-templating it depends on")
    func prismIncludesPHPAfterMarkupTemplating() {
        let langs = HTMLExportService.orderedPrismLanguages(
            available: ["php", "markup-templating", "swift", "python"]
        )
        #expect(langs.contains("php"))
        func idx(_ l: String) -> Int { langs.firstIndex(of: l)! }
        #expect(idx("markup-templating") < idx("php"))
    }

    @Test("dependency providers precede the components that extend them")
    func prismDependencyOrder() {
        let langs = HTMLExportService.orderedPrismLanguages(
            available: ["cpp", "c", "tsx", "jsx", "typescript", "shell-session", "bash", "swift"]
        )
        func idx(_ l: String) -> Int { langs.firstIndex(of: l)! }
        #expect(idx("c") < idx("cpp"))
        #expect(idx("bash") < idx("shell-session"))
        #expect(idx("jsx") < idx("tsx"))
        #expect(idx("typescript") < idx("tsx"))
    }

    @Test("ordering holds for dependencies that sort after their dependents")
    func prismOrderIsNotAlphabetical() {
        // 按字母序 plsql/vbnet 都排在依赖前面——顺序必须来自依赖图而不是字母序
        let langs = HTMLExportService.orderedPrismLanguages(
            available: ["plsql", "sql", "vbnet", "basic", "scala", "java", "objectivec", "c", "json5", "json"]
        )
        func idx(_ l: String) -> Int { langs.firstIndex(of: l)! }
        #expect(idx("plsql") > idx("sql"))
        #expect(idx("vbnet") > idx("basic"))
        #expect(idx("scala") > idx("java"))
        #expect(idx("objectivec") > idx("c"))
        #expect(idx("json5") > idx("json"))
    }

    @Test("templating components load after markup-templating (their load-time capture)")
    func prismTemplatingOrder() {
        let langs = HTMLExportService.orderedPrismLanguages(
            available: ["markup-templating", "django", "handlebars", "twig", "liquid", "ejs", "erb", "ruby"]
        )
        func idx(_ l: String) -> Int { langs.firstIndex(of: l)! }
        for dependent in ["django", "handlebars", "twig", "liquid", "ejs", "erb"] {
            #expect(idx("markup-templating") < idx(dependent), "\(dependent) must follow markup-templating")
        }
        #expect(idx("ruby") < idx("erb"))
    }

    @Test("core and autoloader are never treated as languages")
    func prismSkipsNonLanguageComponents() {
        let langs = HTMLExportService.orderedPrismLanguages(
            available: ["core", "autoloader", "swift"]
        )
        #expect(langs == ["swift"])
    }

    @Test("languages whose dependency is missing are dropped, not ordered")
    func prismDropsUnloadableLanguages() {
        // 缺 basic → vbnet 必须被剔除，否则导出页里它会抛错
        let langs = HTMLExportService.orderedPrismLanguages(available: ["vbnet", "swift", "python"])
        #expect(!langs.contains("vbnet"))
        #expect(Set(langs) == ["swift", "python"])
        #expect(HTMLExportService.orderedPrismLanguages(available: []).isEmpty)
    }

    @Test("with the full table available, every dependency is ordered first")
    func prismFullGraphOrdering() {
        var available = Set(HTMLExportService.prismDependencies.keys)
        for dependencies in HTMLExportService.prismDependencies.values {
            available.formUnion(dependencies)
        }
        let langs = HTMLExportService.orderedPrismLanguages(available: available)
        #expect(Set(langs) == available.subtracting(HTMLExportService.nonLanguageComponents))

        for (language, dependencies) in HTMLExportService.prismDependencies {
            guard let position = langs.firstIndex(of: language) else {
                Issue.record("\(language) is missing from the order")
                continue
            }
            for dependency in dependencies where langs.contains(dependency) {
                let dependencyPosition = langs.firstIndex(of: dependency)!
                #expect(dependencyPosition < position, "\(dependency) must precede \(language)")
            }
        }
    }
}
