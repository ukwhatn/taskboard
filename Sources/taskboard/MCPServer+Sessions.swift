import Foundation
import MCP
import TaskboardDaemon
import TaskboardKit

/// このマシンの host の会話を並べる・起動する・文字を送る tool
extension TaskboardTools {
    static let sessionListTool = ToolEntry(
        name: "session_list", description: Copy.text("agent.tool.session_list"),
        inputSchema: schema([:])) { tools, _ in try await tools.sessionList() }

    static let sessionStartTool = ToolEntry(
        name: "session_start",
        description:
            Copy.text("agent.tool.session_start"),
        inputSchema: schema([
            "task_id": property("integer", Copy.text("agent.tool.session_start.task_id")),
            "cwd": property("string", Copy.text("agent.tool.session_start.cwd")),
            "kind": property("string", Copy.text("agent.tool.session_start.kind"), enum: ["claude", "codex"]),
            "notify": property("boolean", Copy.text("agent.tool.session_start.notify")),
            "disallowed_tools": property("array", Copy.text("agent.tool.session_start.disallowed_tools"), items: property("string")),
            "preset": property("string", Copy.text("agent.tool.session_start.preset"), enum: TaskboardTools.legacyPresets.keys.sorted()),
            // モデルの名前はマシンの Claude Code・codex の一覧で決まるので、enum にしない
            "model": property("string", Copy.text("agent.tool.session_start.model", ["model": LaunchChoice.standard.model!])),
            "effort": property("string", Copy.text("agent.tool.session_start.effort", ["efforts": Effort.allCases.map(\.rawValue).joined(separator: "・"), "effort": LaunchChoice.standard.effort!.rawValue])),
            "prompt": property("string", Copy.unfilled("agent.tool.session_start.prompt")),
            "worktree_branch": property("string", Copy.text("agent.tool.session_start.worktree_branch")),
            "worktree_base": property("string"),
            "account": accountProperty,
        ])) { tools, args in try await tools.sessionStart(args) }

    static let accountProperty: Value = property(
        "string", Copy.text("agent.mcp.sessions.accountProperty"))

    static let sessionAccountTool = ToolEntry(
        name: "session_account",
        description:
            Copy.text("agent.tool.session_account"),
        inputSchema: schema([
            "conversation_id": conversationProperty,
            "account": property("string", Copy.text("agent.tool.session_account.account")),
        ])) { tools, args in try await tools.sessionAccount(args) }

    static let sessionPromptTool = ToolEntry(
        name: "session_prompt",
        description:
            Copy.text("agent.tool.session_prompt"),
        inputSchema: schema([
            "conversation_id": conversationProperty,
            "text": property("string", Copy.text("agent.tool.devin_message.message")),
        ], required: ["conversation_id", "text"])) { tools, args in try await tools.sessionPrompt(args) }

    func sessionList() async throws -> String {
        let conversations = conversationLines(try await client.snapshot())
        return conversations.isEmpty ? Copy.text("agent.mcp.sessions.conversations") : ([Copy.text("agent.mcp.sessions.conversations.2", ["conversations": "\(conversations.count)"])] + conversations).joined(separator: "\n")
    }

    func sessionPrompt(_ args: [String: Value]) async throws -> String {
        guard let given = args.string("text"), !given.isEmpty else { throw ToolError.missing("text") }
        guard let conversation = args.string("conversation_id"), !conversation.isEmpty else { throw ToolError.missing("conversation_id") }
        return try await conversationPrompt(conversation, text: given)
    }

    /// 送る文に、別のセッションからの発言だと分かる印・頭・送り主を付ける。渡された文の頭に印があれば外す（ほかの知らせに見せない）
    func sessionPromptText(_ given: String) async throws -> String {
        let snapshot = try await client.snapshot()
        let own = conversationID.flatMap { id in snapshot.conversations.first { $0.id == id } }
        let task = own?.taskNumber ?? agentSessionID.flatMap { snapshot.tasks.task(linkedToSession: $0)?.number }
        let sender: String
        if let own {
            sender = Copy.text("agent.mcp.conversations.line", ["id": "\(own.id.prefix(8))"]) + (own.title.map { "「\($0)」" } ?? "") + (task.map { "（#\($0)）" } ?? "")
        } else {
            sender = Copy.text("agent.mcp.sessions.sender")
        }
        let marker = TaskboardNotice.marker(
            .sessionPrompt, ["from": own.map { String($0.id.prefix(8)) } ?? "", "task": task.map(String.init) ?? ""])
        return [
            marker,
            TaskboardNotice.sessionPromptHead,
            Copy.text("agent.mcp.sessions.marker", ["sender": "\(sender)"]),
            TaskboardNotice.bodyHeading,
            TaskboardNotice.stripMarker(given),
        ].joined(separator: "\n")
    }

    /// 前の版の `preset` の id（エージェント・モデル・effort の組）
    static let legacyPresets: [String: LaunchChoice] = [
        "claude-opus-medium": LaunchChoice(kind: .claude, model: "opus", effort: .medium),
        "claude-fable-high": LaunchChoice(kind: .claude, model: "fable", effort: .high),
        "claude-sonnet-high": LaunchChoice(kind: .claude, model: "sonnet", effort: .high),
        "codex-default": LaunchChoice(kind: .codex),
    ]

    func sessionStart(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        let snapshot = try await client.snapshot()
        guard let task = snapshot.tasks.first(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
        let board = snapshot.boards.first { $0.id == task.boardID }
        var choice = LaunchChoice(defaults: board?.launchDefaults)
        if let value = args.string("preset") {
            // 前の版の指定（/taskboard のスキルと、それを覚えたセッションが使う）。model と effort を渡せばそちらが上書きする
            guard let preset = Self.legacyPresets[value] else {
                throw ToolError.invalid(Copy.text("agent.mcp.sessions.choice", ["value": "\(value)"]) + Self.legacyPresets.keys.sorted().joined(separator: ", "))
            }
            choice = preset
        }
        let kind = args.string("kind").flatMap(AgentKind.init(rawValue:)) ?? choice.kind
        if args["preset"] != nil, kind != choice.kind { throw ToolError.invalid(Copy.text("agent.mcp.sessions.kind", ["args": "\(args.string("preset") ?? "")", "kind": "\(choice.kind.rawValue)"])) }
        choice.select(kind: kind)
        // codex のモデルと effort は codex の名前のまま daemon に渡す（Claude の名前の表に無い）
        if let value = args.string("model") {
            if kind == .codex {
                guard ConversationInput.acceptsCodexName(value) else { throw ToolError.invalid(Copy.text("agent.mcp.sessions.kind.2", ["value": "\(value)"])) }
                choice.select(codexModel: value)
            } else {
                choice.select(model: value)
            }
        }
        // 別名も前の版の指定も、マシンの一覧で --model に渡す名前にそろえる（`fable` のままでは 1M の版にならない）
        let models = await claudeModels()
        if kind == .claude, let model = choice.model { choice.select(model: try claudeModel(model, in: models)) }
        if let value = args.string("effort") {
            if kind == .codex {
                guard ConversationInput.acceptsCodexName(value) else { throw ToolError.invalid(Copy.text("agent.mcp.sessions.models", ["value": "\(value)"])) }
                choice.select(codexEffort: value)
            } else {
                guard let effort = Effort(rawValue: value) else { throw ToolError.invalid(Copy.text("agent.mcp.health.models", ["value": "\(value)"]) + Effort.allCases.map(\.rawValue).joined(separator: ", ")) }
                choice.select(effort: effort)
            }
        }
        let cwd = args.string("cwd") ?? ownCwd(in: snapshot)
        let prompt = args.string("prompt") ?? board.map { PromptTemplate.template(for: task.columnID, in: $0) } ?? ""
        // 自分のタスクのセッションだけ委譲先にする（別のタスクに起動したものは、そのタスクの lead）
        let own = try? await currentTask(in: snapshot)?.number
        let delegating = args["task_id"] == nil || own == number
        return try await conversationStart(
            task: number, cwd: cwd, choice: choice, prompt: prompt, delegating: delegating, args: args,
            snapshot: snapshot)
    }

    /// 起動の既定の作業ディレクトリ。host の会話の中ならその会話の cwd、外ならこの process の cwd
    private func ownCwd(in snapshot: StateSnapshot) -> String {
        conversationID.flatMap { id in snapshot.conversations.first { $0.id == id }?.cwd } ?? cwd
    }
}

extension TaskboardTools {
    /// `account` の引数。claude のときだけ受ける
    static func account(_ args: [String: Value], kind: AgentKind) throws -> String? {
        guard let value = args.string("account"), !value.isEmpty else { return nil }
        guard kind == .claude else { throw ToolError.invalid(Copy.text("agent.mcp.sessions.account")) }
        return value
    }

    func sessionAccount(_ args: [String: Value]) async throws -> String {
        let snapshot = try await client.snapshot()
        guard let account = args.string("account"), !account.isEmpty else { return Self.describe(accounts: snapshot.usage) }
        guard let given = args.string("conversation_id"), !given.isEmpty else { throw ToolError.missing("conversation_id") }
        let conversation = try Self.conversation(given, in: snapshot.conversations)
        if conversation.id == conversationID { throw ToolError.invalid(Copy.text("agent.mcp.sessions.conversation")) }
        let result = try await client.switchAccount(SessionAccountRequest(conversationID: conversation.id, account: account))
        let switched = result.conversation ?? conversation
        return [
            Copy.text("agent.mcp.sessions.switched"), "- conversation_id: \(switched.id)", Copy.text("agent.mcp.devin.lines.3", ["account": "\(switched.account ?? ClaudeAccount.login)"]),
            Copy.text("agent.mcp.sessions.switched.2"),
        ].joined(separator: "\n")
    }

    static func describe(accounts usage: UsageSnapshot?) -> String {
        var lines = [Copy.text("agent.mcp.sessions.lines"), Copy.text("agent.mcp.sessions.lines.2") + window(usage?.claude)]
        for account in usage?.claudeAccounts ?? [] {
            lines.append("- \(account.name)" + window(account.usage) + (account.boards.isEmpty ? "" : Copy.text("agent.mcp.sessions.lines.3") + account.boards.joined(separator: "・")))
        }
        if usage?.claudeAccounts?.isEmpty ?? true { lines.append(Copy.text("agent.mcp.sessions.lines.4")) }
        return lines.joined(separator: "\n")
    }

    private static func window(_ usage: ClaudeUsage?) -> String {
        guard let usage else { return Copy.text("agent.mcp.sessions.window") }
        var parts: [String] = []
        if let five = usage.fiveHour { parts.append(Copy.text("agent.mcp.sessions.parts", ["value": "\(Int(five.usedPercent.rounded()))"])) }
        if let seven = usage.sevenDay { parts.append(Copy.text("agent.mcp.sessions.parts.2", ["value": "\(Int(seven.usedPercent.rounded()))"])) }
        return parts.isEmpty ? Copy.text("agent.mcp.sessions.window") : " " + parts.joined(separator: "・")
    }
}
