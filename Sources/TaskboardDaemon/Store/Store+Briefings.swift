import Foundation
import GRDB

/// 廃止した文書の説明（ブリーフィング）の表。3 台の DB に適用済みなので、登録だけを残して読み書きしない（表を消すとデータの削除になる）
extension Store {
    static let briefingMigration = "v46 briefings"

    static func registerBriefingMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(briefingMigration) { db in
            try db.create(table: "briefing") { t in
                t.primaryKey("docId", .integer).references("doc", onDelete: .cascade)
                t.column("taskNumber", .integer).notNull()
                t.column("rev", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("script", .text)
                // 説明役の会話（ConversationRecord の id）と、ブリーフィングを閉じた時刻（開いている間は nil）・開いているアプリが最後に知らせた時刻。
                // どちらかから 30 分たつと会話を終える（開いたままアプリが終わっても終える）
                t.column("conversationId", .text)
                t.column("closedAt", .datetime)
                t.column("presentAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "briefingQuestion") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("docId", .integer).notNull().references("briefing", column: "docId", onDelete: .cascade)
                t.column("slideId", .text).notNull()
                t.column("text", .text).notNull()
                t.column("status", .text).notNull()
                t.column("answer", .text).notNull().defaults(to: "")
                t.column("sources", .text).notNull().defaults(to: "[]")
                t.column("slide", .text)
                t.column("commentId", .integer).references("docComment", onDelete: .setNull)
                t.column("reply", .text)
                t.column("askedAt", .datetime).notNull()
                t.column("answeredAt", .datetime)
                t.column("repliedAt", .datetime)
            }
            try db.create(index: "briefingQuestion_doc", on: "briefingQuestion", columns: ["docId"])
            try db.create(index: "briefingQuestion_comment", on: "briefingQuestion", columns: ["commentId"])
        }
    }
}
