import Foundation
import MCP
import TaskboardKit

/// セッションの操作・オーケストレーター・マシンの設定・受信箱・PR・利用枠と、全体の状態（`health`）の tool。
/// 主にオーケストレーターが全体の health を保つために使う
extension TaskboardTools {
    static let healthTools: [ToolEntry] = [
        ToolEntry(
            name: "health",
            description: Copy.text("agent.tool.health"),
            inputSchema: schema([:])) { tools, _ in try await tools.health() },
        ToolEntry(
            name: "session_stop",
            description:
                Copy.text("agent.tool.session_stop"),
            inputSchema: schema([
                "conversation_id": conversationProperty,
                "force": property("boolean", Copy.text("agent.tool.session_stop.force")), "confirm": confirmProperty,
                "close": property("boolean", Copy.text("agent.tool.session_stop.close")),
            ], required: ["conversation_id"])) { tools, args in try await tools.sessionStop(args) },
        ToolEntry(
            name: "session_exit",
            description:
                Copy.text("agent.tool.session_exit"),
            inputSchema: schema([:])) { tools, _ in try await tools.sessionExit() },
        ToolEntry(
            name: "session_resume",
            description: Copy.text("agent.tool.session_resume"),
            inputSchema: schema([
                "conversation_id": conversationProperty,
                "task_id": property("integer", Copy.text("agent.mcp.core.currentTaskIDProperty")),
                "account": accountProperty,
                "session_id": property("string", Copy.text("agent.tool.session_resume.session_id")),
            ])) { tools, args in try await tools.sessionResume(args) },
        ToolEntry(
            name: "session_history",
            description:
                Copy.text("agent.tool.session_history"),
            inputSchema: schema([
                "task_id": property("integer"), "conversation_id": conversationProperty,
                "limit": property("integer", Copy.text("agent.tool.session_history.limit")),
            ])) { tools, args in try await tools.sessionHistory(args) },
        ToolEntry(
            name: "session_rename", description: Copy.text("agent.tool.session_rename"),
            inputSchema: schema(["conversation_id": conversationProperty, "label": property("string")], required: ["conversation_id", "label"])) { tools, args in try await tools.sessionRename(args) },
        ToolEntry(
            name: "orchestrator_status", description: Copy.text("agent.tool.orchestrator_status"),
            inputSchema: schema([:])) { tools, _ in Self.describe(orchestrator: try await tools.client.orchestrator()) },
        ToolEntry(
            name: "orchestrator_start", description: Copy.text("agent.tool.orchestrator_start"),
            inputSchema: schema([
                "model": claudeModelProperty,
                "effort": property("string", enum: Effort.allCases.map(\.rawValue)),
            ])) { tools, args in try await tools.orchestratorStart(args) },
        ToolEntry(
            name: "orchestrator_restart", description: Copy.text("agent.tool.orchestrator_restart"),
            inputSchema: schema([:])) { tools, _ in try await tools.orchestratorRestart() },
        ToolEntry(
            name: "orchestrator_prompt", description: Copy.text("agent.tool.orchestrator_prompt"),
            inputSchema: schema(["text": property("string")], required: ["text"])) { tools, args in try await tools.orchestratorPrompt(args) },
        ToolEntry(
            name: "settings_get", description: Copy.text("agent.tool.settings_get"),
            inputSchema: schema([:])) { tools, _ in
                Copy.text("agent.mcp.health.text") + Self.describe(settings: try await tools.client.settings(), models: await tools.claudeModels())
            },
        ToolEntry(
            name: "settings_update", description: Copy.text("agent.tool.settings_update"),
            inputSchema: schema([
                "orchestrator_enabled": property("boolean"),
                "orchestrator_model": claudeModelProperty,
                "orchestrator_effort": property("string", enum: Effort.allCases.map(\.rawValue)),
                "orchestrator_agent_args": property("array", Copy.text("agent.tool.settings_update.orchestrator_agent_args"), items: property("string")),
                "idle_stop_minutes": .object([
                    "type": .string("integer"), "enum": .array(MachineSettings.idleStopChoices.map { .int($0) }),
                    "description": .string(Copy.text("agent.mcp.health.text.2")),
                ]),
                "usage_pause_five_hour_percent": usagePauseProperty(Copy.text("agent.mcp.health.text.3")),
                "usage_pause_seven_day_percent": usagePauseProperty(Copy.text("agent.mcp.health.text.4")),
            ])) { tools, args in try await tools.settingsUpdate(args) },
        ToolEntry(
            name: "inbox_list", description: Copy.text("agent.tool.inbox_list"),
            inputSchema: schema(["include_dismissed": property("boolean", Copy.text("agent.tool.inbox_list.include_dismissed"))])) { tools, args in try await tools.inboxList(args) },
        ToolEntry(
            name: "inbox_dismiss", description: Copy.text("agent.tool.inbox_dismiss"),
            inputSchema: schema(["item_ids": property("array", Copy.text("agent.tool.inbox_dismiss.item_ids"), items: property("string"))], required: ["item_ids"])) { tools, args in try await tools.inboxDismiss(args) },
        ToolEntry(
            name: "inbox_restore", description: Copy.text("agent.tool.inbox_restore"),
            inputSchema: schema(["item_ids": property("array", items: property("string"))], required: ["item_ids"])) { tools, args in try await tools.inboxRestore(args) },
        ToolEntry(
            name: "prs_list", description: Copy.text("agent.tool.prs_list"),
            inputSchema: schema(["category": property("string", enum: PRCategory.allCases.map(\.rawValue))])) { tools, args in try await tools.prsList(args) },
        ToolEntry(
            name: "prs_refresh", description: Copy.text("agent.tool.prs_refresh"),
            inputSchema: schema([:])) { tools, _ in Self.describe(prs: try await tools.client.refreshPullRequests(), category: nil) },
        ToolEntry(
            name: "usage_get", description: Copy.text("agent.tool.usage_get"),
            inputSchema: schema([:])) { tools, _ in Self.describe(usage: try await tools.client.usage()) },
        ToolEntry(
            name: "usage_history",
            description:
                Copy.text("agent.tool.usage_history"),
            inputSchema: schema([
                "days": property("integer", Copy.text("agent.tool.usage_history.days"))
            ])) { tools, args in try await tools.usageHistory(args) },
    ]

    private static func usagePauseProperty(_ window: String) -> Value {
        let range = MachineSettings.UsagePause.percentRange
        return .object([
            "type": .string("integer"), "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "description": .string(Copy.text("agent.mcp.health.range", ["window": "\(window)"])),
        ])
    }

    /// ISO8601DateFormatter は Sendable でないので static に持たず、呼ぶたびに作る（health の行の数なので足りる）
    static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    // MARK: health

    static func healthReport(
        snapshot: StateSnapshot, apnsConfigured: Bool?, now: Date = Date()
    ) -> String {
        var lines = ["# health（\(snapshot.machine.name)、daemon \(snapshot.machine.daemonVersion)、\(time(now))）"]
        if let prs = snapshot.prs {
            let failing = prs.accounts.compactMap { account in account.error.map { "\(account.account)@\(account.host): " + Self.failure($0, account) } }
            lines.append("- gh: " + (failing.isEmpty ? Copy.text("agent.mcp.health.failing", ["accounts": "\(prs.accounts.count)"]) : Copy.text("agent.mcp.health.failing.2") + failing.joined(separator: " / ")))
        } else {
            lines.append(Copy.text("agent.mcp.health.failing.3"))
        }
        switch apnsConfigured {
        case true?: lines.append(Copy.text("agent.mcp.health.failing.4"))
        case false?: lines.append(Copy.text("agent.mcp.health.failing.5"))
        case nil: lines.append(Copy.text("agent.mcp.health.failing.6"))
        }
        if let host = snapshot.machine.agentHost { lines.append(Copy.text("agent.mcp.health.failing.7") + Self.describe(agentHost: host, conversations: snapshot.conversations)) }
        if let cli = snapshot.machine.claudeCLI { lines.append(Copy.text("agent.mcp.health.failing.8") + Self.describe(cli: cli, engine: .claude)) }
        if let cli = snapshot.machine.codexCLI { lines.append(Copy.text("agent.mcp.health.failing.9") + Self.describe(cli: cli, engine: .codex)) }
        if let orchestrator = snapshot.orchestrator {
            var line = Copy.text("agent.mcp.health.orchestrator", ["standing": Copy.text(orchestrator.enabled ? "agent.mcp.health.on" : "agent.mcp.health.off")])
            line += orchestrator.conversationID.map { Copy.text("agent.mcp.health.line", ["value": "\($0)"]) } ?? Copy.text("agent.mcp.health.line.2")
            if let error = orchestrator.lastError { line += Copy.text("agent.mcp.health.line.3", ["error": "\(error)"]) }
            lines.append(line)
        }
        if let claude = snapshot.usage?.claude {
            let windows = [(Copy.text("agent.mcp.health.windows"), claude.fiveHour), (Copy.text("agent.mcp.health.windows.2"), claude.sevenDay)].compactMap { name, window in window.map { "\(name) \(percent($0.usedPercent))" } }
            if !windows.isEmpty { lines.append(Copy.text("agent.mcp.health.windows.3") + windows.joined(separator: "、")) }
        }

        let asking = snapshot.conversations.filter { !$0.requests.isEmpty }
        lines.append("")
        lines.append(Copy.text("agent.mcp.health.asking", ["asking": "\(asking.count)"]))
        lines += asking.map { "- " + describe(waiting: $0, tasks: snapshot.tasks) }

        let troubled = snapshot.schedules.filter { schedule in
            guard schedule.enabled, let run = schedule.lastRun else { return false }
            return run.outcome == .failed || run.outcome == .skipped || run.outcome == .notStarted
        }
        let unlinked = snapshot.schedules.filter { $0.enabled && $0.taskNumber == nil }
        lines.append("")
        lines.append(Copy.text("agent.mcp.health.unlinked", ["filter": "\(snapshot.schedules.filter(\.enabled).count)", "schedules": "\(snapshot.schedules.count)"]))
        for schedule in troubled {
            lines.append(Copy.text("agent.mcp.health.unlinked.2", ["scheduleID": "\(schedule.scheduleID)", "name": "\(schedule.name)"]) + String(describe(run: schedule.lastRun!).dropFirst(2)) + Copy.text("agent.mcp.health.unlinked.3"))
        }
        for schedule in unlinked {
            lines.append(Copy.text("agent.mcp.health.unlinked.4", ["scheduleID": "\(schedule.scheduleID)", "name": "\(schedule.name)"]))
        }
        if troubled.isEmpty && unlinked.isEmpty { lines.append(Copy.text("agent.mcp.health.unlinked.5")) }

        let pendingWakes = snapshot.wakes.filter { $0.state == .pending }
        let failedWakes = snapshot.wakes.filter { $0.state == .failed }
        lines.append("")
        lines.append(Copy.text("agent.mcp.health.failedWakes", ["pendingWakes": "\(pendingWakes.count)", "failedWakes": "\(failedWakes.count)"]))
        for wake in failedWakes + pendingWakes.filter({ $0.failure != nil }) {
            lines.append("- " + Self.describe(wake: wake, snapshot: snapshot, own: nil).replacingOccurrences(of: "\n  - ", with: " ・ "))
        }

        let activeWatches = snapshot.watches.filter { $0.state == .active }
        let unfetched = activeWatches.filter { $0.error != nil }
        // 取り消したものと、届け先の会話が無くなって daemon が終えたもの（終えてから残す間だけ見える）
        let dropped = snapshot.watches.filter { $0.state == .cancelled || $0.ending == .targetMissing }
        lines.append("")
        lines.append(Copy.text("agent.mcp.health.dropped", ["activeWatches": "\(activeWatches.count)", "unfetched": "\(unfetched.count)", "dropped": "\(dropped.count)"]))
        for watch in unfetched + dropped {
            lines.append("- " + Self.describe(watch: watch, snapshot: snapshot, own: nil).replacingOccurrences(of: "\n  - ", with: " ・ "))
        }

        var state = MachineState()
        state.apply(.stateSnapshot(snapshot))
        let items = state.inbox(now: now).items
        let waiting = items.filter { $0.group == .waiting }
        let stalledTasks = items.filter { if case .stalled = $0.kind { true } else { false } }
        lines.append("")
        lines.append(Copy.text("agent.mcp.health.stalled", ["waiting": "\(waiting.count)"]))
        if !stalledTasks.isEmpty {
            lines.append(Copy.text("agent.mcp.health.stalled.2", ["thresholdDays": "\(TaskStall.thresholdDays)", "stalledTasks": "\(stalledTasks.count)"]))
            lines += stalledTasks.prefix(10).map { Self.describe(inbox: $0) }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(cli: CLIVersionStatus, engine: AgentKind) -> String {
        let check = engine == .claude ? "taskboard conversation check" : "taskboard conversation check --engine \(engine.rawValue)"
        var text = cli.using.map { Copy.text("agent.mcp.health.text.5", ["value": "\($0)"]) } ?? Copy.text("agent.mcp.health.text.6", ["check": "\(check)"])
        if let failed = cli.failedVersion {
            text += Copy.text("agent.mcp.health.failedCheck", ["failed": "\(failed)", "step": cli.failedStep ?? Copy.text("agent.mcp.health.noStep")])
        } else if let newest = cli.newest, newest != cli.using {
            text += Copy.text("agent.mcp.health.text.7", ["newest": "\(newest)"])
        }
        return text
    }

    private func health() async throws -> String {
        let snapshot = try await client.snapshot()
        let apns = apnsDirectory.map { directory in
            ["AuthKey.p8", "apns.json"].allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
        }
        var report = Self.healthReport(snapshot: snapshot, apnsConfigured: apns)
        var slack: [String] = []
        for board in snapshot.boards {
            guard let settings = try? await client.boardSlack(id: board.id), settings.configured else { continue }
            slack.append("- Slack（\(board.name)）: " + Self.describe(slack: settings))
        }
        if !slack.isEmpty { report += "\n" + slack.joined(separator: "\n") }
        return report
    }

    static func describe(slack: BoardSlack) -> String {
        let state =
            switch slack.connection {
            case .off: Copy.text("agent.mcp.health.off")
            case .connecting: Copy.text("agent.mcp.health.connecting")
            case .connected: Copy.text("agent.mcp.health.connected")
            case .failed(let message): Copy.text("agent.mcp.health.failed", ["message": "\(message)"])
            }
        let people = slack.allowedUsers.isEmpty ? Copy.text("agent.mcp.health.people") : Copy.text("agent.mcp.health.people.2", ["allowedUsers": "\(slack.allowedUsers.count)"])
        return [slack.workspace, state, people, Copy.text("agent.mcp.health.people.3", ["routes": "\(slack.routes.count)"])].compactMap { $0 }.joined(separator: "、")
    }

    // MARK: セッション

    private func sessionStop(_ args: [String: Value]) async throws -> String {
        guard let conversation = args.string("conversation_id"), !conversation.isEmpty else { throw ToolError.missing("conversation_id") }
        if args.bool("close") == true { return try await conversationClose(conversation, args) }
        return try await conversationStop(conversation, args)
    }

    private func sessionExit() async throws -> String {
        guard let own = conversationID else {
            throw ToolError.invalid(Copy.text("agent.mcp.health.sessionExit"))
        }
        try await client.closeConversationAfterTurn(own)
        return [
            Copy.text("agent.mcp.health.sessionExit.2"), "- conversation_id: \(own)", Copy.text("agent.mcp.health.sessionExit.3"),
            Copy.text("agent.mcp.health.sessionExit.4"),
        ].joined(separator: "\n")
    }

    private func sessionResume(_ args: [String: Value]) async throws -> String {
        let account = try Self.account(args, kind: .claude)
        if let conversation = args.string("conversation_id"), !conversation.isEmpty { return try await conversationResume(conversation, account: account) }
        let number = try await resolveTaskNumber(args)
        let snapshot = try await client.snapshot()
        guard let task = snapshot.tasks.first(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
        let running = Set(snapshot.conversations.filter { !$0.isClosed && $0.phase != .stopped }.compactMap(\.agentSessionID))
        let sessionID: String
        if let given = args.string("session_id"), !given.isEmpty {
            sessionID = try Self.sessionID(given, in: task)
            if let conversation = snapshot.conversations.first(where: { $0.agentSessionID == sessionID }) { return try await conversationResume(conversation.id, account: account) }
        } else {
            var state = MachineState()
            state.apply(.stateSnapshot(snapshot))
            guard let latest = state.stoppedSessions(of: task).first else {
                throw ToolError.invalid(Copy.text("agent.mcp.health.state", ["number": "\(number)"]))
            }
            sessionID = latest.sessionID
        }
        if running.contains(sessionID) { throw ToolError.invalid(Copy.text("agent.mcp.health.state.2", ["sessionID": "\(sessionID.prefix(8))"])) }
        let result = try await client.resumeSession(task: number, SessionResumeRequest(agentSessionID: sessionID, account: account))
        guard let conversation = result.conversation else { throw ToolError.invalid(Copy.text("agent.mcp.health.result")) }
        return [
                Copy.text("agent.mcp.conversations.resumed"), "- conversation_id: \(conversation.id)", Copy.text("agent.mcp.conversations.fork.6") + Self.taskLabel(number, in: snapshot), Copy.text("agent.mcp.health.result.2", ["sessionID": "\(sessionID.prefix(8))"]),
            Copy.text("agent.mcp.conversations.resumed.3", ["cwd": "\(conversation.cwd)"]), Copy.text("agent.mcp.conversations.fork.8"),
        ].joined(separator: "\n")
    }

    private func sessionHistory(_ args: [String: Value]) async throws -> String {
        if let conversation = args.string("conversation_id"), !conversation.isEmpty {
            return try await conversationHistory(conversation, limit: args.int("limit") ?? 10)
        }
        let number = try await resolveTaskNumber(args)
        let snapshot = try await client.snapshot()
        guard let task = snapshot.tasks.first(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
        let histories = try await client.sessionHistory(task: number)
        guard !histories.isEmpty else { return Copy.text("agent.mcp.health.histories", ["number": "\(number)"]) }
        var lines = [Copy.text("agent.mcp.health.lines", ["number": "\(number)", "title": "\(task.title)", "histories": "\(histories.count)"])]
        for history in histories {
            let live = snapshot.conversations.first { !$0.isClosed && $0.phase != .stopped && $0.agentSessionID == history.sessionID }
            var line = "- \(history.sessionID)"
            line += live.map { Copy.text("agent.mcp.health.line.4", ["id": "\($0.id)", "phase": "\($0.phase.rawValue)"]) } ?? Copy.text("agent.mcp.health.line.5")
            if let title = history.title(taskTitle: task.title) { line += " 「\(title)」" }
            lines.append(line)
            if let branch = history.branch { lines.append("  - branch: \(branch)") }
            if let at = history.updatedAt { lines.append(Copy.text("agent.mcp.health.line.6", ["time": "\(Self.time(at))"])) }
        }
        return lines.joined(separator: "\n")
    }

    private func sessionRename(_ args: [String: Value]) async throws -> String {
        guard let label = args.string("label") else { throw ToolError.missing("label") }
        guard let conversation = args.string("conversation_id"), !conversation.isEmpty else { throw ToolError.missing("conversation_id") }
        return try await conversationRename(conversation, title: label)
    }

    // MARK: オーケストレーター・設定

    static func describe(orchestrator info: OrchestratorInfo) -> String {
        var lines = [Copy.text("agent.mcp.health.lines.2"), Copy.text("agent.mcp.health.standing", ["standing": Copy.text(info.enabled ? "agent.mcp.health.on" : "agent.mcp.health.off")])]
        if let id = info.conversationID {
            lines.append(Copy.text("agent.mcp.health.lines.3", ["id": "\(id)"]))
        } else {
            lines.append(Copy.text("agent.mcp.health.lines.4"))
        }
        if let error = info.lastError { lines.append(Copy.text("agent.mcp.health.lines.5", ["error": "\(error)"])) }
        if let reply = info.lastReply {
            let text = reply.text.count > 500 ? String(reply.text.prefix(500)) + "…" : reply.text
            lines.append(Copy.text("agent.mcp.health.text.8", ["time": "\(time(reply.at))", "value": "\(text)"]))
        }
        return lines.joined(separator: "\n")
    }

    private func orchestratorStart(_ args: [String: Value]) async throws -> String {
        var choice = LaunchChoice(kind: .claude, args: try await client.settings().orchestrator.agentArgs)
        let models = await claudeModels()
        if let value = args.string("model") {
            choice.select(model: try claudeModel(value, in: models))
        }
        if let value = args.string("effort") {
            guard let effort = Effort(rawValue: value) else { throw ToolError.invalid(Copy.text("agent.mcp.health.models", ["value": "\(value)"]) + Effort.allCases.map(\.rawValue).joined(separator: ", ")) }
            choice.select(effort: effort)
        }
        // prompt を空で送ると daemon が `OrchestratorInfo.startPrompt` を入れる（常駐の起動と同じ文）
        let info = try await client.startOrchestrator(LaunchRequest(cwd: "", kind: .claude, agentArgs: choice.args, prompt: ""))
        return ([Copy.text("agent.mcp.health.info"), Copy.text("agent.mcp.conversations.lines.13", ["summary": "\(choice.summary(models))"])] + Self.started(info) + [Copy.text("agent.mcp.health.info.2")]).joined(separator: "\n")
    }

    private func orchestratorRestart() async throws -> String {
        let info = try await client.restartOrchestrator()
        return ([Copy.text("agent.mcp.health.info.3")] + Self.started(info) + [Copy.text("agent.mcp.health.info.2")]).joined(separator: "\n")
    }

    /// 起動した先の項目
    static func started(_ info: OrchestratorInfo) -> [String] {
        info.conversationID.map { ["- conversation_id: \($0)"] } ?? [Copy.text("agent.mcp.health.started")]
    }

    private func orchestratorPrompt(_ args: [String: Value]) async throws -> String {
        guard let text = args.string("text"), !text.isEmpty else { throw ToolError.missing("text") }
        let info = try await client.orchestrator()
        if let id = info.conversationID, id == conversationID { throw ToolError.invalid(Copy.text("agent.mcp.health.info.4")) }
        _ = try await client.promptOrchestrator(text)
        return Copy.text("agent.mcp.health.info.5", ["value": "\(text.count)"])
    }

    static func describe(settings: MachineSettings, models: ClaudeModels) -> String {
        let choice = LaunchChoice(kind: .claude, args: settings.orchestrator.agentArgs)
        return [
            Copy.text("agent.mcp.health.settingsOrchestrator", ["standing": Copy.text(settings.orchestrator.enabled ? "agent.mcp.health.on" : "agent.mcp.health.off"), "choice": choice.summary(models), "args": settings.orchestrator.agentArgs.joined(separator: " ")]),
            Copy.text("agent.mcp.health.choice") + (settings.idleStopMinutes == 0 ? Copy.text("agent.mcp.health.choice.2") : Copy.text("agent.mcp.health.choice.3", ["idleStopMinutes": "\(settings.idleStopMinutes)"])),
            Copy.text("agent.mcp.health.choice.4", ["fiveHourPercent": "\(settings.usagePause.fiveHourPercent)", "sevenDayPercent": "\(settings.usagePause.sevenDayPercent)"]),
        ].joined(separator: "\n")
    }

    private func settingsUpdate(_ args: [String: Value]) async throws -> String {
        var update = MachineSettingsUpdate()
        update.orchestratorEnabled = args.bool("orchestrator_enabled")
        if let minutes = args.int("idle_stop_minutes") {
            guard MachineSettings.idleStopChoices.contains(minutes) else {
                throw ToolError.invalid(Copy.text("agent.mcp.health.update") + MachineSettings.idleStopChoices.map(String.init).joined(separator: " / "))
            }
            update.idleStopMinutes = minutes
        }
        let range = MachineSettings.UsagePause.percentRange
        for key in ["usage_pause_five_hour_percent", "usage_pause_seven_day_percent"] {
            if let percent = args.int(key), !range.contains(percent) {
                throw ToolError.invalid(Copy.text("agent.mcp.health.range.2", ["key": "\(key)", "lowerBound": "\(range.lowerBound)", "upperBound": "\(range.upperBound)"]))
            }
        }
        update.usagePauseFiveHourPercent = args.int("usage_pause_five_hour_percent")
        update.usagePauseSevenDayPercent = args.int("usage_pause_seven_day_percent")
        let model = args.string("orchestrator_model")
        let effort = args.string("orchestrator_effort")
        if let raw = args.array("orchestrator_agent_args") {
            guard model == nil, effort == nil else { throw ToolError.invalid(Copy.text("agent.mcp.health.effort")) }
            update.orchestratorAgentArgs = raw.compactMap(\.stringValue)
        } else if model != nil || effort != nil {
            var choice = LaunchChoice(kind: .claude, args: try await client.settings().orchestrator.agentArgs)
            if let model {
                choice.select(model: try claudeModel(model, field: "orchestrator_model", in: await claudeModels()))
            }
            if let effort {
                guard let value = Effort(rawValue: effort) else { throw ToolError.invalid(Copy.text("agent.mcp.health.choice.5", ["effort": "\(effort)"]) + Effort.allCases.map(\.rawValue).joined(separator: ", ")) }
                choice.select(effort: value)
            }
            update.orchestratorAgentArgs = choice.args
        }
        guard update != MachineSettingsUpdate() else { throw ToolError.invalid(Copy.text("agent.mcp.health.choice.6")) }
        return Copy.text("agent.mcp.health.choice.7") + Self.describe(settings: try await client.updateSettings(update), models: await claudeModels())
    }

    // MARK: 受信箱

    private func machineState() async throws -> MachineState {
        var state = MachineState()
        state.apply(.stateSnapshot(try await client.snapshot()))
        return state
    }

    static func describe(inbox item: InboxItem, dismissed: Bool = false) -> String {
        var line = "- [\(item.localID)] \(item.group == .waiting ? "対応待ち" : "お知らせ"): \(item.title)"
        if !item.detail.isEmpty { line += "（\(item.detail)）" }
        if dismissed { line += Copy.text("agent.mcp.health.line.7") }
        return line
    }

    private func inboxList(_ args: [String: Value]) async throws -> String {
        let contents = try await machineState().inbox()
        var lines = [Copy.text("agent.mcp.health.lines.6", ["items": "\(contents.items.count)", "filter": "\(contents.items.filter { $0.group == .waiting }.count)"])]
        lines += contents.items.map { Self.describe(inbox: $0) }
        if args.bool("include_dismissed") == true {
            lines.append(Copy.text("agent.mcp.health.lines.7", ["dismissed": "\(contents.dismissed.count)"]))
            lines += contents.dismissed.map { Self.describe(inbox: $0, dismissed: true) }
        }
        return lines.joined(separator: "\n")
    }

    private func inboxDismiss(_ args: [String: Value]) async throws -> String {
        let ids = args.strings("item_ids") ?? []
        guard !ids.isEmpty else { throw ToolError.missing("item_ids") }
        let items = try await machineState().inboxItems()
        let unknown = ids.filter { id in !items.contains { $0.localID == id } }
        guard unknown.isEmpty else { throw ToolError.invalid(Copy.text("agent.mcp.health.unknown", ["unknown": "\(unknown.joined(separator: ", "))"])) }
        let chosen = items.filter { ids.contains($0.localID) }
        _ = try await client.dismissInbox(chosen.map(\.dismissRequestItem))
        return Copy.text("agent.mcp.health.chosen", ["chosen": "\(chosen.count)"])
    }

    private func inboxRestore(_ args: [String: Value]) async throws -> String {
        let ids = args.strings("item_ids") ?? []
        guard !ids.isEmpty else { throw ToolError.missing("item_ids") }
        let left = try await client.restoreInbox(itemIDs: ids)
        return Copy.text("agent.mcp.health.left", ["ids": "\(ids.count)", "left": "\(left.count)"])
    }

    // MARK: PR・利用枠

    private func prsList(_ args: [String: Value]) async throws -> String {
        let category = try args.string("category").map { raw in
            guard let value = PRCategory(rawValue: raw) else { throw ToolError.invalid(Copy.text("agent.mcp.health.category") + PRCategory.allCases.map(\.rawValue).joined(separator: " / ")) }
            return value
        }
        return Self.describe(prs: try await client.pullRequests(), category: category)
    }

    /// 取得の失敗の理由（gh の文のまま。画面の `failureMessage` は理由を落とすので使わない）
    private static func failure(_ error: String, _ account: PRAccountStatus) -> String {
        error + (account.rateLimited ? "（rate limit。" + (account.nextFetchAt.map { Copy.text("agent.mcp.health.failure", ["time": "\(time($0))"]) } ?? Copy.text("agent.mcp.health.failure.2")) + "）" : "")
    }

    static func describe(prs: PRSnapshot, category: PRCategory?) -> String {
        var lines = prs.accounts.map { account in
            Copy.text("agent.mcp.health.lines.8", ["account": "\(account.account)", "host": "\(account.host)"]) + (account.error.map { Copy.text("agent.mcp.health.failing.2") + failure($0, account) } ?? account.fetchedAt.map { Copy.text("agent.mcp.health.lines.9", ["time": "\(time($0))"]) } ?? Copy.text("agent.mcp.health.lines.10"))
        }
        let shown = prs.pullRequests.filter { category == nil || $0.category == category }
        lines.append(Copy.text("agent.mcp.health.shown", ["shown": "\(shown.count)"]))
        for pr in shown.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            var line = "- [\(pr.category.rawValue)] \(pr.shortLabel) \(pr.title)"
            if pr.isDraft { line += " (Draft)" }
            if let checks = pr.checks { line += " CI=\(checks.rawValue)" }
            if let decision = pr.reviewDecision { line += " review=\(decision)" }
            if let turn = pr.turn { line += Copy.text("agent.mcp.health.line.8", ["turn": "\(turn.rawValue)"]) }
            line += "  \(pr.url)"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func describe(usage: UsageSnapshot) -> String {
        var lines: [String] = []
        func window(_ name: String, _ value: UsageWindow?) -> String? {
            value.map { "\(name) \(percent($0.usedPercent))" + ($0.resetsAt.map { Copy.text("agent.mcp.health.window", ["time": "\(time($0))"]) } ?? "") }
        }
        if let claude = usage.claude {
            lines.append("Claude: " + [window(Copy.text("agent.mcp.health.windows"), claude.fiveHour), window(Copy.text("agent.mcp.health.windows.2"), claude.sevenDay)].compactMap { $0 }.joined(separator: "、"))
        } else {
            lines.append(Copy.text("agent.mcp.health.window.2"))
        }
        if let codex = usage.codex {
            var parts = [window(Copy.text("agent.mcp.health.parts"), codex.primary), window(Copy.text("agent.mcp.health.parts.2"), codex.secondary)].compactMap { $0 }
            if let monthly = codex.monthly { parts.append(Copy.text("agent.mcp.health.parts.3", ["percent": "\(percent(monthly.usedPercent))"])) }
            lines.append("Codex: " + (parts.isEmpty ? Copy.text("agent.mcp.health.parts.4") : parts.joined(separator: "、")))
        }
        let contexts = usage.contexts.filter { $0.usedPercent != nil }.sorted { ($0.usedPercent ?? 0) > ($1.usedPercent ?? 0) }
        if !contexts.isEmpty {
            lines.append(Copy.text("agent.mcp.health.contexts"))
            for context in contexts {
                lines.append("- \(context.agentSessionID.prefix(8))… \(percent(context.usedPercent ?? 0))" + (context.model.map { " \($0)" } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }
}
