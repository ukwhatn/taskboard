import Foundation
import MCP
import TaskboardKit

/// 案件・タスク・作業項目・文書・質問・定期起動の管理の tool。消す tool は、confirm: true が無ければ何が消えるかを返すだけで消さない
/// （全体の health を保つオーケストレーターが、誤って消さないため）
extension TaskboardTools {
    static let boardArgumentDescription = Copy.text("agent.mcp.manage.boardArgumentDescription")

    static let confirmProperty: Value = property("boolean", Copy.text("agent.mcp.manage.confirmProperty"))

    static let columnEditSchema: Value = schema([
        "id": property("string"),
        "label": property("string", Copy.text("agent.tool.columnEditSchema.label")),
        "description": property("string", Copy.text("agent.tool.columnEditSchema.description")),
        "collapsed": property("boolean", Copy.text("agent.tool.columnEditSchema.collapsed")),
        "prompt_template": property("string", Copy.text("agent.tool.columnEditSchema.prompt_template")),
    ], required: ["id"])

    static let columnAddSchema: Value = schema([
        "label": property("string"),
        "description": property("string"),
        "kind": property("string", Copy.text("agent.tool.columnAddSchema.kind"), enum: ["open", "terminal"]),
        "after": property("string", Copy.text("agent.tool.columnAddSchema.after")),
    ], required: ["label"])

    static let manageTools: [ToolEntry] = [
        ToolEntry(
            name: "board_create", description: Copy.text("agent.tool.board_create"),
            inputSchema: schema(["name": property("string")], required: ["name"])) { tools, args in try await tools.boardCreate(args) },
        ToolEntry(
            name: "board_update",
            description: Copy.text("agent.tool.board_update"),
            inputSchema: schema([
                "board": property("string", Copy.text("agent.tool.board_update.board")),
                "name": property("string"),
                "prompt_template": property("string", Copy.unfilled("agent.tool.board_update.prompt_template")),
                "merge_target": property("string", Copy.text("agent.tool.board_update.merge_target"), enum: MergeTarget.allCases.map(\.rawValue)),
                "archived": property("boolean", Copy.text("agent.tool.board_update.archived")),
                "edit_columns": property("array", items: columnEditSchema),
                "add_columns": property("array", items: columnAddSchema),
                "remove_columns": property("array", Copy.text("agent.tool.board_update.remove_columns"), items: property("string")),
                "reassign": .object([
                    "type": .string("object"), "additionalProperties": property("string"),
                    "description": .string(Copy.text("agent.mcp.manage.manageTools")),
                ]),
            ], required: ["board"])) { tools, args in try await tools.boardUpdate(args) },
        ToolEntry(
            name: "board_delete", description: Copy.text("agent.tool.board_delete"),
            inputSchema: schema(["board": property("string", Copy.text("agent.tool.board_update.board")), "confirm": confirmProperty], required: ["board"])) { tools, args in try await tools.boardDelete(args) },
        ToolEntry(
            name: "task_delete",
            description: Copy.text("agent.tool.task_delete"),
            inputSchema: schema(["task_id": property("integer", Copy.text("agent.tool.task_delete.task_id")), "confirm": confirmProperty], required: ["task_id"])) { tools, args in try await tools.taskDelete(args) },
        ToolEntry(
            name: "work_delete",
            description: Copy.text("agent.tool.work_delete"),
            inputSchema: schema(["id": property("integer"), "confirm": confirmProperty], required: ["id"])) { tools, args in try await tools.workDelete(args) },
        ToolEntry(
            name: "doc_read", description: Copy.text("agent.tool.doc_read"),
            inputSchema: schema([
                "doc_id": property("integer", Copy.text("agent.tool.doc_read.doc_id")),
                "rev": property("integer", Copy.text("agent.tool.doc_read.rev")),
            ], required: ["doc_id"])) { tools, args in try await tools.docRead(args) },
        ToolEntry(
            name: "doc_delete", description: Copy.text("agent.tool.doc_delete"),
            inputSchema: schema(["doc_id": property("integer"), "confirm": confirmProperty], required: ["doc_id"])) { tools, args in try await tools.docDelete(args) },
        ToolEntry(
            name: "ask_cancel", description: Copy.text("agent.tool.ask_cancel"),
            inputSchema: schema(["ask_id": property("integer", Copy.text("agent.tool.ask_cancel.ask_id"))], required: ["ask_id"])) { tools, args in try await tools.askCancel(args) },
        ToolEntry(
            name: "schedule_delete", description: Copy.text("agent.tool.schedule_delete"),
            inputSchema: schema(["id": property("integer"), "confirm": confirmProperty], required: ["id"])) { tools, args in try await tools.scheduleDelete(args) },
        ToolEntry(
            name: "schedule_runs", description: Copy.text("agent.tool.schedule_runs"),
            inputSchema: schema(["id": property("integer"), "limit": property("integer", Copy.text("agent.tool.schedule_runs.limit"))], required: ["id"])) { tools, args in try await tools.scheduleRuns(args) },
    ]

    // MARK: 解決

    /// 案件を id か名前で引く。名前は大文字小文字を区別せずに比べ、重なれば候補を返す。nil は既定の起票先
    static func board(_ value: String?, in boards: [Board]) throws -> Board {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            guard let board = boards.defaultBoard else { throw ToolError.invalid(Copy.text("agent.mcp.manage.board")) }
            return board
        }
        if let board = boards.first(where: { $0.id == value }) ?? boards.first(where: { $0.name == value }) { return board }
        let named = boards.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
        if named.count == 1 { return named[0] }
        let list = (named.isEmpty ? boards : named).map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        if named.isEmpty { throw ToolError.invalid(Copy.text("agent.mcp.manage.list", ["value": "\(value)"]) + list) }
        throw ToolError.invalid(Copy.text("agent.mcp.manage.list.2", ["value": "\(value)", "named": "\(named.count)"]) + list)
    }

    /// リンクの id（数）か URL を、タスクのリンクの id に
    static func linkIDs(_ value: Value?, in task: BoardTask) throws -> [Int64] {
        try (value?.arrayValue ?? []).map { item in
            if let id = item.intValue.map(Int64.init) ?? item.stringValue.flatMap(Int64.init) {
                guard task.links.contains(where: { $0.id == id }) else { throw ToolError.invalid(Copy.text("agent.mcp.manage.linkIDs", ["id": "\(id)", "number": "\(task.number)"])) }
                return id
            }
            guard let url = item.stringValue, let link = task.links.first(where: { $0.url == url }) else {
                throw ToolError.invalid(Copy.text("agent.mcp.manage.linkIDs.2", ["stringValue": "\(item.stringValue ?? "")", "number": "\(task.number)"]))
            }
            return link.id
        }
    }

    /// タスクに紐づくセッションの ID。完全に一致するか、8 字以上の先頭で 1 つに決まるもの
    static func sessionID(_ given: String, in task: BoardTask) throws -> String {
        let ids = Array(Set(task.sessions.map(\.sessionID)))
        if ids.contains(given) { return given }
        let matched = given.count >= 8 ? ids.filter { $0.hasPrefix(given) } : []
        guard matched.count == 1 else {
            throw ToolError.invalid(
                Copy.text("agent.mcp.manage.matched", ["given": "\(given)", "number": "\(task.number)"]) + (ids.isEmpty ? Copy.text("agent.mcp.manage.matched.2") : ids.sorted().joined(separator: ", ")))
        }
        return matched[0]
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func isConfirmed(_ args: [String: Value]) -> Bool { args.bool("confirm") == true }

    /// 消す（`stopping` なら止める）前に返す文。`lines` は何が消えるか
    static func confirmation(_ lines: [String], stopping: Bool = false) -> String {
        let head = stopping ? [Copy.text("agent.mcp.manage.head"), Copy.text("agent.mcp.manage.head.2")] : [Copy.text("agent.mcp.manage.head.3"), Copy.text("agent.mcp.manage.head.4")]
        let tail = stopping ? Copy.text("agent.mcp.manage.tail") : Copy.text("agent.mcp.manage.tail.2")
        return (head + lines.map { "- " + $0 } + [tail]).joined(separator: "\n")
    }

    // MARK: 案件

    static func describe(board: Board) -> String {
        var lines = [Copy.text("agent.mcp.core.lines.4", ["name": "\(board.name)", "id": "\(board.id)"]) + (board.archived ? Copy.text("agent.mcp.core.lines.2") : ""), Copy.text("agent.mcp.manage.lines", ["columnID": "\(board.mergeTarget.columnID)"]), Copy.text("agent.mcp.manage.lines.2")]
        lines += board.orderedColumns.map { column in
            var flags: [String] = []
            if column.kind == .terminal { flags.append(Copy.text("agent.mcp.manage.flags")) }
            if column.promptTemplate.map({ !$0.isEmpty }) ?? false { flags.append(Copy.text("agent.mcp.manage.flags.2")) }
            return "  - " + SessionGuidance.columnLine(column) + flags.map { " ・ " + $0 }.joined()
        }
        return lines.joined(separator: "\n")
    }

    private func boardCreate(_ args: [String: Value]) async throws -> String {
        guard let name = args.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError.missing("name") }
        return Copy.text("agent.mcp.manage.boardCreate") + Self.describe(board: try await client.createBoard(BoardCreateRequest(name: name)))
    }

    /// 今の列から、編集・削除・追加を当てた列の全体（`BoardUpdateRequest.columns` は置き換え）
    static func columnEdits(_ board: Board, edit: [Value], add: [Value], remove: [String]) throws -> [BoardColumnEdit] {
        var columns = board.orderedColumns.map {
            BoardColumnEdit(id: $0.id, label: $0.label, kind: $0.kind, collapsed: $0.collapsed)
        }
        for value in edit {
            guard let object = value.objectValue, let id = object["id"]?.stringValue else { throw ToolError.invalid(Copy.text("agent.mcp.manage.columns")) }
            guard let index = columns.firstIndex(where: { $0.id == id }) else { throw ToolError.invalid(Copy.text("agent.mcp.manage.columns.2", ["id": "\(id)", "name": "\(board.name)"])) }
            if let label = object["label"]?.stringValue { columns[index].label = label }
            if let description = object["description"]?.stringValue { columns[index].description = description }
            if let collapsed = object["collapsed"]?.boolValue { columns[index].collapsed = collapsed }
            if let template = object["prompt_template"]?.stringValue { columns[index].promptTemplate = template }
        }
        for id in remove {
            guard columns.contains(where: { $0.id == id }) else { throw ToolError.invalid(Copy.text("agent.mcp.manage.columns.2", ["id": "\(id)", "name": "\(board.name)"])) }
            guard id != BoardColumn.doneID else { throw ToolError.invalid(Copy.text("agent.mcp.manage.columns.3")) }
            columns.removeAll { $0.id == id }
        }
        for value in add {
            guard let object = value.objectValue, let label = object["label"]?.stringValue, !label.isEmpty else {
                throw ToolError.invalid(Copy.text("agent.mcp.manage.columns.4"))
            }
            let kind = try object["kind"]?.stringValue.map { raw in
                guard let kind = BoardColumn.Kind(rawValue: raw) else { throw ToolError.invalid(Self.invalidChoice("kind", ["open", "terminal"])) }
                return kind
            } ?? .open
            let column = BoardColumnEdit(id: nil, label: label, kind: kind, collapsed: kind == .terminal, description: object["description"]?.stringValue)
            if let after = object["after"]?.stringValue {
                guard let index = columns.firstIndex(where: { $0.id == after }) else { throw ToolError.invalid(Copy.text("agent.mcp.manage.column", ["after": "\(after)"])) }
                columns.insert(column, at: index + 1)
            } else {
                let lastOpen = columns.lastIndex { $0.kind == .open }.map { $0 + 1 } ?? 0
                columns.insert(column, at: kind == .open ? lastOpen : columns.count)
            }
        }
        return columns
    }

    private func boardUpdate(_ args: [String: Value]) async throws -> String {
        let snapshot = try await client.snapshot()
        guard let value = args.string("board"), !value.isEmpty else { throw ToolError.missing("board") }
        let board = try Self.board(value, in: snapshot.boards)
        var request = BoardUpdateRequest()
        request.name = args.string("name")
        request.promptTemplate = args.string("prompt_template")
        request.archived = args.bool("archived")
        if let raw = args.string("merge_target") {
            guard let target = MergeTarget(rawValue: raw) else { throw ToolError.invalid(Self.invalidChoice("merge_target", ["deploying", "done"])) }
            request.mergeTarget = target
        }
        let edit = args.array("edit_columns") ?? []
        let add = args.array("add_columns") ?? []
        let remove = args.strings("remove_columns") ?? []
        if !edit.isEmpty || !add.isEmpty || !remove.isEmpty {
            request.columns = try Self.columnEdits(board, edit: edit, add: add, remove: remove)
        }
        if let reassign = args["reassign"]?.objectValue {
            request.reassign = reassign.compactMapValues(\.stringValue)
        }
        guard request != BoardUpdateRequest() else { throw ToolError.invalid(Copy.text("agent.mcp.manage.remove")) }
        let updated = try await client.updateBoard(id: board.id, request)
        return Copy.text("agent.mcp.manage.updated") + Self.describe(board: updated)
    }

    private func boardDelete(_ args: [String: Value]) async throws -> String {
        let snapshot = try await client.snapshot()
        guard let value = args.string("board"), !value.isEmpty else { throw ToolError.missing("board") }
        let board = try Self.board(value, in: snapshot.boards)
        let tasks = snapshot.tasks.filter { $0.boardID == board.id }
        guard tasks.isEmpty else {
            throw ToolError.invalid(Copy.text("agent.mcp.manage.tasks", ["name": "\(board.name)", "tasks": "\(tasks.count)"]))
        }
        guard Self.isConfirmed(args) else {
            return Self.confirmation([Copy.text("agent.mcp.manage.tasks.2", ["name": "\(board.name)", "id": "\(board.id)", "columns": "\(board.columns.count)"])])
        }
        try await client.deleteBoard(id: board.id)
        return Copy.text("agent.mcp.manage.tasks.3", ["name": "\(board.name)", "id": "\(board.id)"])
    }

    // MARK: タスク・作業項目

    private func taskDelete(_ args: [String: Value]) async throws -> String {
        guard let number = args.int("task_id") ?? args.string("task_id").flatMap(Int.init) else { throw ToolError.missing("task_id") }
        let snapshot = try await client.snapshot()
        guard let task = snapshot.tasks.first(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
        guard Self.isConfirmed(args) else {
            let board = snapshot.boards.first { $0.id == task.boardID }
            let live = snapshot.conversations.filter { $0.taskNumber == number && $0.phase != .stopped && !$0.isClosed }
            var lines = [Copy.text("agent.mcp.manage.lines.3", ["number": "\(task.number)", "title": "\(task.title)", "board": "\(board?.name ?? task.boardID)", "columnID": "\(task.columnID)"])]
            lines.append(Copy.text("agent.mcp.manage.lines.4", ["filter": "\(snapshot.workItems.filter { $0.taskNumber == number }.count)", "filter2": "\(snapshot.documents.filter { $0.taskNumber == number }.count)", "links": "\(task.links.count)"]))
            lines.append(Copy.text("agent.mcp.manage.lines.5", ["Set": "\(Set(task.sessions.map(\.sessionID)).count)", "live": "\(live.count)"]))
            let schedules = snapshot.schedules.filter { $0.taskNumber == number }
            if !schedules.isEmpty { lines.append(Copy.text("agent.mcp.manage.schedules") + schedules.map { "[\($0.scheduleID)] \($0.name)" }.joined(separator: ", ")) }
            if let current = currentAgentSessionID(snapshot), task.sessions.contains(where: { $0.sessionID == current }) {
                lines.append(Copy.text("agent.mcp.manage.schedules.2"))
            }
            return Self.confirmation(lines)
        }
        try await client.deleteTask(number: number)
        return Copy.text("agent.mcp.manage.schedules.3", ["number": "\(number)", "title": "\(task.title)"])
    }

    private func workDelete(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("id") else { throw ToolError.missing("id") }
        let snapshot = try await client.snapshot()
        guard let item = snapshot.workItems.first(where: { $0.itemID == id }) else { throw ToolError.invalid(Copy.text("agent.mcp.manage.snapshot", ["id": "\(id)"])) }
        guard Self.isConfirmed(args) else {
            var lines = [Copy.text("agent.mcp.manage.lines.6", ["itemID": "\(item.itemID)", "state": "\(item.state.rawValue)", "title": "\(item.codedTitle)", "taskNumber": "\(item.taskNumber)"])]
            let dependents = snapshot.workItems.filter { $0.taskNumber == item.taskNumber && $0.dependsOn.contains(id) }
            if !dependents.isEmpty { lines.append(Copy.text("agent.mcp.manage.dependents") + dependents.map { "[\($0.itemID)] \($0.codedTitle)" }.joined(separator: ", ")) }
            return Self.confirmation(lines)
        }
        try await client.deleteWorkItem(id: id)
        return Copy.text("agent.mcp.manage.dependents.2", ["id": "\(id)", "title": "\(item.title)"])
    }

    // MARK: 文書・質問

    private func docRead(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("doc_id") else { throw ToolError.missing("doc_id") }
        let content = try await client.documentContent(id: id, rev: args.int("rev"))
        var lines = [Copy.text("agent.mcp.manage.lines.7", ["id": "\(id)", "rev": "\(content.rev)", "format": "\(content.format.rawValue)"]), "", content.content]
        let open = try await client.comments(doc: id).filter { $0.state == .open }
        if !open.isEmpty {
            lines += ["", Copy.text("agent.mcp.manage.open", ["open": "\(open.count)"])]
            for comment in open {
                lines.append("- [\(comment.id)] rev \(comment.rev): \(comment.body)")
                for reply in comment.replies where reply.state == .submitted {
                    lines.append("  - \(reply.author == .agent ? "エージェント" : "人"): \(reply.body)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func docDelete(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("doc_id") else { throw ToolError.missing("doc_id") }
        let snapshot = try await client.snapshot()
        guard let doc = snapshot.documents.first(where: { $0.docID == id }) else { throw ToolError.invalid(Copy.text("agent.mcp.manage.snapshot.2", ["id": "\(id)"])) }
        guard Self.isConfirmed(args) else {
            let asks = snapshot.asks.filter { $0.docID == id && $0.status == .open }
            return Self.confirmation([
                Copy.text("agent.mcp.manage.asks", ["docID": "\(doc.docID)", "name": "\(doc.name)", "taskNumber": "\(doc.taskNumber)", "latestRev": "\(doc.latestRev)", "openComments": "\(doc.openComments)", "asks": "\(asks.count)"])
            ])
        }
        try await client.deleteDocument(id: id)
        return Copy.text("agent.mcp.manage.asks.2", ["id": "\(id)", "name": "\(doc.name)"])
    }

    private func askCancel(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("ask_id") else { throw ToolError.missing("ask_id") }
        let snapshot = try await client.snapshot()
        if let ask = snapshot.asks.first(where: { $0.askID == id }), ask.status != .open {
            throw ToolError.invalid(Copy.text("agent.mcp.manage.snapshot.3", ["id": "\(id)", "status": "\(ask.status.rawValue)"]))
        }
        try await client.cancelAsk(id: id)
        return Copy.text("agent.mcp.manage.snapshot.4", ["id": "\(id)"])
    }

    // MARK: 定期起動

    private func scheduleDelete(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("id") else { throw ToolError.missing("id") }
        guard let schedule = try await client.schedules().first(where: { $0.scheduleID == id }) else { throw ToolError.invalid(Copy.text("agent.mcp.manage.scheduleDelete", ["id": "\(id)"])) }
        guard Self.isConfirmed(args) else {
            return Self.confirmation([Self.describe(schedule), Copy.text("agent.mcp.manage.scheduleDelete.2")])
        }
        try await client.deleteSchedule(id: id)
        return Copy.text("agent.mcp.manage.scheduleDelete.3", ["id": "\(id)", "name": "\(schedule.name)"])
    }

    private func scheduleRuns(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("id") else { throw ToolError.missing("id") }
        let runs = try await client.scheduleRuns(id: id).sorted { $0.scheduledAt > $1.scheduledAt }
        guard !runs.isEmpty else { return Copy.text("agent.mcp.manage.runs", ["id": "\(id)"]) }
        let limit = max(1, args.int("limit") ?? 10)
        return ([Copy.text("agent.mcp.manage.limit", ["id": "\(id)", "runs": "\(runs.count)", "min": "\(min(limit, runs.count))"])] + runs.prefix(limit).map(Self.describe(run:))).joined(separator: "\n")
    }

    static func describe(run: ScheduleRun) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var line = Copy.text("agent.mcp.manage.run", ["id": "\(run.id)", "trigger": Copy.text(run.trigger == .manual ? "agent.mcp.manage.manual" : "agent.mcp.manage.scheduled"), "scheduledAt": formatter.string(from: run.scheduledAt)])
        switch run.outcome {
        case .skipped: line += Copy.text("agent.mcp.manage.skipped", ["skipped": "\(run.skipped ?? "")"])
        case .launched: line += Copy.text("agent.mcp.manage.launched")
        case .failed: line += Copy.text("agent.mcp.manage.failed", ["error": run.error ?? Copy.text("agent.mcp.manage.noReason")])
        case .launching: line += Copy.text("agent.mcp.manage.launching", ["stage": "\(run.stage?.rawValue ?? "")"])
        case .notStarted: line += Copy.text("agent.mcp.manage.notStarted")
        }
        if let id = run.conversationID { line += Copy.text("agent.mcp.manage.notStarted.2", ["id": "\(id)"]) }
        return line
    }
}
