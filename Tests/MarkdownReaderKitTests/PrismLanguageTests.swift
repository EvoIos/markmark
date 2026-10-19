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
