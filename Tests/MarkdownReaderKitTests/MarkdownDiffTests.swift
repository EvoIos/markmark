import Testing
import Foundation
@testable import MarkdownReaderKit

@Suite("MarkdownDiff")
struct MarkdownDiffTests {

    @Test("identical documents have no changes")
    func identical() {
        let doc = "# T\n\nA para.\n\n- x\n- y\n"
        #expect(MarkdownDiff.diff(old: doc, new: doc).stats.total == 0)
        #expect(!MarkdownDiff.hasChanges(old: doc, new: doc))
    }

    @Test("detects added, deleted and modified blocks")
    func basicChanges() {
        let old = "# T\n\n第一段内容保持不变。\n\n第二段会被修改一些文字。\n\n第三段会被删除。\n"
        let new = "# T\n\n第一段内容保持不变。\n\n第二段会被修改了一些字。\n\n新增的一段。\n"
        let r = MarkdownDiff.diff(old: old, new: new)
        #expect(r.stats == MarkdownDiff.Stats(added: 1, deleted: 1, modified: 1))
    }

    @Test("list items are diffed individually and renumbering is ignored")
    func listItems() {
        let old = "1. alpha\n2. beta\n3. gamma\n"
        let new = "1. alpha\n2. gamma\n"
        let r = MarkdownDiff.diff(old: old, new: new)
        #expect(r.stats == MarkdownDiff.Stats(added: 0, deleted: 1, modified: 0))
        #expect(r.oldBlocks.map(\.kind) == [.listItem, .listItem, .listItem])
    }

    @Test("CriticMarkup annotations do not count as changes")
    func ignoresCriticMarkup() {
        let old = "Plain sentence here.\n\nNext block.\n"
        let new = "Plain {==sentence==}{>>why?<<} here.\n\n{>>block comment<<}\n\nNext {--block--}{++part++}.\n"
        #expect(!MarkdownDiff.hasChanges(old: old, new: new))
        #expect(MarkdownDiff.diff(old: old, new: new).stats.total == 0)
    }

    @Test("block lines skip front matter and trailing blank lines")
    func blockLines() {
        let blocks = MarkdownDiff.blocks(in: "---\na: 1\n---\n# H\n\npara\nmore\n\n\n- i\n")
        #expect(blocks.map(\.startLine) == [4, 6, 10])
        #expect(blocks[1].endLine == 7)
    }

    @Test("payload anchors deleted blocks between their neighbours")
    func payloadAnchors() throws {
        let old = "A\n\nB gone\n\nC\n"
        let new = "A\n\nC\n"
        let json = try #require(MarkdownDiff.payloadJSON(old: old, new: new) { "<p>\($0)</p>" })
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let removed = try #require(obj["removed"] as? [[String: Any]])
        #expect(removed.count == 1)
        #expect(removed[0]["afterLine"] as? Int == 1)
        #expect(removed[0]["beforeLine"] as? Int == 3)
        #expect(removed[0]["html"] as? String == "<p>B gone</p>")
    }

    @Test("modified block payload carries the old rendering without CriticMarkup")
    func payloadModified() throws {
        let old = "The quick brown fox jumps.\n"
        let new = "The quick red fox jumps.\n"
        let json = try #require(MarkdownDiff.payloadJSON(old: old, new: new) { $0 })
        #expect(json.contains("\"status\":\"modified\""))
        #expect(json.contains("brown"))
    }

    @Test("LCS keeps deletions before insertions within a run")
    func lcsOrdering() {
        let ops = MarkdownDiff.lcsOps(["a", "b", "c"], ["a", "x", "c"])
        #expect(ops == [.equal(0, 0), .delete(1), .insert(1), .equal(2, 2)])
    }
}

@Suite("MarkdownDiff ordering")
struct MarkdownDiffOrderingTests {

    @Test("unpaired deletions come before the insertions that replace them")
    func deletionsFirst() {
        let r = MarkdownDiff.diff(old: "# H\n\nold stuff entirely\n", new: "# H\n\nAAA one\n\nBBB two\n")
        let kinds = r.changes.map { c -> String in
            switch c {
            case .equal: return "="
            case .inserted: return "+"
            case .deleted: return "-"
            case .modified: return "~"
            }
        }
        #expect(kinds == ["=", "-", "+", "+"])
    }

    @Test("deletions between pairs stay in their original position")
    func interleaved() {
        let old = "alpha beta gamma\n\nremove me please\n\ndelta epsilon zeta\n"
        let new = "alpha beta gamma!\n\ndelta epsilon zeta!\n"
        let kinds = MarkdownDiff.diff(old: old, new: new).changes.map { c -> String in
            switch c {
            case .equal: return "="
            case .inserted: return "+"
            case .deleted: return "-"
            case .modified: return "~"
            }
        }
        #expect(kinds == ["~", "-", "~"])
    }
}
