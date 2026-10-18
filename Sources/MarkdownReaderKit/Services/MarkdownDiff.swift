import Foundation
import Markdown

/// Markdown 块级 diff：把「修改前」与「修改后」两版文档切成块（段落、标题、列表项、表格、代码块…），
/// 用 LCS 对齐后标出新增 / 删除 / 修改的块。渲染视图据此在新文档上叠加 diff 标记，
/// 修改块内部的逐词 diff 由前端（markdown-reader.js）在 DOM 文本上完成，以保留行内格式。
///
/// 比较时忽略 CriticMarkup：两侧都先按「拒绝全部修改」还原（删除评论、去掉新增建议），
/// 这样用户在 diff 视图里继续加批注，不会让批注本身被当成改动。
public enum MarkdownDiff {

    // MARK: - 数据结构

    public struct Block: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case paragraph, heading, listItem, blockQuote, code, table, thematicBreak, html, other
        }
        public let kind: Kind
        /// 起止源码行（1 基，含）
        public let startLine: Int
        public let endLine: Int
        /// 块的源码（原样，含 CriticMarkup）
        public let source: String
        /// 比较用的规范化文本：去掉 CriticMarkup、列表标记，压缩空白。为空表示「透明块」（如纯批注段落）
        public let key: String
    }

    public enum Change: Equatable, Sendable {
        case equal(old: Int, new: Int)
        case inserted(new: Int)
        case deleted(old: Int)
        case modified(old: Int, new: Int)
    }

    public struct Stats: Equatable, Sendable {
        public var added = 0
        public var deleted = 0
        public var modified = 0
        public var total: Int { added + deleted + modified }
        public init(added: Int = 0, deleted: Int = 0, modified: Int = 0) {
            self.added = added
            self.deleted = deleted
            self.modified = modified
        }
    }

    public struct Result: Sendable {
        public let oldBlocks: [Block]
        public let newBlocks: [Block]
        /// 按文档顺序排列的变化序列（删除块排在它原来位置之后的第一个新块之前）
        public let changes: [Change]

        public var stats: Stats {
            var s = Stats()
            for c in changes {
                switch c {
                case .inserted: s.added += 1
                case .deleted: s.deleted += 1
                case .modified: s.modified += 1
                case .equal: break
                }
            }
            return s
        }
    }

    // MARK: - 入口

    public static func diff(old: String, new: String) -> Result {
        let oldBlocks = blocks(in: old)
        let newBlocks = blocks(in: new)
        // 透明块（纯批注段落）不参与对齐
        let oldIdx = oldBlocks.indices.filter { !oldBlocks[$0].key.isEmpty }
        let newIdx = newBlocks.indices.filter { !newBlocks[$0].key.isEmpty }
        let ops = lcsOps(oldIdx.map { oldBlocks[$0].key }, newIdx.map { newBlocks[$0].key })

        var changes: [Change] = []
        var pendingDel: [Int] = []
        var pendingIns: [Int] = []
        func flush() {
            changes.append(contentsOf: pairRun(deleted: pendingDel, inserted: pendingIns, old: oldBlocks, new: newBlocks))
            pendingDel.removeAll()
            pendingIns.removeAll()
        }
        for op in ops {
            switch op {
            case .equal(let o, let n):
                flush()
                changes.append(.equal(old: oldIdx[o], new: newIdx[n]))
            case .delete(let o):
                pendingDel.append(oldIdx[o])
            case .insert(let n):
                pendingIns.append(newIdx[n])
            }
        }
        flush()
        return Result(oldBlocks: oldBlocks, newBlocks: newBlocks, changes: changes)
    }

    /// 两版文档在忽略 CriticMarkup 后是否有差异。
    public static func hasChanges(old: String, new: String) -> Bool {
        normalizedDocument(old) != normalizedDocument(new)
    }

    // MARK: - 切块

    public static func blocks(in source: String) -> [Block] {
        let blanked = blankFrontMatter(source)
        let lines = blanked.components(separatedBy: "\n")
        let doc = Markdown.Document(parsing: blanked, options: [.disableSmartOpts])
        var result: [Block] = []

        func slice(_ start: Int, _ end: Int) -> String {
            guard start >= 1, start <= end, end <= lines.count else { return "" }
            return lines[(start - 1)...(end - 1)].joined(separator: "\n")
        }
        func add(_ kind: Block.Kind, _ markup: Markup) {
            guard let range = markup.range else { return }
            var end = range.upperBound.line
            // cmark 的块末行有时落在其后的空行上
            while end > range.lowerBound.line, end <= lines.count,
                  lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1
            }
            let src = slice(range.lowerBound.line, end)
            result.append(Block(kind: kind, startLine: range.lowerBound.line, endLine: end,
                                source: src, key: normalizedKey(src, kind: kind)))
        }

        for child in doc.children {
            switch child {
            case let list as UnorderedList:
                for item in list.listItems { add(.listItem, item) }
            case let list as OrderedList:
                for item in list.listItems { add(.listItem, item) }
            case is Paragraph: add(.paragraph, child)
            case is Heading: add(.heading, child)
            case is BlockQuote: add(.blockQuote, child)
            case is CodeBlock: add(.code, child)
            case is Table: add(.table, child)
            case is ThematicBreak: add(.thematicBreak, child)
            case is HTMLBlock: add(.html, child)
            default: add(.other, child)
            }
        }
        return result
    }

    /// 比较用的规范化：CriticMarkup 还原为原文、列表项去掉标记（编号变化不算改动）、空白压缩。
    static func normalizedKey(_ source: String, kind: Block.Kind) -> String {
        var s = CriticMarkup.rejecting(source)
        if kind == .listItem {
            s = s.replacingOccurrences(of: #"^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#,
                                       with: "", options: .regularExpression)
        }
        if kind == .code {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func normalizedDocument(_ source: String) -> String {
        blocks(in: source).map(\.key).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// YAML front matter 换成等量空行：不参与 diff，同时保持行号与源码一致。
    private static func blankFrontMatter(_ content: String) -> String {
        guard let range = content.range(of: #"^---\s*\n[\s\S]*?\n---\s*\n"#, options: .regularExpression) else {
            return content
        }
        var result = content
        let newlines = content[range].filter { $0 == "\n" }.count
        result.replaceSubrange(range, with: String(repeating: "\n", count: newlines))
        return result
    }

    // MARK: - LCS

    enum Op: Equatable {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// 经典 LCS（先剥掉公共前后缀以缩小 DP 表）。结果按顺序给出 equal / delete / insert，
    /// 同一段差异中 delete 排在 insert 之前。
    static func lcsOps(_ a: [String], _ b: [String]) -> [Op] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        var ops: [Op] = (0..<prefix).map { .equal($0, $0) }
        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])
        let n = aMid.count, m = bMid.count

        if n == 0 || m == 0 || n * m > 4_000_000 {
            // 无公共部分可找（或规模过大）：整段删除 + 整段新增
            ops += (0..<n).map { .delete(prefix + $0) }
            ops += (0..<m).map { .insert(prefix + $0) }
        } else {
            // dp[i][j] = aMid[i...] 与 bMid[j...] 的 LCS 长度
            var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
            let w = m + 1
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i * w + j] = aMid[i] == bMid[j]
                        ? dp[(i + 1) * w + j + 1] + 1
                        : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
                }
            }
            var i = 0, j = 0
            var dels: [Op] = [], ins: [Op] = []
            while i < n || j < m {
                if i < n, j < m, aMid[i] == bMid[j] {
                    ops += dels + ins
                    dels.removeAll(); ins.removeAll()
                    ops.append(.equal(prefix + i, prefix + j))
                    i += 1; j += 1
                } else if j >= m || (i < n && dp[(i + 1) * w + j] >= dp[i * w + j + 1]) {
                    dels.append(.delete(prefix + i)); i += 1
                } else {
                    ins.append(.insert(prefix + j)); j += 1
                }
            }
            ops += dels + ins
        }
        let tailStartA = a.count - suffix, tailStartB = b.count - suffix
        ops += (0..<suffix).map { .equal(tailStartA + $0, tailStartB + $0) }
        return ops
    }

    // MARK: - 修改块配对

    /// 一段连续的删除 + 新增：按顺序把相似的旧块 / 新块配成「修改」，其余保持删除 / 新增。
    /// 输出顺序：每个新块之前先放与它位置相邻的未配对删除块，保证删除块显示在原位附近。
    private static func pairRun(deleted: [Int], inserted: [Int], old: [Block], new: [Block]) -> [Change] {
        guard !deleted.isEmpty || !inserted.isEmpty else { return [] }
        // 先按顺序贪心配对：每个新块找剩余删除块里第一个足够相似、类型相容的
        var pairOf = [Int?](repeating: nil, count: inserted.count)
        var searchFrom = 0
        for (i, n) in inserted.enumerated() {
            for k in searchFrom..<deleted.count where compatible(old[deleted[k]].kind, new[n].kind)
                && similarity(old[deleted[k]].key, new[n].key) >= 0.4 {
                pairOf[i] = k
                searchFrom = k + 1
                break
            }
        }
        // 再输出：旧内容在前、新内容在后。未配对的删除块排在下一个配对点之前
        var out: [Change] = []
        var cursor = 0
        for (i, n) in inserted.enumerated() {
            let nextPaired = pairOf[i...].compactMap { $0 }.first ?? deleted.count
            while cursor < nextPaired {
                out.append(.deleted(old: deleted[cursor]))
                cursor += 1
            }
            if let k = pairOf[i] {
                out.append(.modified(old: deleted[k], new: n))
                cursor = k + 1
            } else {
                out.append(.inserted(new: n))
            }
        }
        while cursor < deleted.count {
            out.append(.deleted(old: deleted[cursor]))
            cursor += 1
        }
        return out
    }

    private static func compatible(_ a: Block.Kind, _ b: Block.Kind) -> Bool {
        if a == b { return true }
        let prose: Set<Block.Kind> = [.paragraph, .listItem, .blockQuote]
        return prose.contains(a) && prose.contains(b)
    }

    /// 字符二元组 Dice 系数（对中英文都适用）。
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let ca = Array(a), cb = Array(b)
        guard ca.count >= 2, cb.count >= 2 else { return 0 }
        var grams: [String: Int] = [:]
        for i in 0..<(ca.count - 1) { grams[String(ca[i...i + 1]), default: 0] += 1 }
        var common = 0
        for i in 0..<(cb.count - 1) {
            let g = String(cb[i...i + 1])
            if let c = grams[g], c > 0 { common += 1; grams[g] = c - 1 }
        }
        return Double(2 * common) / Double(ca.count + cb.count - 2)
    }
}

// MARK: - 渲染载荷

extension MarkdownDiff {

    /// 交给 markdown-reader.js（`MR.applyDiff`）的 diff 描述，按新文档的源码行号定位块。
    public struct Payload: Encodable, Sendable {
        public struct Mark: Encodable, Sendable {
            public let line: Int
            public let status: String        // "added" | "modified"
            public let kind: String
            public let oldHTML: String?      // 修改块的旧版渲染结果（前端据此做逐词 diff）
        }
        public struct Removed: Encodable, Sendable {
            public let afterLine: Int        // 前一个新块的起始行（0 表示文档开头）
            public let beforeLine: Int       // 后一个新块的起始行（0 表示文档末尾）
            public let kind: String
            public let html: String
        }
        public let added: Int
        public let deleted: Int
        public let modified: Int
        public let marks: [Mark]
        public let removed: [Removed]
    }

    /// 生成 JSON 载荷。`render` 负责把旧块源码渲染成 HTML（与正文同一渲染管线）。
    public static func payloadJSON(old: String, new: String, render: (String) -> String) -> String? {
        payload(old: old, new: new, render: render).json
    }

    /// 同 `payloadJSON`，并返回统计（避免调用方为显示数字再算一遍 diff）。
    public static func payload(old: String, new: String, render: (String) -> String) -> (json: String?, stats: Stats) {
        let result = diff(old: old, new: new)
        let stats = result.stats
        var marks: [Payload.Mark] = []
        var removed: [Payload.Removed] = []
        var lastNewLine = 0

        // 删除块的「后一个新块」：变化序列里它之后第一个带新块的项
        func nextNewLine(after index: Int) -> Int {
            for c in result.changes[(index + 1)...] {
                switch c {
                case .equal(_, let n), .inserted(let n), .modified(_, let n):
                    return result.newBlocks[n].startLine
                case .deleted: continue
                }
            }
            return 0
        }
        func renderOld(_ block: Block) -> String {
            render(CriticMarkup.rejecting(block.source))
        }

        for (i, c) in result.changes.enumerated() {
            switch c {
            case .equal(_, let n):
                lastNewLine = result.newBlocks[n].startLine
            case .inserted(let n):
                let b = result.newBlocks[n]
                marks.append(.init(line: b.startLine, status: "added", kind: b.kind.rawValue, oldHTML: nil))
                lastNewLine = b.startLine
            case .modified(let o, let n):
                let b = result.newBlocks[n]
                marks.append(.init(line: b.startLine, status: "modified", kind: b.kind.rawValue,
                                   oldHTML: renderOld(result.oldBlocks[o])))
                lastNewLine = b.startLine
            case .deleted(let o):
                let b = result.oldBlocks[o]
                removed.append(.init(afterLine: lastNewLine, beforeLine: nextNewLine(after: i),
                                     kind: b.kind.rawValue, html: renderOld(b)))
            }
        }

        let payload = Payload(added: stats.added, deleted: stats.deleted, modified: stats.modified,
                              marks: marks, removed: removed)
        let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
        return (json, stats)
    }
}
