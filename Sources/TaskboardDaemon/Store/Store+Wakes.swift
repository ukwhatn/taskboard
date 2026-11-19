import Foundation
import GRDB
import TaskboardKit

/// 起こす予定（`wake`）。起こすのは `WakeService`
extension Store {
    static let wakeMigration = "v24 wakes"
    static let wakePromptLimit = 20_000

    static func registerWakeMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(wakeMigration) { db in
            try db.create(table: "wake") { t in
                t.autoIncrementedPrimaryKey("id")
                // 会話の記録を消しても予定は残す（起こすときに失敗にする）
                t.column("conversationId", .text)
                t.column("taskNumber", .integer).references("task", onDelete: .cascade)
                t.column("at", .datetime).notNull()
                t.column("prompt", .text).notNull()
                t.column("cwd", .text).notNull().defaults(to: "")
                t.column("closeConversationId", .text)
                t.column("createdBy", .text)
                t.column("state", .text).notNull()
                // 初めて届けようとした時刻（届かないまま 24 時間たったら失敗にする）
                t.column("triedAt", .datetime)
                t.column("deliveredAt", .datetime)
                t.column("failure", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "wake_state_at", on: "wake", columns: ["state", "at"])
        }
    }

    struct WakeRow: Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "wake"
        var id: Int64?
        var conversationId: String?
        var taskNumber: Int?
        var at: Date
        var prompt: String
        var cwd: String
        var closeConversationId: String?
        var createdBy: String?
        var state: String
        var triedAt: Date?
        var deliveredAt: Date?
        var failure: String?
        var createdAt: Date
        var updatedAt: Date

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

        var stateValue: Wake.State { Wake.State(rawValue: state) ?? .failed }
    }

    func wake(from row: WakeRow) -> Wake {
        Wake(
            wakeID: row.id ?? 0, machine: machineID, at: row.at, prompt: row.prompt, conversationID: row.conversationId, taskNumber: row.taskNumber,
            closesCreator: row.closeConversationId != nil, createdBy: row.createdBy, state: row.stateValue, deliveredAt: row.deliveredAt,
            failure: row.failure, createdAt: row.createdAt, updatedAt: row.updatedAt)
    }

    public func wakes() throws -> [Wake] {
        try database.read { db in try WakeRow.order(Column("at"), Column("id")).fetchAll(db).map(wake(from:)) }
    }

    func wakeRow(id: Int64) throws -> WakeRow? {
        try database.read { db in try WakeRow.fetchOne(db, key: id) }
    }

    public func wake(id: Int64) throws -> Wake? {
        try wakeRow(id: id).map(wake(from:))
    }

    /// 予定を書く。届け先は会話かタスクのどちらか 1 つで、在ること。時刻はいまより後で 1 年以内
    public func createWake(_ request: WakeCreateRequest, now: Date = Date()) throws -> Wake {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw StoreError.invalid("prompt が要る") }
        guard prompt.count <= Self.wakePromptLimit else {
            throw StoreError.refused(.textTooLong, ["limit": "\(Self.wakePromptLimit)"], "prompt は \(Self.wakePromptLimit) 字まで")
        }
        guard request.at > now else { throw StoreError.invalid("at が過ぎている") }
        guard request.at <= now.addingTimeInterval(WakeCreateRequest.horizon) else { throw StoreError.invalid("at は 1 年以内") }
        guard (request.conversationID == nil) != (request.taskNumber == nil) else { throw StoreError.invalid("conversationID と taskNumber のどちらか 1 つを渡す") }
        let id: Int64 = try database.write { db in
            if let number = request.taskNumber, try Row.fetchOne(db, sql: "SELECT 1 FROM task WHERE number = ?", arguments: [number]) == nil {
                throw StoreError.taskNotFound(number)
            }
            for conversation in [request.conversationID, request.closeConversationID].compactMap({ $0 }) {
                guard try ConversationRecord.exists(db, key: conversation) else { throw StoreError.invalid("会話 \(conversation) が無い") }
            }
            // オーケストレーターの会話は終了できない（`ConversationService.close` が断る）
            if let closing = request.closeConversationID, try ConversationRecord.fetchOne(db, key: closing)?.purposeValue == .orchestrator {
                throw StoreError.invalid("オーケストレーターの会話は終了しない")
            }
            var row = WakeRow(
                id: nil, conversationId: request.conversationID, taskNumber: request.taskNumber, at: Self.storedDate(request.at), prompt: prompt,
                cwd: request.cwd, closeConversationId: request.closeConversationID, createdBy: request.createdBy, state: Wake.State.pending.rawValue,
                createdAt: now, updatedAt: now)
            try row.insert(db)
            return row.id ?? 0
        }
        changed(.wake(id))
        guard let created = try wake(id: id) else { throw StoreError.wakeNotFound(id) }
        return created
    }

    /// 時刻を過ぎた予定（古い順）
    func dueWakes(now: Date) throws -> [WakeRow] {
        try database.read { db in
            try WakeRow.filter(Column("state") == Wake.State.pending.rawValue && Column("at") <= now).order(Column("at"), Column("id")).fetchAll(db)
        }
    }

    /// 仕掛けた会話を終了する予定（まだ終了していないもの）
    func closingWakes() throws -> [WakeRow] {
        try database.read { db in
            try WakeRow.filter(Column("state") == Wake.State.pending.rawValue && Column("closeConversationId") != nil).order(Column("id")).fetchAll(db)
        }
    }

    /// 取り消す。届けた・失敗した予定は取り消せない
    public func cancelWake(id: Int64, now: Date = Date()) throws -> Wake {
        let row = try cancel(
            WakeRow.self, id: id, notFound: .wakeNotFound(id), label: "予定", live: Wake.State.pending.rawValue, cancelled: Wake.State.cancelled.rawValue, now: now
        ) { $0.closeConversationId = nil }
        changed(.wake(id))
        return wake(from: row)
    }

    /// タスク宛ての予定の届け先に、選んだ会話（新しく起こした会話を含む）を書く。書いてあれば書き換えない
    func assignWake(id: Int64, conversationID: String, now: Date = Date()) throws -> WakeRow {
        try updateWakeRow(id: id, now: now) { row in
            if row.conversationId == nil { row.conversationId = conversationID }
        }
    }

    func markWakeDelivered(id: Int64, now: Date = Date()) throws {
        _ = try updateWakeRow(id: id, now: now) { row in
            guard row.stateValue == .pending else { return }
            row.state = Wake.State.delivered.rawValue
            row.deliveredAt = now
            row.failure = nil
            row.closeConversationId = nil
        }
    }

    func markWakeFailed(id: Int64, reason: String, now: Date = Date()) throws {
        _ = try updateWakeRow(id: id, now: now) { row in
            guard row.stateValue == .pending else { return }
            row.state = Wake.State.failed.rawValue
            row.failure = reason
            row.closeConversationId = nil
        }
    }

    /// 届けられなかった回を残す（最初の回の時刻と、最後の理由）。返すのは書いた後の行
    func noteWakeAttempt(id: Int64, reason: String?, now: Date = Date()) throws -> WakeRow {
        try updateWakeRow(id: id, now: now) { row in
            if row.triedAt == nil { row.triedAt = now }
            row.failure = reason
        }
    }

    /// 仕掛けた会話を終了した（か、終了しないことにした）
    func clearWakeClose(id: Int64, now: Date = Date()) throws {
        _ = try updateWakeRow(id: id, now: now) { $0.closeConversationId = nil }
    }

    /// 終えてから 7 日を過ぎた予定を消す
    func purgeFinishedWakes(now: Date) throws {
        let ids = try database.write {
            try Self.purgeFinished(WakeRow.self, live: Wake.State.pending.rawValue, before: now.addingTimeInterval(-Self.finishedRowRetention), $0)
        }
        changed(ids.map { .wake($0) })
    }

    /// 変わったときだけ書いて流す
    private func updateWakeRow(id: Int64, now: Date, _ change: (inout WakeRow) throws -> Void) throws -> WakeRow {
        let (row, wrote) = try database.write { db -> (WakeRow, Bool) in
            guard var row = try WakeRow.fetchOne(db, key: id) else { throw StoreError.wakeNotFound(id) }
            let before = row
            try change(&row)
            guard !Self.sameWake(before, row) else { return (row, false) }
            row.updatedAt = now
            try row.update(db)
            return (row, true)
        }
        if wrote { changed(.wake(id)) }
        return row
    }

    private static func sameWake(_ a: WakeRow, _ b: WakeRow) -> Bool {
        a.conversationId == b.conversationId && a.state == b.state && a.triedAt == b.triedAt && a.deliveredAt == b.deliveredAt && a.failure == b.failure
            && a.closeConversationId == b.closeConversationId
    }
}
