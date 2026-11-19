import Foundation
import TaskboardKit

/// Claude Code の TaskCreate・TaskUpdate の一覧。CLI は 1 項目を `<設定の置き場>/tasks/<会話 ID>/<番号>.json` に書き、消した項目のファイルは消す
enum ClaudeTaskList {
    private struct File: Decodable {
        var id: String
        var subject: String
        var activeForm: String?
        var status: String
    }

    /// 番号の順。項目が無ければ nil
    static func read(_ agentSessionID: String, environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ConversationPlanItem]? {
        let directory = ClaudeConfigDirectory.url(environment: environment, home: home).appending(path: "tasks", directoryHint: .isDirectory)
            .appending(path: agentSessionID, directoryHint: .isDirectory)
        guard directory.lastPathComponent == agentSessionID,
            let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        let items = urls.filter { $0.pathExtension == "json" }
            .compactMap { url -> (order: Int, item: ConversationPlanItem)? in
                guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data), let status = status(file.status) else { return nil }
                let item = ConversationPlanItem(id: file.id, title: file.subject, activeTitle: file.activeForm.flatMap { $0.isEmpty ? nil : $0 }, status: status)
                return (Int(file.id) ?? .max, item)
            }
            .sorted { ($0.order, $0.item.id) < ($1.order, $1.item.id) }
            .map(\.item)
        return items.isEmpty ? nil : items
    }

    private static func status(_ value: String) -> ConversationPlanItem.Status? {
        switch value {
        case "pending": .pending
        case "in_progress": .inProgress
        case "completed": .completed
        default: nil
        }
    }
}
