import Foundation
import GRDB
import Logging
import TaskboardKit

/// daemon の SQLite。ボード・列・タスク・リンク・セッション紐づけ。
///
/// 開くときに未適用の migration があれば、先に `backups/taskboard.<時刻>.db` へ GRDB の backup を取る（3 世代）。
public final class Store: Sendable {
    public let machineID: MachineID
    public let databaseURL: URL
    public let backupDirectory: URL
    /// ファイルは `DatabasePool`（WAL。読みは並べて走り、書きを待たない）、`init(inMemory:)` は `DatabaseQueue`（DatabasePool はメモリ上を開けない）
    let database: any DatabaseWriter
    let undeliveredFeedbackTasks = UndeliveredFeedbackTasks()
    /// 書き込みが触ったもの。`StatePublisher` が受けて DaemonState に入れる（`changed`）
    let changeLog = StoreChangeLog()
    private let publisherLock = NSLock()
    nonisolated(unsafe) private var publisher: StatePublisher?
    private let logger = Logger(label: "uk.whatn.taskboardd.store")

    public static let backupGenerations = 3

    public init(databaseURL: URL, backupDirectory: URL, machineID: MachineID) throws {
        self.machineID = machineID
        self.databaseURL = databaseURL
        self.backupDirectory = backupDirectory
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        database = pool
        let migrator = Self.migrator()
        let hasUnapplied = try database.read { db in try migrator.hasCompletedMigrations(db) == false }
        let isNew = try database.read { db in try db.tableExists("board") == false }
        if hasUnapplied, !isNew {
            let url = try backup(label: "pre-migration")
            logger.info("backup before migration", metadata: ["file": .string(url.lastPathComponent)])
        }
        try migrator.migrate(database)
        // migration の前の読みで開いた接続は、列を足した表を Codable で decode すると足した列を見失う（v6 の DB で再現）
        pool.invalidateReadOnlyConnections()
        database.add(transactionObserver: undeliveredFeedbackTasks)
    }

    /// テスト用（メモリ上）。
    init(inMemory machineID: MachineID) throws {
        self.machineID = machineID
        databaseURL = URL(fileURLWithPath: ":memory:")
        backupDirectory = FileManager.default.temporaryDirectory
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        database = try DatabaseQueue(configuration: configuration)
        try Self.migrator().migrate(database)
        database.add(transactionObserver: undeliveredFeedbackTasks)
    }

    /// 書き込みの後（commit の後）に、触ったものを流す
    func changed(_ changes: StoreChange...) { changeLog.record(changes) }
    func changed(_ changes: [StoreChange]) { changeLog.record(changes) }

    /// この Store の変更を `state` に入れる受け手。初めて呼んだときに作って動かし、次からは同じものを返す（受け手が 2 つあると変更を取り合う）
    func statePublisher(state: DaemonState) -> StatePublisher {
        publisherLock.withLock {
            if let publisher { return publisher }
            let created = StatePublisher(store: self, state: state)
            publisher = created
            return created
        }
    }

    /// DB の migration。GRDB はまだ回していないものを登録した順に回し、回したものを識別子で DB に記録する。
    /// 回る順は版の番号の順ではない（下の並びのとおり）。並べ替えると、新しい DB と途中の版の DB で回る順が変わるので、足すのは末尾だけ（`MigrationOrderTests`）
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerCoreMigrations(&migrator)  // v1〜v3
        registerDocumentMigrations(&migrator)  // v4（Store+Documents）
        registerPullRequestMigrations(&migrator)  // v5（Store+PullRequests）
        registerScheduleMigrations(&migrator)  // v6（Store+Schedules）
        registerScheduleRunFailureMigration(&migrator)  // v11（Store+Schedules）
        registerBoardSettingsMigrations(&migrator)  // v7（Store+Boards）
        registerBoardMergeTargetMigration(&migrator)  // v12（Store+Boards）
        registerSettingsMigrations(&migrator)  // v8（Store+Settings）
        registerDeviceMigrations(&migrator)  // v9（Store+Devices）
        registerDevicePushMigration(&migrator)  // v13（Store+Devices）
        registerBookmarkMigrations(&migrator)  // v10（Store+Bookmarks）
        registerColumnGuideMigrations(&migrator)  // v14（Store+Boards）
        registerInboxMigrations(&migrator)  // v15（Store+Inbox）
        registerConversationMigrations(&migrator)  // v16〜v19（Store+Conversations）
        registerLookupIndexMigration(&migrator)  // v20
        registerLinkNoticeMigrations(&migrator)  // v21（Store+LinkNotices）
        registerConversationStatsMigrations(&migrator)  // v22（Store+Conversations）
        registerBrowserMigrations(&migrator)  // v23（Store+Browser）
        registerWakeMigrations(&migrator)  // v24（Store+Wakes）
        registerWatchMigrations(&migrator)  // v25・v26（Store+Watches）
        registerConversationSourceMigrations(&migrator)  // v27（Store+Conversations）
        registerUsagePauseMigrations(&migrator)  // v28（Store+Conversations）
        registerCustomTitleMigrations(&migrator)  // v29（Store+Conversations）
        registerNetworkResumeMigrations(&migrator)  // v30（Store+Conversations）
        registerUsageMigrations(&migrator)  // v31（Store+Usage）
        registerRewindRedoMigrations(&migrator)  // v32（Store+Conversations）
        registerConversationSearchMigrations(&migrator)  // v33（Store+ConversationSearch）
        registerScheduleRunLaunchMigration(&migrator)  // v34（Store+Schedules）
        registerShellMigrations(&migrator)  // v35（Store+Conversations）
        registerCommandWatchMigration(&migrator)  // v36（Store+CommandWatches）
        registerSlackMigration(&migrator)  // v37（Store+Slack）
        registerReplyMigrations(&migrator)  // v38（Store+Conversations）
        registerAskWorkItemMigration(&migrator)  // v39（Store+Documents）
        registerTurnRequestMigration(&migrator)  // v40・v41（Store+TurnRequests）
        registerFinishedWorkMigration(&migrator)  // v42（Store+Documents）
        registerDelegationMigration(&migrator)  // v43（Store+Delegation）
        registerWorkGroupMigration(&migrator)  // v44（Store+Panels）
        registerPanelMigration(&migrator)  // v45（Store+Panels）
        registerBriefingMigration(&migrator)  // v46（Store+Briefings。表だけ残す）
        registerLinkStatusCacheMigration(&migrator)  // v47（Store+LinkStatusCache）
        registerDocDraftMigration(&migrator)  // v48（Store+DocDrafts）
        registerDocExternalHostsMigration(&migrator)  // v49（Store+Documents）
        registerUsageAccountSampleMigration(&migrator)  // v50（Store+Usage）
        registerDocChangesMigration(&migrator)  // v51（Store+Documents）
        registerClientPrefsMigration(&migrator)  // v52（Store+ClientPrefs）
        registerTaskStatusMigration(&migrator)  // v53（Store+TaskStatus）
        return migrator
    }

    /// ボードとタスク、作業項目、起動
    private static func registerCoreMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1 boards and tasks") { db in
            try db.create(table: "board") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "boardColumn") { t in
                t.column("boardId", .text).notNull().references("board", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("label", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("position", .integer).notNull()
                t.primaryKey(["boardId", "id"])
            }
            try db.create(table: "task") { t in
                t.autoIncrementedPrimaryKey("number")
                t.column("boardId", .text).notNull().references("board", onDelete: .cascade)
                t.column("columnId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("due", .text)
                t.column("importedId", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["boardId", "importedId"])
            }
            try db.create(table: "taskLink") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "taskSession") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("agent", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("cwd", .text).notNull().defaults(to: "")
                t.column("label", .text).notNull().defaults(to: "")
                t.column("linkedAt", .datetime).notNull()
                t.uniqueKey(["taskNumber", "sessionId"])
            }
        }
        migrator.registerMigration("v2 work items") { db in
            try db.create(table: "workItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskNumber", .integer).notNull().references("task", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("state", .text).notNull()
                t.column("blockerKind", .text)
                t.column("blockerText", .text).notNull().defaults(to: "")
                t.column("blockerTone", .text)
                t.column("dependsOn", .text).notNull().defaults(to: "[]")
                t.column("deliverableKind", .text)
                t.column("deliverableRef", .text).notNull().defaults(to: "")
                t.column("owner", .text).notNull().defaults(to: "")
                t.column("position", .integer).notNull()
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "workItem_task", on: "workItem", columns: ["taskNumber", "position"])
        }
        migrator.registerMigration("v3 launches and prompt templates") { db in
            try db.alter(table: "board") { t in
                t.add(column: "promptTemplate", .text).notNull().defaults(to: "")
            }
            try db.alter(table: "boardColumn") { t in
                t.add(column: "promptTemplate", .text)
            }
            try db.create(table: "launch") { t in
                t.primaryKey("id", .text)
                t.column("taskNumber", .integer).references("task", onDelete: .setNull)
                t.column("stage", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("agentName", .text).notNull()
                t.column("cwd", .text).notNull()
                t.column("agentArgs", .text).notNull().defaults(to: "[]")
                t.column("prompt", .text).notNull().defaults(to: "")
                t.column("worktreeBranch", .text)
                t.column("worktreeBase", .text)
                t.column("worktreePath", .text)
                t.column("workspaceId", .text)
                t.column("paneId", .text)
                t.column("tabId", .text)
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "launch_task", on: "launch", columns: ["taskNumber"])
        }
    }

    private static func registerLookupIndexMigration(_ migrator: inout DatabaseMigrator) {
        // 未受領の回答・レビューの読み（`collectUndelivered`）と、セッションからタスクを引く読み（`task(linkedToSession:)`）は
        // state のイベントのたびに走る。index が無いと表を全部読む
        migrator.registerMigration("v20 feedback and session lookup indexes") { db in
            try db.create(index: "ask_task", on: "ask", columns: ["taskNumber", "status"])
            try db.create(index: "docComment_review", on: "docComment", columns: ["reviewId"])
            try db.create(index: "commentReply_review", on: "commentReply", columns: ["reviewId"])
            try db.create(index: "taskSession_session", on: "taskSession", columns: ["sessionId"])
        }
    }

    // MARK: 読み出し

    public func boards() throws -> [Board] {
        try database.read { db in try Self.fetchBoards(db, machine: machineID) }
    }

    public func tasks() throws -> [BoardTask] {
        try database.read { db in try Self.fetchTasks(db, machine: machineID) }
    }

    public func task(number: Int) throws -> BoardTask? {
        try database.read { db in try Self.fetchTasks(db, machine: machineID, numbers: [number]).first }
    }

    // MARK: ボード

    public func createBoard(name: String, columns: [BoardColumn]?) throws -> Board {
        let board = try database.write { db in
            let name = try Self.validBoardName(db, name, excluding: nil)
            let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM board") ?? 0
            // 新しい案件は既定の起動プロンプト（taskboard の使い方は hook が差し込むので、タスクの中身だけ）
            let row = BoardRow(id: UUID().uuidString.lowercased(), name: name, position: position, createdAt: Date(), promptTemplate: PromptTemplate.defaultBoardTemplate)
            try row.insert(db)
            for (index, column) in (columns ?? BoardColumn.standard).enumerated() {
                try ColumnRow(
                    boardId: row.id, id: column.id, label: column.label, kind: column.kind.rawValue, position: index,
                    promptTemplate: column.promptTemplate ?? PromptTemplate.defaultColumnTemplates[column.id], collapsed: column.collapsed,
                    description: column.description
                ).insert(db)
            }
            return try Self.fetchBoards(db, machine: machineID, ids: [row.id]).first!
        }
        changed(.board(board.id))
        return board
    }

    public func updateBoard(id: String, _ request: BoardUpdateRequest) throws -> Board {
        try editBoard(id: id, request).board
    }

    static func encodeStrings(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self)
    }
    static func decodeStrings(_ text: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    // MARK: タスク

    public func createTask(_ request: TaskCreateRequest) throws -> BoardTask {
        let task = try database.write { db in
            guard let board = try BoardRow.fetchOne(db, key: request.boardID) else { throw StoreError.boardNotFound(request.boardID) }
            guard board.archivedAt == nil else { throw StoreError.boardArchived(board.name) }
            guard try ColumnRow.filter(Column("boardId") == request.boardID && Column("id") == request.columnID).fetchCount(db) == 1 else {
                throw StoreError.columnNotFound(request.columnID)
            }
            let now = Date()
            var row = TaskRow(
                number: nil, boardId: request.boardID, columnId: request.columnID, title: request.title, note: request.note, due: request.due,
                importedId: nil, createdAt: now, updatedAt: now)
            try row.insert(db)
            let number = Int(row.number!)
            for url in request.links where !url.isEmpty {
                try LinkRow(id: nil, taskNumber: number, url: url, kind: TaskLink.kind(of: url).rawValue, note: "", addedAt: now).insert(db)
            }
            return try Self.fetchTasks(db, machine: machineID, numbers: [number]).first!
        }
        changed(.task(task.number))
        return task
    }

    public func updateTask(number: Int, _ request: TaskUpdateRequest) throws -> BoardTask {
        try updateTaskCancellingAsks(number: number, request).task
    }

    /// 終端の列（完了・見送り）に移したら、未回答の質問と、結ばれた会話の開いている依頼を同じトランザクションで閉じ、取り下げた質問も返す（受信箱の「対応待ち」に残さない）
    public func updateTaskCancellingAsks(number: Int, _ request: TaskUpdateRequest) throws -> (task: BoardTask, cancelled: [Ask]) {
        let result = try database.write { db -> (task: BoardTask, cancelled: [Ask]) in
            guard var row = try TaskRow.fetchOne(db, key: number) else { throw StoreError.taskNotFound(number) }
            let before = (board: row.boardId, column: row.columnId)
            if let boardID = request.boardID, boardID != row.boardId {
                guard let board = try BoardRow.fetchOne(db, key: boardID) else { throw StoreError.boardNotFound(boardID) }
                guard board.archivedAt == nil else { throw StoreError.boardArchived(board.name) }
                let columns = try ColumnRow.filter(Column("boardId") == boardID).order(Column("position")).fetchAll(db)
                if let columnID = request.columnID {
                    guard columns.contains(where: { $0.id == columnID }) else {
                        throw StoreError.refused(.notFound, ["kind": "column"], "列 \(columnID) は案件「\(board.name)」に無い")
                    }
                    row.columnId = columnID
                } else if !columns.contains(where: { $0.id == row.columnId }) {
                    let open = columns.filter { $0.kind == BoardColumn.Kind.open.rawValue }.map(\.id)
                    guard let first = BoardColumn.firstWorkColumnID(openIDs: open) else {
                        throw StoreError.refused(.noOpenColumn, [:], "案件「\(board.name)」に進行中の列が無い")
                    }
                    row.columnId = first
                }
                row.boardId = boardID
            } else if let columnID = request.columnID {
                guard try ColumnRow.filter(Column("boardId") == row.boardId && Column("id") == columnID).fetchCount(db) == 1 else {
                    throw StoreError.columnNotFound(columnID)
                }
                row.columnId = columnID
            }
            if let title = request.title { row.title = title }
            if let note = request.note { row.note = note }
            if request.clearDue { row.due = nil } else if let due = request.due { row.due = due }
            if let status = request.status { try Self.apply(status, to: &row) }
            row.updatedAt = Date()
            try row.update(db)
            for url in request.addLinks where !url.isEmpty {
                try LinkRow(id: nil, taskNumber: number, url: url, kind: TaskLink.kind(of: url).rawValue, note: "", addedAt: Date()).insert(db)
            }
            if !request.removeLinkIDs.isEmpty {
                try LinkRow.filter(Column("taskNumber") == number && request.removeLinkIDs.contains(Column("id"))).deleteAll(db)
            }
            var cancelled: [Ask] = []
            if before != (row.boardId, row.columnId),
                try ColumnRow.filter(Column("boardId") == row.boardId && Column("id") == row.columnId).fetchOne(db)?.kind == BoardColumn.Kind.terminal.rawValue
            {
                cancelled = try Self.cancelOpenAsks(db, task: number, machine: machineID)
                // 終わったタスクの状態は古い記録なので外す（`ux-principles.md`「自動で閉じる条件」）
                if row.statusText != nil {
                    Self.clearStatus(&row)
                    try row.update(db)
                }
            }
            return (try Self.fetchTasks(db, machine: machineID, numbers: [number]).first!, cancelled)
        }
        changed([.task(number)] + result.cancelled.map { .ask($0.askID) })
        return (result.task, result.cancelled)
    }

    public func deleteTask(number: Int) throws {
        try database.write { db in
            guard try TaskRow.deleteOne(db, key: number) else { throw StoreError.taskNotFound(number) }
        }
        changed(.task(number))
    }

    // MARK: 作業項目

    public func workItems() throws -> [WorkItem] {
        try database.read { db in try Self.fetchWorkItems(db, machine: machineID) }
    }

    public func workItems(task number: Int) throws -> [WorkItem] {
        try database.read { db in try Self.fetchWorkItems(db, machine: machineID, task: number) }
    }

    public func createWorkItem(task number: Int, _ request: WorkItemCreateRequest) throws -> WorkItem {
        let item = try database.write { db in
            guard try TaskRow.exists(db, key: number) else { throw StoreError.taskNotFound(number) }
            let now = Date()
            let position: Int
            if let wanted = request.position {
                // 指定位置に差し込む: それ以降を 1 つ後ろへ
                try db.execute(sql: "UPDATE workItem SET position = position + 1 WHERE taskNumber = ? AND position >= ?", arguments: [number, wanted])
                position = wanted
            } else {
                position = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM workItem WHERE taskNumber = ?", arguments: [number])) ?? 0
            }
            var row = WorkItemRow(
                id: nil, taskNumber: number, title: request.title, state: request.state.rawValue, blockerKind: request.blockerKind?.rawValue,
                blockerText: request.blockerText, blockerTone: request.blockerTone?.rawValue, dependsOn: Self.encodeIDs(request.dependsOn),
                deliverableKind: request.deliverableKind?.rawValue, deliverableRef: request.deliverableRef, owner: request.owner,
                groupName: request.group, code: request.code, position: position, source: request.source, createdAt: now, updatedAt: now)
            try row.insert(db)
            try Self.touchTask(db, number: number, at: now)
            return try Self.fetchWorkItems(db, machine: machineID, ids: [row.id!]).first!
        }
        changed(.workItems(task: item.taskNumber), .task(item.taskNumber))
        return item
    }

    public func updateWorkItem(id: Int64, _ request: WorkItemUpdateRequest) throws -> WorkItem {
        let item = try database.write { db in
            guard var row = try WorkItemRow.fetchOne(db, key: id) else { throw StoreError.workItemNotFound(id) }
            if let title = request.title { row.title = title }
            if let state = request.state {
                row.state = state.rawValue
                // 待ち以外へ動いたら blocker は消す（待ちの理由は待ちの間だけ意味を持つ）
                if state != .wait, !request.clearBlocker, request.blockerKind == nil, request.blockerText == nil {
                    row.blockerKind = nil
                    row.blockerText = ""
                    row.blockerTone = nil
                }
            }
            if request.clearBlocker {
                row.blockerKind = nil
                row.blockerText = ""
                row.blockerTone = nil
            } else {
                if let kind = request.blockerKind { row.blockerKind = kind.rawValue }
                if let text = request.blockerText { row.blockerText = text }
                if let tone = request.blockerTone { row.blockerTone = tone.rawValue }
            }
            if let deps = request.dependsOn { row.dependsOn = Self.encodeIDs(deps) }
            if request.clearDeliverable {
                row.deliverableKind = nil
                row.deliverableRef = ""
            } else {
                if let kind = request.deliverableKind { row.deliverableKind = kind.rawValue }
                if let ref = request.deliverableRef { row.deliverableRef = ref }
            }
            if let owner = request.owner { row.owner = owner }
            if let group = request.group { row.groupName = group }
            if let code = request.code { row.code = code }
            if let position = request.position, position != row.position {
                // 他の項目を詰めて、指定位置に入れる
                try db.execute(sql: "UPDATE workItem SET position = position - 1 WHERE taskNumber = ? AND position > ?", arguments: [row.taskNumber, row.position])
                try db.execute(sql: "UPDATE workItem SET position = position + 1 WHERE taskNumber = ? AND position >= ? AND id <> ?", arguments: [row.taskNumber, position, id])
                row.position = position
            }
            row.updatedAt = Date()
            try row.update(db)
            try Self.touchTask(db, number: row.taskNumber, at: row.updatedAt)
            return try Self.fetchWorkItems(db, machine: machineID, ids: [id]).first!
        }
        changed(.workItems(task: item.taskNumber), .task(item.taskNumber))
        return item
    }

    /// 消した項目の taskNumber を返す。
    @discardableResult
    public func deleteWorkItem(id: Int64) throws -> Int {
        let number = try database.write { db in
            guard let row = try WorkItemRow.fetchOne(db, key: id) else { throw StoreError.workItemNotFound(id) }
            try row.delete(db)
            try db.execute(sql: "UPDATE workItem SET position = position - 1 WHERE taskNumber = ? AND position > ?", arguments: [row.taskNumber, row.position])
            try Self.touchTask(db, number: row.taskNumber, at: Date())
            return row.taskNumber
        }
        changed(.workItems(task: number), .task(number))
        return number
    }

    // MARK: セッションの紐づけ

    /// session_id で既に結ばれているタスク。
    public func task(linkedToSession sessionID: String) throws -> BoardTask? {
        try database.read { db in
            guard let row = try SessionRow.filter(Column("sessionId") == sessionID).order(Column("id").desc).fetchOne(db) else { return nil }
            return try Self.fetchTasks(db, machine: machineID, numbers: [row.taskNumber]).first
        }
    }

    /// `task(linkedToSession:)` の番号だけ（リンクとセッションを読まない）
    public func taskNumber(linkedToSession sessionID: String) throws -> Int? {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT taskNumber FROM taskSession WHERE sessionId = ? ORDER BY id DESC LIMIT 1", arguments: [sessionID])
        }
    }

    /// 同じ cwd のセッションが結ばれているタスクのうち、終端でなく最後に動いたもの。
    public func task(matchingCwd cwd: String) throws -> BoardTask? {
        guard !cwd.isEmpty else { return nil }
        return try database.read { db in
            let numbers = try SessionRow.filter(Column("cwd") == cwd).fetchAll(db).map(\.taskNumber)
            guard !numbers.isEmpty else { return nil }
            let tasks = try Self.fetchTasks(db, machine: machineID, numbers: Array(Set(numbers)))
            let terminal = Set(try ColumnRow.filter(Column("kind") == "terminal").fetchAll(db).map { "\($0.boardId)/\($0.id)" })
            return tasks.filter { !terminal.contains("\($0.boardID)/\($0.columnID)") }.max { $0.updatedAt < $1.updatedAt }
        }
    }

    public func task(linkedToURL url: String) throws -> BoardTask? {
        try database.read { db in
            guard let row = try LinkRow.filter(Column("url") == url).fetchOne(db) else { return nil }
            return try Self.fetchTasks(db, machine: machineID, numbers: [row.taskNumber]).first
        }
    }

    /// `url` がどのタスクにもリンクしていなければタスク `number` に足す（確かめるのと足すのを 1 つの transaction で行う）
    public func linkIfUnlinked(task number: Int, url: String) throws -> AutoLinkResult {
        let result = try database.write { db -> AutoLinkResult in
            guard var row = try TaskRow.fetchOne(db, key: number) else { throw StoreError.taskNotFound(number) }
            let owners = try Int.fetchAll(db, sql: "SELECT taskNumber FROM taskLink WHERE url = ? ORDER BY id", arguments: [url])
            if owners.contains(number) { return .alreadyLinked(task: number) }
            if let owner = owners.first { return .linkedElsewhere(task: owner) }
            let now = Date()
            try LinkRow(id: nil, taskNumber: number, url: url, kind: TaskLink.kind(of: url).rawValue, note: "", addedAt: now).insert(db)
            row.updatedAt = now
            try row.update(db)
            return .linked(task: number)
        }
        if result == .linked(task: number) { changed(.task(number)) }
        return result
    }

    /// 監視の代わりに `url` をタスク `number` にリンクし、監視の指示（`prompt`）をリンクのメモにする（指示が無ければメモは変えない）。
    /// ほかのタスクにリンク済みなら何もせず nil（リンクの知らせがそのタスクに行くので、監視を作る）
    public func linkInsteadOfWatch(_ request: WatchCreateRequest, task number: Int) throws -> AutoLinkResult? {
        guard let url = request.url.flatMap(Self.watchURL)?.url else { return nil }
        let result = try linkIfUnlinked(task: number, url: url)
        if case .linkedElsewhere = result { return nil }
        if let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            try database.write { db in
                try LinkRow.filter(Column("taskNumber") == number && Column("url") == url).updateAll(db, Column("note").set(to: prompt))
            }
            changed(.task(number))
        }
        return result
    }

    /// セッションをタスクに結ぶ（同じ session_id が既にあれば何もしない）。
    /// `launchArgs` を渡すと、既にある行の引数もそれにする（SessionStart hook が起動より先に結んだとき・アカウントを替えて起こし直したとき）
    public func linkSession(task number: Int, agent: String, sessionID: String, cwd: String, label: String, launchArgs: [String] = []) throws -> BoardTask {
        let (task, changes) = try database.write { db -> (BoardTask, [StoreChange]) in
            guard try TaskRow.exists(db, key: number) else { throw StoreError.taskNotFound(number) }
            // host の会話の ID は会話ごと移す（ほかのタスクの行を残すと、移した先を消したときにそこへ戻る）
            if var conversation = try Self.conversationOwning(db, sessionID: sessionID) {
                let tasks = try Self.bind(db, &conversation, task: number, at: Date())
                return (try Self.fetchTasks(db, machine: machineID, numbers: [number]).first!, tasks.map { .task($0) } + [.conversation(conversation.id)])
            }
            let filter = Column("taskNumber") == number && Column("sessionId") == sessionID
            if try SessionRow.filter(filter).fetchCount(db) == 0 {
                try SessionRow(
                    id: nil, taskNumber: number, agent: agent, sessionId: sessionID, cwd: cwd, label: label, linkedAt: Date(),
                    launchArgs: Self.encodeStrings(launchArgs)
                ).insert(db)
                try Self.touchTask(db, number: number, at: Date())
            } else if !launchArgs.isEmpty {
                let encoded = Self.encodeStrings(launchArgs)
                try SessionRow.filter(filter && Column("launchArgs") != encoded).updateAll(db, Column("launchArgs").set(to: encoded))
            }
            return (try Self.fetchTasks(db, machine: machineID, numbers: [number]).first!, [.task(number)])
        }
        changed(changes)
        return task
    }

    // MARK: backup / restore

    /// `backups/taskboard.<時刻>[.<label>].db` に GRDB の backup を取り、古いものを消して 3 世代にする。
    @discardableResult
    public func backup(label: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: Date())
        let name = "taskboard.\(stamp)\(label.map { ".\($0)" } ?? "").db"
        let url = backupDirectory.appending(path: name)
        let destination = try DatabaseQueue(path: url.path)
        try database.backup(to: destination)
        try destination.close()
        try Self.rotateBackups(in: backupDirectory, keep: Self.backupGenerations)
        return url
    }

    public static func listBackups(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("taskboard.") && $0.pathExtension == "db" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func rotateBackups(in directory: URL, keep: Int) throws {
        let backups = try listBackups(in: directory)
        guard backups.count > keep else { return }
        for url in backups.prefix(backups.count - keep) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// backup ファイルを開いて `integrity_check` と必要なテーブルの有無を見る。件数を返す。
    public static func verify(backupAt url: URL) throws -> (boards: Int, tasks: Int) {
        // WAL の DB は readonly で開くと -shm を作れず "unable to open database file" になるので、通常に開いて読むだけにする
        let db = try DatabaseQueue(path: url.path)
        defer { try? db.close() }
        return try db.read { db in
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
            guard integrity == "ok" else { throw StoreError.integrityCheckFailed(integrity) }
            for table in ["board", "boardColumn", "task", "taskLink", "taskSession", "workItem"] where try !db.tableExists(table) {
                throw StoreError.missingTable(table)
            }
            _ = try verifyConversationTables(db)
            try verifyLinkNoticeTables(db)
            try verifyWakeAndWatchTables(db)
            return (try BoardRow.fetchCount(db), try TaskRow.fetchCount(db))
        }
    }

    public func close() throws {
        try database.close()
    }

    // MARK: 行 → モデル

    static func fetchBoards(_ db: Database, machine: MachineID, ids: [String]? = nil) throws -> [Board] {
        var request = BoardRow.order(Column("position"))
        if let ids { request = request.filter(ids.contains(Column("id"))) }
        let rows = try request.fetchAll(db)
        let columns = try ColumnRow.filter(rows.map(\.id).contains(Column("boardId"))).order(Column("position")).fetchAll(db)
        let grouped = Dictionary(grouping: columns, by: \.boardId)
        return rows.map { row in
            Board(
                id: row.id, machine: machine, name: row.name, position: row.position,
                columns: (grouped[row.id] ?? []).map {
                    BoardColumn(
                        id: $0.id, label: $0.label, kind: BoardColumn.Kind(rawValue: $0.kind) ?? .open, position: $0.position,
                        promptTemplate: $0.promptTemplate, collapsed: $0.collapsed, description: $0.description)
                },
                createdAt: row.createdAt, promptTemplate: row.promptTemplate, archived: row.archivedAt != nil,
                launchDefaults: row.launchDefaults.flatMap { try? JSONDecoder().decode(LaunchDefaults.self, from: Data($0.utf8)) },
                mergeTarget: MergeTarget(rawValue: row.mergeTarget) ?? .deploying)
        }
    }

    static func touchTask(_ db: Database, number: Int, at date: Date) throws {
        try db.execute(sql: "UPDATE task SET updatedAt = ? WHERE number = ?", arguments: [date, number])
    }

    static func encodeIDs(_ ids: [Int64]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }

    static func decodeIDs(_ text: String) -> [Int64] {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func fetchWorkItems(_ db: Database, machine: MachineID, task: Int? = nil, ids: [Int64]? = nil) throws -> [WorkItem] {
        var request = WorkItemRow.order(Column("taskNumber"), Column("position"), Column("id"))
        if let task { request = request.filter(Column("taskNumber") == task) }
        if let ids { request = request.filter(ids.contains(Column("id"))) }
        return try request.fetchAll(db).map { row in
            WorkItem(
                machine: machine, itemID: row.id!, taskNumber: row.taskNumber, title: row.title,
                state: WorkItem.State(rawValue: row.state) ?? .todo, blockerKind: row.blockerKind.flatMap(WorkItem.BlockerKind.init(rawValue:)),
                blockerText: row.blockerText, blockerTone: row.blockerTone.flatMap(WorkItem.BlockerTone.init(rawValue:)),
                dependsOn: decodeIDs(row.dependsOn), deliverableKind: row.deliverableKind.flatMap(WorkItem.DeliverableKind.init(rawValue:)),
                deliverableRef: row.deliverableRef, owner: row.owner, group: row.groupName, code: row.code, position: row.position, source: row.source,
                createdAt: row.createdAt, updatedAt: row.updatedAt)
        }
    }

    static func fetchTasks(_ db: Database, machine: MachineID, numbers: [Int]? = nil) throws -> [BoardTask] {
        var request = TaskRow.order(Column("number"))
        if let numbers { request = request.filter(numbers.map(Int64.init).contains(Column("number"))) }
        let rows = try request.fetchAll(db)
        let keys = rows.compactMap(\.number)
        let links = Dictionary(grouping: try LinkRow.filter(keys.contains(Column("taskNumber"))).order(Column("id")).fetchAll(db), by: \.taskNumber)
        let sessions = Dictionary(
            grouping: try SessionRow.filter(keys.contains(Column("taskNumber"))).order(Column("id")).fetchAll(db), by: \.taskNumber)
        return rows.map { row in
            let number = Int(row.number!)
            return BoardTask(
                machine: machine, number: number, boardID: row.boardId, columnID: row.columnId, title: row.title, note: row.note, due: row.due,
                links: (links[number] ?? []).map {
                    TaskLink(id: $0.id!, url: $0.url, kind: TaskLink.Kind(rawValue: $0.kind) ?? .other, note: $0.note, addedAt: $0.addedAt)
                },
                sessions: (sessions[number] ?? []).map {
                    TaskSessionRef(
                        id: $0.id!, agent: $0.agent, sessionID: $0.sessionId, cwd: $0.cwd, label: $0.label, linkedAt: $0.linkedAt,
                        launchArgs: decodeStrings($0.launchArgs))
                },
                importedID: row.importedId,
                statusNote: row.statusText.flatMap { text in row.statusSetAt.map { TaskStatusNote(text: text, conversationID: row.statusConversationId, setAt: $0) } },
                createdAt: row.createdAt, updatedAt: row.updatedAt)
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

public enum StoreError: Error, CustomStringConvertible, Equatable {
    case boardNotFound(String)
    case columnNotFound(String)
    case taskNotFound(Int)
    case workItemNotFound(Int64)
    case integrityCheckFailed(String)
    case missingTable(String)
    case docNotFound(Int64)
    /// 同じ名前の文書が別の形式で既にある（リビジョンは形式を共有する）
    case docFormatMismatch(name: String, existing: DocFormat)
    case askNotFound(Int64)
    case askNotOpen(Int64)
    case askUnanswered([String])
    case commentNotFound(Int64)
    case commentNotDraft(Int64)
    case revisionNotFound(Int)
    case scheduleNotFound(Int64)
    case wakeNotFound(Int64)
    case watchNotFound(Int64)
    case invalid(String)
    /// アーカイブした案件へタスクを作る・移す
    case boardArchived(String)
    /// 今の状態のままでは受けられない（タスクが残る列を消す・最後の案件をアーカイブする等）
    case conflict(String)
    /// アプリの操作で起こりうる拒否。アプリは code と params から画面の文を組み、文はエージェントとログに返す
    case refused(DaemonErrorCode, [String: String], String)

    public var description: String {
        switch self {
        case .boardNotFound(let id): "ボード \(id) が無い"
        case .columnNotFound(let id): "列 \(id) が無い"
        case .taskNotFound(let n): "タスク #\(n) が無い"
        case .workItemNotFound(let id): "作業項目 \(id) が無い"
        case .integrityCheckFailed(let s): "integrity_check が ok でない: \(s)"
        case .missingTable(let t): "テーブル \(t) が無い"
        case .docNotFound(let id): "文書 \(id) が無い"
        case .docFormatMismatch(let name, let existing): "\(name) は \(existing.rawValue) として既にある。形式を変えるなら別の名前で publish する"
        case .askNotFound(let id): "質問 \(id) が無い"
        case .askNotOpen(let id): "質問 \(id) は回答待ちでない"
        case .askUnanswered(let ids): "未回答の質問がある: " + ids.joined(separator: ", ")
        case .commentNotFound(let id): "コメント \(id) が無い"
        case .commentNotDraft(let id): "コメント \(id) は送信済みで変えられない"
        case .revisionNotFound(let rev): "リビジョン \(rev) が無い"
        case .scheduleNotFound(let id): "定期起動 \(id) が無い"
        case .wakeNotFound(let id): "予定 #\(id) が無い"
        case .watchNotFound(let id): "見張り #\(id) が無い"
        case .invalid(let s): s
        case .boardArchived(let name): "案件「\(name)」はアーカイブしてある: 戻してから移す"
        case .conflict(let s): s
        case .refused(_, _, let s): s
        }
    }
}

// MARK: - 行

struct BoardRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "board"
    var id: String
    var name: String
    var position: Int
    var createdAt: Date
    var promptTemplate: String = ""
    var archivedAt: Date? = nil
    /// `LaunchDefaults` の JSON
    var launchDefaults: String? = nil
    /// `MergeTarget` の rawValue
    var mergeTarget: String = MergeTarget.deploying.rawValue
}

struct ColumnRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "boardColumn"
    var boardId: String
    var id: String
    var label: String
    var kind: String
    var position: Int
    var promptTemplate: String? = nil
    var collapsed: Bool = false
    var description: String = ""
}

struct TaskRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "task"
    var number: Int64?
    var boardId: String
    var columnId: String
    var title: String
    var note: String
    var due: String?
    var importedId: Int?
    var createdAt: Date
    var updatedAt: Date
    /// 会話が書いた状態の文（`TaskStatusNote`）。3 つとも揃うか、どれも NULL
    var statusText: String? = nil
    var statusConversationId: String? = nil
    var statusSetAt: Date? = nil

    mutating func didInsert(_ inserted: InsertionSuccess) {
        number = inserted.rowID
    }
}

struct LinkRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "taskLink"
    var id: Int64?
    var taskNumber: Int
    var url: String
    var kind: String
    var note: String
    var addedAt: Date
}

struct SessionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "taskSession"
    var id: Int64?
    var taskNumber: Int
    var agent: String
    var sessionId: String
    var cwd: String
    var label: String
    var linkedAt: Date
    /// 起動したときの agent の引数（JSON の配列）
    var launchArgs: String = "[]"
}

private struct WorkItemRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "workItem"
    var id: Int64?
    var taskNumber: Int
    var title: String
    var state: String
    var blockerKind: String?
    var blockerText: String
    var blockerTone: String?
    var dependsOn: String
    var deliverableKind: String?
    var deliverableRef: String
    var owner: String
    var groupName: String = ""
    var code: String = ""
    var position: Int
    var source: String
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
