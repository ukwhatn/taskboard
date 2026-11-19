import Foundation
import GRDB
import TaskboardKit

/// リンクの状態（PR・Jira・Devin）の控え。daemon はリンクの状態をメモリに持ち、取り直すまで空になるので、
/// 最後に配った一覧を残して起動直後から配る（マージ済みのリンクは 30 分ごとにしか取り直さない）
extension Store {
    static func registerLinkStatusCacheMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v47 link status cache") { db in
            try db.create(table: "linkStatusCache") { t in
                t.primaryKey("url", .text)
                t.column("payload", .text).notNull()
            }
        }
    }

    public func cachedLinkStatuses() throws -> [LinkStatus] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM linkStatusCache ORDER BY url").compactMap {
                try? WireJSON.decoder().decode(LinkStatus.self, from: Data($0.utf8))
            }
        }
    }

    /// 今の一覧で置き換える
    public func saveLinkStatuses(_ statuses: [LinkStatus]) throws {
        let encoder = WireJSON.encoder()
        let rows = try statuses.map { ($0.url, String(decoding: try encoder.encode($0), as: UTF8.self)) }
        try database.write { db in
            try db.execute(sql: "DELETE FROM linkStatusCache")
            for (url, payload) in rows {
                try db.execute(sql: "INSERT INTO linkStatusCache (url, payload) VALUES (?, ?)", arguments: [url, payload])
            }
        }
    }
}
