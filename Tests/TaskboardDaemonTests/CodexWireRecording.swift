import Foundation

/// 本物の codex app-server から記録した電文（`CodexWire/<name>.jsonl`。`scripts/fixtures/record-codex-subagent.py` が書く）
struct CodexWireRecording {
    /// 受けた順の通知の行
    let notifications: [String]
    /// thread ごとの `thread/items/list` の result の JSON
    let items: [String: String]
    /// 最初の通知の thread（本筋）
    let mainThread: String

    init(_ name: String) throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("CodexWire/\(name).jsonl")
        var notifications: [String] = []
        var items: [String: String] = [:]
        var main: String?
        for raw in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            let entry = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
            let line = entry["line"] as? [String: Any] ?? [:]
            switch entry["kind"] as? String {
            case "notification":
                main = main ?? (line["params"] as? [String: Any])?["threadId"] as? String
                notifications.append(String(decoding: try JSONSerialization.data(withJSONObject: line, options: .withoutEscapingSlashes), as: UTF8.self))
            case "items":
                items[entry["threadId"] as? String ?? ""] = String(decoding: try JSONSerialization.data(withJSONObject: line["result"] ?? [:], options: .withoutEscapingSlashes), as: UTF8.self)
            default:
                continue
            }
        }
        self.notifications = notifications
        self.items = items
        mainThread = main ?? ""
    }

    /// `method` の通知のうち、`thread` の最初のものの位置
    func index(of method: String, thread: String) -> Int? {
        notifications.firstIndex { $0.contains(#""method":"\#(method)""#) && $0.contains(#""threadId":"\#(thread)""#) }
    }
}
