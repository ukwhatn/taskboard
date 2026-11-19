import GRDB

/// タスクのブラウザ（機能は消した）の migration。当てた記録のある DB と新しい DB の形を揃えるために登録だけ残す。
/// 列 `task.browserProfileId`・`task.terminalSince` と表 `browserCleanup` は、もう読み書きしない
extension Store {
    static func registerBrowserMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v23 browser profiles") { db in
            try db.alter(table: "task") { t in
                t.add(column: "browserProfileId", .text)
                t.add(column: "terminalSince", .datetime)
            }
            try db.create(index: "task_browserProfileId", on: "task", columns: ["browserProfileId"], unique: true)
            try db.create(table: "browserCleanup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("browserProfileId", .text).notNull().unique()
                t.column("reason", .text).notNull()
                t.column("taskNumber", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("reservedAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
            }
            // 今終端にあるタスクは、入った時刻が無いので updatedAt を入れる（保存先を持つタスクはまだ無いので、早く数え始めても消えるものは無い）
            try db.execute(
                sql: """
                    UPDATE task SET terminalSince = updatedAt
                    WHERE (SELECT kind FROM boardColumn c WHERE c.boardId = task.boardId AND c.id = task.columnId) = 'terminal'
                    """)
        }
    }
}
