import Foundation
import GRDB
import TaskboardKit

/// 受信箱で消した項目の記録（`inboxDismissal` 表）。このマシンの項目の分だけを持ち、全部の端末に配る
extension Store {
    static func registerInboxMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15 inbox dismissal") { db in
            try db.create(table: "inboxDismissal") { t in
                t.primaryKey("itemId", .text)
                t.column("revision", .text).notNull()
                t.column("dismissedAt", .datetime).notNull()
            }
        }
    }

    /// これより古い記録は書き込みのときに捨てる。お知らせは 24 時間で受信箱から消え、対応待ちが同じ中身のまま
    /// これほど残ることはまず無い（残っていたら、また出して気付かせるほうがよい）
    static let inboxDismissalRetention: TimeInterval = 30 * 24 * 3600

    public func inboxDismissals() throws -> [InboxDismissal] {
        try database.read { db in try Self.fetchInboxDismissals(db) }
    }

    /// 同じ項目は revision と時刻を置き換える。記録の全部を返す
    public func dismissInbox(_ items: [InboxDismissRequest.Item], now: Date = Date()) throws -> [InboxDismissal] {
        try Self.validate(items)
        return try database.write { db in
            for item in items {
                try db.execute(
                    sql: """
                        INSERT INTO inboxDismissal (itemId, revision, dismissedAt) VALUES (?, ?, ?)
                        ON CONFLICT(itemId) DO UPDATE SET revision = excluded.revision, dismissedAt = excluded.dismissedAt
                        """,
                    arguments: [item.itemID, item.revision, now])
            }
            try db.execute(sql: "DELETE FROM inboxDismissal WHERE dismissedAt < ?", arguments: [now.addingTimeInterval(-Self.inboxDismissalRetention)])
            return try Self.fetchInboxDismissals(db)
        }
    }

    /// 記録の無い項目は飛ばす（別の端末が先に戻した）。記録の全部を返す
    public func restoreInbox(itemIDs: [String]) throws -> [InboxDismissal] {
        guard itemIDs.count <= InboxDismissal.batchLimit else {
            throw StoreError.invalid("itemIDs は \(InboxDismissal.batchLimit) 件まで")
        }
        return try database.write { db in
            for id in itemIDs {
                try db.execute(sql: "DELETE FROM inboxDismissal WHERE itemId = ?", arguments: [id])
            }
            return try Self.fetchInboxDismissals(db)
        }
    }

    private static func validate(_ items: [InboxDismissRequest.Item]) throws {
        guard !items.isEmpty else { throw StoreError.invalid("items が要る") }
        guard items.count <= InboxDismissal.batchLimit else { throw StoreError.invalid("items は \(InboxDismissal.batchLimit) 件まで") }
        for item in items {
            guard (1...InboxDismissal.itemIDLimit).contains(item.itemID.count) else {
                throw StoreError.invalid("itemID は 1〜\(InboxDismissal.itemIDLimit) 字")
            }
            guard item.revision.count <= InboxDismissal.revisionLimit else {
                throw StoreError.invalid("revision は \(InboxDismissal.revisionLimit) 字まで")
            }
        }
    }

    private static func fetchInboxDismissals(_ db: Database) throws -> [InboxDismissal] {
        try Row.fetchAll(db, sql: "SELECT itemId, revision, dismissedAt FROM inboxDismissal ORDER BY dismissedAt, itemId").map {
            InboxDismissal(itemID: $0["itemId"], revision: $0["revision"], dismissedAt: $0["dismissedAt"])
        }
    }
}
