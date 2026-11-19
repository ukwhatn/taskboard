import SwiftUI
import TaskboardKit

/// 会話の検索。一致は画面の行（ツールの結果は呼び出しの行）単位で数え、古い順に並べる
/// 会話の画面に検索の欄を語ごと開かせる（⌘K の会話の行から）
struct ChatSearchRequest: Equatable {
    let key: ConversationKey
    let query: String
}

struct ChatSearch: Equatable {
    var isOpen = false
    var query = ""
    /// 今見ている一致の位置。nil は最新の一致（会話は末尾から読むので）
    var position: Int?

    var activeQuery: String? {
        query.isEmpty ? nil : query
    }

    /// 一致した行の id（`ChatTranscript` の ForEach の id）。サブエージェントの中の一致は、本筋の Agent の呼び出しの行で数える
    static func rows(in messages: [ChatMessage], query: String?) -> [String] {
        guard let query, !query.isEmpty else { return [] }
        let calls = messages.filter { $0.kind == .toolUse && $0.toolID != nil }
        let callIDs = Dictionary(calls.map { ($0.toolID!, $0.id) }, uniquingKeysWith: { first, _ in first })
        let callParents = Dictionary(calls.map { ($0.toolID!, $0.parentToolID) }, uniquingKeysWith: { first, _ in first })
        /// 入れ子をたどった、本筋の呼び出しの `toolID`
        func root(_ toolID: String) -> String {
            var id = toolID
            for _ in 0..<8 {
                guard let up = callParents[id] ?? nil else { break }
                id = up
            }
            return id
        }
        var rows: [String] = []
        for message in messages where contains(message, query) {
            let row: String
            if let parent = message.parentToolID {
                row = callIDs[root(parent)] ?? message.id
            } else {
                row = message.kind == .toolResult ? message.toolID.flatMap { callIDs[$0] } ?? message.id : message.id
            }
            if rows.last != row && !rows.contains(row) { rows.append(row) }
        }
        return rows
    }

    /// サブエージェントの発言とツールに一致があるか
    static func matchesInside(_ members: [ChatMessage], query: String?) -> Bool {
        guard let query, !query.isEmpty else { return false }
        return members.contains { contains($0, query) }
    }

    /// 畳んだ中（入力の全文か結果）に一致があるか
    static func matchesInside(call: ChatMessage, result: ChatMessage?, query: String?) -> Bool {
        guard let query, !query.isEmpty else { return false }
        return call.text.range(of: query, options: .caseInsensitive) != nil
            || result.map { $0.text.range(of: query, options: .caseInsensitive) != nil } == true
    }

    private static func contains(_ message: ChatMessage, _ query: String) -> Bool {
        message.text.range(of: query, options: .caseInsensitive) != nil
            || message.toolName.map { $0.range(of: query, options: .caseInsensitive) != nil } == true
    }

    func resolvedPosition(count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(position ?? count - 1, count - 1)
    }

    func currentRow(in messages: [ChatMessage]) -> String? {
        let rows = Self.rows(in: messages, query: activeQuery)
        return resolvedPosition(count: rows.count).map { rows[$0] }
    }

    /// 前後へ送る。端まで行ったら反対の端へ回る
    mutating func step(_ delta: Int, count: Int) {
        guard let current = resolvedPosition(count: count) else { return }
        position = ((current + delta) % count + count) % count
    }

    /// 欄に出す件数
    func label(count: Int) -> String? {
        guard activeQuery != nil else { return nil }
        guard let current = resolvedPosition(count: count) else { return String(localized: "一致なし") }
        return "\(current + 1)/\(count)"
    }
}
