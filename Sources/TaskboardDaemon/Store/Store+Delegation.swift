import Foundation
import GRDB
import TaskboardKit

/// 委任範囲。案件の初期値（`board.delegation`）とタスクの上書き（`task.delegation`）は JSON の列。
/// 表 `delegationRecord`（廃止した判断の記録と範囲の変更の提案）は 3 台の DB に適用済みなので、登録だけを残して読み書きしない
extension Store {
    static let delegationMigration = "v43 delegation scope and records"

    static func registerDelegationMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(delegationMigration) { db in
            try db.alter(table: "board") { t in t.add(column: "delegation", .text) }
            try db.alter(table: "task") { t in t.add(column: "delegation", .text) }
            try db.create(table: "delegationRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("area", .text).notNull()
                t.column("level", .text).notNull()
                t.column("fromLevel", .text)
                t.column("text", .text).notNull()
                t.column("undo", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull()
                // 記録した会話の Claude の会話 ID（取り消しと回答の届け先）
                t.column("requesterSessionId", .text)
                t.column("createdAt", .datetime).notNull()
                // 取り消しを押した・提案に答えた時刻。ここから会話に届けるまでが未受領
                t.column("answeredAt", .datetime)
                t.column("deliveredAt", .datetime)
                t.column("deliveryAttempts", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "delegationRecord_task", on: "delegationRecord", columns: ["taskNumber", "id"])
        }
    }

    // MARK: 範囲（案件の初期値・タスクの上書き）

    /// 空の指定は NULL にする
    static func encodeDelegation(_ scope: DelegationScope) throws -> String? {
        scope.isEmpty ? nil : String(decoding: try JSONEncoder().encode(scope), as: UTF8.self)
    }

    static func decodeDelegation(_ text: String?) -> DelegationScope {
        text.flatMap { try? JSONDecoder().decode(DelegationScope.self, from: Data($0.utf8)) } ?? DelegationScope()
    }
}
