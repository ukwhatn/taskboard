import Foundation
import GRDB
import TaskboardKit

/// リンクの前の様子（`taskLinkSnapshot`、リンク 1 本ごと）と、そこから作った知らせ（`taskLinkNotice`）
extension Store {
    static let linkNoticeMigration = "v21 link snapshots and notices"

    static func registerLinkNoticeMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(linkNoticeMigration) { db in
            try db.create(table: "taskLinkSnapshot") { t in
                t.primaryKey("taskLinkId", .integer).references("taskLink", onDelete: .cascade)
                t.column("snapshot", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "taskLinkNotice") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("notice", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("deliveredAt", .datetime)
            }
            try db.create(index: "taskLinkNotice_task", on: "taskLinkNotice", columns: ["taskNumber", "deliveredAt", "createdAt"])
        }
    }

    /// 取った様子を、`url` を結んだリンク（`tasks` のタスクのもの）の前の様子と比べ、知らせを足して新しい様子を書く。
    /// 全部を 1 つの transaction で行う。`at` は取り始めた時刻。前の様子が無いリンク（初めて見た・結び直した）は元を記録するだけ。
    /// 同じタスクに届く見張りが受ける種類は足さない（見張りの出来事として届き、同じ動きが 2 通にならない。`recordWatchSnapshot` はこの後に走る）。知らせを足したタスクの番号を返す
    @discardableResult
    func recordLinkSnapshot(url: String, snapshot: LinkSnapshot, viewerLogin: String, tasks: Set<Int>, at now: Date) throws -> [Int] {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try database.write { db in
            let links = try Row.fetchAll(db, sql: "SELECT id, taskNumber FROM taskLink WHERE url = ? ORDER BY id", arguments: [url])
            let watches = try Self.watchesCoveringLinks(db, url: url)
            var added: [Int: Set<LinkNotice>] = [:]
            for link in links {
                let linkID: Int64 = link["id"]
                let taskNumber: Int = link["taskNumber"]
                guard tasks.contains(taskNumber) else { continue }
                let stored = try String.fetchOne(db, sql: "SELECT snapshot FROM taskLinkSnapshot WHERE taskLinkId = ?", arguments: [linkID])
                let old = try stored.map { try decoder.decode(LinkSnapshot.self, from: Data($0.utf8)) }
                let merged = snapshot.merged(over: old)
                if let old {
                    // 同じタスクに同じ URL を 2 本結んでいても、知らせは 1 回
                    for notice in LinkNotice.diff(url: url, old: old, new: merged, viewerLogin: viewerLogin)
                    where !(watches[taskNumber] ?? []).contains(where: { $0.accepts(notice.kind) }) && added[taskNumber, default: []].insert(notice).inserted {
                        try db.execute(
                            sql: "INSERT INTO taskLinkNotice (taskNumber, url, kind, notice, createdAt) VALUES (?, ?, ?, ?, ?)",
                            arguments: [taskNumber, url, notice.kind.rawValue, String(decoding: try encoder.encode(notice), as: UTF8.self), now])
                    }
                }
                try db.execute(
                    sql: """
                        INSERT INTO taskLinkSnapshot (taskLinkId, snapshot, fetchedAt) VALUES (?, ?, ?)
                        ON CONFLICT(taskLinkId) DO UPDATE SET snapshot = excluded.snapshot, fetchedAt = excluded.fetchedAt
                        """,
                    arguments: [linkID, String(decoding: try encoder.encode(merged), as: UTF8.self), now])
            }
            return added.keys.sorted()
        }
    }

    /// Devin のセッションの様子を `url` を結んだリンク（`tasks` のタスクのもの）の前の様子と比べ、知らせを足して新しい様子を書く（`recordLinkSnapshot` と同じ形）。
    /// 前の様子が無いリンクは元を記録するだけ（作った直後・結び直した直後に知らせない）。知らせを足したタスクの番号を返す
    @discardableResult
    func recordDevinSnapshot(url: String, snapshot: DevinSnapshot, tasks: Set<Int>, at now: Date) throws -> [Int] {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try database.write { db in
            let links = try Row.fetchAll(db, sql: "SELECT id, taskNumber FROM taskLink WHERE url = ? ORDER BY id", arguments: [url])
            var added: [Int: Set<LinkNotice>] = [:]
            for link in links {
                let linkID: Int64 = link["id"]
                let taskNumber: Int = link["taskNumber"]
                guard tasks.contains(taskNumber) else { continue }
                let stored = try String.fetchOne(db, sql: "SELECT snapshot FROM taskLinkSnapshot WHERE taskLinkId = ?", arguments: [linkID])
                if let old = stored.flatMap({ try? decoder.decode(DevinSnapshot.self, from: Data($0.utf8)) }) {
                    for notice in DevinSnapshot.notices(url: url, old: old, new: snapshot) where added[taskNumber, default: []].insert(notice).inserted {
                        try db.execute(
                            sql: "INSERT INTO taskLinkNotice (taskNumber, url, kind, notice, createdAt) VALUES (?, ?, ?, ?, ?)",
                            arguments: [taskNumber, url, notice.kind.rawValue, String(decoding: try encoder.encode(notice), as: UTF8.self), now])
                    }
                }
                try db.execute(
                    sql: """
                        INSERT INTO taskLinkSnapshot (taskLinkId, snapshot, fetchedAt) VALUES (?, ?, ?)
                        ON CONFLICT(taskLinkId) DO UPDATE SET snapshot = excluded.snapshot, fetchedAt = excluded.fetchedAt
                        """,
                    arguments: [linkID, String(decoding: try encoder.encode(snapshot), as: UTF8.self), now])
            }
            return added.keys.sorted()
        }
    }

    /// Devin のリンクの前の様子に残ったアカウント（URL → 名前）。`task` を渡せばそのタスクのリンクだけ
    func devinAccounts(task: Int? = nil) throws -> [String: String] {
        let decoder = JSONDecoder()
        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT taskLink.url, taskLinkSnapshot.snapshot FROM taskLink JOIN taskLinkSnapshot ON taskLinkSnapshot.taskLinkId = taskLink.id
                    WHERE ? IS NULL OR taskLink.taskNumber = ?
                    """,
                arguments: [task, task])
        }
        var result: [String: String] = [:]
        for row in rows {
            let url: String = row["url"]
            let json: String = row["snapshot"]
            guard DevinSession.id(fromURL: url) != nil,
                let account = (try? decoder.decode(DevinSnapshot.self, from: Data(json.utf8)))?.account
            else { continue }
            result[url] = account
        }
        return result
    }

    /// 届けてから 7 日を過ぎた知らせを消す（`LinkNotices` の 60 秒ごとの見直し）
    func purgeDeliveredLinkNotices(at now: Date) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM taskLinkNotice WHERE deliveredAt < ?",
                arguments: [now.addingTimeInterval(-Self.finishedRowRetention)])
        }
    }

    /// `url` を結んだリンク（`tasks` のタスクのもの）と有効な見張りの、前の様子を取った時刻のうち、いちばん古いもの。様子の無いものがあれば nil
    func oldestLinkSnapshot(url: String, tasks: Set<Int>) throws -> Date? {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT l.taskNumber, s.fetchedAt FROM taskLink l LEFT JOIN taskLinkSnapshot s ON s.taskLinkId = l.id WHERE l.url = ?",
                arguments: [url])
            let watched = try Row.fetchAll(
                db, sql: "SELECT CASE WHEN snapshot IS NULL THEN NULL ELSE fetchedAt END AS fetchedAt FROM watch WHERE state = ? AND kind = ? AND url = ?",
                arguments: [Watch.State.active.rawValue, Watch.Kind.item.rawValue, url])
            let dates = rows.filter { tasks.contains($0["taskNumber"]) }.map { $0["fetchedAt"] as Date? } + watched.map { $0["fetchedAt"] as Date? }
            guard !dates.contains(nil) else { return nil }
            return dates.compactMap { $0 }.min()
        }
    }

    /// 届けていない知らせ（古い順、全部）
    func undeliveredLinkNotices(task number: Int) throws -> [TaskLinkNotice] {
        try database.read { db in
            try Self.fetchLinkNotices(
                db, sql: "SELECT * FROM taskLinkNotice WHERE taskNumber = ? AND deliveredAt IS NULL ORDER BY createdAt, id", arguments: [number])
        }
    }

    func tasksWithUndeliveredLinkNotices() throws -> [Int] {
        try database.read { db in try Int.fetchAll(db, sql: "SELECT DISTINCT taskNumber FROM taskLinkNotice WHERE deliveredAt IS NULL ORDER BY taskNumber") }
    }

    func markLinkNoticesDelivered(ids: [Int64], at now: Date) throws {
        guard !ids.isEmpty else { return }
        try database.write { db in
            try db.execute(
                sql: "UPDATE taskLinkNotice SET deliveredAt = ? WHERE deliveredAt IS NULL AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments([now] + ids))
        }
    }

    /// `GET /v1/tasks/{n}/link-notices`：届けていない数と、新しい `limit` 件
    public func linkNotices(task number: Int, limit: Int = 20) throws -> LinkNoticeList {
        try database.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taskLinkNotice WHERE taskNumber = ? AND deliveredAt IS NULL", arguments: [number]) ?? 0
            let recent = try Self.fetchLinkNotices(
                db, sql: "SELECT * FROM taskLinkNotice WHERE taskNumber = ? ORDER BY createdAt DESC, id DESC LIMIT ?", arguments: [number, limit])
            return LinkNoticeList(undelivered: count, notices: recent)
        }
    }

    private static func fetchLinkNotices(_ db: Database, sql: String, arguments: StatementArguments) throws -> [TaskLinkNotice] {
        let decoder = JSONDecoder()
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            TaskLinkNotice(
                id: row["id"], taskNumber: row["taskNumber"], notice: try decoder.decode(LinkNotice.self, from: Data((row["notice"] as String).utf8)),
                createdAt: row["createdAt"], deliveredAt: row["deliveredAt"])
        }
    }

    /// backup の確かめ：v21 を通った DB に知らせの表が無ければ断る
    static func verifyLinkNoticeTables(_ db: Database) throws {
        guard try db.tableExists("grdb_migrations"),
            try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM grdb_migrations WHERE identifier = ?", arguments: [linkNoticeMigration]) == true
        else { return }
        for table in ["taskLinkSnapshot", "taskLinkNotice"] where try !db.tableExists(table) {
            throw StoreError.missingTable(table)
        }
    }
}
