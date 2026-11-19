import Foundation

/// ツールの結果が読んだ・書いたファイル（`ChatMessage.files`）。daemon が transcript の行の `toolUseResult` から作る。
/// 本文の全文と画像は載せない（backlog が重くなる）。中身は `GET /v1/chat/{pane_id}/files/{tool_id}` で取る
public struct ChatFile: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Hashable, Sendable {
        /// Read で文を読んだ
        case read
        /// Write で新しく書いた
        case created
        /// Edit・Write の上書き・Bash で変えた
        case edited
        /// Read で画像を読んだ
        case image
    }

    /// セッションのマシンの絶対パス。画像の Read で、呼び出しの行が transcript の読んだ範囲より前にあると分からない
    public var path: String?
    public var action: Action
    /// `edited` の diff。`hunkByteLimit` を超えたら空にして `hunksOmitted`（中身の口から unified diff で取る）
    public var hunks: [ChatDiffHunk]
    public var hunksOmitted: Bool
    /// 足した行・消した行の数（`created` は書いた行の数を足した数にする）
    public var added: Int
    public var removed: Int
    /// `read` の読んだ範囲（1 始まり）と、ファイル全体の行の数
    public var firstLine: Int?
    public var lineCount: Int?
    public var totalLines: Int?
    /// `image` の種類（`image/png`）、元のファイルの大きさ、元の幅と高さ（px）
    public var mediaType: String?
    public var bytes: Int?
    public var width: Int?
    public var height: Int?
    /// transcript の中の、この結果の行の先頭の位置（バイト）。中身の口の `at` に渡す
    public var offset: UInt64

    /// これを超える diff は `ChatMessage` に載せない
    public static let hunkByteLimit = 32 * 1024

    public init(
        path: String?, action: Action, hunks: [ChatDiffHunk] = [], hunksOmitted: Bool = false, added: Int = 0, removed: Int = 0,
        firstLine: Int? = nil, lineCount: Int? = nil, totalLines: Int? = nil, mediaType: String? = nil, bytes: Int? = nil,
        width: Int? = nil, height: Int? = nil, offset: UInt64
    ) {
        self.path = path
        self.action = action
        self.hunks = hunks
        self.hunksOmitted = hunksOmitted
        self.added = added
        self.removed = removed
        self.firstLine = firstLine
        self.lineCount = lineCount
        self.totalLines = totalLines
        self.mediaType = mediaType
        self.bytes = bytes
        self.width = width
        self.height = height
        self.offset = offset
    }

    /// 書いた文の行の数。末尾の改行の後ろは行に数えない
    public static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let breaks = text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return text.utf8.last == 0x0A ? breaks : breaks + 1
    }

    /// 中身の口で頼む部分
    public enum Part: String, Sendable {
        /// 読んだ文・書いた文・diff・画像（action で決まる）
        case content
        /// 変える前のファイルの全文（Edit・Write の上書きだけ。diff の畳んだ行を開く）
        case original
    }
}

/// unified diff の 1 塊（Claude Code の `structuredPatch` と `bashEditDiff.files[].hunks` の形）。
/// `lines` の先頭の 1 字が ` `（変わらない）・`-`（消した）・`+`（足した）
public struct ChatDiffHunk: Codable, Hashable, Sendable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [String]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    public var added: Int { lines.count(where: { $0.hasPrefix("+") }) }
    public var removed: Int { lines.count(where: { $0.hasPrefix("-") }) }

    /// 中身の口が diff を返す形（`text/x-diff`）
    public static func unified(_ hunks: [ChatDiffHunk]) -> String {
        hunks.map { hunk in
            (["@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"] + hunk.lines).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// `unified` の逆。`@@` の行より前の行（ファイルの見出し）は読み飛ばす。数を省いた見出し（`@@ -3 +3 @@`）は 1 行
    public static func parse(unified text: String) -> [ChatDiffHunk] {
        var hunks: [ChatDiffHunk] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@"), let header = header(line) {
                hunks.append(ChatDiffHunk(oldStart: header.0, oldLines: header.1, newStart: header.2, newLines: header.3, lines: []))
            } else if !hunks.isEmpty, let first = line.first, first == " " || first == "-" || first == "+" {
                hunks[hunks.count - 1].lines.append(String(line))
            }
        }
        return hunks
    }

    private static func header(_ line: Substring) -> (Int, Int, Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ part: Substring) -> (Int, Int)? {
            let numbers = part.dropFirst().split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
            guard let start = numbers.first ?? nil else { return nil }
            if numbers.count == 1 { return (start, 1) }
            guard numbers.count == 2, let count = numbers[1] else { return nil }
            return (start, count)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }
}

/// diff を画面の行に並べる。hunk の間の変わらない行は `gap` に畳み、変える前の全文（`original`）があれば開ける
public enum ChatDiffRow: Hashable, Sendable, Identifiable {
    public enum Change: Hashable, Sendable { case context, removed, added }

    /// `old`・`new` は行番号（消した行は new が、足した行は old が無い）
    case line(id: Int, change: Change, old: Int?, new: Int?, text: String)
    /// 畳んだ変わらない行。`oldStart` から `count` 行。`lines` は変える前の全文から切り出した行（無ければ開けない）
    case gap(id: Int, oldStart: Int, newStart: Int, count: Int, lines: [String]?)

    public var id: Int {
        switch self {
        case .line(let id, _, _, _, _), .gap(let id, _, _, _, _): id
        }
    }

    /// 先頭の hunk の前と hunk どうしの間を `gap` にする。最後の hunk の後ろは、変える前の全文があるときだけ
    public static func rows(_ hunks: [ChatDiffHunk], original: [String]? = nil) -> [ChatDiffRow] {
        var rows: [ChatDiffRow] = []
        var nextOld = 1
        var nextNew = 1
        func gap(upTo oldEnd: Int) {
            let count = oldEnd - nextOld
            guard count > 0 else { return }
            let lines = original.flatMap { all in nextOld - 1 + count <= all.count ? Array(all[(nextOld - 1)..<(nextOld - 1 + count)]) : nil }
            rows.append(.gap(id: rows.count, oldStart: nextOld, newStart: nextNew, count: count, lines: lines))
        }
        for hunk in hunks {
            // 空のファイルへの追加は oldStart が 0（行の無い位置）
            let start = max(hunk.oldStart, 1)
            gap(upTo: start)
            var old = start
            var new = max(hunk.newStart, 1)
            for raw in hunk.lines {
                let text = String(raw.dropFirst())
                switch raw.first {
                case "-":
                    rows.append(.line(id: rows.count, change: .removed, old: old, new: nil, text: text))
                    old += 1
                case "+":
                    rows.append(.line(id: rows.count, change: .added, old: nil, new: new, text: text))
                    new += 1
                default:
                    rows.append(.line(id: rows.count, change: .context, old: old, new: new, text: text))
                    old += 1
                    new += 1
                }
            }
            nextOld = old
            nextNew = new
        }
        if let original, !hunks.isEmpty { gap(upTo: original.count + 1) }
        return rows
    }
}

/// 中身の口の応答
public enum ChatFileContent: Hashable, Sendable {
    /// 読んだ文・書いた文・変える前の全文
    case text(String)
    case diff([ChatDiffHunk])
    case image(Data)
}
