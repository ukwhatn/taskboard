import Foundation
import GRDB
import TaskboardKit

/// 文書の本文に置く送る文面（`doc_publish` の `drafts`）。中身は `docDraft`、人の承認は概況の送る文面と同じ `panelAnswer` に入れ、
/// 未受領の束（`FeedbackBundle.drafts`）・配信・再試行は概況の送る文面の経路をそのまま通る
extension Store {
    static let docDraftMigration = "v48 document drafts and inline asks"

    static func registerDocDraftMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(docDraftMigration) { db in
            try db.create(table: "docDraft") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("docId", .integer).notNull().references("doc", onDelete: .cascade)
                t.column("draftId", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("spec", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                // 今の本文への承認（`panelAnswer.id`。本文が書き換わったら外す）
                t.column("answerId", .integer)
                t.column("requesterSessionId", .text)
                t.uniqueKey(["docId", "draftId"])
            }
            // 本文の印 `<!-- ask: q1 -->` が指すのは、doc_publish の questions で本文と一緒に出した束だけ
            try db.alter(table: "ask") { t in t.add(column: "inBody", .boolean).notNull().defaults(to: false) }
            // 文書の文面の承認なら、その文書の名前（文書を消しても、届けるまで残す）
            try db.alter(table: "panelAnswer") { t in t.add(column: "docName", .text) }
        }
    }

    struct DocDraftRow: Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "docDraft"
        var id: Int64?
        var docId: Int64
        var draftId: String
        var position: Int
        var spec: String
        var updatedAt: Date
        var answerId: Int64?
        var requesterSessionId: String?

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    /// 中身が変わったかを文字列で比べるので、鍵の並びを固定する
    private static let draftEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func fetchDocDrafts(_ db: Database, doc docID: Int64) throws -> [DocDraft] {
        let rows = try DocDraftRow.filter(Column("docId") == docID).order(Column("position")).fetchAll(db)
        let answerIDs = rows.compactMap(\.answerId)
        let answers = Dictionary(uniqueKeysWithValues: try PanelAnswerRow.filter(answerIDs.contains(Column("id"))).fetchAll(db).map { ($0.id!, $0) })
        return rows.compactMap { row in
            guard let draft = try? JSONDecoder().decode(PanelDraft.self, from: Data(row.spec.utf8)) else { return nil }
            let answer = row.answerId.flatMap { answers[$0] }.map {
                PanelDraftAnswer(answerID: $0.id!, body: $0.body, edited: $0.body != $0.original, answeredAt: $0.answeredAt)
            }
            return DocDraft(id: row.draftId, draft: draft, answer: answer, updatedAt: row.updatedAt)
        }
    }

    static func docDraftIDs(_ db: Database, doc docID: Int64) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT draftId FROM docDraft WHERE docId = ?", arguments: [docID]))
    }

    /// 文書の送る文面を並びごと置き換える。本文の変わらない文面は承認と時刻を残し、変わった文面は承認を外して待ち直す
    static func replaceDocDrafts(_ db: Database, doc docID: Int64, with specs: [DocDraftSpec], requester: String?, at now: Date) throws {
        let existing = Dictionary(uniqueKeysWithValues: try DocDraftRow.filter(Column("docId") == docID).fetchAll(db).map { ($0.draftId, $0) })
        let kept = Set(specs.map(\.id))
        for row in existing.values where !kept.contains(row.draftId) { _ = try row.delete(db) }
        for (position, spec) in specs.enumerated() {
            let json = String(decoding: try draftEncoder.encode(spec.draft), as: UTF8.self)
            if var row = existing[spec.id] {
                row.position = position
                if row.spec != json {
                    row.spec = json
                    row.updatedAt = now
                    row.answerId = nil
                    if let requester { row.requesterSessionId = requester }
                }
                try row.update(db)
            } else {
                var row = DocDraftRow(
                    id: nil, docId: docID, draftId: spec.id, position: position, spec: json, updatedAt: now, answerId: nil, requesterSessionId: requester)
                try row.insert(db)
            }
        }
    }

    /// 人が文書の送る文面を［承認］した。本文は人が編集した後のもの。概況の送る文面と同じく、同じ本文への承認は 1 回だけで、会話へ未受領の知らせとして届く。
    /// 属するタスクの番号を返す
    public func approveDocDraft(doc docID: Int64, draftID: String, body: String) throws -> Int {
        let trimmed = try Self.approvedDraftBody(body, id: draftID)
        let number = try database.write { db -> Int in
            guard let doc = try Row.fetchOne(db, sql: "SELECT taskNumber, name FROM doc WHERE id = ?", arguments: [docID]) else { throw StoreError.docNotFound(docID) }
            let number: Int = doc["taskNumber"]
            guard var row = try DocDraftRow.filter(Column("docId") == docID && Column("draftId") == draftID).fetchOne(db),
                let draft = try? JSONDecoder().decode(PanelDraft.self, from: Data(row.spec.utf8))
            else { throw StoreError.refused(.notFound, ["kind": "doc_draft"], Copy.text("agent.doc.drafts.notFound", ["id": draftID])) }
            guard row.answerId == nil else { return number }
            let now = Date()
            var answer = PanelAnswerRow(
                id: nil, taskNumber: number, partId: draftID, title: draft.title, recipient: draft.to, original: draft.body, body: trimmed,
                requesterSessionId: row.requesterSessionId, answeredAt: now, docName: doc["name"])
            try answer.insert(db)
            row.answerId = answer.id
            try row.update(db)
            try Self.touchTask(db, number: number, at: now)
            return number
        }
        changed(.document(docID), .task(number))
        return number
    }
}
