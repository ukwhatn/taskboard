import Foundation
import GRDB
import TaskboardKit

/// 会話が書いたタスクの状態の文（`TaskStatusNote`）。書いた会話の終了（`clearStatuses(writtenBy:)`）と、終端の列への移動（`updateTaskCancellingAsks`）で外す
extension Store {
    static func registerTaskStatusMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v53 task status note") { db in
            try db.alter(table: "task") { t in
                t.add(column: "statusText", .text)
                t.add(column: "statusConversationId", .text)
                t.add(column: "statusSetAt", .datetime)
            }
        }
    }

    static func apply(_ status: TaskStatusUpdate, to row: inout TaskRow, now: Date = Date()) throws {
        let text = status.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return clearStatus(&row) }
        guard text.count <= TaskStatusNote.limit, !text.contains("\n") else {
            throw StoreError.invalid(Copy.text("agent.store.status.limit", ["limit": "\(TaskStatusNote.limit)"]))
        }
        row.statusText = text
        row.statusConversationId = status.conversationID
        row.statusSetAt = now
    }

    static func clearStatus(_ row: inout TaskRow) {
        row.statusText = nil
        row.statusConversationId = nil
        row.statusSetAt = nil
    }

    /// 終了した会話が書いた状態の文を外し、外したタスクを返す
    public func clearStatuses(writtenBy conversationID: String) throws -> [BoardTask] {
        let numbers = try database.write { db -> [Int] in
            let rows = try TaskRow.filter(Column("statusConversationId") == conversationID).fetchAll(db)
            for var row in rows {
                Self.clearStatus(&row)
                try row.update(db)
            }
            return rows.compactMap { $0.number.map(Int.init) }
        }
        guard !numbers.isEmpty else { return [] }
        changed(numbers.map { .task($0) })
        return try database.read { db in try Self.fetchTasks(db, machine: machineID, numbers: numbers) }
    }
}
