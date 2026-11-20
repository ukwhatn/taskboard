import Foundation
import GRDB
import TaskboardKit

/// 文書・リビジョン・質問・レビュー・コメント（kairan の契約を daemon の SQLite に持つ）。
/// 文書はタスクに属し `(taskNumber, name)` で一意。質問は文書に付き、1 文書に open は 1 つ（部分 unique index）。
extension Store {
    static func registerAskWorkItemMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v39 ask work items") { db in
            try db.alter(table: "ask") { t in t.add(column: "workItemId", .integer).references("workItem", onDelete: .setNull) }
        }
    }

    /// 済ませた手作業（`finishManualWork`）を、質問の回答と同じく会話に届くまで残す
    static func registerFinishedWorkMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v42 finished manual work") { db in
            try db.alter(table: "workItem") { t in
                t.add(column: "finishedRequest", .text)
                t.add(column: "finishedAt", .datetime)
                t.add(column: "finishDeliveredAt", .datetime)
                t.add(column: "finishDeliveryAttempts", .integer).notNull().defaults(to: 0)
            }
        }
    }

    static let docExternalHostsMigration = "v49 document external hosts"

    /// 版ごとの外部の資源のホスト（JSON の配列）。今ある版も本文から集めておく（古い版を開いても帯が出るように）
    static func registerDocExternalHostsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(docExternalHostsMigration) { db in
            try db.alter(table: "docRevision") { t in t.add(column: "externalHosts", .text).notNull().defaults(to: "[]") }
            let rows = try Row.fetchAll(db, sql: "SELECT r.id, r.content, d.format FROM docRevision r JOIN doc d ON d.id = r.docId")
            for row in rows {
                let format = DocFormat(rawValue: row["format"]) ?? .markdown
                let hosts = DocExternalHosts.hosts(in: row["content"], format: format)
                guard !hosts.isEmpty else { continue }
                let id: Int64 = row["id"]
                try db.execute(sql: "UPDATE docRevision SET externalHosts = ? WHERE id = ?", arguments: [encodeJSON(hosts), id])
            }
        }
    }

    static func registerDocumentMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4 documents, asks, reviews") { db in
            try db.create(table: "doc") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("format", .text).notNull()
                t.column("title", .text)
                t.column("sourcePath", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["taskNumber", "name"])
            }
            try db.create(table: "docRevision") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("docId", .integer).notNull().references("doc", onDelete: .cascade)
                t.column("rev", .integer).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["docId", "rev"])
            }
            try db.create(table: "ask") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("docId", .integer).notNull().references("doc", onDelete: .cascade)
                t.column("status", .text).notNull()
                t.column("questions", .text).notNull()
                t.column("answers", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("answeredAt", .datetime)
                t.column("deliveredAt", .datetime)
            }
            // 1 文書に回答待ちの質問は 1 つ。差し替えは前のものを cancelled にしてから入れる
            try db.execute(sql: "CREATE UNIQUE INDEX ask_one_open_per_doc ON ask(docId) WHERE status = 'open'")
            try db.create(table: "review") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("state", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("submittedAt", .datetime)
                t.column("deliveredAt", .datetime)
            }
            try db.create(index: "review_task", on: "review", columns: ["taskNumber", "state"])
            try db.create(table: "docComment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("docId", .integer).notNull().references("doc", onDelete: .cascade)
                t.column("rev", .integer).notNull()
                t.column("quote", .text)
                t.column("prefix", .text)
                t.column("suffix", .text)
                t.column("body", .text).notNull()
                t.column("state", .text).notNull()
                t.column("reviewId", .integer).references("review", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.column("submittedAt", .datetime)
                t.column("resolvedAt", .datetime)
            }
            try db.create(index: "docComment_doc", on: "docComment", columns: ["docId"])
            try db.create(table: "commentReply") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("commentId", .integer).notNull().references("docComment", onDelete: .cascade)
                t.column("author", .text).notNull()
                t.column("body", .text).notNull()
                t.column("state", .text).notNull()
                t.column("reviewId", .integer).references("review", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "reviewRequest") { t in
                t.primaryKey("taskNumber", .integer).references("task", onDelete: .cascade)
                t.column("note", .text).notNull().defaults(to: "")
                t.column("requestedAt", .datetime).notNull()
            }
        }
    }

    // MARK: 文書

    public func documents() throws -> [Document] {
        try database.read { db in try Self.fetchDocuments(db, machine: machineID) }
    }

    public func documents(task number: Int) throws -> [Document] {
        try database.read { db in try Self.fetchDocuments(db, machine: machineID, task: number) }
    }

    public func document(id: Int64) throws -> Document? {
        try database.read { db in try Self.fetchDocuments(db, machine: machineID, ids: [id]).first }
    }

    /// 同じ名前なら新しいリビジョン。本文と質問は同じトランザクション（新リビジョンだけできて質問が旧状態、を見せない）。
    /// `requester` は質問を出した Claude の会話 ID（`FeedbackService.requesterSessionID` で決めたもの）
    public func publish(task number: Int, _ request: DocPublishRequest, requester: String? = nil) throws -> DocPublishResponse {
        if let problem = DocPublishRequest.validateName(request.name) { throw StoreError.invalid(problem) }
        if let questions = request.questions, let problem = AskQuestion.validate(questions) { throw StoreError.invalid(problem) }
        if let title = request.title, title.count > 500 { throw StoreError.invalid("title は 500 文字まで") }
        if let path = request.sourcePath, !path.hasPrefix("/") { throw StoreError.invalid("sourcePath は絶対パス") }
        if let drafts = request.drafts, let problem = DocDraftSpec.validate(drafts) { throw StoreError.invalid(problem) }
        let markers = DocMarkers.markers(in: request.content, format: request.format)
        var touchedAsks: [Int64] = []
        var workChanged = false
        let response = try database.write { db in
            guard try Self.taskExists(db, number) else { throw StoreError.taskNotFound(number) }
            let now = Date()
            let existing = try DocRow.filter(Column("taskNumber") == number && Column("name") == request.name).fetchOne(db)
            let docID: Int64
            let revision: Int
            if let existing {
                guard existing.format == request.format.rawValue else {
                    throw StoreError.docFormatMismatch(name: request.name, existing: DocFormat(rawValue: existing.format) ?? .markdown)
                }
                docID = existing.id!
                revision = (try Int.fetchOne(db, sql: "SELECT MAX(rev) FROM docRevision WHERE docId = ?", arguments: [docID]) ?? 0) + 1
                // title 省略は維持、sourcePath は毎回上書き（content 直接の publish の後に古いパスが残ると別内容のファイルを開くボタンが出る）
                try db.execute(
                    sql: "UPDATE doc SET title = COALESCE(?, title), sourcePath = ?, updatedAt = ? WHERE id = ?",
                    arguments: [request.title, request.sourcePath, now, docID])
            } else {
                var row = DocRow(
                    id: nil, taskNumber: number, name: request.name, format: request.format.rawValue, title: request.title,
                    sourcePath: request.sourcePath, createdAt: now, updatedAt: now)
                try row.insert(db)
                docID = row.id!
                revision = 1
            }
            // 印は、渡した質問・文面か、省いたなら今ある質問（本文と一緒に出した束）・文面を指す
            let questionIDs = try request.questions.map { Set($0.map(\.id)) } ?? Set(Self.latestInBodyAsk(db, doc: docID)?.questions.map(\.id) ?? [])
            let draftIDs = try request.drafts.map { Set($0.map(\.id)) } ?? Self.docDraftIDs(db, doc: docID)
            if let problem = DocMarkers.problem(markers, questions: questionIDs, drafts: draftIDs) { throw StoreError.invalid(problem) }
            let hosts = Self.encodeJSON(DocExternalHosts.hosts(in: request.content, format: request.format))
            var revisionRow = RevisionRow(id: nil, docId: docID, rev: revision, content: request.content, externalHosts: hosts, createdAt: now)
            try revisionRow.insert(db)
            try Self.touchTask(db, number: number, at: now)
            var askID: Int64?
            if let questions = request.questions {
                (askID, touchedAsks, workChanged) = try Self.swapOpenAsk(
                    db, task: number, doc: docID, questions: questions, requester: requester, workItem: request.workItem, inBody: true, now: now)
            } else {
                askID = try AskRow.filter(Column("docId") == docID && Column("status") == "open").fetchOne(db)?.id
            }
            if let drafts = request.drafts { try Self.replaceDocDrafts(db, doc: docID, with: drafts, requester: requester, at: now) }
            guard let document = try Self.fetchDocuments(db, machine: machineID, ids: [docID]).first else { throw StoreError.docNotFound(docID) }
            return DocPublishResponse(
                document: document, revision: revision, isNew: existing == nil, askID: askID,
                pendingFeedback: try Self.countUndelivered(db, task: number))
        }
        changed([.document(response.document.docID)] + touchedAsks.map { .ask($0) } + [.task(number)] + (workChanged ? [.workItems(task: number)] : []))
        return response
    }

    /// 既存の文書に質問だけ付ける。本文・題・リビジョンは変えない（返すリビジョンは最新）
    public func attachQuestions(doc id: Int64, questions: [AskQuestion], requester: String? = nil, workItem: Int64? = nil) throws -> DocPublishResponse {
        if let problem = AskQuestion.validate(questions) { throw StoreError.invalid(problem) }
        var touchedAsks: [Int64] = []
        var workChanged = false
        let response = try database.write { db in
            guard let row = try DocRow.fetchOne(db, key: id) else { throw StoreError.docNotFound(id) }
            let now = Date()
            let askID: Int64?
            (askID, touchedAsks, workChanged) = try Self.swapOpenAsk(
                db, task: row.taskNumber, doc: id, questions: questions, requester: requester, workItem: workItem, inBody: false, now: now)
            try Self.touchTask(db, number: row.taskNumber, at: now)
            guard let document = try Self.fetchDocuments(db, machine: machineID, ids: [id]).first else { throw StoreError.docNotFound(id) }
            return DocPublishResponse(
                document: document, revision: document.latestRev, isNew: false, askID: askID,
                pendingFeedback: try Self.countUndelivered(db, task: row.taskNumber))
        }
        let number = response.document.taskNumber
        changed([.document(id)] + touchedAsks.map { .ask($0) } + [.task(number)] + (workChanged ? [.workItems(task: number)] : []))
        return response
    }

    /// 文書を消す（リビジョン・質問・コメントも消える）。属していたタスクの番号を返す。
    public func deleteDocument(id: Int64) throws -> Int {
        let number = try database.write { db in
            guard let row = try DocRow.fetchOne(db, key: id) else { throw StoreError.docNotFound(id) }
            try row.delete(db)
            return row.taskNumber
        }
        changed(.document(id), .task(number))
        return number
    }

    public func revisions(doc id: Int64) throws -> [DocRevision] {
        try database.read { db in
            guard try DocRow.exists(db, key: id) else { throw StoreError.docNotFound(id) }
            return try RevisionRow.filter(Column("docId") == id).order(Column("rev")).fetchAll(db).map { DocRevision(rev: $0.rev, createdAt: $0.createdAt) }
        }
    }

    /// 本文。`rev` 省略は最新。
    public func content(doc id: Int64, rev: Int?) throws -> DocContent {
        try database.read { db in
            guard let doc = try DocRow.fetchOne(db, key: id) else { throw StoreError.docNotFound(id) }
            var request = RevisionRow.filter(Column("docId") == id)
            if let rev { request = request.filter(Column("rev") == rev) } else { request = request.order(Column("rev").desc) }
            guard let row = try request.fetchOne(db) else { throw StoreError.revisionNotFound(rev ?? 0) }
            return DocContent(
                docID: id, rev: row.rev, format: DocFormat(rawValue: doc.format) ?? .markdown, content: row.content,
                externalHosts: Self.decodeJSON([String].self, row.externalHosts) ?? [])
        }
    }

    public func sourcePath(doc id: Int64) throws -> String? {
        try database.read { db in try DocRow.fetchOne(db, key: id)?.sourcePath }
    }

    // MARK: 質問

    /// snapshot に載せる質問: open と、回答済みで未受領のもの。
    public func asks(pending: Bool) throws -> [Ask] {
        try database.read { db in
            var request = AskRow.order(Column("createdAt"), Column("id"))
            if pending { request = request.filter(Column("status") == "open" || (Column("status") == "answered" && Column("deliveredAt") == nil)) }
            return try request.fetchAll(db).map { Self.ask(from: $0, machine: machineID) }
        }
    }

    public func asks(task number: Int) throws -> [Ask] {
        try database.read { db in
            try AskRow.filter(Column("taskNumber") == number).order(Column("createdAt"), Column("id")).fetchAll(db).map { Self.ask(from: $0, machine: machineID) }
        }
    }

    public func ask(id: Int64) throws -> Ask? {
        try database.read { db in try AskRow.fetchOne(db, key: id).map { Self.ask(from: $0, machine: machineID) } }
    }

    /// 全問に回答が要る。open でなければ 409 相当。
    public func answerAsk(id: Int64, answers: [AskAnswer]) throws -> Ask {
        let ask = try database.write { db in try Self.recordAnswers(db, ask: id, answers: answers, doc: nil, machine: machineID, at: Date()) }
        changed(.ask(ask.askID), .task(ask.taskNumber), .workItems(task: ask.taskNumber))
        return ask
    }

    /// 質問に回答を書く（`answerAsk` と文書の欄の送信 `submitDocForms` の共通）。`doc` を渡すと、その文書の質問でなければ断る
    static func recordAnswers(_ db: Database, ask id: Int64, answers: [AskAnswer], doc docID: Int64?, machine: MachineID, at now: Date) throws -> Ask {
        guard let row = try AskRow.fetchOne(db, key: id), docID.map({ $0 == row.docId }) ?? true else { throw StoreError.askNotFound(id) }
        let ask = Self.ask(from: row, machine: machine)
        guard ask.status == .open else { throw StoreError.askNotOpen(id) }
        let missing = ask.unanswered(in: answers)
        guard missing.isEmpty else { throw StoreError.askUnanswered(missing) }
        for answer in answers {
            if answer.selected.count > 8 || answer.selected.contains(where: { $0.count > 300 }) { throw StoreError.invalid("選択は 8 個・300 文字まで") }
            if (answer.freeText ?? "").count > 20000 { throw StoreError.refused(.textTooLong, ["limit": "20000"], "自由記述は 20000 文字まで") }
        }
        try db.execute(
            sql: "UPDATE ask SET status = 'answered', answers = ?, answeredAt = ? WHERE id = ? AND status = 'open'",
            arguments: [Self.encodeJSON(answers), now, id])
        if let item = row.workItemId { try Self.resumeWorkItem(db, id: item, at: now) }
        try Self.touchTask(db, number: ask.taskNumber, at: now)
        guard let updated = try AskRow.fetchOne(db, key: id) else { throw StoreError.askNotFound(id) }
        return Self.ask(from: updated, machine: machine)
    }

    /// 取り下げ。open でなければ何もしない（nil）。
    public func cancelAsk(id: Int64) throws -> Ask? {
        let ask = try database.write { db -> Ask? in
            guard let row = try AskRow.fetchOne(db, key: id) else { throw StoreError.askNotFound(id) }
            guard row.status == "open" else { return nil }
            try db.execute(sql: "UPDATE ask SET status = 'cancelled' WHERE id = ?", arguments: [id])
            if let item = row.workItemId { try Self.resumeWorkItem(db, id: item, at: Date()) }
            return try AskRow.fetchOne(db, key: id).map { Self.ask(from: $0, machine: machineID) }
        }
        if let ask { changed(.ask(ask.askID), .task(ask.taskNumber), .workItems(task: ask.taskNumber)) }
        return ask
    }

    /// タスクの未回答の質問を取り下げ、取り下げたものを返す
    static func cancelOpenAsks(_ db: Database, task number: Int, machine: MachineID) throws -> [Ask] {
        let open = try AskRow.filter(Column("taskNumber") == number && Column("status") == "open").fetchAll(db)
        guard !open.isEmpty else { return [] }
        try db.execute(sql: "UPDATE ask SET status = 'cancelled' WHERE taskNumber = ? AND status = 'open'", arguments: [number])
        return try AskRow.filter(open.map(\.id).contains(Column("id"))).order(Column("id")).fetchAll(db).map { ask(from: $0, machine: machine) }
    }

    /// 文書の open な質問を差し替える。同じ質問なら作り直さない（入力途中の回答を消さないため）が、別の会話が出し直したら届け先はその会話にする。空配列は取り下げ。
    /// 作業項目は渡したものか、差し替える前の質問に結ばれていたものを新しい質問に結び、回答待ちにする（取り下げなら作業中に戻す）。
    /// 返すのは open な質問、書いた質問（取り下げたものと作ったもの）、作業項目を書いたか
    private static func swapOpenAsk(
        _ db: Database, task number: Int, doc docID: Int64, questions: [AskQuestion], requester: String?, workItem: Int64?, inBody: Bool, now: Date
    ) throws -> (open: Int64?, touched: [Int64], workChanged: Bool) {
        if let workItem {
            let owner = try Int.fetchOne(db, sql: "SELECT taskNumber FROM workItem WHERE id = ?", arguments: [workItem])
            guard owner == number else { throw StoreError.invalid("作業項目 \(workItem) はタスク #\(number) に無い") }
        }
        let serialized = encodeJSON(questions)
        let existing = try AskRow.filter(Column("docId") == docID && Column("status") == "open").fetchOne(db)
        if let existing, existing.questions == serialized {
            var touched: [Int64] = []
            if inBody, !existing.inBody, let id = existing.id {
                try db.execute(sql: "UPDATE ask SET inBody = 1 WHERE id = ?", arguments: [id])
                touched = [id]
            }
            if let requester {
                try db.execute(sql: "UPDATE ask SET requesterSessionId = ? WHERE id = ?", arguments: [requester, existing.id])
                touched = existing.id.map { [$0] } ?? []
            }
            guard let workItem else { return (existing.id, touched, false) }
            try db.execute(sql: "UPDATE ask SET workItemId = ? WHERE id = ?", arguments: [workItem, existing.id])
            try waitOnAsk(db, item: workItem, questions: questions, at: now)
            return (existing.id, existing.id.map { [$0] } ?? [], true)
        }
        var touched: [Int64] = []
        if let existing, let id = existing.id {
            try db.execute(sql: "UPDATE ask SET status = 'cancelled' WHERE id = ?", arguments: [id])
            touched.append(id)
        }
        let linked = workItem ?? existing?.workItemId
        guard !questions.isEmpty else {
            guard let linked else { return (nil, touched, false) }
            try resumeWorkItem(db, id: linked, at: now)
            return (nil, touched, true)
        }
        var row = AskRow(
            id: nil, taskNumber: number, docId: docID, status: "open", questions: serialized, answers: nil, createdAt: now, answeredAt: nil, deliveredAt: nil,
            requesterSessionId: requester, workItemId: linked, inBody: inBody)
        try row.insert(db)
        if let linked { try waitOnAsk(db, item: linked, questions: questions, at: now) }
        return (row.id, touched + [row.id!], linked != nil)
    }

    /// 本文と一緒に出した最新の質問の束（本文の印はこの束を指す）
    private static func latestInBodyAsk(_ db: Database, doc docID: Int64) throws -> Ask? {
        try AskRow.filter(Column("docId") == docID && Column("inBody") == true).order(Column("id").desc).fetchOne(db).map { ask(from: $0, machine: MachineID(rawValue: "")) }
    }

    /// 質問に結んだ作業項目を回答待ちにする。終わった項目（済み・やめた）は動かさない
    private static func waitOnAsk(_ db: Database, item id: Int64, questions: [AskQuestion], at now: Date) throws {
        let first = questions.first?.question ?? ""
        let head = first.count > 40 ? String(first.prefix(40)) + "…" : first
        try db.execute(
            sql: """
                UPDATE workItem SET state = 'wait', blockerKind = 'approval', blockerText = ?, blockerTone = NULL, updatedAt = ?
                WHERE id = ? AND state NOT IN ('done', 'drop')
                """,
            arguments: ["質問「\(head)」の回答待ち", now, id])
    }

    /// 回答・取り下げで、結んだ作業項目を待ちから作業中に戻す。待ちでなくなっていれば（会話が先に動かした）触らない
    static func resumeWorkItem(_ db: Database, id: Int64, at now: Date) throws {
        try db.execute(
            sql: "UPDATE workItem SET state = 'doing', blockerKind = NULL, blockerText = '', blockerTone = NULL, updatedAt = ? WHERE id = ? AND state = 'wait'",
            arguments: [now, id])
    }

    // MARK: コメント

    public func comments(doc id: Int64) throws -> [DocComment] {
        try database.read { db in
            guard try DocRow.exists(db, key: id) else { throw StoreError.docNotFound(id) }
            return try Self.fetchComments(db, CommentRow.filter(Column("docId") == id))
        }
    }

    public func comment(id: Int64) throws -> DocComment? {
        try database.read { db in try Self.fetchComments(db, CommentRow.filter(Column("id") == id)).first }
    }

    public func createDraftComment(doc id: Int64, _ request: CommentCreateRequest) throws -> DocComment {
        guard !request.body.isEmpty, request.body.count <= 20000 else { throw StoreError.refused(.textTooLong, ["limit": "20000"], "本文は 1〜20000 文字") }
        if let anchor = request.anchor, anchor.exact.isEmpty || anchor.exact.count > 5000 || anchor.prefix.count > 500 || anchor.suffix.count > 500 {
            throw StoreError.invalid("引用は exact 1〜5000 文字、prefix / suffix 500 文字まで")
        }
        let comment = try database.write { db in
            guard try DocRow.exists(db, key: id) else { throw StoreError.docNotFound(id) }
            guard try RevisionRow.filter(Column("docId") == id && Column("rev") == request.rev).fetchCount(db) == 1 else {
                throw StoreError.revisionNotFound(request.rev)
            }
            var row = CommentRow(
                id: nil, docId: id, rev: request.rev, quote: request.anchor?.exact, prefix: request.anchor?.prefix, suffix: request.anchor?.suffix,
                body: request.body, state: "draft", reviewId: nil, createdAt: Date(), submittedAt: nil, resolvedAt: nil)
            try row.insert(db)
            return try Self.fetchComments(db, CommentRow.filter(Column("id") == row.id!)).first!
        }
        changed(.document(id))
        return comment
    }

    public func updateDraftComment(id: Int64, body: String) throws -> DocComment {
        guard !body.isEmpty, body.count <= 20000 else { throw StoreError.refused(.textTooLong, ["limit": "20000"], "本文は 1〜20000 文字") }
        return try database.write { db in
            guard let row = try CommentRow.fetchOne(db, key: id) else { throw StoreError.commentNotFound(id) }
            guard row.state == "draft" else { throw StoreError.commentNotDraft(id) }
            try db.execute(sql: "UPDATE docComment SET body = ? WHERE id = ?", arguments: [body, id])
            return try Self.fetchComments(db, CommentRow.filter(Column("id") == id)).first!
        }
    }

    /// draft だけ消せる。属していた文書の id を返す。
    public func deleteDraftComment(id: Int64) throws -> Int64 {
        let docID = try database.write { db in
            guard let row = try CommentRow.fetchOne(db, key: id) else { throw StoreError.commentNotFound(id) }
            guard row.state == "draft" else { throw StoreError.commentNotDraft(id) }
            try row.delete(db)
            return row.docId
        }
        changed(.document(docID))
        return docID
    }

    /// 返信。agent は即 submitted、human はレビューの送信まで draft。`resolve` は open なコメントだけ閉じる。
    public func addReply(comment id: Int64, author: CommentReply.Author, body: String, resolve: Bool) throws -> CommentReply {
        guard !body.isEmpty, body.count <= 20000 else { throw StoreError.refused(.textTooLong, ["limit": "20000"], "本文は 1〜20000 文字") }
        let (reply, docID) = try database.write { db in
            guard let comment = try CommentRow.fetchOne(db, key: id) else { throw StoreError.commentNotFound(id) }
            let now = Date()
            var row = ReplyRow(
                id: nil, commentId: id, author: author.rawValue, body: body, state: author == .agent ? "submitted" : "draft", reviewId: nil,
                createdAt: now)
            try row.insert(db)
            if resolve, comment.state == "open" {
                try db.execute(sql: "UPDATE docComment SET state = 'resolved', resolvedAt = ? WHERE id = ?", arguments: [now, id])
            }
            return (Self.reply(from: row), comment.docId)
        }
        changed(.document(docID))
        return reply
    }

    public func setCommentResolved(id: Int64, _ resolved: Bool) throws -> DocComment {
        let comment = try database.write { db in
            guard let row = try CommentRow.fetchOne(db, key: id) else { throw StoreError.commentNotFound(id) }
            guard row.state != "draft" else { throw StoreError.refused(.commentIsDraft, [:], "下書きのコメントは解決にできない") }
            if resolved {
                try db.execute(sql: "UPDATE docComment SET state = 'resolved', resolvedAt = ? WHERE id = ?", arguments: [Date(), id])
            } else {
                try db.execute(sql: "UPDATE docComment SET state = 'open', resolvedAt = NULL WHERE id = ?", arguments: [id])
            }
            return try Self.fetchComments(db, CommentRow.filter(Column("id") == id)).first!
        }
        changed(.document(comment.docID))
        return comment
    }

    // MARK: レビュー

    /// 送る前のレビュー: 総括の下書きと、タスクの文書に付いた draft コメント。
    public func reviewDraft(task number: Int) throws -> ReviewDraft {
        try database.read { db in
            let review = try ReviewRow.filter(Column("taskNumber") == number && Column("state") == "draft").fetchOne(db).map(Self.review(from:))
            let docIDs = try DocRow.filter(Column("taskNumber") == number).fetchAll(db).compactMap(\.id)
            let comments = try Self.fetchComments(db, CommentRow.filter(docIDs.contains(Column("docId")) && Column("state") == "draft"))
            return ReviewDraft(review: review, comments: comments)
        }
    }

    public func setReviewSummary(task number: Int, summary: String) throws -> Review {
        guard summary.count <= 20000 else { throw StoreError.refused(.textTooLong, ["limit": "20000"], "総括は 20000 文字まで") }
        return try database.write { db in
            guard try Self.taskExists(db, number) else { throw StoreError.taskNotFound(number) }
            return try Self.setDraftSummary(db, task: number, summary: summary)
        }
    }

    private static func setDraftSummary(_ db: Database, task number: Int, summary: String) throws -> Review {
        if let existing = try ReviewRow.filter(Column("taskNumber") == number && Column("state") == "draft").fetchOne(db) {
            try db.execute(sql: "UPDATE review SET summary = ? WHERE id = ?", arguments: [summary, existing.id])
            return review(from: try ReviewRow.fetchOne(db, key: existing.id!)!)
        }
        var row = ReviewRow(
            id: nil, taskNumber: number, summary: summary, state: "draft", createdAt: Date(), submittedAt: nil, deliveredAt: nil, requesterSessionId: nil)
        try row.insert(db)
        return review(from: row)
    }

    /// 送信。draft のコメントと人の返信を open / submitted にしてこのレビューに結び、依頼を消す。
    public func submitReview(task number: Int) throws -> Review {
        let (review, docIDs) = try database.write { db in
            guard try Self.taskExists(db, number) else { throw StoreError.taskNotFound(number) }
            let now = Date()
            let draft = try Self.setDraftSummary(
                db, task: number,
                summary: try ReviewRow.filter(Column("taskNumber") == number && Column("state") == "draft").fetchOne(db)?.summary ?? "")
            // 頼まれて送るレビューは、頼んだ会話に届ける（頼まれずに送ったものは、タスクに結ばれたセッションから届け先を決める）
            let requester = try String.fetchOne(db, sql: "SELECT requesterSessionId FROM reviewRequest WHERE taskNumber = ?", arguments: [number])
            try db.execute(
                sql: "UPDATE review SET state = 'submitted', submittedAt = ?, requesterSessionId = ? WHERE id = ?", arguments: [now, requester, draft.id])
            try db.execute(
                sql: """
                    UPDATE docComment SET state = 'open', submittedAt = ?, reviewId = ?
                    WHERE state = 'draft' AND docId IN (SELECT id FROM doc WHERE taskNumber = ?)
                    """, arguments: [now, draft.id, number])
            try db.execute(
                sql: """
                    UPDATE commentReply SET state = 'submitted', reviewId = ?
                    WHERE state = 'draft' AND commentId IN (
                      SELECT c.id FROM docComment c JOIN doc d ON d.id = c.docId WHERE d.taskNumber = ?)
                    """, arguments: [draft.id, number])
            try db.execute(sql: "DELETE FROM reviewRequest WHERE taskNumber = ?", arguments: [number])
            try Self.touchTask(db, number: number, at: now)
            let docIDs = try Int64.fetchAll(db, sql: "SELECT id FROM doc WHERE taskNumber = ? ORDER BY id", arguments: [number])
            return (Self.review(from: try ReviewRow.fetchOne(db, key: draft.id)!), docIDs)
        }
        changed([.reviewRequest(task: number)] + docIDs.map { .document($0) } + [.task(number)])
        return review
    }

    public func reviewRequests() throws -> [ReviewRequest] {
        try database.read { db in
            try ReviewRequestRow.order(Column("requestedAt")).fetchAll(db).map {
                ReviewRequest(machine: machineID, taskNumber: $0.taskNumber, note: $0.note, requestedAt: $0.requestedAt)
            }
        }
    }

    /// セッションが「読んでほしい」と立てる。未受領のレビューが残っていれば立てずに `feedbackPending`。
    public func requestReview(task number: Int, note: String, requester: String? = nil) throws -> (ReviewRequestResult, ReviewRequest?) {
        let result = try database.write { db -> (ReviewRequestResult, ReviewRequest?) in
            guard try Self.taskExists(db, number) else { throw StoreError.taskNotFound(number) }
            let pending = try Self.countUndelivered(db, task: number)
            if try Self.countUndeliveredReviews(db, task: number) > 0 {
                return (ReviewRequestResult(status: .feedbackPending, pendingFeedback: pending), nil)
            }
            let row = ReviewRequestRow(taskNumber: number, note: String(note.prefix(500)), requestedAt: Date(), requesterSessionId: requester)
            try row.save(db)
            return (
                ReviewRequestResult(status: .requested, pendingFeedback: pending),
                ReviewRequest(machine: machineID, taskNumber: number, note: row.note, requestedAt: row.requestedAt)
            )
        }
        if result.1 != nil { changed(.reviewRequest(task: number)) }
        return result
    }

    // MARK: フィードバック（セッションへの配送）

    /// 利用者が手作業を済ませた。手作業待ちの項目を作業中に戻し、頼んだ文を未受領の知らせとして残す（`FeedbackService` が会話へ届ける）。
    /// 手作業待ちでなければ（会話が先に動かした・2 回押した）断る。タスクの番号を返す
    public func finishManualWork(id: Int64) throws -> Int {
        let number = try database.write { db -> Int in
            guard let row = try Row.fetchOne(db, sql: "SELECT taskNumber, state, blockerKind, blockerText FROM workItem WHERE id = ?", arguments: [id]) else {
                throw StoreError.workItemNotFound(id)
            }
            guard row["state"] == WorkItem.State.wait.rawValue, row["blockerKind"] == WorkItem.BlockerKind.manual.rawValue else {
                throw StoreError.conflict("作業項目 \(id) は手作業待ちでない")
            }
            let number: Int = row["taskNumber"]
            let request: String = row["blockerText"]
            let now = Date()
            try db.execute(
                sql: """
                    UPDATE workItem SET state = 'doing', blockerKind = NULL, blockerText = '', blockerTone = NULL, updatedAt = ?,
                    finishedRequest = ?, finishedAt = ?, finishDeliveredAt = NULL, finishDeliveryAttempts = 0 WHERE id = ?
                    """,
                arguments: [now, request, now, id])
            try Self.touchTask(db, number: number, at: now)
            return number
        }
        changed(.workItems(task: number), .task(number))
        return number
    }

    /// 未受領の回答・レビュー・済ませた手作業があるタスクの番号（控えから。`ask`・`review`・`workItem` が書かれた後の 1 回だけ DB を読む）
    public func tasksWithUndeliveredFeedback() throws -> Set<Int> {
        try undeliveredFeedbackTasks.numbers {
            try database.read { db in
                Set(
                    try Int.fetchAll(
                        db,
                        sql: """
                            SELECT taskNumber FROM review WHERE state = 'submitted' AND deliveredAt IS NULL
                            UNION SELECT taskNumber FROM ask WHERE status = 'answered' AND deliveredAt IS NULL
                            UNION SELECT taskNumber FROM workItem WHERE finishedAt IS NOT NULL AND finishDeliveredAt IS NULL
                            UNION \(Self.undeliveredDraftSQL)
                            """))
            }
        }
    }

    private static func countUndeliveredReviews(_ db: Database, task number: Int) throws -> Int {
        try ReviewRow.filter(Column("taskNumber") == number && Column("state") == "submitted" && Column("deliveredAt") == nil).fetchCount(db)
    }

    private static func countUndelivered(_ db: Database, task number: Int) throws -> Int {
        // Swift 6.3 は 4 項以上の和を 1 式のままだと型の推論が時間切れになる
        let reviews = try countUndeliveredReviews(db, task: number)
        let asks = try AskRow.filter(Column("taskNumber") == number && Column("status") == "answered" && Column("deliveredAt") == nil).fetchCount(db)
        let finished = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM workItem WHERE taskNumber = ? AND finishedAt IS NOT NULL AND finishDeliveredAt IS NULL", arguments: [number]) ?? 0
        let drafts = try Self.undeliveredDraftRows(db, task: number).count
        return reviews + asks + finished + drafts
    }

    /// 未受領の 1 件（レビュー・回答・済ませた手作業）
    public enum FeedbackItem: Hashable, Sendable {
        case review(Int64)
        case ask(Int64)
        /// 作業項目の id
        case finished(Int64)
        /// 送る文面の承認の id（`panelAnswer`）
        case draft(Int64)
    }

    public struct UndeliveredFeedback: Sendable {
        public var bundle: FeedbackBundle
        /// 頼んだ Claude の会話 ID。頼まれずに送ったレビュー・前の版の記録・済ませた手作業には無い
        var requesters: [FeedbackItem: String] = [:]
        /// host の会話に届けて取り消された回数（届け直すたびに発言の uuid を変える）
        var attempts: [FeedbackItem: Int] = [:]

        var items: [FeedbackItem] {
            bundle.reviews.map { .review($0.review.id) } + bundle.answeredAsks.map { .ask($0.askID) } + bundle.finishedWork.map { .finished($0.itemID) } + bundle.drafts.map { .draft($0.answerID) }
        }
        var askIDs: [Int64] { bundle.answeredAsks.map(\.askID) }

        /// 指定した分を除いた残り
        func excluding(_ excluded: Set<FeedbackItem>) -> UndeliveredFeedback {
            guard !excluded.isEmpty else { return self }
            return only(Set(items).subtracting(excluded))
        }

        /// 指定した分だけ
        func only(_ kept: Set<FeedbackItem>) -> UndeliveredFeedback {
            UndeliveredFeedback(
                bundle: FeedbackBundle(
                    reviews: bundle.reviews.filter { kept.contains(.review($0.review.id)) },
                    answeredAsks: bundle.answeredAsks.filter { kept.contains(.ask($0.askID)) },
                    finishedWork: bundle.finishedWork.filter { kept.contains(.finished($0.itemID)) },
                    drafts: bundle.drafts.filter { kept.contains(.draft($0.answerID)) }),
                requesters: requesters.filter { kept.contains($0.key) }, attempts: attempts.filter { kept.contains($0.key) })
        }
    }

    /// 未受領を返す（受領済みにはしない）。届けきれたときだけ `markFeedbackDelivered`。
    public func peekUndeliveredFeedback(task number: Int) throws -> UndeliveredFeedback {
        try database.read { db in try Self.collectUndelivered(db, task: number, machine: machineID) }
    }

    /// タスクに結ばれたセッションの ID（回答・レビューの届け先の候補）
    public func agentSessionIDs(linkedToTask number: Int) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT sessionId FROM taskSession WHERE taskNumber = ?", arguments: [number])
        }
    }

    /// 受領済みにする。更新した質問を返す（配信用）。
    @discardableResult
    public func markFeedbackDelivered(_ items: [FeedbackItem]) throws -> [Ask] {
        let ids = Self.ids(items)
        let asks = try database.write { db in
            try Self.markDelivered(db, items)
            return try AskRow.filter(ids.asks.contains(Column("id"))).fetchAll(db).map { Self.ask(from: $0, machine: machineID) }
        }
        changed(asks.map { .ask($0.askID) })
        return asks
    }

    /// host の会話に届けて取り消された分の回数を進める（次は別の uuid で届ける）
    public func markFeedbackAttempted(_ items: [FeedbackItem]) throws {
        let ids = Self.ids(items)
        try database.write { db in
            for (table, column, values) in [
                ("review", "deliveryAttempts", ids.reviews), ("ask", "deliveryAttempts", ids.asks), ("workItem", "finishDeliveryAttempts", ids.finished), ("panelAnswer", "deliveryAttempts", ids.drafts),
            ]
            where !values.isEmpty {
                try db.execute(sql: "UPDATE \(table) SET \(column) = \(column) + 1 WHERE id IN (\(values.map(String.init).joined(separator: ",")))")
            }
        }
    }

    /// 未受領を返して受領済みにする（1 回だけ返る）。
    public func takeUndeliveredFeedback(task number: Int) throws -> (FeedbackBundle, [Ask]) {
        let taken = try database.write { db in
            let collected = try Self.collectUndelivered(db, task: number, machine: machineID)
            try Self.markDelivered(db, collected.items)
            let asks = try AskRow.filter(collected.askIDs.contains(Column("id"))).fetchAll(db).map { Self.ask(from: $0, machine: machineID) }
            return (collected.bundle, asks)
        }
        changed(taken.1.map { .ask($0.askID) })
        return taken
    }

    private static func ids(_ items: [FeedbackItem]) -> (reviews: [Int64], asks: [Int64], finished: [Int64], drafts: [Int64]) {
        var result: (reviews: [Int64], asks: [Int64], finished: [Int64], drafts: [Int64]) = ([], [], [], [])
        for item in items {
            switch item {
            case .review(let id): result.reviews.append(id)
            case .ask(let id): result.asks.append(id)
            case .finished(let id): result.finished.append(id)
            case .draft(let id): result.drafts.append(id)
            }
        }
        return result
    }

    private static func markDelivered(_ db: Database, _ items: [FeedbackItem]) throws {
        let now = Date()
        let ids = ids(items)
        for (table, column, values) in [
            ("review", "deliveredAt", ids.reviews), ("ask", "deliveredAt", ids.asks), ("workItem", "finishDeliveredAt", ids.finished), ("panelAnswer", "deliveredAt", ids.drafts),
        ]
        where !values.isEmpty {
            try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE id IN (\(values.map(String.init).joined(separator: ",")))", arguments: [now])
        }
    }

    private static func collectUndelivered(_ db: Database, task number: Int, machine: MachineID) throws -> UndeliveredFeedback {
        let reviewRows = try ReviewRow.filter(Column("taskNumber") == number && Column("state") == "submitted" && Column("deliveredAt") == nil)
            .order(Column("submittedAt"), Column("id")).fetchAll(db)
        var entries: [FeedbackBundle.ReviewEntry] = []
        for row in reviewRows {
            let comments = try fetchComments(db, CommentRow.filter(Column("reviewId") == row.id!))
            let replyRows = try ReplyRow.filter(Column("reviewId") == row.id!).order(Column("createdAt"), Column("id")).fetchAll(db)
            var replies: [FeedbackBundle.ReplyEntry] = []
            for replyRow in replyRows {
                guard let comment = try CommentRow.fetchOne(db, key: replyRow.commentId), let doc = try DocRow.fetchOne(db, key: comment.docId) else { continue }
                replies.append(FeedbackBundle.ReplyEntry(reply: reply(from: replyRow), docName: doc.name, commentBody: comment.body))
            }
            entries.append(FeedbackBundle.ReviewEntry(review: review(from: row), comments: comments, replies: replies))
        }
        let askRows = try AskRow.filter(Column("taskNumber") == number && Column("status") == "answered" && Column("deliveredAt") == nil)
            .order(Column("answeredAt"), Column("id")).fetchAll(db)
        var requesters: [FeedbackItem: String] = [:]
        var attempts: [FeedbackItem: Int] = [:]
        for row in reviewRows {
            requesters[.review(row.id!)] = row.requesterSessionId
            attempts[.review(row.id!)] = row.deliveryAttempts
        }
        for row in askRows {
            requesters[.ask(row.id!)] = row.requesterSessionId
            attempts[.ask(row.id!)] = row.deliveryAttempts
        }
        let finishedRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, title, finishedRequest, finishedAt, finishDeliveryAttempts FROM workItem
                WHERE taskNumber = ? AND finishedAt IS NOT NULL AND finishDeliveredAt IS NULL ORDER BY finishedAt, id
                """,
            arguments: [number])
        var finished: [FeedbackBundle.FinishedWork] = []
        for row in finishedRows {
            let id: Int64 = row["id"]
            finished.append(
                FeedbackBundle.FinishedWork(itemID: id, taskNumber: number, title: row["title"], request: row["finishedRequest"] ?? "", finishedAt: row["finishedAt"]))
            attempts[.finished(id)] = row["finishDeliveryAttempts"]
        }
        var drafts: [PanelDraftFeedback] = []
        for row in try undeliveredDraftRows(db, task: number) {
            drafts.append(draftFeedback(from: row))
            requesters[.draft(row.id!)] = row.requesterSessionId
            attempts[.draft(row.id!)] = row.deliveryAttempts
        }
        return UndeliveredFeedback(
            bundle: FeedbackBundle(
                reviews: entries, answeredAsks: askRows.map { ask(from: $0, machine: machine) }, finishedWork: finished, drafts: drafts),
            requesters: requesters, attempts: attempts)
    }

    // MARK: 行の変換

    /// `TaskRow` は Store.swift の private なので SQL で見る
    private static func taskExists(_ db: Database, _ number: Int) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM task WHERE number = ?)", arguments: [number]) ?? false
    }

    private static func fetchDocuments(_ db: Database, machine: MachineID, task: Int? = nil, ids: [Int64]? = nil) throws -> [Document] {
        var request = DocRow.order(Column("updatedAt").desc, Column("id").desc)
        if let task { request = request.filter(Column("taskNumber") == task) }
        if let ids { request = request.filter(ids.contains(Column("id"))) }
        return try request.fetchAll(db).map { row in
            let id = row.id!
            let latest = try Int.fetchOne(db, sql: "SELECT MAX(rev) FROM docRevision WHERE docId = ?", arguments: [id]) ?? 0
            let open = try CommentRow.filter(Column("docId") == id && Column("state") == "open").fetchCount(db)
            let drafts = try CommentRow.filter(Column("docId") == id && Column("state") == "draft").fetchCount(db)
            return Document(
                machine: machine, docID: id, taskNumber: row.taskNumber, name: row.name, format: DocFormat(rawValue: row.format) ?? .markdown,
                title: row.title, latestRev: latest, hasSourceFile: row.sourcePath != nil, openComments: open, draftComments: drafts,
                drafts: try fetchDocDrafts(db, doc: id), createdAt: row.createdAt, updatedAt: row.updatedAt)
        }
    }

    private static func fetchComments(_ db: Database, _ request: QueryInterfaceRequest<CommentRow>) throws -> [DocComment] {
        let rows = try request.order(Column("createdAt"), Column("id")).fetchAll(db)
        let ids = rows.compactMap(\.id)
        let replies = Dictionary(grouping: try ReplyRow.filter(ids.contains(Column("commentId"))).order(Column("createdAt"), Column("id")).fetchAll(db), by: \.commentId)
        let docs = Dictionary(uniqueKeysWithValues: try DocRow.filter(Set(rows.map(\.docId)).contains(Column("id"))).fetchAll(db).map { ($0.id!, $0.name) })
        return rows.map { row in
            DocComment(
                id: row.id!, docID: row.docId, docName: docs[row.docId] ?? "", rev: row.rev,
                anchor: row.quote.map { CommentAnchor(exact: $0, prefix: row.prefix ?? "", suffix: row.suffix ?? "") }, body: row.body,
                state: DocComment.State(rawValue: row.state) ?? .draft, reviewID: row.reviewId, createdAt: row.createdAt, submittedAt: row.submittedAt,
                resolvedAt: row.resolvedAt, replies: (replies[row.id!] ?? []).map(reply(from:)))
        }
    }

    private static func ask(from row: AskRow, machine: MachineID) -> Ask {
        Ask(
            machine: machine, askID: row.id!, taskNumber: row.taskNumber, docID: row.docId, status: Ask.Status(rawValue: row.status) ?? .cancelled,
            questions: decodeJSON([AskQuestion].self, row.questions) ?? [], answers: row.answers.flatMap { decodeJSON([AskAnswer].self, $0) },
            createdAt: row.createdAt, answeredAt: row.answeredAt, deliveredAt: row.deliveredAt, inBody: row.inBody)
    }

    private static func review(from row: ReviewRow) -> Review {
        Review(
            id: row.id!, taskNumber: row.taskNumber, summary: row.summary, state: Review.State(rawValue: row.state) ?? .draft, createdAt: row.createdAt,
            submittedAt: row.submittedAt, deliveredAt: row.deliveredAt)
    }

    private static func reply(from row: ReplyRow) -> CommentReply {
        CommentReply(
            id: row.id!, commentID: row.commentId, author: CommentReply.Author(rawValue: row.author) ?? .human, body: row.body,
            state: CommentReply.State(rawValue: row.state) ?? .submitted, createdAt: row.createdAt)
    }

    /// 質問・回答の JSON。キー順を固定して「同じ質問での再 publish」を文字列一致で判定できるようにする
    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

// MARK: - 行

private struct DocRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "doc"
    var id: Int64?
    var taskNumber: Int
    var name: String
    var format: String
    var title: String?
    var sourcePath: String?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct RevisionRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "docRevision"
    var id: Int64?
    var docId: Int64
    var rev: Int
    var content: String
    var externalHosts: String
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct AskRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "ask"
    var id: Int64?
    var taskNumber: Int
    var docId: Int64
    var status: String
    var questions: String
    var answers: String?
    var createdAt: Date
    var answeredAt: Date?
    var deliveredAt: Date?
    var requesterSessionId: String?
    var deliveryAttempts = 0
    var workItemId: Int64?
    var inBody = false

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct ReviewRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "review"
    var id: Int64?
    var taskNumber: Int
    var summary: String
    var state: String
    var createdAt: Date
    var submittedAt: Date?
    var deliveredAt: Date?
    var requesterSessionId: String?
    var deliveryAttempts = 0

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct CommentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "docComment"
    var id: Int64?
    var docId: Int64
    var rev: Int
    var quote: String?
    var prefix: String?
    var suffix: String?
    var body: String
    var state: String
    var reviewId: Int64?
    var createdAt: Date
    var submittedAt: Date?
    var resolvedAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct ReplyRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "commentReply"
    var id: Int64?
    var commentId: Int64
    var author: String
    var body: String
    var state: String
    var reviewId: Int64?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct ReviewRequestRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reviewRequest"
    var taskNumber: Int
    var note: String
    var requestedAt: Date
    var requesterSessionId: String?
}
