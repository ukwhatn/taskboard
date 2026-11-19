import Foundation
import GRDB
import TaskboardKit

/// agent host で動かす Claude の会話の記録（`conversation` 表と `conversationSession` 表）。プロセスの今の状態（生成中・答えを待っている問い）は持たず、
/// daemon の入れ替えを越えて要るもの（タスクとの紐づけ、Claude の会話 ID、何が動かしているか、defer で終えた問い）だけを置く
extension Store {
    static let conversationMigration = "v16 conversations"

    static func registerConversationMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(conversationMigration) { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                t.column("taskNumber", .integer).references("task", onDelete: .setNull)
                t.column("engine", .text).notNull()
                t.column("agentSessionId", .text).notNull()
                t.column("cwd", .text).notNull()
                t.column("model", .text)
                t.column("effort", .text)
                t.column("permissionMode", .text)
                t.column("title", .text)
                t.column("runner", .text).notNull()
                t.column("deferred", .text)
                t.column("recentMessageIds", .text).notNull().defaults(to: "[]")
                t.column("lastExit", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "conversation_task", on: "conversation", columns: ["taskNumber"])
            // 会話がこれまでに持った Claude の会話 ID（`/clear` の前のものを含む）。1 つの ID を 2 つの会話が持てない
            try db.create(table: "conversationSession") { t in
                t.primaryKey("sessionId", .text)
                t.column("conversationId", .text).notNull().references("conversation", onDelete: .cascade)
                t.column("linkedAt", .datetime).notNull()
            }
            try db.create(index: "conversationSession_conversation", on: "conversationSession", columns: ["conversationId"])
            // 回答・レビューを頼んだ Claude の会話 ID（そこに届ける）と、host の会話に届けて取り消された回数（届け直す発言の uuid を変える）
            for table in ["ask", "review"] {
                try db.alter(table: table) { t in
                    t.add(column: "requesterSessionId", .text)
                    t.add(column: "deliveryAttempts", .integer).notNull().defaults(to: 0)
                }
            }
            try db.alter(table: "reviewRequest") { t in t.add(column: "requesterSessionId", .text) }
        }
        // daemon が host の控えを捨てた所。裏のタスクの数が分かっている（0）ときだけ捨てるので、引き取ったときの控えの欠けがここまでなら数え直せる
        migrator.registerMigration("v17 conversation trims") { db in
            try db.alter(table: "conversation") { t in t.add(column: "trimmedThrough", .integer).notNull().defaults(to: 0) }
        }
        // フォーク・巻き戻し・端末で開く・会話のシェル（E3）
        migrator.registerMigration("v18 conversation forks and terminals") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "forkSourceId", .text)
                t.add(column: "forkRequestId", .text)
                t.add(column: "pendingForkSessionId", .text)
                t.add(column: "pendingForkAt", .text)
                t.add(column: "previousSessionId", .text)
                t.add(column: "rewindFilesPending", .boolean).notNull().defaults(to: false)
                t.add(column: "terminalPaneId", .text)
                t.add(column: "terminalRequestId", .text)
                t.add(column: "shellPaneId", .text)
            }
            // 応答を受け取れずに送り直したフォークで、2 つ作らない
            try db.create(index: "conversation_forkRequest", on: "conversation", columns: ["forkRequestId"], unique: true)
        }
        // CLI に渡す引数・役目・起こした側への知らせ・利用枠の上限の待ち（E4）。定期起動の回に、その回の会話
        migrator.registerMigration("v19 conversation purposes and parents") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "extraArgs", .text).notNull().defaults(to: "[]")
                t.add(column: "purpose", .text)
                t.add(column: "parentConversationId", .text)
                t.add(column: "parentPane", .text)
                t.add(column: "parentAgentSessionId", .text)
                t.add(column: "notifyParent", .boolean).notNull().defaults(to: false)
                t.add(column: "parentNoticeTurns", .integer).notNull().defaults(to: 0)
                t.add(column: "parentNoticeAt", .datetime)
                t.add(column: "parentNoticeSeq", .integer).notNull().defaults(to: 0)
                t.add(column: "limitResumeAt", .datetime)
            }
            try db.alter(table: "scheduleRun") { t in t.add(column: "conversationId", .text) }
        }
    }

    /// 会話の値（費用・トークン・解決したモデル・版・コンテキスト）。リンクの知らせ（v21）の後に入れたので、登録もその後
    static func registerConversationStatsMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v22 conversation stats") { db in
            try db.alter(table: "conversation") { t in t.add(column: "stats", .text) }
        }
    }

    /// フォーク・巻き戻しで作った Claude の会話 ID の写し元（`TranscriptSource`）
    static func registerConversationSourceMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v27 conversation session sources") { db in
            try db.alter(table: "conversationSession") { t in
                t.add(column: "forkSourceSessionId", .text)
                t.add(column: "forkSourceEnd", .integer)
            }
        }
    }

    /// 利用枠の待ちが、上限の前に taskboard が区切ったものか（戻ったときに続きを送らない）
    static func registerUsagePauseMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v28 conversation usage pauses") { db in
            try db.alter(table: "conversation") { t in t.add(column: "limitPaused", .boolean).notNull().defaults(to: false) }
        }
    }

    /// 人が付けた会話の名前。自動の題（`title`。hook・タスクの題・engine が付ける）とは別に持ち、あればこちらを出す
    static func registerCustomTitleMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v29 conversation custom titles") { db in
            try db.alter(table: "conversation") { t in t.add(column: "customTitle", .text) }
        }
    }

    /// ネットワークに繋がらずに止まった会話の、接続が戻った後の続き
    static func registerNetworkResumeMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v30 conversation network resumes") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "networkResumeAt", .datetime)
                t.add(column: "networkResumeTries", .integer).notNull().defaults(to: 0)
            }
        }
    }

    /// 元に戻した巻き戻しの、巻き戻した先（やり直す）と、フォークの地点（発言の行に出すフォークの数）
    static func registerRewindRedoMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v32 conversation rewind redo and fork points") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "redoSessionId", .text)
                t.add(column: "redoForkSessionId", .text)
                t.add(column: "redoForkAt", .text)
                t.add(column: "forkAt", .text)
            }
        }
    }

    /// 最後の応答の頭とターンの時刻（見張り盤の札）。止まった会話と、daemon の入れ替えの後にも出すため記録に置く
    static func registerReplyMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v38 conversation replies") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "lastReply", .text)
                t.add(column: "lastReplyAt", .datetime)
                t.add(column: "turnStartedAt", .datetime)
            }
        }
    }

    static func registerShellMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v35 conversations without panes") { db in
            try db.alter(table: "conversation") { t in
                t.drop(column: "terminalPaneId")
                t.drop(column: "terminalRequestId")
                t.drop(column: "parentPane")
                t.drop(column: "parentAgentSessionId")
                t.rename(column: "shellPaneId", to: "shellId")
            }
        }
    }

    /// 記録を作り、タスクがあれば Claude の会話 ID をそのタスクに結ぶ（SessionStart の hook を待たない。cwd 一致に回さないため）
    public func createConversation(_ record: ConversationRecord) throws -> ConversationRecord {
        let (created, tasks, schedules) = try database.write { db -> (ConversationRecord, [Int], [Int64]) in
            if let number = record.taskNumber {
                guard try TaskRow.exists(db, key: number) else { throw StoreError.taskNotFound(number) }
            }
            try Self.refuseOwnedSession(db, record.agentSessionId)
            var record = record
            try record.insert(db)
            try ConversationSessionRow(sessionId: record.agentSessionId, conversationId: record.id, linkedAt: record.createdAt).insert(db)
            let tasks = try Self.bind(db, &record, task: record.taskNumber, at: record.createdAt)
            return (record, tasks, try Self.scheduleIDs(db, runColumn: "conversationId", value: record.id))
        }
        changed(tasks.map { .task($0) } + schedules.map { .schedule($0) })
        return created
    }

    public func conversation(id: String) throws -> ConversationRecord? {
        try database.read { db in try ConversationRecord.fetchOne(db, key: id) }
    }

    /// その Claude の会話 ID を持つ会話（今の ID か、`/clear` の前の ID）
    public func conversation(agentSessionID: String) throws -> ConversationRecord? {
        try database.read { db in
            guard let row = try ConversationSessionRow.fetchOne(db, key: agentSessionID) else { return nil }
            return try ConversationRecord.fetchOne(db, key: row.conversationId)
        }
    }

    /// そのフォークの要求で作った会話（送り直しで 2 つ作らない）
    public func conversation(forkRequestID: String) throws -> ConversationRecord? {
        try database.read { db in try ConversationRecord.filter(Column("forkRequestId") == forkRequestID).fetchOne(db) }
    }

    public func conversations() throws -> [ConversationRecord] {
        try database.read { db in try ConversationRecord.order(Column("createdAt").desc).fetchAll(db) }
    }

    /// その Claude の会話 ID の transcript の頭より前を持つ写し元。記録が無ければ nil
    public func transcriptSource(of agentSessionID: String) throws -> TranscriptSource? {
        try database.read { db in
            guard let row = try ConversationSessionRow.fetchOne(db, key: agentSessionID), let session = row.forkSourceSessionId, let end = row.forkSourceEnd
            else { return nil }
            return TranscriptSource(session: session, end: end)
        }
    }

    /// 写し元を書く。会話に結んでいない会話 ID なら何もしない
    public func setTranscriptSource(of agentSessionID: String, _ source: TranscriptSource) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE conversationSession SET forkSourceSessionId = ?, forkSourceEnd = ? WHERE sessionId = ?",
                arguments: [source.session, source.end, agentSessionID])
        }
    }

    /// その会話がこれまでに持った Claude の会話 ID か。MCP が env の会話 ID を使ってよいかの判定に使う
    /// （Bash から起こした別の claude にも env が継がれ、その claude の会話 ID はここに無い）
    public func conversation(_ id: String, owns agentSessionID: String) throws -> Bool {
        try database.read { db in try ConversationSessionRow.fetchOne(db, key: agentSessionID)?.conversationId == id }
    }

    /// Claude の会話 ID が変わった（`/clear`）。今の ID を替え、新しい ID もタスクに結ぶ
    public func updateConversationSession(id: String, agentSessionID: String, at: Date = Date()) throws -> ConversationRecord {
        let (record, tasks) = try database.write { db -> (ConversationRecord, [Int]) in
            guard var record = try ConversationRecord.fetchOne(db, key: id) else { throw Self.conversationNotFound(id) }
            guard record.agentSessionId != agentSessionID else { return (record, []) }
            if try ConversationSessionRow.fetchOne(db, key: agentSessionID)?.conversationId != id {
                try Self.refuseOwnedSession(db, agentSessionID)
                try ConversationSessionRow(sessionId: agentSessionID, conversationId: id, linkedAt: at).insert(db)
            }
            record.agentSessionId = agentSessionID
            let tasks = try Self.bind(db, &record, task: record.taskNumber, at: at)
            return (record, tasks)
        }
        changed(tasks.map { .task($0) })
        return record
    }

    /// 巻き戻し・元に戻す：Claude の会話 ID を替え（`updateConversationSession` と同じく新しい ID もタスクに結ぶ）、ほかの列も同じ transaction で書く。
    /// `discarding` の ID は、会話とタスクの結びから外す（巻き戻しを取りやめたとき、transcript を作らなかった ID）
    public func switchConversationSession(
        id: String, agentSessionID: String, discarding: String? = nil, at: Date = Date(), _ change: (inout ConversationRecord) -> Void
    ) throws -> ConversationRecord {
        let (record, tasks) = try database.write { db -> (ConversationRecord, [Int]) in
            guard var record = try ConversationRecord.fetchOne(db, key: id) else { throw Self.conversationNotFound(id) }
            if try ConversationSessionRow.fetchOne(db, key: agentSessionID)?.conversationId != id {
                try Self.refuseOwnedSession(db, agentSessionID)
                try ConversationSessionRow(sessionId: agentSessionID, conversationId: id, linkedAt: at).insert(db)
            }
            if let discarding, discarding != agentSessionID {
                try db.execute(sql: "DELETE FROM conversationSession WHERE sessionId = ? AND conversationId = ?", arguments: [discarding, id])
                try db.execute(sql: "DELETE FROM taskSession WHERE sessionId = ?", arguments: [discarding])
            }
            record.agentSessionId = agentSessionID
            change(&record)
            let tasks = try Self.bind(db, &record, task: record.taskNumber, at: at)
            return (record, tasks)
        }
        changed(tasks.map { .task($0) })
        return record
    }

    /// 会話をタスクに結ぶ。会話が持った Claude の会話 ID の全部について、`task` 以外のタスクの `taskSession` の行を消してから、`task` に結ぶ。
    /// 前の行を 1 つでも残すと、移した先を消したときに `task(linkedToSession:)` がその行のタスクを返す（TUI で A・B の順に結んだ会話は A の行も持つ）
    /// 返すのは、紐づけの行を外したタスクと結んだタスク（DaemonState に載せ直す）
    @discardableResult
    static func bind(_ db: Database, _ record: inout ConversationRecord, task number: Int?, at: Date) throws -> [Int] {
        let sessions = try sessionIDs(db, conversation: record.id)
        let marks = databaseQuestionMarks(count: sessions.count)
        let others = try Int.fetchAll(
            db, sql: "SELECT DISTINCT taskNumber FROM taskSession WHERE sessionId IN (\(marks)) AND taskNumber IS NOT ?",
            arguments: StatementArguments(sessions + [number]))
        if !others.isEmpty {
            try db.execute(
                sql: "DELETE FROM taskSession WHERE sessionId IN (\(marks)) AND taskNumber IS NOT ?", arguments: StatementArguments(sessions + [number]))
            for other in others { try touchTask(db, number: other, at: at) }
        }
        record.taskNumber = number
        record.updatedAt = at
        try record.update(db)
        guard let number else { return others }
        for session in sessions {
            try linkConversationSession(db, task: number, sessionID: session, cwd: record.cwd, at: at)
        }
        return others + [number]
    }

    /// その Claude の会話 ID を持つ会話（`linkSession` が会話の ID を結ぶときに `bind` へ回す）
    static func conversationOwning(_ db: Database, sessionID: String) throws -> ConversationRecord? {
        guard let row = try ConversationSessionRow.fetchOne(db, key: sessionID) else { return nil }
        return try ConversationRecord.fetchOne(db, key: row.conversationId)
    }

    /// 書いて読み直したときと同じ時刻（DB はミリ秒までの文字列で持つ）。actor の記録と読み直した記録を == で比べる列には、これを入れる
    static func storedDate(_ date: Date) -> Date { Date.fromDatabaseValue(date.databaseValue) ?? date }

    /// 何が動かしているか・defer の問い・終わった理由・題・モデルなど、紐づけ以外の列を書き換える。タスクと Claude の会話 ID は `taskSession` も
    /// 一緒に直す `linkSession`・`unlinkSession`・`updateConversationSession`・`switchConversationSession` で変え、`change` が書いても戻す
    public func updateConversation(id: String, at: Date = Date(), _ change: (inout ConversationRecord) -> Void) throws -> ConversationRecord {
        try database.write { db in
            guard var record = try ConversationRecord.fetchOne(db, key: id) else { throw Self.conversationNotFound(id) }
            let (task, session) = (record.taskNumber, record.agentSessionId)
            change(&record)
            (record.taskNumber, record.agentSessionId) = (task, session)
            record.updatedAt = at
            try record.update(db)
            return record
        }
    }

    /// 会話の値だけを書く。ターンのたびに書くので `updatedAt` は進めない（最近の並びを動かさない）
    public func updateConversationStats(id: String, _ stats: ConversationStats?) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE conversation SET stats = ? WHERE id = ?", arguments: [ConversationRecord.encode(stats: stats), id])
        }
    }

    /// ターンの始まりと最後の応答を書く。ターンのたびに書くので `updatedAt` は進めない（`updateConversationStats` と同じ）
    public func updateConversationTurn(id: String, turnStartedAt: Date?, lastReply: String?, lastReplyAt: Date?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE conversation SET turnStartedAt = ?, lastReply = ?, lastReplyAt = ? WHERE id = ?",
                arguments: [turnStartedAt, lastReply, lastReplyAt, id])
        }
    }

    /// 起こした側を替える：`fromConversation` の子を `to` の会話の子にする。替えた子の id
    public func reparentConversations(fromConversation: String, to target: String, at: Date = Date()) throws -> [String] {
        try database.write { db in
            var moved: [String] = []
            for var record in try ConversationRecord.filter(Column("parentConversationId") == fromConversation).fetchAll(db) where record.id != target {
                record.parentConversationId = target
                record.updatedAt = at
                try record.update(db)
                moved.append(record.id)
            }
            return moved
        }
    }

    /// 会話の記録を消す（`conversationSession` は cascade で消える）。タスクとの結び（`taskSession`）と、回答を頼んだ会話の記録は残す
    public func deleteConversation(id: String) throws {
        let schedules = try database.write { db in
            guard try ConversationRecord.deleteOne(db, key: id) else { throw Self.conversationNotFound(id) }
            return try Self.scheduleIDs(db, runColumn: "conversationId", value: id)
        }
        changed(schedules.map { .schedule($0) })
    }

    private static func sessionIDs(_ db: Database, conversation id: String) throws -> [String] {
        try ConversationSessionRow.filter(Column("conversationId") == id).order(Column("linkedAt")).fetchAll(db).map(\.sessionId)
    }

    private static func refuseOwnedSession(_ db: Database, _ sessionID: String) throws {
        if let owner = try ConversationSessionRow.fetchOne(db, key: sessionID) {
            throw StoreError.refused(.invalidRequest, ["conversation": owner.conversationId], "Claude の会話 \(sessionID) は会話 \(owner.conversationId) のもの")
        }
    }

    private static func linkConversationSession(_ db: Database, task number: Int, sessionID: String, cwd: String, at: Date) throws {
        try db.execute(
            sql: """
                INSERT INTO taskSession (taskNumber, agent, sessionId, cwd, label, linkedAt, launchArgs) VALUES (?, 'claude', ?, ?, '', ?, '[]')
                ON CONFLICT (taskNumber, sessionId) DO NOTHING
                """,
            arguments: [number, sessionID, cwd, at])
        if db.changesCount > 0 { try touchTask(db, number: number, at: at) }
    }

    static func conversationNotFound(_ id: String) -> StoreError {
        .refused(.notFound, ["kind": DaemonErrorCode.Kind.conversation.rawValue], "会話 \(id) が無い")
    }

    /// backup の検証：会話の migration を通った DB なら、会話の表もあること
    static func verifyConversationTables(_ db: Database) throws -> Int? {
        guard try db.tableExists("grdb_migrations"),
            try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM grdb_migrations WHERE identifier = ?", arguments: [conversationMigration]) == true
        else { return nil }
        for table in ["conversation", "conversationSession"] where try !db.tableExists(table) {
            throw StoreError.missingTable(table)
        }
        return try ConversationRecord.fetchCount(db)
    }
}

/// `conversation` 表の 1 行
public struct ConversationRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversation"

    public var id: String
    public var taskNumber: Int?
    public var engine: String
    /// 今の Claude の会話 ID（前の ID も含めた全部は `conversationSession`）
    public var agentSessionId: String
    public var cwd: String
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    /// 自動の題（hook・タスクの題・engine が付ける）。人が付けた名前は `customTitle`
    public var title: String?
    public var customTitle: String?
    public var runner: String
    /// defer で終えた問い（`ConversationRequest` の JSON）
    public var deferred: String?
    /// CLI が受けた発言の uuid（新しい順に `recentMessageLimit` 件の JSON）。host の控えはターンの終わりに捨てるので、同じ発言を 2 回入れないためにここにも持つ
    public var recentMessageIds: String
    public var lastExit: String?
    /// daemon が host の控えを捨てた所（裏のタスクが無いと分かっているときだけ捨てる）。host が起き直したら意味が無い（子も控えも無くなる）
    public var trimmedThrough: Int = 0
    /// フォーク元の会話の id（表示だけ）
    public var forkSourceId: String?
    /// フォークした地点（`Conversation.forkAt`）。`pendingForkAt` と違い、写した後も残す
    public var forkAt: String?
    /// フォークを頼んだ要求の id（UNIQUE）
    public var forkRequestId: String?
    /// フォーク・巻き戻しの後、まだ transcript が無い間：写す元の Claude の会話 ID と、写す最後の行の uuid（無ければ先頭から新しく始める）
    public var pendingForkSessionId: String?
    public var pendingForkAt: String?
    /// 巻き戻す前の Claude の会話 ID（元に戻す）
    public var previousSessionId: String?
    /// 元に戻した巻き戻しの先の Claude の会話 ID と、そのときの `pendingForkSessionId`・`pendingForkAt`（やり直す）。次に送るまで持つ
    public var redoSessionId: String?
    public var redoForkSessionId: String?
    public var redoForkAt: String?
    /// 巻き戻しでファイルを戻したかが分からない（戻す前に記録を替えたまま、結果を受けていない）
    public var rewindFilesPending: Bool = false
    /// 会話の作業フォルダのシェル（`ConversationShells.key`）
    public var shellId: String?
    /// CLI にそのまま渡す引数（`ConversationArguments.acceptsExtra` を通ったものの JSON）
    public var extraArgs: String = "[]"
    /// `Conversation.Purpose` の rawValue。人や agent が起こした会話は nil
    public var purpose: String?
    /// 起こした側の会話の id
    public var parentConversationId: String?
    public var notifyParent: Bool = false
    /// 起こした側にまだ知らせていないターンの数・最後に知らせを残した時刻（nil なら残っていない）・数えた最後の `result` の行の seq
    public var parentNoticeTurns: Int = 0
    public var parentNoticeAt: Date?
    public var parentNoticeSeq: Int = 0
    /// 利用枠の上限で止まった会話に続きを送る時刻
    public var limitResumeAt: Date?
    /// `limitResumeAt` の待ちは上限の前に区切ったもの（続きを送らずに待ちを解く）
    public var limitPaused: Bool = false
    /// ネットワークに繋がらずに止まった会話に、接続があれば続きを送る時刻（印。`NetworkResumeRule`）
    public var networkResumeAt: Date?
    /// 印を付けてから送った続きの数。誤りでないターンの終わりと、人・agent の発言で 0 に戻す
    public var networkResumeTries: Int = 0
    /// engine の会話の値（`ConversationStats` の JSON。止まった会話でも出すため）。読めなければ値なし
    public var stats: String?
    /// 最後の応答の頭（`ConversationReply.limit` 字まで）と、そのターンが終わった時刻
    public var lastReply: String?
    public var lastReplyAt: Date?
    /// 最後に始まったターンの時刻
    public var turnStartedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(), taskNumber: Int?, engine: Conversation.Engine = .claude, agentSessionId: String, cwd: String,
        model: String? = nil, effort: String? = nil, permissionMode: String? = nil, title: String? = nil, customTitle: String? = nil,
        runner: Conversation.Runner,
        deferred: String? = nil, lastExit: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.taskNumber = taskNumber
        self.engine = engine.rawValue
        self.agentSessionId = agentSessionId
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.title = title
        self.customTitle = customTitle
        self.runner = runner.rawValue
        self.deferred = deferred
        self.recentMessageIds = "[]"
        self.lastExit = lastExit
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var runnerValue: Conversation.Runner { Conversation.Runner(rawValue: runner) ?? .none }

    public mutating func clearRedo() {
        redoSessionId = nil
        redoForkSessionId = nil
        redoForkAt = nil
    }

    /// 会話の題として出すもの。人が付けた名前があればそちら
    public var displayTitle: String? { customTitle ?? title }

    /// engine が知らせた題を自動の題にする。今の自動の題と同じものと、人の名前を engine に送り返したもの（同じ名前）は取らない。取ったら true
    public mutating func takeReportedTitle(_ reported: String) -> Bool {
        guard reported != title, reported != customTitle else { return false }
        title = reported
        return true
    }

    public var purposeValue: Conversation.Purpose? { purpose.flatMap(Conversation.Purpose.init(rawValue:)) }
    /// この版が知らない engine（新しい版の daemon が書いた記録）は `.unknown`
    public var engineValue: Conversation.Engine { Conversation.Engine(rawValue: engine) ?? .unknown }

    public var stopCause: ConversationStopCause? { lastExit.map(ConversationStopCause.init(lastExit:)) }

    /// 日時は秒の端数まで残す（wire の JSON は秒で丸める）
    public var statsValue: ConversationStats? {
        stats.flatMap { try? JSONDecoder().decode(ConversationStats.self, from: Data($0.utf8)) }
    }

    /// defer で終えた問い（読めなければ無いものとして扱う）
    var deferredQuestion: DeferredQuestion? {
        deferred.flatMap { try? JSONDecoder().decode(DeferredQuestion.self, from: Data($0.utf8)) }
    }

    static func encode(stats: ConversationStats?) -> String? {
        stats.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    public var extraArguments: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(extraArgs.utf8))) ?? [] }
        set { extraArgs = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self) }
    }

    public static let recentMessageLimit = 256

    public var recentMessages: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentMessageIds.utf8))) ?? []
    }

    public mutating func forget(message uuid: String) {
        let list = recentMessages.filter { $0 != uuid }
        recentMessageIds = String(decoding: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// 受けた発言の uuid を先頭に足す（あれば何もしない）
    public mutating func remember(message uuid: String) {
        var list = recentMessages
        guard !list.contains(uuid) else { return }
        list.insert(uuid, at: 0)
        recentMessageIds = String(decoding: (try? JSONEncoder().encode(Array(list.prefix(Self.recentMessageLimit)))) ?? Data("[]".utf8), as: UTF8.self)
    }
}

struct ConversationSessionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversationSession"

    var sessionId: String
    var conversationId: String
    var linkedAt: Date
    var forkSourceSessionId: String?
    var forkSourceEnd: UInt64?
}
