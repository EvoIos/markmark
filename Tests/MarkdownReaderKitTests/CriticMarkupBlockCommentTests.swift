import Testing
@testable import MarkdownReaderKit

// MARK: - 段落批注（块间「+」插入的独立批注）

@Suite("CriticMarkup block comments")
struct CriticMarkupBlockCommentTests {

    @Test("inserts a standalone comment paragraph after the given line")
    func insertsBetweenBlocks() {
        let src = "第一段\n\n第二段\n"
        let result = CriticMarkup.insertBlockComment(in: src, afterLine: 1, comment: "需要补数据")
        #expect(result?.source == "第一段\n\n{>>需要补数据<<}\n\n第二段\n")
        #expect(result?.annotations == [.init(kind: .comment, text: "需要补数据", payload: nil)])
    }

    @Test("adds a separating blank line when the next line is not blank")
    func separatesFromFollowingLine() {
        let src = "| a |\n|---|\n| 1 |\nNext"
        let result = CriticMarkup.insertBlockComment(in: src, afterLine: 3, comment: "c")
        #expect(result?.source == "| a |\n|---|\n| 1 |\n\n{>>c<<}\n\nNext")
    }

    @Test("appends at the end of the document")
    func appendsAtEnd() {
        let result = CriticMarkup.insertBlockComment(in: "Only\n", afterLine: 1, comment: "c")
        #expect(result?.source == "Only\n\n{>>c<<}\n")
    }

    @Test("falls back from a trailing blank line to the block's last content line")
    func skipsTrailingBlankLines() {
        let result = CriticMarkup.insertBlockComment(in: "- a\n- b\n\n\nNext", afterLine: 4, comment: "c")
        #expect(result?.source == "- a\n- b\n\n{>>c<<}\n\n\nNext")
    }

    @Test("rejects empty comments and out-of-range lines")
    func rejectsInvalidInput() {
        #expect(CriticMarkup.insertBlockComment(in: "A", afterLine: 1, comment: "  \n ") == nil)
        #expect(CriticMarkup.insertBlockComment(in: "A", afterLine: 0, comment: "c") == nil)
        #expect(CriticMarkup.insertBlockComment(in: "A", afterLine: 5, comment: "c") == nil)
    }

    @Test("collapses blank lines inside the comment")
    func collapsesBlankLines() {
        let result = CriticMarkup.insertBlockComment(in: "A", afterLine: 1, comment: "x\n\n\ny")
        #expect(result?.source == "A\n\n{>>x\ny<<}")
    }

    @Test("deleting a block comment also removes its blank-line separator")
    func deleteRemovesParagraph() {
        let src = "A\n\n{>>c<<}\n\nB"
        #expect(CriticMarkup.deleteComment(in: src, comment: "c", nearLine: 3) == "A\n\nB")
        #expect(CriticMarkup.deleteComment(in: "A\n\n{>>c<<}\n", comment: "c", nearLine: 3) == "A\n")
    }

    @Test("inline comments are still deleted in place")
    func deleteInlineUntouched() {
        #expect(CriticMarkup.deleteComment(in: "A {>>c<<} B", comment: "c", nearLine: 1) == "A  B")
    }

    @Test("fragment export of a block comment includes the block above it")
    func fragmentIncludesPreviousBlock() {
        let src = "# 标题\n\n无关段落\n\n目标段落\n\n{>>请改写<<}\n\n后面的段落"
        let anns = CriticMarkup.parseAnnotations(in: src)
        let frags = CriticMarkup.fragments(for: anns, in: src)
        #expect(frags.count == 1)
        #expect(frags.first?.text == "目标段落\n\n{>>请改写<<}")
        #expect(frags.first?.heading == "# 标题")
    }

    @Test("block comment and an inline mark in the same block export once")
    func fragmentMergesOverlappingGroups() {
        let src = "目标{==段落==}{>>a<<}\n\n{>>b<<}\n\n后面"
        let frags = CriticMarkup.fragments(for: CriticMarkup.parseAnnotations(in: src), in: src)
        #expect(frags.count == 1)
        #expect(frags.first?.text == "目标{==段落==}{>>a<<}\n\n{>>b<<}")
    }
}

@Suite("Markdown HTML block line attributes")
struct MarkdownBlockLineAttrTests {

    @Test("blocks carry start and end source lines")
    func lineEndAttributes() {
        let html = MarkdownHTMLService.render("para one\ncontinues\n\n| a |\n|---|\n| 1 |\n| 2 |\n").html
        #expect(html.contains("<p data-line=\"1\" data-line-end=\"2\">"))
        #expect(html.contains("<table data-line=\"4\" data-line-end=\"7\">"))
    }

    @Test("front matter keeps body line numbers aligned with the source")
    func frontMatterPreservesLines() {
        let html = MarkdownHTMLService.render("---\ntitle: x\n---\nBody\n").html
        #expect(html.contains("<p data-line=\"4\" data-line-end=\"4\">"))
    }
}

@Suite("CriticMarkup nesting guard")
struct CriticMarkupNestingTests {

    @Test("selection inside an existing deletion is rejected instead of nesting")
    func rejectsNestedDeletion() {
        let src = "新增第三方{--登录（微信、Apple--}）"
        #expect(CriticMarkup.applyDetailed(.delete, to: src, selectedText: "登录（微信、Apple", nearLine: 1) == nil)
    }

    @Test("selection inside a highlight-with-comment is rejected")
    func rejectsNestedHighlight() {
        let src = "前文{==重点内容==}{>>评论<<}后文"
        #expect(CriticMarkup.applyDetailed(.highlight, to: src, selectedText: "点内", nearLine: 1) == nil)
    }

    @Test("same text outside annotations is still annotated")
    func plainTextStillWorks() {
        let src = "登录页面 {--旧的--}"
        #expect(CriticMarkup.apply(.delete, to: src, selectedText: "登录", nearLine: 1) == "{--登录--}页面 {--旧的--}")
    }

    @Test("selection straddling an annotation still absorbs it")
    func straddleStillAbsorbs() {
        let src = "abc {--def--} ghi"
        #expect(CriticMarkup.apply(.highlight, to: src, selectedText: "c def g", nearLine: 1) == "ab{==c {--def--} g==}hi")
    }
}
