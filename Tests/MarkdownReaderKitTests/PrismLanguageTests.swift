import Testing
import Foundation
@testable import MarkdownReaderKit

// MARK: - 围栏语言标签归一化

@Suite("Prism fence label normalization")
struct PrismLanguageTests {

    @Test("keeps canonical language names, lowercased")
    func canonicalPassthrough() {
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "swift") == "swift")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "Swift") == "swift")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "  PYTHON  ") == "python")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "objc") == "objc")
    }

    @Test("maps spellings Prism does not register itself")
    func aliasMapping() {
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "objective-c") == "objectivec")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "obj-c") == "objectivec")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "C++") == "cpp")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "cplusplus") == "cpp")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "c#") == "csharp")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "f#") == "fsharp")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "patch") == "diff")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "proto") == "protobuf")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "asm") == "nasm")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "golang") == "go")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "console") == "shell-session")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "zsh") == "bash")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "make") == "makefile")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "postgresql") == "sql")
    }

    @Test("drops fence info after the language token")
    func stripsInfoString() {
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "swift title=Example") == "swift")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "objective-c showLineNumbers") == "objectivec")
    }

    @Test("handles Pandoc-style curly brace info strings")
    func stripsPandocBraces() {
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "{.swift}") == "swift")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "{.objective-c .numberLines}") == "objectivec")
    }

    @Test("empty and unknown labels are handled")
    func edgeCases() {
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: nil) == "")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "") == "")
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "   ") == "")
        // 未知语言原样保留：Prism 与 autoloader 会各自决定是否处理
        #expect(MarkdownHTMLService.prismLanguage(forFenceLabel: "Brainfuck") == "brainfuck")
    }

    @Test("rendered HTML carries the normalized language class")
    func renderedClassIsNormalized() {
        let markdown = """
        ```objective-c
        NSString *optionQuoteType = @"x";
        ```

        ```C++
        int x = 1;
        ```

        ```{.objc}
        id y = nil;
        ```

        ```
        no language
        ```
        """
        let html = MarkdownHTMLService.render(markdown).html
        #expect(html.contains("class=\"language-objectivec\""))
        #expect(html.contains("class=\"language-cpp\""))
        #expect(html.contains("class=\"language-objc\""))
        // 无语言围栏：code 标签不带 language- 类（内容保留尾部换行）
        #expect(html.contains("<code>no language"))
        #expect(!html.contains("language-objective-c"))
        #expect(!html.contains("language-C++"))
        #expect(!html.contains("language-{.objc}"))
    }
}

// MARK: - ObjC 语法增强层

/// Prism 自带的 objectivec 语法对「纯消息发送」代码几乎不产出 token（只剩 operator/punctuation，
/// 而主题把这两个画成正文色），整块看起来像没高亮。`prism-objectivec-extra.js` 负责补
/// class-name / function / boolean 三类 token。这里只断言「页面确实引用了这个增强脚本、
/// 且顺序在 prism 之后」，token 生成本身由 Node 侧验证（见 CHANGELOG 记录的复现脚本）。
@Suite("ObjC highlighting enhancement wiring")
struct PrismObjcEnhancementTests {

    private static let scriptTag = "<script src=\"mr:///js/prism-objectivec-extra.js\"></script>"

    @Test("full HTML loads the enhancement script after prism core/autoloader")
    func fullHTMLIncludesEnhancement() {
        let html = MarkdownHTMLService.buildFullHTML(
            content: "```objc\nNSString *a = nil;\n```\n",
            themeCSS: "",
            contentPadding: 24,
            baseURL: nil,
            isDark: false
        )
        #expect(html.contains(Self.scriptTag))
        let autoloaderRange = html.range(of: "prism-autoloader.min.js")
        let extraRange = html.range(of: "prism-objectivec-extra.js")
        #expect(autoloaderRange != nil && extraRange != nil)
        if let autoloaderRange, let extraRange {
            #expect(autoloaderRange.lowerBound < extraRange.lowerBound)
        }
    }

    @Test("content-aware HTML (rendered view / Quick Look) loads the enhancement script")
    func contentAwareHTMLIncludesEnhancement() {
        let html = MarkdownHTMLService.buildContentAwareHTML(
            content: "```objc\nNSString *a = nil;\n```\n",
            themeCSS: "",
            contentPadding: 24,
            baseURL: nil,
            isDark: false,
            hasMermaid: false,
            hasKaTeX: false
        )
        #expect(html.contains(Self.scriptTag))
    }
}
