import Foundation
import GRDB
import TaskboardKit

/// 会話が登録する概況。部品は `panelPart`（中身は JSON）、タスクのターン数は `panel`、送る文面の承認は `panelAnswer`。
/// 予算と書式の検証（`PanelValidation.check`）は、置き換えた後の部品の全部に、ここの書き込みの入口で 1 回だけ当てる（MCP も HTTP もここを通る）
extension Store {
    static let workGroupMigration = "v44 work item groups and codes"
    static let panelMigration = "v45 task panels"

    static func registerWorkGroupMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(workGroupMigration) { db in
            try db.alter(table: "workItem") { t in
                t.add(column: "groupName", .text).notNull().defaults(to: "")
                t.add(column: "code", .text).notNull().defaults(to: "")
            }
        }
    }

    static func registerPanelMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(panelMigration) { db in
            try db.create(table: "panel") { t in
                t.primaryKey("taskNumber", .integer).references("task", onDelete: .cascade)
                // タスクに紐づいたセッションの Stop hook の回数（部品の古さを数える）
                t.column("turn", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "panelPart") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("partId", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("spec", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("updatedTurn", .integer).notNull()
                // 今の本文への承認（本文が書き換わったら外す）
                t.column("answerId", .integer)
                t.column("requesterSessionId", .text)
                t.uniqueKey(["taskNumber", "partId"])
            }
            try db.create(table: "panelAnswer") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("partId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("recipient", .text).notNull()
                t.column("original", .text).notNull()
                t.column("body", .text).notNull()
                t.column("requesterSessionId", .text)
                t.column("answeredAt", .datetime).notNull()
                t.column("deliveredAt", .datetime)
                t.column("deliveryAttempts", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "panelAnswer_undelivered", on: "panelAnswer", columns: ["taskNumber", "deliveredAt"])
        }
    }

    struct PanelRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "panel"
        var taskNumber: Int
        var turn: Int
        var updatedAt: Date
    }

    struct PanelPartRow: Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "panelPart"
        var id: Int64?
        var taskNumber: Int
        var partId: String
        var position: Int
        var spec: String
        var updatedAt: Date
        var updatedTurn: Int
        var answerId: Int64?
        var requesterSessionId: String?

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    struct PanelAnswerRow: Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "panelAnswer"
        var id: Int64?
        var taskNumber: Int
        var partId: String
        var title: String
        var recipient: String
        var original: String
        var body: String
        var requesterSessionId: String?
        var answeredAt: Date
        var deliveredAt: Date?
        var deliveryAttempts: Int = 0
        /// 文書の送る文面の承認なら、その文書の名前（migration v48）
        var docName: String?

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    // MARK: 読む

    /// 部品のあるタスクの概況（state に載せる）
    public func panels() throws -> [OverviewPanel] {
        try database.read { db in
            let numbers = try Int.fetchAll(db, sql: "SELECT DISTINCT taskNumber FROM panelPart ORDER BY taskNumber")
            return try numbers.compactMap { try Self.fetchPanel(db, task: $0, machine: machineID) }
        }
    }

    /// 部品が無ければ nil
    public func panel(task number: Int) throws -> OverviewPanel? {
        try database.read { db in try Self.fetchPanel(db, task: number, machine: machineID) }
    }

    private static func fetchPanel(_ db: Database, task number: Int, machine: MachineID) throws -> OverviewPanel? {
        let rows = try PanelPartRow.filter(Column("taskNumber") == number).order(Column("position"), Column("id")).fetchAll(db)
        guard !rows.isEmpty else { return nil }
        let head = try PanelRow.fetchOne(db, key: number)
        let answerIDs = rows.compactMap(\.answerId)
        let answers = Dictionary(
            try PanelAnswerRow.filter(answerIDs.contains(Column("id"))).fetchAll(db).map { ($0.id!, $0) }, uniquingKeysWith: { a, _ in a })
        let parts = rows.compactMap { row -> PanelPart? in
            // 後の版の種類の部品は読み捨てる
            guard let spec = try? JSONDecoder().decode(PanelPartSpec.self, from: Data(row.spec.utf8)) else { return nil }
            let answer = row.answerId.flatMap { answers[$0] }.map {
                PanelDraftAnswer(answerID: $0.id!, body: $0.body, edited: $0.body != $0.original, answeredAt: $0.answeredAt)
            }
            return PanelPart(spec: spec, updatedAt: row.updatedAt, updatedTurn: row.updatedTurn, answer: answer)
        }
        return OverviewPanel(machine: machine, taskNumber: number, parts: parts, turn: head?.turn ?? 0, updatedAt: head?.updatedAt ?? rows[0].updatedAt)
    }

    // MARK: 書く

    /// 概況を部品の配列で置き換える。中身の変わらない部品は更新の時刻とターン数と承認を残す
    public func setPanel(task number: Int, _ request: PanelSetRequest, requesterSessionID: String?) throws -> PanelWriteResult {
        let warnings = try Self.validatePanel(request.parts)
        let panel = try database.write { db -> OverviewPanel? in
            try Self.requireTask(db, number)
            let now = Date()
            let turn = try Self.panelHead(db, task: number, at: now).turn
            let existing = Dictionary(
                try PanelPartRow.filter(Column("taskNumber") == number).fetchAll(db).map { ($0.partId, $0) }, uniquingKeysWith: { a, _ in a })
            let kept = Set(request.parts.map(\.id))
            for (id, row) in existing where !kept.contains(id) { try row.delete(db) }
            for (position, spec) in request.parts.enumerated() {
                try Self.upsertPart(db, task: number, spec: spec, position: position, existing: existing[spec.id], turn: turn, at: now, requester: requesterSessionID)
            }
            try Self.touchTask(db, number: number, at: now)
            return try Self.fetchPanel(db, task: number, machine: machineID)
        }
        changed(.panel(task: number), .task(number))
        return PanelWriteResult(panel: panel ?? OverviewPanel(machine: machineID, taskNumber: number, parts: [], turn: 0, updatedAt: Date()), warnings: warnings)
    }

    /// 部品 1 つを id で置き換えるか加える（`remove` なら外す）。予算は置き換えた後の全部で見る
    public func updatePanelPart(task number: Int, _ request: PanelUpdateRequest, requesterSessionID: String?) throws -> PanelWriteResult {
        let now = Date()
        var warnings: [String] = []
        let panel = try database.write { db -> OverviewPanel? in
            try Self.requireTask(db, number)
            let rows = try PanelPartRow.filter(Column("taskNumber") == number).order(Column("position"), Column("id")).fetchAll(db)
            if let removed = request.remove {
                guard let row = rows.first(where: { $0.partId == removed }) else {
                    throw StoreError.refused(.notFound, ["kind": "panel_part"], Copy.text("agent.panel.notFound", ["id": removed]))
                }
                try row.delete(db)
                try db.execute(sql: "UPDATE panelPart SET position = position - 1 WHERE taskNumber = ? AND position > ?", arguments: [number, row.position])
            }
            if let spec = request.part {
                var specs = rows.filter { $0.partId != request.remove }.compactMap { try? JSONDecoder().decode(PanelPartSpec.self, from: Data($0.spec.utf8)) }
                let existing = rows.first { $0.partId == spec.id }
                if let index = specs.firstIndex(where: { $0.id == spec.id }) {
                    specs[index] = spec
                } else {
                    specs.insert(spec, at: min(max(request.position ?? specs.count, 0), specs.count))
                }
                // 予算は全部の部品で判定し、注意は置き換えた部品の分だけを返す（ほかの部品の注意は登録したときに返してある）
                warnings = try Self.validatePanel(specs).filter { $0.hasPrefix("\(spec.id): ") }
                let turn = try Self.panelHead(db, task: number, at: now).turn
                let byID = Dictionary(rows.map { ($0.partId, $0) }, uniquingKeysWith: { a, _ in a })
                for (position, item) in specs.enumerated() {
                    if item.id == spec.id {
                        try Self.upsertPart(db, task: number, spec: item, position: position, existing: existing, turn: turn, at: now, requester: requesterSessionID)
                    } else if var row = byID[item.id] {
                        row.position = position
                        try row.update(db)
                    }
                }
            }
            try Self.touchTask(db, number: number, at: now)
            return try Self.fetchPanel(db, task: number, machine: machineID)
        }
        changed(.panel(task: number), .task(number))
        return PanelWriteResult(panel: panel ?? OverviewPanel(machine: machineID, taskNumber: number, parts: [], turn: 0, updatedAt: now), warnings: warnings)
    }

    /// 人が送る文面を［承認］した。本文は人が編集した後のもの。承認は会話へ未受領の知らせとして届く。
    /// 同じ本文への承認は 1 回だけ（2 回押しても届けるのは 1 回）
    public func approvePanelDraft(task number: Int, partID: String, body: String) throws -> OverviewPanel {
        let trimmed = try Self.approvedDraftBody(body, id: partID)
        let panel = try database.write { db -> OverviewPanel? in
            guard var row = try PanelPartRow.filter(Column("taskNumber") == number && Column("partId") == partID).fetchOne(db),
                let spec = try? JSONDecoder().decode(PanelPartSpec.self, from: Data(row.spec.utf8)), case .draft(let draft) = spec.content
            else { throw StoreError.refused(.notFound, ["kind": "panel_part"], Copy.text("agent.panel.notFound", ["id": partID])) }
            if row.answerId == nil {
                let now = Date()
                var answer = PanelAnswerRow(
                    id: nil, taskNumber: number, partId: partID, title: draft.title, recipient: draft.to, original: draft.body, body: trimmed,
                    requesterSessionId: row.requesterSessionId, answeredAt: now)
                try answer.insert(db)
                row.answerId = answer.id
                try row.update(db)
                try Self.touchTask(db, number: number, at: now)
            }
            return try Self.fetchPanel(db, task: number, machine: machineID)
        }
        changed(.panel(task: number), .task(number))
        guard let panel else { throw StoreError.refused(.notFound, ["kind": "panel_part"], Copy.text("agent.panel.notFound", ["id": partID])) }
        return panel
    }

    /// 人が承認した本文の検査（概況と文書の送る文面で同じ）。前後の空白を外して返す
    static func approvedDraftBody(_ body: String, id: String) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalid(Copy.text("agent.panel.invalid.empty", ["id": id, "field": "body"])) }
        guard trimmed.count <= PanelBudget.draftBodyChars else {
            throw StoreError.invalid(
                Copy.text("agent.panel.invalid.text", ["id": id, "field": "body", "count": "\(trimmed.count)", "limit": "\(PanelBudget.draftBodyChars)"]))
        }
        return trimmed
    }

    /// タスクに紐づいたセッションがターンを終えた（Stop hook）。概況のあるタスクだけ数える
    public func notePanelTurn(task number: Int) throws {
        let counted = try database.write { db -> Bool in
            guard try PanelPartRow.filter(Column("taskNumber") == number).fetchCount(db) > 0 else { return false }
            try db.execute(sql: "UPDATE panel SET turn = turn + 1 WHERE taskNumber = ?", arguments: [number])
            return db.changesCount > 0
        }
        if counted { changed(.panel(task: number)) }
    }

    /// 中身が変わったかを文字列で比べるので、鍵の並びを固定する
    private static let specEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func validatePanel(_ parts: [PanelPartSpec]) throws -> [String] {
        do {
            return try PanelValidation.check(parts)
        } catch let invalid as PanelInvalid {
            throw StoreError.invalid(invalid.message)
        }
    }

    private static func requireTask(_ db: Database, _ number: Int) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM task WHERE number = ?)", arguments: [number]) == true else {
            throw StoreError.taskNotFound(number)
        }
    }

    /// タスクの概況の行（ターン数）。無ければ作る
    private static func panelHead(_ db: Database, task number: Int, at now: Date) throws -> PanelRow {
        if var head = try PanelRow.fetchOne(db, key: number) {
            head.updatedAt = now
            try head.update(db)
            return head
        }
        let head = PanelRow(taskNumber: number, turn: 0, updatedAt: now)
        try head.insert(db)
        return head
    }

    private static func upsertPart(
        _ db: Database, task number: Int, spec: PanelPartSpec, position: Int, existing: PanelPartRow?, turn: Int, at now: Date, requester: String?
    ) throws {
        let json = String(decoding: try specEncoder.encode(spec), as: UTF8.self)
        if var row = existing {
            row.position = position
            if row.spec != json {
                row.spec = json
                row.updatedAt = now
                row.updatedTurn = turn
                // 本文が変わった送る文面は、承認を待ち直す
                row.answerId = nil
                if let requester { row.requesterSessionId = requester }
            }
            try row.update(db)
        } else {
            var row = PanelPartRow(
                id: nil, taskNumber: number, partId: spec.id, position: position, spec: json, updatedAt: now, updatedTurn: turn, answerId: nil,
                requesterSessionId: requester)
            try row.insert(db)
        }
    }

    // MARK: 未受領（`Store+Documents` の未受領の集まりから呼ぶ）

    static let undeliveredDraftSQL = "SELECT taskNumber FROM panelAnswer WHERE deliveredAt IS NULL"

    static func undeliveredDraftRows(_ db: Database, task number: Int) throws -> [PanelAnswerRow] {
        try PanelAnswerRow.filter(Column("taskNumber") == number && Column("deliveredAt") == nil).order(Column("answeredAt"), Column("id")).fetchAll(db)
    }

    static func draftFeedback(from row: PanelAnswerRow) -> PanelDraftFeedback {
        PanelDraftFeedback(
            answerID: row.id!, taskNumber: row.taskNumber, partID: row.partId, title: row.title, to: row.recipient, original: row.original, body: row.body,
            answeredAt: row.answeredAt, docName: row.docName)
    }
}
