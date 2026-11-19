import Foundation
import GRDB
import TaskboardKit

/// 作業ディレクトリのブックマーク（`workdirBookmark` 表）と、最近使った作業ディレクトリ。
/// マシンごとのパスなので daemon に置く（Mac・iPad・iPhone のどれから起動しても同じ候補が出る）
extension Store {
    static func registerBookmarkMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10 working directory bookmarks") { db in
            try db.create(table: "workdirBookmark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
            }
        }
    }

    /// 最近使ったものに出す数
    static let recentWorkdirLimit = 8

    /// ブックマーク（登録順）と、最近使った作業ディレクトリ（タスクに結んだ会話の cwd を新しい順に、重複と `~`・空を除く）
    public func workingDirectories() throws -> WorkingDirectories {
        try database.read { db in
            let bookmarks = try Row.fetchAll(db, sql: "SELECT id, path, createdAt FROM workdirBookmark ORDER BY id").map {
                WorkdirBookmark(id: $0["id"], path: $0["path"], createdAt: $0["createdAt"])
            }
            let started = try String.fetchAll(db, sql: "SELECT cwd FROM conversation WHERE taskNumber IS NOT NULL ORDER BY createdAt DESC LIMIT 200")
            return WorkingDirectories(bookmarks: bookmarks, recent: Self.recentWorkdirs(started))
        }
    }

    /// 新しい順の cwd から、重複と空・ホームそのものを除いて上限まで
    static func recentWorkdirs(_ cwds: [String], home: String = NSHomeDirectory()) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for cwd in cwds {
            let path = cwd.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, path != home, path != "~", seen.insert(path).inserted else { continue }
            result.append(path)
            if result.count == recentWorkdirLimit { break }
        }
        return result
    }

    /// 同じパスが既にあればそれを返す（2 度押しで増えない）
    public func addWorkdirBookmark(path: String, now: Date = Date()) throws -> WorkdirBookmark {
        let path = path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { throw StoreError.refused(.invalidRequest, [:], "path が要る") }
        return try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT id, path, createdAt FROM workdirBookmark WHERE path = ?", arguments: [path]) {
                return WorkdirBookmark(id: row["id"], path: row["path"], createdAt: row["createdAt"])
            }
            try db.execute(sql: "INSERT INTO workdirBookmark (path, createdAt) VALUES (?, ?)", arguments: [path, now])
            return WorkdirBookmark(id: db.lastInsertedRowID, path: path, createdAt: now)
        }
    }

    public func deleteWorkdirBookmark(id: Int64) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM workdirBookmark WHERE id = ?", arguments: [id])
            guard db.changesCount > 0 else { throw StoreError.refused(.notFound, ["kind": "workdirBookmark"], "ブックマーク \(id) が無い") }
        }
    }
}
