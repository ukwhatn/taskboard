import Foundation
import GRDB
import TaskboardKit

/// 定期起動と各回。各回の起動の進み具合は `launch` の行にあり、ここには request id だけを持つ
extension Store {
    static func registerScheduleMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6 schedules") { db in
            try db.create(table: "schedule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("enabled", .boolean).notNull()
                // ScheduleRule の JSON
                t.column("rule", .text).notNull()
                t.column("cwd", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("agentArgs", .text).notNull().defaults(to: "[]")
                t.column("prompt", .text).notNull()
                t.column("taskNumber", .integer).references("task", onDelete: .setNull)
                t.column("overlap", .text).notNull()
                // ここより後の時刻だけを起こす。作成・規則の変更・再開でいまに進める（過去の分をさかのぼって起こさない）
                t.column("anchorAt", .datetime).notNull()
                t.column("lastScheduledAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "scheduleRun") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scheduleId", .integer).notNull().references("schedule", onDelete: .cascade)
                t.column("scheduledAt", .datetime).notNull()
                t.column("trigger", .text).notNull()
                t.column("requestId", .text)
                t.column("skipped", .text)
                t.column("createdAt", .datetime).notNull()
                // daemon の再起動や二重の tick で同じ回を 2 度起こさない
                t.uniqueKey(["scheduleId", "scheduledAt"])
            }
        }
    }

    static func registerScheduleRunFailureMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11 schedule run failures") { db in
            try db.alter(table: "scheduleRun") { t in
                // Launcher が受け付けなかった回の理由。skipped（起こさないと決めた回）と分ける
                t.add(column: "failure", .text)
            }
        }
    }

    static func registerScheduleRunLaunchMigration(_ migrator: inout DatabaseMigrator) {
        // pane で起こした回の結果を回の行に写し、起動の記録（`launch`）を消す。途中の段階で終わった回は、起こせなかったものとして残す
        migrator.registerMigration("v34 schedule runs without launches") { db in
            try db.alter(table: "scheduleRun") { t in t.add(column: "launched", .boolean).notNull().defaults(to: false) }
            try db.execute(sql: "UPDATE scheduleRun SET launched = 1 WHERE requestId IN (SELECT id FROM launch WHERE stage = 'done')")
            try db.execute(
                sql: """
                    UPDATE scheduleRun SET failure = coalesce((SELECT error FROM launch WHERE launch.id = scheduleRun.requestId), '')
                    WHERE failure IS NULL AND requestId IN (SELECT id FROM launch WHERE stage = 'failed')
                    """)
            try db.drop(table: "launch")
        }
    }

    struct ScheduleRow: Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "schedule"
        var id: Int64?
        var name: String
        var enabled: Bool
        var rule: String
        var cwd: String
        var kind: String
        var agentArgs: String
        var prompt: String
        var taskNumber: Int?
        var overlap: String
        var anchorAt: Date
        var lastScheduledAt: Date?
        var createdAt: Date
        var updatedAt: Date

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

        var parsedRule: ScheduleRule? { try? JSONDecoder().decode(ScheduleRule.self, from: Data(rule.utf8)) }
    }

    struct ScheduleRunRow: Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "scheduleRun"
        var id: Int64?
        var scheduleId: Int64
        var scheduledAt: Date
        var trigger: String
        var requestId: String?
        var skipped: String?
        var failure: String?
        /// pane で起こした回が起動まで済んだ
        var launched: Bool = false
        /// host の会話で動かした回の会話の id（回の id から決める。この回は `requestId` を持たない）
        var conversationId: String?
        var createdAt: Date

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    static func encodeRule(_ rule: ScheduleRule) -> String {
        String(decoding: (try? JSONEncoder().encode(rule)) ?? Data(), as: UTF8.self)
    }

    static func encodeArgs(_ args: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(args)) ?? Data("[]".utf8), as: UTF8.self)
    }

    public func schedules(now: Date = Date()) throws -> [Schedule] {
        try database.read { db in
            try ScheduleRow.order(Column("id")).fetchAll(db).map { try schedule(from: $0, db: db, now: now) }
        }
    }

    public func schedule(id: Int64, now: Date = Date()) throws -> Schedule {
        try database.read { db in
            guard let row = try ScheduleRow.fetchOne(db, key: id) else { throw StoreError.scheduleNotFound(id) }
            return try schedule(from: row, db: db, now: now)
        }
    }

    /// 次に起こす時刻。最後に起こした時刻と anchor の新しい方より後の最初の時刻
    static func nextAt(_ row: ScheduleRow) -> Date? {
        guard row.enabled, let rule = row.parsedRule else { return nil }
        let after = max(row.anchorAt, row.lastScheduledAt ?? row.anchorAt)
        return rule.next(after: after, anchor: row.anchorAt)
    }

    /// `now` までに過ぎた最新の時刻（過ぎていなければ nil）
    static func latestDue(_ row: ScheduleRow, now: Date) -> Date? {
        guard var due = nextAt(row), due <= now, let rule = row.parsedRule else { return nil }
        for _ in 0..<100_000 {
            guard let next = rule.next(after: due, anchor: row.anchorAt), next <= now else { break }
            due = next
        }
        return due
    }

    /// 起こす時刻が過ぎた定期起動と、その最新の時刻
    public func dueSchedules(now: Date = Date()) throws -> [(schedule: Schedule, due: Date)] {
        try database.read { db in
            try ScheduleRow.order(Column("id")).fetchAll(db).compactMap { row in
                guard let due = Self.latestDue(row, now: now) else { return nil }
                return (try schedule(from: row, db: db, now: now), due)
            }
        }
    }

    private func schedule(from row: ScheduleRow, db: Database, now: Date) throws -> Schedule {
        let id = row.id ?? 0
        let last = try ScheduleRunRow.filter(Column("scheduleId") == id).order(Column("id").desc).fetchOne(db).map { try run(from: $0, db: db) }
        return Schedule(
            scheduleID: id, machine: machineID, name: row.name, enabled: row.enabled, rule: row.parsedRule ?? .cron("0 0 31 2 *"), cwd: row.cwd,
            kind: AgentKind(rawValue: row.kind) ?? .claude,
            agentArgs: (try? JSONDecoder().decode([String].self, from: Data(row.agentArgs.utf8))) ?? [], prompt: row.prompt, taskNumber: row.taskNumber,
            overlap: ScheduleOverlap(rawValue: row.overlap) ?? .skip, nextAt: Self.nextAt(row), lastRun: last, createdAt: row.createdAt,
            updatedAt: row.updatedAt)
    }

    private func run(from row: ScheduleRunRow, db: Database) throws -> ScheduleRun {
        var run = ScheduleRun(
            id: row.id ?? 0, scheduleID: row.scheduleId, scheduledAt: row.scheduledAt, trigger: ScheduleRun.Trigger(rawValue: row.trigger) ?? .schedule,
            requestID: row.requestId, skipped: row.skipped, conversationID: row.conversationId, createdAt: row.createdAt)
        if let failure = row.failure {
            run.stage = .failed
            run.error = failure
        } else if let conversationID = row.conversationId {
            // 会話の記録を作ったら起きている（生成中か終わったかは会話の様子で見る）
            run.stage = try ConversationRecord.exists(db, key: conversationID) ? .done : nil
        } else if row.launched {
            run.stage = .done
        }
        return run
    }

    public func scheduleRuns(id: Int64, limit: Int = 50) throws -> [ScheduleRun] {
        try database.read { db in
            guard try ScheduleRow.exists(db, key: id) else { throw StoreError.scheduleNotFound(id) }
            return try ScheduleRunRow.filter(Column("scheduleId") == id).order(Column("id").desc).limit(limit).fetchAll(db).map { try run(from: $0, db: db) }
        }
    }

    /// 検証を済ませてから常設タスクを作る（createTask は自分で transaction を張るので、定期起動の行とは別の書き込みになる）
    public func createSchedule(_ request: ScheduleCreateRequest, now: Date = Date()) throws -> (Schedule, BoardTask?) {
        try Self.validate(name: request.name, rule: request.rule)
        var created: BoardTask?
        if let newTask = request.newTask {
            created = try createTask(
                TaskCreateRequest(
                    boardID: newTask.boardID, columnID: newTask.columnID, title: request.name,
                    note: "定期起動「\(request.name)」の常設タスク。各回のセッションがここに紐づく。"))
        }
        let id: Int64 = try database.write { db in
            let taskNumber = created?.number ?? request.taskNumber
            if let taskNumber, try Row.fetchOne(db, sql: "SELECT 1 FROM task WHERE number = ?", arguments: [taskNumber]) == nil {
                throw StoreError.taskNotFound(taskNumber)
            }
            var row = ScheduleRow(
                id: nil, name: request.name.trimmingCharacters(in: .whitespaces), enabled: request.enabled, rule: Self.encodeRule(request.rule), cwd: request.cwd,
                kind: request.kind.rawValue, agentArgs: Self.encodeArgs(request.agentArgs), prompt: request.prompt, taskNumber: taskNumber,
                overlap: request.overlap.rawValue, anchorAt: now, lastScheduledAt: nil, createdAt: now, updatedAt: now)
            try row.insert(db)
            return row.id ?? 0
        }
        changed(.schedule(id))
        return (try schedule(id: id, now: now), created)
    }

    /// `newTask` があれば常設タスクを作って紐づけ直す（createSchedule と同じく、タスクの作成は別の書き込み）
    public func updateSchedule(id: Int64, _ request: ScheduleUpdateRequest, now: Date = Date()) throws -> (Schedule, BoardTask?) {
        var created: BoardTask?
        if let newTask = request.newTask {
            guard request.taskNumber == nil, !request.clearTask else { throw StoreError.invalid("newTask と taskNumber / clearTask は同時に送らない") }
            let current = try schedule(id: id, now: now)
            let name = request.name?.trimmingCharacters(in: .whitespaces) ?? current.name
            created = try createTask(
                TaskCreateRequest(
                    boardID: newTask.boardID, columnID: newTask.columnID, title: name,
                    note: "定期起動「\(name)」の常設タスク。各回のセッションがここに紐づく。"))
        }
        let schedule = try updateScheduleRow(id: id, request, taskNumber: created?.number, now: now)
        return (schedule, created)
    }

    private func updateScheduleRow(id: Int64, _ request: ScheduleUpdateRequest, taskNumber created: Int?, now: Date) throws -> Schedule {
        try database.write { db in
            guard var row = try ScheduleRow.fetchOne(db, key: id) else { throw StoreError.scheduleNotFound(id) }
            if let name = request.name { row.name = name.trimmingCharacters(in: .whitespaces) }
            if let rule = request.rule {
                row.rule = Self.encodeRule(rule)
                row.anchorAt = now
            }
            if let enabled = request.enabled {
                // 再開したときに止めていた間の分を起こさない
                if enabled && !row.enabled { row.anchorAt = now }
                row.enabled = enabled
            }
            if let cwd = request.cwd { row.cwd = cwd }
            if let kind = request.kind { row.kind = kind.rawValue }
            if let args = request.agentArgs { row.agentArgs = Self.encodeArgs(args) }
            if let prompt = request.prompt { row.prompt = prompt }
            if request.clearTask { row.taskNumber = nil }
            if let number = created ?? request.taskNumber {
                guard try Row.fetchOne(db, sql: "SELECT 1 FROM task WHERE number = ?", arguments: [number]) != nil else { throw StoreError.taskNotFound(number) }
                row.taskNumber = number
            }
            if let overlap = request.overlap { row.overlap = overlap.rawValue }
            try Self.validate(name: row.name, rule: row.parsedRule ?? .interval(minutes: 0))
            row.updatedAt = now
            try row.update(db)
        }
        changed(.schedule(id))
        return try schedule(id: id, now: now)
    }

    public func deleteSchedule(id: Int64) throws {
        try database.write { db in
            guard try ScheduleRow.deleteOne(db, key: id) else { throw StoreError.scheduleNotFound(id) }
        }
        changed(.schedule(id))
    }

    /// 起こす回を記録する。同じ (定期起動, 時刻) が既にあれば nil（別の tick か再起動前に記録済み）。
    /// 回は host の会話で動かす（`conversationID` で回の id から会話の id を決め、同じ書き込みで入れる）
    public func recordScheduleRun(
        id: Int64, at scheduledAt: Date, trigger: ScheduleRun.Trigger, skipped: String?, conversationID: (Int64) -> String, now: Date = Date()
    ) throws -> ScheduleRun? {
        let run = try database.write { db -> ScheduleRun? in
            guard var schedule = try ScheduleRow.fetchOne(db, key: id) else { throw StoreError.scheduleNotFound(id) }
            if try ScheduleRunRow.filter(Column("scheduleId") == id && Column("scheduledAt") == scheduledAt).fetchCount(db) > 0 { return nil }
            var row = ScheduleRunRow(
                id: nil, scheduleId: id, scheduledAt: scheduledAt, trigger: trigger.rawValue, requestId: nil, skipped: skipped, failure: nil, conversationId: nil,
                createdAt: now)
            try row.insert(db)
            if trigger == .schedule {
                schedule.lastScheduledAt = max(schedule.lastScheduledAt ?? scheduledAt, scheduledAt)
                try schedule.update(db)
            }
            if skipped == nil, let runID = row.id {
                row.conversationId = conversationID(runID)
                try row.update(db)
            }
            return try self.run(from: row, db: db)
        }
        if run != nil { changed(.schedule(id)) }
        return run
    }

    /// その会話で動かした回（会話が定期起動のものか、止めてよいか）
    public func scheduleRun(conversationID: String) throws -> ScheduleRun? {
        try database.read { db in
            try ScheduleRunRow.filter(Column("conversationId") == conversationID).fetchOne(db).map { try run(from: $0, db: db) }
        }
    }

    /// host の会話で動かした回のうち、失敗にしていないもの（daemon が起きたとき、起こす途中で止まった回を探す）
    public func conversationScheduleRuns() throws -> [ScheduleRun] {
        try database.read { db in
            try ScheduleRunRow.filter(Column("conversationId") != nil && Column("failure") == nil).fetchAll(db).map { try run(from: $0, db: db) }
        }
    }

    /// 会話で動かした回のターンが error で終わった。まだ失敗にしていなければ失敗にする
    public func markScheduleRunFailed(conversationID: String, reason: String) throws {
        let schedules = try database.write { db in
            try db.execute(sql: "UPDATE scheduleRun SET failure = ? WHERE conversationId = ? AND failure IS NULL", arguments: [reason, conversationID])
            return try Self.scheduleIDs(db, runColumn: "conversationId", value: conversationID)
        }
        changed(schedules.map { .schedule($0) })
    }

    /// 会話を起こせなかった回（引数を読み替えられない・タスクが消えた・起こす途中で daemon が止まった等）。起動の失敗として残す（スキップは「起こさないと決めた回」なので分ける）
    public func markScheduleRunFailed(runID: Int64, reason: String) throws {
        let schedules = try database.write { db in
            try db.execute(sql: "UPDATE scheduleRun SET failure = ? WHERE id = ?", arguments: [reason, runID])
            return try Self.scheduleIDs(db, runColumn: "id", value: runID)
        }
        changed(schedules.map { .schedule($0) })
    }

    /// 回の列（`requestId`・`conversationId`・`id`）がその値の回を持つ定期起動。最後の回の段階が変わるので state に載せ直す
    static func scheduleIDs(_ db: Database, runColumn column: String, value: some DatabaseValueConvertible) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT DISTINCT scheduleId FROM scheduleRun WHERE \(column) = ?", arguments: [value])
    }

    static func validate(name: String, rule: ScheduleRule) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw StoreError.refused(.scheduleNameEmpty, [:], "name が要る") }
        guard rule.isValid else {
            switch rule {
            case .cron(let source): throw StoreError.refused(.cronInvalid, [:], "cron 式を読めない: \(source)（分 時 日 月 曜日 の 5 つ）")
            case .interval:
                let minimum = ScheduleRule.minimumIntervalMinutes
                throw StoreError.refused(.intervalTooShort, ["minimum": "\(minimum)"], "間隔は \(minimum) 分以上")
            }
        }
    }
}
