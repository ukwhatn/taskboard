import ArgumentParser
import Foundation
import Logging
import MCP
import TaskboardDaemon
import TaskboardKit

/// `taskboard mcp`: stdio の MCP server。Claude Code / Codex のセッションがボードと作業項目を読み書きする。
/// stdout は JSON-RPC だけ。ログは stderr。`task_id` を省くと、このセッションに紐づくタスクを使う。セッションは host の会話なら
/// `TASKBOARD_CONVERSATION_ID` で、その外では Claude Code が MCP の process に渡す `CLAUDE_CODE_SESSION_ID` で見分ける
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: Copy.text("cli.mcp.core.configuration"))

    @OptionGroup var common: CommonOptions

    func run() async throws {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .warning
            return handler
        }
        let common = common.inheritingDaemon(from: ProcessInfo.processInfo.environment)
        let endpoint = try Daemon.localEndpoint(port: common.port, supportDirectory: common.supportDirectoryURL)
        let tools = TaskboardTools(
            client: DaemonClient(endpoint: endpoint), environment: ProcessInfo.processInfo.environment,
            apnsDirectory: try? Paths(directory: common.supportDirectoryURL).apnsDirectory)
        let server = Server(
            name: "taskboard", version: Daemon.version, instructions: SessionGuidance.mcpInstructions, capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: TaskboardTools.definitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                return .init(content: try await tools.callContent(params.name, params.arguments ?? [:]), isError: false)
            } catch {
                return .init(content: [.text(text: String(describing: error), annotations: nil, _meta: nil)], isError: true)
            }
        }
        try await server.start(transport: MCPStdioTransport())
        await server.waitUntilCompleted()
    }
}

/// swift-sdk 0.12.1 は experimental capability の値を String として読む。
/// Codex は仕様どおり object を送るため、SDK が使わないこの field だけを initialize から除く。
private actor MCPStdioTransport: Transport {
    private let base = StdioTransport()
    nonisolated let logger = Logger(label: "taskboard.mcp.stdio")

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, Error> {
        let base = base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var firstMessage = true
                    for try await data in await base.receive() {
                        if firstMessage {
                            continuation.yield(try Self.normalizeInitialize(data))
                            firstMessage = false
                        } else {
                            continuation.yield(data)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private nonisolated static func normalizeInitialize(_ data: Data) throws -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["method"] as? String == "initialize",
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              experimental.values.contains(where: { !($0 is String) })
        else { return data }

        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        request["params"] = params
        return try JSONSerialization.data(withJSONObject: request)
    }
}

/// tool の実体。daemon の HTTP API を呼ぶだけで、状態は持たない。
struct TaskboardTools: Sendable {
    let client: DaemonClient
    let session: SessionEnvironment
    var agentSessionID: String? { session.agentSessionID }
    var conversationID: String? { session.conversationID }
    let cwd: String
    /// APNs の鍵の置き場（`health` が鍵と設定のファイルの有無だけを見る。中身は読まない）
    let apnsDirectory: URL?

    init(
        client: DaemonClient, environment: [String: String], cwd: String = FileManager.default.currentDirectoryPath,
        apnsDirectory: URL? = nil
    ) {
        self.client = client
        session = SessionEnvironment(environment: environment)
        self.cwd = cwd
        self.apnsDirectory = apnsDirectory
    }

    enum ToolError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unresolved
        case unidentified
        case unknown(String)
        case invalid(String)

        var description: String {
            switch self {
            case .missing(let name): Copy.text("agent.mcp.core.missing", ["name": "\(name)"])
            case .unresolved:
                Copy.text("agent.mcp.core.unresolved")
            case .unidentified:
                Copy.text("agent.mcp.core.unidentified")
            case .unknown(let name): Copy.text("agent.mcp.core.unknown", ["name": "\(name)"])
            case .invalid(let s): s
            }
        }
    }

    /// このセッションをタスクに紐づけた結果。tool の結果の `- セッション: ` の値にする
    enum LinkOutcome: Equatable {
        case environment(String)
        case conversation(String)
        case unidentified

        var note: String {
            switch self {
            case .environment(let id):
                Copy.text("agent.mcp.core.environment", ["id": "\(id.prefix(8))"])
            case .conversation(let id): Copy.text("agent.mcp.core.conversation", ["id": "\(id.prefix(8))"])
            case .unidentified: Copy.text("agent.mcp.core.unidentified.2") + ToolError.unidentified.description
            }
        }
    }

    /// tool 1 つの、一覧に出す定義（名前・説明・引数の schema）と呼ばれたときの処理
    struct ToolEntry: Sendable {
        let definition: Tool
        let run: @Sendable (TaskboardTools, [String: Value]) async throws -> [Tool.Content]

        init(name: String, description: String, inputSchema: Value, run: @escaping @Sendable (TaskboardTools, [String: Value]) async throws -> String) {
            definition = Tool(name: name, description: description, inputSchema: inputSchema)
            self.run = { tools, args in [.text(text: try await run(tools, args), annotations: nil, _meta: nil)] }
        }
    }

    /// tool の引数の schema（object）。`required` を省くと要る引数は無い
    static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    /// 引数 1 つの schema。`items` は配列の要素の schema
    static func property(_ type: String, _ description: String? = nil, enum values: [String]? = nil, items: Value? = nil) -> Value {
        var object: [String: Value] = ["type": .string(type)]
        if let description { object["description"] = .string(description) }
        if let values { object["enum"] = .array(values.map { .string($0) }) }
        if let items { object["items"] = items }
        return .object(object)
    }

    /// 一覧に出す順。名前の重なりは `MCPToolTableTests` が見る
    private static let entries: [ToolEntry] = coreTools + manageTools + healthTools + conversationTools + wakeTools + watchTools + devinTools + slackTools + panelTools
    static let definitions: [Tool] = entries.map(\.definition)
    private static let entriesByName = Dictionary(entries.map { ($0.definition.name, $0) }, uniquingKeysWith: { first, _ in first })

    static let coreTools: [ToolEntry] = boardTools + scheduleTools + [sessionListTool, sessionStartTool] + documentTools + [sessionPromptTool, sessionAccountTool]

    /// `task_id` の引数。省くとこのセッションに紐づくタスクを引く tool が共有する
    static let currentTaskIDProperty: Value = property("integer", Copy.text("agent.mcp.core.currentTaskIDProperty"))

    /// `task_id` だけを取る tool の引数
    static let currentTaskOnlySchema: Value = schema(["task_id": currentTaskIDProperty])

    static let boardTools: [ToolEntry] = [
        ToolEntry(
            name: "board_overview", description: Copy.text("agent.tool.board_overview"),
            inputSchema: schema([:])) { tools, _ in try await tools.boardOverview() },
        ToolEntry(
            name: "task_get",
            description: Copy.text("agent.tool.task_get"),
            inputSchema: currentTaskOnlySchema) { tools, args in try await tools.taskGet(args) },
        ToolEntry(
            name: "session_guide",
            description: Copy.text("agent.tool.session_guide"),
            inputSchema: currentTaskOnlySchema) { tools, args in try await tools.sessionGuide(args) },
        ToolEntry(
            name: "task_create", description: Copy.text("agent.tool.task_create"),
            inputSchema: schema([
                "title": property("string", Copy.text("agent.tool.task_create.title")),
                "board": property("string", boardArgumentDescription),
                "column": property("string", Copy.text("agent.tool.task_create.column")),
                "links": property("array", Copy.text("agent.tool.task_create.links"), items: property("string")),
                "note": property("string", Copy.text("agent.tool.task_create.note")),
                "due": property("string", "YYYY-MM-DD"),
                "link_session": property("boolean", Copy.text("agent.tool.task_create.link_session")),
            ], required: ["title"])) { tools, args in try await tools.taskCreate(args) },
        ToolEntry(
            name: "task_update",
            description: Copy.text("agent.tool.task_update"),
            inputSchema: schema([
                "task_id": currentTaskIDProperty,
                "title": property("string"),
                "column": property("string"),
                "board": property("string", Copy.text("agent.tool.task_update.board")),
                "note": property("string"),
                "due": property("string", Copy.text("agent.tool.task_update.due")),
                "add_links": property("array", items: property("string")),
                "remove_links": property("array", Copy.text("agent.tool.task_update.remove_links"), items: .object(["type": .array([.string("integer"), .string("string")])])),
                "link_session": property("boolean", Copy.text("agent.tool.task_update.link_session")),
                "unlink_session": property("boolean", Copy.text("agent.tool.task_update.unlink_session")),
                "unlink_sessions": property("array", Copy.text("agent.tool.task_update.unlink_sessions"), items: property("string")),
            ])) { tools, args in try await tools.taskUpdate(args) },
        ToolEntry(
            name: "work_list", description: Copy.text("agent.tool.work_list"),
            inputSchema: currentTaskOnlySchema) { tools, args in try await tools.workList(args) },
        ToolEntry(
            name: "work_add", description: Copy.text("agent.tool.work_add"),
            inputSchema: schema([
                "task_id": currentTaskIDProperty,
                "title": property("string", Copy.text("agent.tool.work_add.title")),
                "state": property("string", enum: ["todo", "doing", "wait", "done", "drop"]),
                "depends_on": property("array", Copy.text("agent.tool.work_add.depends_on"), items: property("integer")),
                "owner": property("string", Copy.text("agent.tool.work_add.owner")),
                "blocker_kind": property("string", Copy.text("agent.tool.work_add.blocker_kind"), enum: ["approval", "manual", "review", "ci", "deploy", "item", "external"]),
                "blocker_text": property("string"),
                "deliverable_kind": property("string", enum: ["pr", "commit", "file", "doc"]),
                "deliverable_ref": property("string", Copy.text("agent.tool.work_add.deliverable_ref")),
                "position": property("integer", Copy.text("agent.tool.work_add.position")),
                "group": property("string", Copy.text("agent.tool.work_add.group")),
                "code": property("string", Copy.text("agent.tool.work_add.code")),
            ], required: ["title"])) { tools, args in try await tools.workAdd(args) },
        ToolEntry(
            name: "work_update", description: Copy.text("agent.tool.work_update"),
            inputSchema: schema([
                "id": property("integer"),
                "title": property("string"),
                "state": property("string", enum: ["todo", "doing", "wait", "done", "drop"]),
                "blocker_kind": property("string", Copy.text("agent.tool.work_add.blocker_kind"), enum: ["approval", "manual", "review", "ci", "deploy", "item", "external"]),
                "blocker_text": property("string"),
                "depends_on": property("array", items: property("integer")),
                "owner": property("string"),
                "deliverable_kind": property("string", enum: ["pr", "commit", "file", "doc"]),
                "deliverable_ref": property("string"),
                "position": property("integer"),
                "group": property("string", Copy.text("agent.tool.work_update.group")),
                "code": property("string", Copy.text("agent.tool.work_update.code")),
            ], required: ["id"])) { tools, args in try await tools.workUpdate(args) },
    ]

    func callContent(_ name: String, _ args: [String: Value]) async throws -> [Tool.Content] {
        guard let entry = Self.entriesByName[name] else { throw ToolError.unknown(name) }
        return try await entry.run(self, args)
    }

    /// 結果の文（画像は `[image <mimeType>]` と書く）
    func call(_ name: String, _ args: [String: Value]) async throws -> String {
        try await callContent(name, args).map { content in
            switch content {
            case .text(let text, _, _): text
            case .image(_, let mimeType, _, _): "[image \(mimeType)]"
            default: ""
            }
        }.joined(separator: "\n")
    }

    // MARK: 解決

    func resolveTaskNumber(_ args: [String: Value]) async throws -> Int {
        if let n = args.int("task_id") { return n }
        if let s = args.string("task_id"), let n = Int(s) { return n }
        guard let task = try await currentTask() else {
            throw agentSessionID == nil && conversationID == nil ? ToolError.unidentified : ToolError.unresolved
        }
        return task.number
    }

    /// このセッションに紐づくタスク。会話の中なら会話の記録のタスク（環境の ID は /clear の後も起動したときのまま）。
    /// 会話が state に無いとき（前の版の daemon）と会話の外は、環境のセッション ID で daemon に引く
    func currentTask(in snapshot: StateSnapshot? = nil) async throws -> BoardTask? {
        if conversationID != nil {
            let state = if let snapshot { snapshot } else { try await client.snapshot() }
            if let conversation = ownConversation(in: state) { return conversation.taskNumber.flatMap { n in state.tasks.first { $0.number == n } } }
        }
        guard let agentSessionID else { return nil }
        return try await client.resolveTask(pane: nil, agentSessionID: agentSessionID).task
    }

    /// このセッションの Claude の会話 ID。会話の中なら会話の記録の今の ID、ほかは環境の値
    func currentAgentSessionID(_ snapshot: StateSnapshot) -> String? {
        if let id = ownConversation(in: snapshot)?.agentSessionID, !id.isEmpty { return id }
        return agentSessionID
    }

    private func ownConversation(in snapshot: StateSnapshot) -> Conversation? {
        conversationID.flatMap { id in snapshot.conversations.first { $0.id == id } }
    }

    /// 環境のセッション ID を結ぶ
    func linkCurrentSession(to number: Int) async throws -> LinkOutcome {
        guard let agentSessionID else { return .unidentified }
        _ = try await client.linkSession(SessionLinkRequest(agent: "claude", agentSessionID: agentSessionID, cwd: cwd, taskNumber: number))
        return conversationID.map(LinkOutcome.conversation) ?? .environment(agentSessionID)
    }

    /// 質問・レビューを頼んだこの会話（回答をこの会話に届ける）
    var requester: FeedbackRequester? {
        let value = FeedbackRequester(conversationID: conversationID, agentSessionID: agentSessionID)
        return value.isEmpty ? nil : value
    }

    // MARK: tools

    private func boardOverview() async throws -> String {
        let snapshot = try await client.snapshot()
        var lines = [Copy.text("agent.mcp.core.lines", ["boards": "\(snapshot.boards.count)"])]
        for board in snapshot.boards {
            lines.append("## \(board.name) (\(board.id))" + (board.archived ? Copy.text("agent.mcp.core.lines.2") : ""))
            let tasks = snapshot.tasks.filter { $0.boardID == board.id }
            for column in board.columns {
                let inColumn = tasks.filter { $0.columnID == column.id }
                guard !inColumn.isEmpty || column.kind == .open else { continue }
                lines.append(Copy.text("agent.mcp.core.inColumn", ["columnName": "\(SessionGuidance.columnName(column))", "inColumn": "\(inColumn.count)"]) + Self.summarySuffix(column))
                if column.kind == .open {
                    for task in inColumn.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(12) {
                        lines += Self.rows(of: task, snapshot: snapshot)
                    }
                }
            }
        }
        lines.append("")
        if let current = try? await currentTask(in: snapshot) {
            lines.append(Copy.text("agent.mcp.core.inColumn.2", ["number": "\(current.number)", "title": "\(current.title)", "columnID": "\(current.columnID)"]))
        } else {
            lines.append(Copy.text("agent.mcp.core.inColumn.3"))
        }
        return lines.joined(separator: "\n")
    }

    /// 一覧の行に付ける列の説明（1 行目だけ、80 字まで）
    static func summarySuffix(_ column: BoardColumn) -> String {
        let first = column.description.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !first.isEmpty else { return "" }
        return " ・ " + (first.count > 80 ? first.prefix(80) + "…" : first)
    }

    /// 進行中の列のタスクの行。1 行目に番号・題・進捗、2 行目に待ち・PR・期日
    private static func rows(of task: BoardTask, snapshot: StateSnapshot) -> [String] {
        var head = ["#\(task.number) \(task.title)"]
        var rest: [String] = []
        let items = snapshot.workItems.filter { $0.taskNumber == task.number }
        if let progress = TaskProgress.derive(items) {
            head.append(Copy.text("agent.mcp.core.items", ["fractionLabel": "\(progress.fractionLabel)"]))
            if let current = progress.currentLabel { head.append(Copy.text("agent.mcp.core.items.2", ["current": "\(current)"])) }
            if let wait = progress.primaryWait { rest.append(Copy.text("agent.mcp.core.items.3", ["wait": "\(wait.text)"])) }
        }
        let prs = task.pullRequestLinks.map(\.shortLabel)
        if !prs.isEmpty { rest.append("PR " + prs.joined(separator: "、")) }
        if let due = task.due { rest.append(Copy.text("agent.mcp.core.prs", ["due": "\(due)"])) }
        var rows = ["  - " + head.joined(separator: " ・ ")]
        if !rest.isEmpty { rows.append("    - " + rest.joined(separator: " ・ ")) }
        return rows
    }

    private func taskGet(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        let snapshot = try await client.snapshot()
        guard let task = snapshot.tasks.first(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
        let items = snapshot.workItems.filter { $0.taskNumber == number }
        var state = MachineState()
        state.apply(.stateSnapshot(snapshot))
        return Self.describe(task, board: snapshot.boards.first { $0.id == task.boardID }, items: items, state: state, linkNotices: await linkNoticeCount(task))
    }

    /// GitHub の PR・issue をリンクしたタスクの、未通知のリンクの動きの数。読めなければ（前の版の daemon）nil で、行を出さない
    private func linkNoticeCount(_ task: BoardTask) async -> Int? {
        guard task.links.contains(where: { $0.kind == .githubPR || $0.kind == .githubIssue || DevinSession.id(fromURL: $0.url) != nil }) else { return nil }
        return try? await client.linkNotices(task: task.number).undelivered
    }

    static func linkNoticeLine(_ count: Int) -> String {
        Copy.text("agent.mcp.core.linkNoticeLine", ["value": "\(count)"])
    }

    /// タスクの会話・止まったセッションは、アプリのタスクの画面と同じ `MachineState` の見分けで出す
    static func describe(_ task: BoardTask, board: Board?, items: [WorkItem], state: MachineState, linkNotices: Int? = nil) -> String {
        var lines = [Copy.text("agent.mcp.core.lines.3", ["number": "\(task.number)", "title": "\(task.title)"])]
        if let board, let column = board.columns.first(where: { $0.id == task.columnID }) {
            lines.append(Copy.text("agent.mcp.core.lines.4", ["name": "\(board.name)", "id": "\(board.id)"]))
            lines.append(Copy.text("agent.mcp.core.lines.5", ["columnLine": "\(SessionGuidance.columnLine(column))"]))
        } else {
            lines.append(Copy.text("agent.mcp.core.lines.6", ["boardID": "\(task.boardID)"]))
            lines.append(Copy.text("agent.mcp.core.lines.7", ["columnID": "\(task.columnID)"]))
        }
        if let due = task.due { lines.append(Copy.text("agent.mcp.core.lines.8", ["due": "\(due)"])) }
        if !task.note.isEmpty { lines.append(Copy.text("agent.mcp.core.lines.9", ["note": "\(task.note)"])) }
        for link in task.links {
            let kind = DevinSession.id(fromURL: link.url) != nil ? Copy.text("agent.mcp.core.kind") : link.kind.rawValue
            lines.append(Copy.text("agent.mcp.core.kind.2", ["url": "\(link.url)", "kind": "\(kind)", "id": "\(link.id)"]))
        }
        if let linkNotices { lines.append(linkNoticeLine(linkNotices)) }
        let conversations = state.conversations(of: task)
        for conversation in conversations {
            var line = Copy.text("agent.mcp.core.line", ["id": "\(conversation.id)", "isClosed": "\(conversation.isClosed ? "closed" : conversation.phase.rawValue)"])
            if let title = conversation.title { line += " ・ 「\(title)」" }
            if state.isDelegate(conversation) { line += Copy.text("agent.mcp.core.line.2") }
            lines.append(line)
        }
        let stopped = state.stoppedSessions(of: task)
        for ref in stopped {
            lines.append(Copy.text("agent.mcp.core.stopped", ["sessionID": "\(ref.sessionID)", "agent": "\(ref.agent)"]))
            lines.append("  - cwd: \(ref.cwd)")
        }
        var operations: [String] = []
        if !conversations.isEmpty { operations.append(Copy.text("agent.mcp.core.operations")) }
        if !stopped.isEmpty { operations.append(Copy.text("agent.mcp.core.operations.2")) }
        if !operations.isEmpty { lines.append(Copy.text("agent.mcp.core.operations.3") + operations.joined(separator: "。")) }
        lines.append(describeWork(items))
        if let panel = state.panels[task.id] {
            lines.append(Copy.text("agent.mcp.panel.summary", ["count": "\(panel.parts.count)", "turn": "\(panel.turn)"]))
            lines += panelSummary(panel).map { "  " + $0 }
        } else {
            lines.append(Copy.text("agent.mcp.panel.summary.none"))
        }
        return lines.joined(separator: "\n")
    }

    private static func describeWork(_ items: [WorkItem]) -> String {
        guard let progress = TaskProgress.derive(items) else { return Copy.text("agent.mcp.core.describeWork") }
        var lines = [Copy.text("agent.mcp.core.lines.10", ["fractionLabel": "\(progress.fractionLabel)", "ready": "\(progress.ready)", "current": "\(progress.current.count)", "waiting": "\(progress.waiting.count)"])]
        let ordered = items.sorted { ($0.position, $0.itemID) < ($1.position, $1.itemID) }
        let states = WorkItem.effectiveStates(of: ordered)
        for item in ordered {
            let state = states[item.itemID] ?? .todo
            lines.append("- [\(item.itemID)] \(state.label): \(item.codedTitle)")
            var assignment: [String] = []
            if !item.group.isEmpty { assignment.append("group: \(item.group)") }
            if !item.owner.isEmpty { assignment.append("owner: \(item.owner)") }
            if !item.dependsOn.isEmpty { assignment.append("depends_on: \(item.dependsOn.map(String.init).joined(separator: ","))") }
            if !assignment.isEmpty { lines.append("  - " + assignment.joined(separator: " ・ ")) }
            var status: [String] = []
            if let wait = item.waitLine { status.append(Copy.text("agent.mcp.core.items.3", ["wait": "\(wait.text)"])) }
            if let kind = item.deliverableKind { status.append(Copy.text("agent.mcp.core.status", ["kind": "\(kind.rawValue)", "deliverableRef": "\(item.deliverableRef)"])) }
            if !status.isEmpty { lines.append("  - " + status.joined(separator: " ・ ")) }
        }
        return lines.joined(separator: "\n")
    }

    /// SessionStart hook と同じ案内（今の列と、案件の列の id・名前・説明）
    private func sessionGuide(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        let snapshot = try await client.snapshot()
        guard let task = snapshot.tasks.first(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
        return SessionGuidance.text(task: task, board: snapshot.boards.first { $0.id == task.boardID }, machineName: Copy.text("agent.mcp.core.snapshot.2"))
    }

    private func taskCreate(_ args: [String: Value]) async throws -> String {
        guard let title = args.string("title"), !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError.missing("title") }
        let snapshot = try await client.snapshot()
        let board = try Self.board(args.string("board"), in: snapshot.boards)
        guard let column = args.string("column") ?? board.defaultColumn?.id else {
            throw ToolError.invalid(Copy.text("agent.mcp.core.board", ["name": "\(board.name)"]))
        }
        guard board.columns.contains(where: { $0.id == column }) else {
            throw ToolError.invalid(Copy.text("agent.mcp.core.board.2", ["column": "\(column)"]) + board.columns.map(\.id).joined(separator: ", "))
        }
        let links = args.strings("links") ?? []
        for url in links {
            if let dup = snapshot.tasks.first(where: { $0.links.contains { $0.url == url } }) {
                throw ToolError.invalid(Copy.text("agent.mcp.core.links", ["number": "\(dup.number)", "title": "\(dup.title)", "columnID": "\(dup.columnID)"]))
            }
        }
        let request = TaskCreateRequest(
            boardID: board.id, columnID: column, title: title, note: args.string("note") ?? "",
            due: args.string("due").flatMap { $0.isEmpty ? nil : $0 }, links: links)
        let task = try await client.createTask(request)
        var lines = [Copy.text("agent.mcp.core.lines.11"), Copy.text("agent.mcp.core.lines.12", ["number": "\(task.number)", "title": "\(task.title)"]), Copy.text("agent.mcp.core.lines.7", ["columnID": "\(task.columnID)"]), Copy.text("agent.mcp.core.lines.4", ["name": "\(board.name)", "id": "\(board.id)"])]
        if args.bool("link_session") ?? true {
            lines.append(Copy.text("agent.mcp.core.lines.13") + (try await linkCurrentSession(to: task.number).note))
        }
        return lines.joined(separator: "\n")
    }

    private func taskUpdate(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        var request = TaskUpdateRequest()
        request.title = args.string("title")
        request.columnID = args.string("column")
        request.note = args.string("note")
        if let due = args.string("due") {
            if due.isEmpty { request.clearDue = true } else { request.due = due }
        }
        request.addLinks = args.strings("add_links") ?? []
        let unlinkIDs = args.strings("unlink_sessions") ?? []
        let unlinkSelf = args.bool("unlink_session") == true
        var unlinks: [String] = []
        if args["board"] != nil || args["remove_links"] != nil || !unlinkIDs.isEmpty || unlinkSelf {
            let snapshot = try await client.snapshot()
            guard let task = snapshot.tasks.first(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
            if let value = args.string("board") {
                let board = try Self.board(value, in: snapshot.boards)
                if board.id != task.boardID { request.boardID = board.id }
            }
            request.removeLinkIDs = try Self.linkIDs(args["remove_links"], in: task)
            unlinks = try unlinkIDs.map { try Self.sessionID($0, in: task) }
            if unlinkSelf {
                guard let own = currentAgentSessionID(snapshot) else { throw ToolError.unidentified }
                guard task.sessions.contains(where: { $0.sessionID == own }) else {
                    throw ToolError.invalid(Copy.text("agent.mcp.core.board.3", ["number": "\(number)"]))
                }
                unlinks.append(own)
            }
        }
        var task = try await client.updateTask(number: number, request)
        for sessionID in Self.unique(unlinks) {
            task = try await client.unlinkSession(task: number, sessionID: sessionID)
        }
        var lines = [Copy.text("agent.mcp.core.lines.14"), Copy.text("agent.mcp.core.lines.12", ["number": "\(task.number)", "title": "\(task.title)"]), Copy.text("agent.mcp.core.lines.7", ["columnID": "\(task.columnID)"])]
        if request.columnID != nil || request.boardID != nil, let board = try await client.snapshot().boards.first(where: { $0.id == task.boardID }) {
            if request.boardID != nil { lines.append(Copy.text("agent.mcp.core.lines.15", ["name": "\(board.name)", "id": "\(board.id)"])) }
            if let column = board.columns.first(where: { $0.id == task.columnID }) { lines.append(Copy.text("agent.mcp.core.lines.16") + SessionGuidance.columnLine(column)) }
            if request.boardID != nil { lines.append(Copy.text("agent.mcp.core.lines.17")) }
        }
        if !request.removeLinkIDs.isEmpty { lines.append(Copy.text("agent.mcp.core.lines.18", ["removeLinkIDs": "\(request.removeLinkIDs.count)"])) }
        for sessionID in Self.unique(unlinks) { lines.append(Copy.text("agent.mcp.core.lines.19", ["sessionID": "\(sessionID.prefix(8))"])) }
        if args.bool("link_session") == true {
            lines.append(Copy.text("agent.mcp.core.lines.13") + (try await linkCurrentSession(to: number).note))
        }
        return lines.joined(separator: "\n")
    }

    private func workList(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        let snapshot = try await client.snapshot()
        guard let task = snapshot.tasks.first(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
        var header = Copy.text("agent.mcp.core.header", ["number": "\(number)"])
        if let count = await linkNoticeCount(task) { header += "\n" + Self.linkNoticeLine(count) }
        return header + "\n" + Self.describeWork(snapshot.workItems.filter { $0.taskNumber == number })
    }

    private func workAdd(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        guard let title = args.string("title"), !title.isEmpty else { throw ToolError.missing("title") }
        var request = WorkItemCreateRequest(title: title, source: "session")
        if let state = args.string("state") {
            guard let value = WorkItem.State(rawValue: state) else { throw ToolError.invalid(Self.invalidChoice("state", Self.workStates)) }
            request.state = value
        }
        request.dependsOn = Self.ids(args["depends_on"])
        request.owner = args.string("owner") ?? ""
        if let kind = args.string("blocker_kind") {
            guard let value = WorkItem.BlockerKind(rawValue: kind) else { throw ToolError.invalid(Self.invalidChoice("blocker_kind", Self.blockerKinds)) }
            request.blockerKind = value
            request.blockerTone = value.defaultTone
        }
        request.blockerText = args.string("blocker_text") ?? ""
        if let kind = args.string("deliverable_kind") {
            guard let value = WorkItem.DeliverableKind(rawValue: kind) else { throw ToolError.invalid(Self.invalidChoice("deliverable_kind", Self.deliverableKinds)) }
            request.deliverableKind = value
        }
        request.deliverableRef = args.string("deliverable_ref") ?? ""
        request.position = args.int("position")
        request.group = args.string("group") ?? ""
        request.code = args.string("code") ?? ""
        let item = try await client.createWorkItem(task: number, request)
        return Copy.text("agent.mcp.core.item", ["itemID": "\(item.itemID)", "title": "\(item.codedTitle)", "state": "\(item.state.rawValue)", "number": "\(number)"])
    }

    private func workUpdate(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("id") else { throw ToolError.missing("id") }
        var request = WorkItemUpdateRequest()
        request.title = args.string("title")
        if let state = args.string("state") {
            guard let value = WorkItem.State(rawValue: state) else { throw ToolError.invalid(Self.invalidChoice("state", Self.workStates)) }
            request.state = value
        }
        if let kind = args.string("blocker_kind") {
            guard let value = WorkItem.BlockerKind(rawValue: kind) else { throw ToolError.invalid(Self.invalidChoice("blocker_kind", Self.blockerKinds)) }
            request.blockerKind = value
            request.blockerTone = value.defaultTone
        }
        request.blockerText = args.string("blocker_text")
        if args["depends_on"] != nil { request.dependsOn = Self.ids(args["depends_on"]) }
        request.owner = args.string("owner")
        if let kind = args.string("deliverable_kind") {
            guard let value = WorkItem.DeliverableKind(rawValue: kind) else { throw ToolError.invalid(Self.invalidChoice("deliverable_kind", Self.deliverableKinds)) }
            request.deliverableKind = value
        }
        request.deliverableRef = args.string("deliverable_ref")
        request.position = args.int("position")
        request.group = args.string("group")
        request.code = args.string("code")
        if request.state == .wait, request.blockerKind == nil, request.blockerText == nil {
            throw ToolError.invalid(Copy.text("agent.mcp.core.request"))
        }
        let item = try await client.updateWorkItem(id: id, request)
        return Copy.text("agent.mcp.core.item.2", ["itemID": "\(item.itemID)", "title": "\(item.codedTitle)", "state": "\(item.state.rawValue)"])
    }

    private static let workStates = ["todo", "doing", "wait", "done", "drop"]
    private static let blockerKinds = WorkItem.BlockerKind.allCases.map(\.rawValue)
    private static let deliverableKinds = ["pr", "commit", "file", "doc"]

    /// enum の引数に、選択肢に無い値が渡されたときの誤り
    static func invalidChoice(_ name: String, _ choices: [String]) -> String {
        Copy.text("agent.mcp.core.invalidChoice", ["name": name, "choices": choices.joined(separator: "・")])
    }

    static func ids(_ value: Value?) -> [Int64] {
        value?.arrayValue?.compactMap { $0.intValue.map(Int64.init) ?? $0.stringValue.flatMap(Int64.init) } ?? []
    }
}
