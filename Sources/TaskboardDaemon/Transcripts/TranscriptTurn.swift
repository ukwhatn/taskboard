import Foundation

/// Stop hook のときの、終わったターンの様子。Claude Code の transcript（JSONL）の末尾から読む
public struct TranscriptTurn: Equatable, Sendable {
    /// 最後の人の発話の時刻
    public var startedAt: Date
    /// その後に taskboard 以外のツールを呼んだか（taskboard の tool だけなら、作業項目を読み書きしただけ）
    public var usedTools: Bool
    /// 人に読ませる・答えさせるもの（文書・質問・レビューの依頼・送る文面・AskUserQuestion・計画の承認）を出したか
    public var presented: Bool

    public init(startedAt: Date, usedTools: Bool, presented: Bool = false) {
        self.startedAt = startedAt
        self.usedTools = usedTools
        self.presented = presented
    }

    static let presentingTools: Set<String> = [
        "mcp__taskboard__doc_publish", "mcp__taskboard__ask_user", "mcp__taskboard__review_request", "mcp__taskboard__panel_set",
        "AskUserQuestion", "ExitPlanMode",
    ]

    /// 末尾 `tailBytes` を読む。1 ターンが長くても、人の発話がその中に無ければ nil（見直しをしないだけ）
    public static func read(_ url: URL, tailBytes: Int = 4 << 20) -> TranscriptTurn? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        // 途中から読んだときの先頭は行の途中
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return parse(lines)
    }

    static func parse(_ lines: [Data]) -> TranscriptTurn? {
        var usedTools = false
        var presented = false
        for line in lines.reversed() {
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let content = (entry["message"] as? [String: Any])?["content"]
            switch entry["type"] as? String {
            case "assistant":
                let blocks = content as? [[String: Any]] ?? []
                let tools = blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["name"] as? String }
                if tools.contains(where: { !$0.hasPrefix("mcp__taskboard__") }) { usedTools = true }
                if tools.contains(where: presentingTools.contains) { presented = true }
            case "user":
                guard TranscriptParser.humanPrompt(entry) != nil, let at = (entry["timestamp"] as? String).flatMap(parseDate) else { continue }
                return TranscriptTurn(startedAt: at, usedTools: usedTools, presented: presented)
            default:
                continue
            }
        }
        return nil
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
