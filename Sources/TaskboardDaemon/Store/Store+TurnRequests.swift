import GRDB

/// 廃止したターンの終わりの抜き出しの表（`conversationDigest`・`extractedRequest`）。もう読み書きしないが、作った版の migration は消さずに残す（消すと記録した migration と食い違う）
extension Store {
    static func registerTurnRequestMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v40 turn digests and requests") { db in
            try db.create(table: "conversationDigest") { t in
                t.primaryKey("conversationId", .text).references("conversation", onDelete: .cascade)
                t.column("now", .text).notNull()
                t.column("at", .datetime).notNull()
            }
            try db.create(table: "extractedRequest") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull().references("conversation", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("quote", .text).notNull()
                t.column("messageId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("closedAt", .datetime)
                t.column("closedBy", .text)
            }
            try db.create(index: "extractedRequestOpen", on: "extractedRequest", columns: ["conversationId", "closedAt"])
        }
        migrator.registerMigration("v41 turn request options") { db in
            try db.alter(table: "extractedRequest") { t in
                t.add(column: "options", .text).notNull().defaults(to: "[]")
            }
        }
    }
}
