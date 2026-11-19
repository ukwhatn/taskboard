import Foundation
import GRDB
import TaskboardKit

/// Slack から受けた依頼（`SlackBridge`）。同じ知らせを 2 回届けないための `eventId` と、`slack_reply` が返してよいスレッドの記録
extension Store {
    static let slackMigration = "v37 slack requests"
    /// 届けた・届けられなかった依頼を残す日数（`slack_get`・`slack_reply` に使える期間）
    static let slackRequestRetention: TimeInterval = 30 * 24 * 3600

    static func registerSlackMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(slackMigration) { db in
            try db.create(table: "slackRequest") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("eventId", .text).notNull().unique()
                t.column("boardId", .text).notNull()
                t.column("channelId", .text).notNull()
                t.column("channelName", .text)
                t.column("ts", .text).notNull()
                // 返信を付けるスレッド（スレッドの中の依頼ならそのスレッド、そうでなければ依頼そのもの）
                t.column("threadTs", .text).notNull()
                t.column("userId", .text).notNull()
                t.column("userName", .text)
                t.column("text", .text).notNull()
                // 知らせの `event` の JSON（転送されたメッセージを slack_get で読む）
                t.column("event", .text).notNull()
                t.column("permalink", .text)
                t.column("taskNumber", .integer)
                t.column("conversationId", .text)
                // received・delivered・failed
                t.column("state", .text).notNull()
                t.column("failure", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }

    struct SlackRequestRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
        static let databaseTableName = "slackRequest"
        var id: Int64?
        var eventId: String
        var boardId: String
        var channelId: String
        var channelName: String?
        var ts: String
        var threadTs: String
        var userId: String
        var userName: String?
        var text: String
        var event: String
        var permalink: String?
        var taskNumber: Int?
        var conversationId: String?
        var state: String
        var failure: String?
        var createdAt: Date
        var updatedAt: Date

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

        enum State: String {
            case received, delivered, failed
        }
    }

    /// 受けた依頼を残す。同じ `eventId` がもうあれば nil（Slack の送り直し）
    func recordSlackRequest(_ row: SlackRequestRow) throws -> SlackRequestRow? {
        try database.write { db in
            if try SlackRequestRow.filter(Column("eventId") == row.eventId).fetchCount(db) > 0 { return nil }
            var row = row
            try row.insert(db)
            return row
        }
    }

    func slackRequest(id: Int64) throws -> SlackRequestRow? {
        try database.read { db in try SlackRequestRow.fetchOne(db, key: id) }
    }

    /// そのスレッドで最初に受けた依頼（スレッドの続きを同じ届け先にする）
    func firstSlackRequest(board: String, channel: String, threadTs: String) throws -> SlackRequestRow? {
        try database.read { db in
            try SlackRequestRow.filter(Column("boardId") == board && Column("channelId") == channel && Column("threadTs") == threadTs)
                .order(Column("id")).fetchOne(db)
        }
    }

    /// 届ける前に daemon が止まった依頼（起きたときに届け直す）
    func receivedSlackRequests() throws -> [SlackRequestRow] {
        try database.read { db in
            try SlackRequestRow.filter(Column("state") == SlackRequestRow.State.received.rawValue).order(Column("id")).fetchAll(db)
        }
    }

    func markSlackRequest(id: Int64, delivered conversationID: String?, taskNumber: Int?, now: Date) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE slackRequest SET state = ?, conversationId = ?, taskNumber = ?, failure = NULL, updatedAt = ? WHERE id = ?",
                arguments: [SlackRequestRow.State.delivered.rawValue, conversationID, taskNumber, now, id])
        }
    }

    func markSlackRequest(id: Int64, failed reason: String, now: Date) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE slackRequest SET state = ?, failure = ?, updatedAt = ? WHERE id = ?",
                arguments: [SlackRequestRow.State.failed.rawValue, reason, now, id])
        }
    }

    /// 残す日数を過ぎた依頼を消す
    func purgeSlackRequests(now: Date) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM slackRequest WHERE createdAt < ?", arguments: [now.addingTimeInterval(-Self.slackRequestRetention)])
        }
    }
}
