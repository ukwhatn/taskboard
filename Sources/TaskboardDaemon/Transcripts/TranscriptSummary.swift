import Foundation
import TaskboardKit

/// Claude Code の transcript の末尾から、会話の題・最後の指示・ブランチ・最後の時刻を読む（`SessionHistory`）。
/// `ai-title` と `last-prompt` は発言のたびに書き足されるので末尾にある（216MB の transcript でも末尾 6KB 以内だった）。
/// 末尾で見つからなければ、読む範囲を広げて 1 回だけ読み直す
actor TranscriptSummaryReader {
    static let tailBytes = 256 << 10
    static let wideTailBytes = 4 << 20

    private let projects: URL
    /// 大きさと更新時刻が変わっていなければ読み直さない
    private var cache: [String: (size: UInt64, modified: Date, history: SessionHistory)] = [:]

    init(projects: URL) {
        self.projects = projects.standardizedFileURL.resolvingSymlinksInPath()
    }

    func history(sessionID: String) -> SessionHistory {
        guard let url = TranscriptTail.locate(sessionID, in: projects),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? UInt64, let modified = attributes[.modificationDate] as? Date
        else { return SessionHistory(sessionID: sessionID) }
        if let cached = cache[url.path], cached.size == size, cached.modified == modified { return cached.history }
        var history = Self.read(url, sessionID: sessionID, size: size, tail: Self.tailBytes)
        if history.aiTitle == nil, history.customTitle == nil, size > UInt64(Self.tailBytes) {
            history = Self.read(url, sessionID: sessionID, size: size, tail: Self.wideTailBytes)
        }
        cache[url.path] = (size, modified, history)
        return history
    }

    static func read(_ url: URL, sessionID: String, size: UInt64, tail: Int) -> SessionHistory {
        var history = SessionHistory(sessionID: sessionID)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return history }
        defer { try? handle.close() }
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.read(upToCount: Int(size - start)) else { return history }
        // 途中から読んだ最初の行は欠けている
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[data.index(after: newline)...] }
        var spoke = false
        for line in data.split(separator: 0x0A).reversed() {
            if history.customTitle != nil, history.aiTitle != nil, history.lastPrompt != nil, spoke { break }
            if history.customTitle == nil, line.starts(with: Self.customTitle) {
                history.customTitle = field(line, "customTitle")
            } else if history.aiTitle == nil, line.starts(with: Self.aiTitle) {
                history.aiTitle = field(line, "aiTitle")
            } else if history.lastPrompt == nil, line.starts(with: Self.lastPrompt) {
                history.lastPrompt = field(line, "lastPrompt")
            } else if !spoke, line.firstRange(of: Self.gitBranch) != nil,
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                ["user", "assistant"].contains(object["type"] as? String)
            {
                spoke = true
                history.branch = (object["gitBranch"] as? String).flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
                history.updatedAt = (object["timestamp"] as? String).flatMap(parseDate)
            }
        }
        return history
    }

    // 題の行は `type` が先頭に来る。発言の行は `type` が中身の後ろにあるので、`gitBranch` を持つ行だけを decode する
    private static let customTitle = Data(#"{"type":"custom-title""#.utf8)
    private static let aiTitle = Data(#"{"type":"ai-title""#.utf8)
    private static let lastPrompt = Data(#"{"type":"last-prompt""#.utf8)
    private static let gitBranch = Data(#""gitBranch":""#.utf8)

    private static func field(_ line: Data.SubSequence, _ key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let value = object[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
