import Foundation
import GRDB
import TaskboardKit

/// PR 一覧のキャッシュ。アカウントごとに最後に取れた一覧を持ち、起動直後や VPN が切れている間もそれを見せる。
extension Store {
    static func registerPullRequestMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5 pr cache") { db in
            try db.create(table: "prCache") { t in
                // `host|login`
                t.primaryKey("account", .text)
                t.column("payload", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
        }
    }

    public struct CachedPullRequests: Sendable {
        public var host: String
        public var login: String
        public var pullRequests: [PullRequestSummary]
        public var fetchedAt: Date
    }

    public func cachedPullRequests() throws -> [CachedPullRequests] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT account, payload, fetchedAt FROM prCache ORDER BY account").compactMap { row in
                let key: String = row["account"]
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let prs = try? WireJSON.decoder().decode([PullRequestSummary].self, from: Data((row["payload"] as String).utf8))
                else { return nil }
                return CachedPullRequests(host: parts[0], login: parts[1], pullRequests: prs, fetchedAt: row["fetchedAt"])
            }
        }
    }

    public func savePullRequests(host: String, login: String, _ prs: [PullRequestSummary], fetchedAt: Date) throws {
        let payload = String(decoding: try WireJSON.encoder().encode(prs), as: UTF8.self)
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO prCache (account, payload, fetchedAt) VALUES (?, ?, ?) ON CONFLICT(account) DO UPDATE SET payload = excluded.payload, fetchedAt = excluded.fetchedAt",
                arguments: ["\(host)|\(login)", payload, fetchedAt])
        }
    }

    /// ログインが外れたアカウントの分を消す
    public func deleteCachedPullRequests(keeping accounts: Set<String>) throws {
        try database.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT account FROM prCache") {
                let key: String = row["account"]
                if !accounts.contains(key) { try db.execute(sql: "DELETE FROM prCache WHERE account = ?", arguments: [key]) }
            }
        }
    }
}
