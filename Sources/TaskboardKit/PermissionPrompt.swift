import CryptoKit
import Foundation

/// Claude Code の権限の確認（選択肢の 1 が Yes の確認）を画面の文字から読む。
///
/// 画面の形（Claude Code 2.1.290 の実測。P9 で使い捨ての herdr に写した）:
/// ```
/// ────────────────────            ← 上の枠
///  Bash command                   ← ツール
///  Create file c.txt and echo made
/// ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
///  touch c.txt && echo made       ← 中身
/// ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
///  Do you want to proceed?
///  ❯ 1. Yes
/// ```
/// `hash` は上の枠から「1. Yes」の直前まで（区切りの線を除く）の文字。空白をすべて落としてから数えるので、
/// pane の幅が変わって折り返しが変わっても同じ値になる。通知を出したときと応答のときで、同じ確認かを比べるのに使う
public struct PermissionPrompt: Hashable, Sendable {
    /// 確認の見出し（「Bash command」「Create file」など、Claude Code の文のまま）
    public var tool: String
    /// コマンドなら中身、ファイルなどなら見出しの下の行（パス・URL）。`summaryLimit` 字まで
    public var summary: String
    /// SHA-256 の hex
    public var hash: String

    public static let summaryLimit = 120
    /// 「1. Yes」を探す範囲（画面の下から）。上の方に残った前の確認の文と取り違えない
    static let scanLines = 20
    /// 上の枠を探す範囲（「1. Yes」から上へ）。見つからなければ `fallbackLines` 行だけを確認とみなす
    static let borderSearchLines = 60
    static let fallbackLines = 15

    public init(tool: String, summary: String, hash: String) {
        self.tool = tool
        self.summary = summary
        self.hash = hash
    }

    /// 権限の確認が出ていなければ nil
    public init?(screen: String) {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let yes = Self.yesLine(in: lines) else { return nil }
        let lowest = max(0, yes - Self.borderSearchLines)
        let border = (lowest..<yes).last { Self.isLine(lines[$0], of: "─") }
        let block = lines[(border.map { $0 + 1 } ?? max(0, yes - Self.fallbackLines))..<yes]

        var sections: [[String]] = [[]]
        for line in block {
            if Self.isLine(line, of: "╌") || Self.isLine(line, of: "─") {
                if !(sections.last ?? []).isEmpty { sections.append([]) }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { sections[sections.count - 1].append(trimmed) }
        }
        sections.removeAll { $0.isEmpty }
        // 最後の行が問い（「Do you want to proceed?」）なら中身から外す
        if let last = sections.last?.last, last.hasSuffix("?") {
            sections[sections.count - 1].removeLast()
            if sections.last?.isEmpty == true { sections.removeLast() }
        }
        let header = sections.first ?? []
        let tool = header.first ?? ""
        let headerRest = Array(header.dropFirst())
        let content = sections.count > 1 ? sections[1] : []
        let isCommand = tool.lowercased().contains("command")
        let parts = isCommand ? (content.isEmpty ? headerRest : content) : (headerRest.isEmpty ? content : headerRest)

        let normalized = block.filter { !Self.isLine($0, of: "╌") && !Self.isLine($0, of: "─") }
            .joined().filter { !$0.isWhitespace }
        self.tool = tool
        summary = Self.truncate(parts.joined(separator: " "))
        hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 選択肢の 1 が Yes の確認か（応答のシートが「許可」を出すか）。画面の下の方だけを見る
    public static func isPermissionPrompt(_ screen: String) -> Bool {
        yesLine(in: screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)) != nil
    }

    private static func yesLine(in lines: [String]) -> Int? {
        let start = max(0, lines.count - scanLines)
        return lines.indices[start...].last { lines[$0].range(of: #"^\s*[❯>]?\s*1\.\s*Yes\b"#, options: .regularExpression) != nil }
    }

    /// 区切りの線（1 種類の罫線の文字だけでできた行）か
    private static func isLine(_ line: String, of character: Character) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == character }
    }

    private static func truncate(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > summaryLimit else { return collapsed }
        return String(collapsed.prefix(summaryLimit - 1)) + "…"
    }
}
