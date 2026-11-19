import Foundation
import GRDB
import TaskboardKit

/// 会話をまたいだ全文検索の索引（`ConversationSearchIndex` が書き、`GET /v1/conversations/search` が引く）。
/// 本文は `conversationSearchEntry` に 1 度だけ持ち、FTS5 の表（trigram）はその索引だけを持つ（external content）。
/// 記録の元は transcript と codex の thread で、索引はいつ捨てても作り直せる
extension Store {
    /// 索引に載せた 1 つの発言
    struct ConversationSearchEntry: Equatable, Sendable {
        var messageID: String
        var role: ChatMessage.Role
        var at: Date?
        var text: String
        /// transcript の行の頭（codex は 0）
        var position: UInt64
    }

    /// 会話の記録の元（Claude の会話 ID か codex の thread）ごとの、読んだ所
    struct ConversationSearchSource: Equatable, Sendable {
        var source: String
        /// 次に読む transcript の位置（codex は 0）
        var position: UInt64
        /// 読む範囲の終わり（写し元の transcript の地点）。nil は末尾まで
        var end: UInt64?
        /// codex の thread を読んだときの会話の値（変わったら読み足す）
        var mark: String?
    }

    /// 1 度に引く一致の行の上限。会話ごとの件数（`ConversationSearchHit.matches`）はこの中で数える
    static let conversationSearchRowLimit = 5_000

    static func registerConversationSearchMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v33 conversation search") { db in
            try db.create(table: "conversationSearchEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull().references("conversation", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("messageId", .text).notNull()
                t.column("role", .text).notNull()
                t.column("at", .datetime)
                t.column("text", .text).notNull()
            }
            try db.create(index: "conversationSearchEntry_source", on: "conversationSearchEntry", columns: ["conversationId", "source", "position"])
            try db.execute(
                sql: """
                    CREATE VIRTUAL TABLE conversationSearchText USING fts5(text, content='conversationSearchEntry', content_rowid='id', tokenize='trigram');
                    CREATE TRIGGER conversationSearchEntry_ai AFTER INSERT ON conversationSearchEntry BEGIN
                        INSERT INTO conversationSearchText(rowid, text) VALUES (new.id, new.text);
                    END;
                    CREATE TRIGGER conversationSearchEntry_ad AFTER DELETE ON conversationSearchEntry BEGIN
                        INSERT INTO conversationSearchText(conversationSearchText, rowid, text) VALUES ('delete', old.id, old.text);
                    END;
                    """)
            try db.create(table: "conversationSearchSource") { t in
                t.column("conversationId", .text).notNull().references("conversation", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("end", .integer)
                t.column("mark", .text)
                t.primaryKey(["conversationId", "source"])
            }
        }
    }

    /// FTS5 の索引が本文の表と食い違っていないか（`integrity-check`。食い違いは SQLITE_CORRUPT_VTAB の失敗で返る）
    func conversationSearchIntact() throws -> Bool {
        do {
            try database.write { db in
                try db.execute(sql: "INSERT INTO conversationSearchText(conversationSearchText, rank) VALUES ('integrity-check', 1)")
            }
            return true
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT {
            return false
        }
    }

    /// 索引の 3 つの表を空にする。次に読むときは、どの会話も初めから読み直す。
    /// 壊れた索引に、本文を消す trigger の 'delete' を当てると malformed で失敗する（先に 'delete-all' しても同じ）。
    /// trigger を外して本文を消し、'rebuild' で空の本文から索引を作り直してから、trigger を v33 と同じ形で戻す
    func clearConversationSearch() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM conversationSearchSource")
            try db.execute(sql: "DROP TRIGGER conversationSearchEntry_ad")
            try db.execute(sql: "DELETE FROM conversationSearchEntry")
            try db.execute(sql: "INSERT INTO conversationSearchText(conversationSearchText) VALUES ('rebuild')")
            try db.execute(
                sql: """
                    CREATE TRIGGER conversationSearchEntry_ad AFTER DELETE ON conversationSearchEntry BEGIN
                        INSERT INTO conversationSearchText(conversationSearchText, rowid, text) VALUES ('delete', old.id, old.text);
                    END;
                    """)
        }
    }

    func conversationSearchSources(conversation id: String) throws -> [String: ConversationSearchSource] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT source, position, \"end\", mark FROM conversationSearchSource WHERE conversationId = ?", arguments: [id])
            return Dictionary(
                uniqueKeysWithValues: rows.map { row in
                    let source: String = row["source"]
                    let end: Int64? = row["end"]
                    return (source, ConversationSearchSource(source: source, position: UInt64(row["position"] as Int64), end: end.map(UInt64.init), mark: row["mark"]))
                })
        }
    }

    /// 発言を足し、読んだ所を進める（1 つのトランザクション）。会話が消えていれば何もしない
    func addConversationSearch(conversation id: String, source: ConversationSearchSource, entries: [ConversationSearchEntry]) throws {
        try database.write { db in
            guard try ConversationRecord.exists(db, key: id) else { return }
            for entry in entries {
                try db.execute(
                    sql: "INSERT INTO conversationSearchEntry (conversationId, source, position, messageId, role, at, text) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [id, source.source, Int64(entry.position), entry.messageID, entry.role.rawValue, entry.at, entry.text])
            }
            try db.execute(
                sql: """
                    INSERT INTO conversationSearchSource (conversationId, source, position, "end", mark) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (conversationId, source) DO UPDATE SET position = excluded.position, "end" = excluded."end", mark = excluded.mark
                    """,
                arguments: [id, source.source, Int64(source.position), source.end.map(Int64.init), source.mark])
        }
    }

    /// 今の記録の元（`ends`：元 → 読む範囲の終わり。nil は末尾まで）に合わせる。無くなった元と、範囲の終わりより後ろの発言を消し、読んだ所を終わりまで戻す
    func trimConversationSearch(conversation id: String, keeping ends: [String: UInt64?]) throws {
        try database.write { db in
            let stored = try String.fetchAll(db, sql: "SELECT source FROM conversationSearchSource WHERE conversationId = ?", arguments: [id])
            for source in stored {
                guard let end = ends[source] else {
                    try db.execute(sql: "DELETE FROM conversationSearchEntry WHERE conversationId = ? AND source = ?", arguments: [id, source])
                    try db.execute(sql: "DELETE FROM conversationSearchSource WHERE conversationId = ? AND source = ?", arguments: [id, source])
                    continue
                }
                guard let end else { continue }
                try db.execute(
                    sql: "DELETE FROM conversationSearchEntry WHERE conversationId = ? AND source = ? AND position >= ?", arguments: [id, source, Int64(end)])
                try db.execute(
                    sql: "UPDATE conversationSearchSource SET position = min(position, ?), \"end\" = ? WHERE conversationId = ? AND source = ?",
                    arguments: [Int64(end), Int64(end), id, source])
            }
        }
    }

    /// その元に、その id の発言が載っているか（codex の thread を新しい方から読み足すときの止め所）
    func hasConversationSearchEntry(conversation id: String, source: String, messageID: String) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM conversationSearchEntry WHERE conversationId = ? AND source = ? AND messageId = ?)",
                arguments: [id, source, messageID]) ?? false
        }
    }

    /// すべての語を含む発言を、会話ごとに最新の 1 つにまとめて、新しい順に `limit` 件。
    /// 3 字以上の語は FTS5 の索引で引き、短い語は本文を順に見る（trigram は 3 字に満たない語を索引で引けない）
    func searchConversations(terms: [String], limit: Int) throws -> [ConversationSearchHit] {
        guard !terms.isEmpty else { return [] }
        let long = terms.filter { $0.count >= 3 }
        let short = terms.filter { $0.count < 3 }
        var conditions: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if !long.isEmpty {
            conditions.append("e.id IN (SELECT rowid FROM conversationSearchText WHERE conversationSearchText MATCH ?)")
            arguments.append(long.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND "))
        }
        for term in short {
            conditions.append("instr(lower(e.text), lower(?)) > 0")
            arguments.append(term)
        }
        arguments.append(Self.conversationSearchRowLimit)
        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT e.conversationId, e.messageId, e.role, e.at, e.text FROM conversationSearchEntry e
                    WHERE \(conditions.joined(separator: " AND ")) ORDER BY e.at DESC, e.id DESC LIMIT ?
                    """,
                arguments: StatementArguments(arguments))
        }
        var hits: [ConversationSearchHit] = []
        var index: [String: Int] = [:]
        for row in rows {
            let text: String = row["text"]
            // SQL は大文字と小文字の畳み方が ASCII だけなので、ここで同じ規則（`ConversationSearchQuery.matches`）に揃える
            guard ConversationSearchQuery.matches(text, terms: terms) else { continue }
            let conversation: String = row["conversationId"]
            if let at = index[conversation] {
                hits[at].matches += 1
                continue
            }
            index[conversation] = hits.count
            hits.append(
                ConversationSearchHit(
                    conversationID: conversation, messageID: row["messageId"], role: ChatMessage.Role(rawValue: row["role"]) ?? .assistant, at: row["at"],
                    snippet: ConversationSearchQuery.snippet(text, terms: terms), matches: 1))
        }
        return Array(hits.prefix(limit))
    }
}
