import Foundation

/// 差分の行に付けたコメントを、次の発言に入れる文にする
public enum DiffLineComment {
    /// 行の中身はこの字数で切る
    public static let codeLimit = 120
    /// 複数の行を引くときは、頭からこの行数まで
    public static let lineLimit = 40

    public struct Line: Equatable, Sendable {
        public let change: ChatDiffRow.Change
        public let old: Int?
        public let new: Int?
        public let text: String

        public init(change: ChatDiffRow.Change, old: Int?, new: Int?, text: String) {
            self.change = change
            self.old = old
            self.new = new
            self.text = text
        }
    }

    /// 選んだ行へのコメント。1 行なら 1 行の形（`prompt(path:change:old:new:text:comment:)`）、複数なら「`path` 10〜12行目：」の後に diff の行を引く。
    /// 行番号は今の行番号の範囲で、消した行だけなら変える前の行番号の範囲
    public static func prompt(path: String, lines: [Line], comment: String) -> String {
        if lines.count == 1, let line = lines.first {
            return prompt(path: path, change: line.change, old: line.old, new: line.new, text: line.text, comment: comment)
        }
        let body = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lines.isEmpty else { return MarkdownCode.inline(path) + "：" + body }
        let current = lines.filter { $0.change != .removed }.compactMap(\.new)
        let numbers = current.isEmpty ? lines.compactMap(\.old) : current
        var place = MarkdownCode.inline(path)
        if let first = numbers.min(), let last = numbers.max() {
            let range = first == last ? "\(first)行目" : "\(first)〜\(last)行目"
            place += current.isEmpty ? " 変更前の\(range)" : " \(range)"
        }
        let quoted = lines.prefix(lineLimit).map { line in
            (line.change == .added ? "+" : line.change == .removed ? "-" : " ") + line.text
        } + (lines.count > lineLimit ? ["…"] : [])
        let fence = lines.contains { $0.text.contains("```") } ? "````" : "```"
        return ([place + "：", fence + "diff"] + quoted + [fence, body]).joined(separator: "\n")
    }

    /// 「`path` 12行目（`code`）：comment」。消した行は変える前の行番号で「変更前の12行目（消した行`code`）」。
    /// 行番号が無ければ path だけ、中身が空白だけなら括弧を省く
    public static func prompt(path: String, change: ChatDiffRow.Change, old: Int?, new: Int?, text: String, comment: String) -> String {
        let removed = change == .removed
        let number = removed ? old : new
        var place = MarkdownCode.inline(path)
        if let number { place += removed ? " 変更前の\(number)行目" : " \(number)行目" }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let cut = trimmed.count > codeLimit ? String(trimmed.prefix(codeLimit)) + "…" : trimmed
            place += removed ? "（消した行\(MarkdownCode.inline(cut))）" : "（\(MarkdownCode.inline(cut))）"
        }
        return place + "：" + comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
