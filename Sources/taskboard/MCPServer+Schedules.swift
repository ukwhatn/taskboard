import Foundation
import MCP
import TaskboardKit

/// 定期起動の tool
extension TaskboardTools {
    static let scheduleTools: [ToolEntry] = [
        ToolEntry(
            name: "schedule_list", description: Copy.text("agent.tool.schedule_list"),
            inputSchema: schema([:])) { tools, _ in try await tools.scheduleList() },
        ToolEntry(
            name: "schedule_create",
            description: Copy.text("agent.tool.schedule_create"),
            inputSchema: schema([
                "name": property("string"),
                "cron": property("string", Copy.text("agent.tool.schedule_create.cron")),
                "interval_minutes": property("integer", Copy.text("agent.tool.schedule_create.interval_minutes")),
                "cwd": property("string"),
                "agent": property("string", enum: ["claude", "codex"]),
                "agent_args": property("array", Copy.text("agent.tool.schedule_create.agent_args"), items: property("string")),
                "prompt": property("string", Copy.unfilled("agent.tool.schedule_create.prompt")),
                "task_id": property("integer", Copy.text("agent.tool.schedule_create.task_id")),
                "new_task": property("boolean", Copy.text("agent.tool.schedule_create.new_task")),
                "board": property("string", Copy.text("agent.tool.schedule_create.board")),
                "overlap": property("string", Copy.text("agent.tool.schedule_create.overlap"), enum: ["skip", "parallel"]),
            ], required: ["name", "cwd", "prompt"])) { tools, args in try await tools.scheduleCreate(args) },
        ToolEntry(
            name: "schedule_update", description: Copy.text("agent.tool.schedule_update"),
            inputSchema: schema([
                "id": property("integer"),
                "enabled": property("boolean"),
                "name": property("string"),
                "cron": property("string"),
                "interval_minutes": property("integer"),
                "cwd": property("string"),
                "prompt": property("string"),
                "overlap": property("string", enum: ["skip", "parallel"]),
                "agent": property("string", enum: ["claude", "codex"]),
                "agent_args": property("array", items: property("string")),
                "task_id": property("integer", Copy.text("agent.tool.schedule_update.task_id")),
                "new_task": property("boolean", Copy.text("agent.tool.schedule_update.new_task")),
                "board": property("string", Copy.text("agent.tool.schedule_create.board")),
                "clear_task": property("boolean", Copy.text("agent.tool.schedule_update.clear_task")),
            ], required: ["id"])) { tools, args in try await tools.scheduleUpdate(args) },
        ToolEntry(
            name: "schedule_run", description: Copy.text("agent.tool.schedule_run"),
            inputSchema: schema(["id": property("integer")], required: ["id"])) { tools, args in try await tools.scheduleRun(args) },
    ]

    static func rule(_ args: [String: Value]) throws -> ScheduleRule? {
        let cron = args.string("cron")
        let minutes = args.int("interval_minutes")
        switch (cron, minutes) {
        case (nil, nil): return nil
        case (let cron?, nil): return .cron(cron)
        case (nil, let minutes?): return .interval(minutes: minutes)
        default: throw ToolError.invalid(Copy.text("agent.mcp.schedules.minutes"))
        }
    }

    /// 定期起動 1 件。1 行目が `[id] 名前`、続きは `  - ` の項目（呼び出し側が `- ` を前に付ける）
    static func describe(_ schedule: Schedule) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var lines = [Copy.text("agent.mcp.schedules.summary", ["id": "\(schedule.scheduleID)", "name": schedule.name, "state": Copy.text(schedule.enabled ? "agent.mcp.schedules.enabled" : "agent.mcp.schedules.disabled"), "rule": schedule.rule.summary])]
        lines.append(Copy.text("agent.mcp.schedules.lines", ["kind": "\(schedule.kind.rawValue)", "cwd": "\(schedule.cwd)"]))
        if let task = schedule.taskNumber { lines.append(Copy.text("agent.mcp.schedules.lines.2", ["task": "\(task)"])) }
        if let next = schedule.nextAt { lines.append(Copy.text("agent.mcp.schedules.lines.3", ["formatter": "\(formatter.string(from: next))"])) }
        if let run = schedule.lastRun {
            let result = run.skipped ?? run.error ?? run.stage?.rawValue ?? Copy.text("agent.mcp.schedules.result")
            lines.append(Copy.text("agent.mcp.schedules.result.2", ["formatter": "\(formatter.string(from: run.scheduledAt))", "result": "\(result)"]) + (run.conversationID.map { Copy.text("agent.mcp.schedules.result.3", ["value": "\($0)"]) } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    private func scheduleList() async throws -> String {
        let schedules = try await client.schedules()
        return schedules.isEmpty ? Copy.text("agent.mcp.schedules.schedules") : ([Copy.text("agent.mcp.schedules.schedules.2", ["schedules": "\(schedules.count)"])] + schedules.map { "- " + Self.describe($0) }).joined(separator: "\n")
    }

    private func scheduleCreate(_ args: [String: Value]) async throws -> String {
        guard let name = args.string("name"), !name.isEmpty else { throw ToolError.missing("name") }
        guard let rule = try Self.rule(args) else { throw ToolError.missing(Copy.text("agent.mcp.schedules.scheduleCreate")) }
        guard let cwd = args.string("cwd") else { throw ToolError.missing("cwd") }
        guard let prompt = args.string("prompt") else { throw ToolError.missing("prompt") }
        let kind = try args.string("agent").map { value in
            guard let kind = AgentKind(rawValue: value) else { throw ToolError.invalid(Self.invalidChoice("agent", ["claude", "codex"])) }
            return kind
        } ?? .claude
        var newTask: ScheduleCreateRequest.NewTask?
        if args.bool("new_task") == true {
            newTask = try await newScheduleTask(board: args.string("board"))
        }
        let overlap = try args.string("overlap").map { value in
            guard let overlap = ScheduleOverlap(rawValue: value) else { throw ToolError.invalid(Self.invalidChoice("overlap", ["skip", "parallel"])) }
            return overlap
        } ?? .skip
        let schedule = try await client.createSchedule(
            ScheduleCreateRequest(
                name: name, rule: rule, cwd: cwd, kind: kind, agentArgs: args.strings("agent_args") ?? [], prompt: prompt,
                taskNumber: args.int("task_id"), newTask: newTask, overlap: overlap))
        return Copy.text("agent.mcp.schedules.schedule") + Self.describe(schedule)
    }

    private func scheduleUpdate(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("id") else { throw ToolError.missing("id") }
        var request = ScheduleUpdateRequest()
        request.enabled = args.bool("enabled")
        request.name = args.string("name")
        request.rule = try Self.rule(args)
        request.cwd = args.string("cwd")
        request.prompt = args.string("prompt")
        if let value = args.string("overlap") {
            guard let overlap = ScheduleOverlap(rawValue: value) else { throw ToolError.invalid(Self.invalidChoice("overlap", ["skip", "parallel"])) }
            request.overlap = overlap
        }
        if let value = args.string("agent") {
            guard let kind = AgentKind(rawValue: value) else { throw ToolError.invalid(Self.invalidChoice("agent", ["claude", "codex"])) }
            request.kind = kind
        }
        request.agentArgs = args.strings("agent_args")
        let retarget = [args["task_id"] != nil, args.bool("new_task") == true, args.bool("clear_task") == true].filter { $0 }.count
        guard retarget <= 1 else { throw ToolError.invalid(Copy.text("agent.mcp.schedules.retarget")) }
        request.taskNumber = args.int("task_id")
        request.clearTask = args.bool("clear_task") == true
        if args.bool("new_task") == true { request.newTask = try await newScheduleTask(board: args.string("board")) }
        return Copy.text("agent.mcp.schedules.retarget.2") + Self.describe(try await client.updateSchedule(id: id, request))
    }

    /// 定期起動の常設タスクを新しく作る先。列は起票の既定（常設の列は人が選ぶ。起票の受け皿にしない）
    private func newScheduleTask(board value: String?) async throws -> ScheduleCreateRequest.NewTask {
        let board = try Self.board(value, in: try await client.snapshot().boards)
        guard let column = board.defaultColumn ?? board.columns.first else { throw ToolError.invalid(Copy.text("agent.mcp.schedules.board", ["name": "\(board.name)"])) }
        return .init(boardID: board.id, columnID: column.id)
    }

    private func scheduleRun(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("id") else { throw ToolError.missing("id") }
        let run = try await client.runSchedule(id: id)
        if let skipped = run.skipped { return Copy.text("agent.mcp.schedules.run", ["skipped": "\(skipped)"]) }
        var lines = [Copy.text("agent.mcp.schedules.lines.4"), Copy.text("agent.mcp.schedules.lines.5", ["id": "\(run.id)"])]
        if let requestID = run.requestID { lines.append("- request_id: \(requestID)") }
        lines.append(Copy.text("agent.mcp.schedules.lines.6"))
        return lines.joined(separator: "\n")
    }
}
