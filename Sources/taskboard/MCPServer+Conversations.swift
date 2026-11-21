import Foundation
import MCP
import TaskboardDaemon
import TaskboardKit

/// host の会話（daemon が stream-json で動かす Claude Code と Codex）。session_* の tool に `conversation_id` で載せ、答えるのだけ `session_answer` を足す
extension TaskboardTools {
    static let conversationProperty: Value = property("string", Copy.text("agent.mcp.conversations.conversationProperty"))

    /// 使える名前はマシンの Claude Code が返す一覧で決まるので enum にしない（`claudeModel` が確かめる）
    static let claudeModelText = Copy.text("agent.mcp.conversations.claudeModelText")
    static let claudeModelProperty: Value = property("string", claudeModelText)

    /// マシンの Claude Code のモデルの一覧。API の無い daemon と、まだ一覧を受けていない daemon は既定の一覧
    func claudeModels() async -> ClaudeModels {
        ClaudeModels(try? await client.claudeMachine())
    }

    /// 一覧の名前を `--model` に渡す名前にそろえる。無い名前は、選べる名前を並べて断る
    func claudeModel(_ value: String, field: String = "model", in models: ClaudeModels) throws -> String {
        guard let argument = models.argument(for: value) else {
            throw ToolError.invalid(models.rejection(value, field: field))
        }
        return argument
    }

    static let conversationTools: [ToolEntry] = [
        ToolEntry(
            name: "session_control",
            description:
                Copy.text("agent.tool.session_control"),
            inputSchema: schema([
                "conversation_id": conversationProperty,
                "model": property("string", Copy.text("agent.tool.session_control.model", ["claudeModel": claudeModelText])),
                "effort": property("string", Copy.text("agent.tool.session_control.effort", ["efforts": Effort.allCases.map(\.rawValue).joined(separator: "・")])),
                "permission_mode": property("string", enum: ConversationInput.acceptedPermissionModes),
                "notify": property("boolean", Copy.text("agent.tool.session_control.notify")),
                "interrupt": property("boolean", Copy.text("agent.tool.session_control.interrupt")),
            ], required: ["conversation_id"])) { tools, args in try await tools.sessionControl(args) },
        ToolEntry(
            name: "session_answer",
            description:
                Copy.text("agent.tool.session_answer"),
            inputSchema: schema([
                "conversation_id": conversationProperty,
                "request_id": property("string", Copy.text("agent.tool.session_answer.request_id")),
                "answers": property("array", Copy.text("agent.tool.session_answer.answers"), items: schema([
                        "question_id": property("string", Copy.text("agent.tool.session_answer.question_id")),
                        "selected": property("array", Copy.text("agent.tool.session_answer.selected"), items: property("string")),
                        "free_text": property("string", Copy.text("agent.tool.session_answer.free_text")),
                    ])),
                "allow": property("boolean", Copy.text("agent.tool.session_answer.allow")),
                "message": property("string", Copy.text("agent.tool.session_answer.message")),
                "suggestion_id": property(
                    "string",
                    Copy.text("agent.mcp.conversations.conversationTools.4")),
                "action": property("string", Copy.text("agent.tool.session_answer.action"), enum: ElicitationAction.allCases.map(\.rawValue)),
                "content": property("object", Copy.text("agent.tool.session_answer.content")),
            ], required: ["conversation_id"])) { tools, args in try await tools.sessionAnswer(args) },
        ToolEntry(
            name: "session_fork",
            description:
                Copy.text("agent.tool.session_fork"),
            inputSchema: schema([
                "conversation_id": conversationProperty,
                "message_id": property("string", Copy.text("agent.tool.session_fork.message_id")),
                "prompt": property("string", Copy.text("agent.tool.session_fork.prompt")),
            ], required: ["conversation_id"])) { tools, args in try await tools.sessionFork(args) },
    ]

    // MARK: 引く・書く

    /// id か、先頭 8 字以上で 1 つに決まる頭から会話を引く
    static func conversation(_ given: String, in conversations: [Conversation]) throws -> Conversation {
        let value = given.lowercased()
        if let exact = conversations.first(where: { $0.id == value }) { return exact }
        guard value.count >= 8 else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.value")) }
        let matches = conversations.filter { $0.id.hasPrefix(value) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw ToolError.invalid(Copy.text("agent.mcp.conversations.matches", ["given": "\(given)"]))
        default: throw ToolError.invalid(Copy.text("agent.mcp.conversations.matches.2", ["given": "\(given)", "matches": "\(matches.count)"]))
        }
    }

    /// session_list・止める・終了の確かめの会話の行（自分の会話に印を付ける）
    static func describe(conversation: Conversation, tasks: [BoardTask], own: String?) -> String {
        let taskTitle = conversation.taskNumber.flatMap { number in tasks.first { $0.number == number }?.title }
        return Copy.text("agent.mcp.conversations.taskTitle") + conversation.line(taskTitle: taskTitle) + (conversation.id == own ? Copy.text("agent.mcp.conversations.taskTitle.2") : "")
    }

    /// `answers` の入力を、問いの選択肢と照らして `AskAnswer` に
    /// MCP の server の問いの入力。欄の値は文字・数・真偽だけ
    static func elicitationContent(_ value: Value) throws -> [String: ElicitationValue] {
        guard let object = value.objectValue else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.elicitationContent")) }
        return try object.mapValues { field in
            switch field {
            case .string(let text): .string(text)
            case .int(let number): .number(Double(number))
            case .double(let number): .number(number)
            case .bool(let flag): .bool(flag)
            default: throw ToolError.invalid(Copy.text("agent.mcp.conversations.bool"))
            }
        }
    }

    static func answers(_ values: [Value], for questions: [AskQuestion]) throws -> [AskAnswer] {
        try values.enumerated().map { index, value in
            guard let object = value.objectValue else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.answers", ["index": "\(index)"])) }
            let question: AskQuestion
            if let id = object["question_id"]?.stringValue, !id.isEmpty {
                guard let found = questions.first(where: { $0.id == id }) else {
                    throw ToolError.invalid(Copy.text("agent.mcp.conversations.question", ["id": "\(id)"]) + questions.map(\.id).joined(separator: ", "))
                }
                question = found
            } else {
                guard questions.count == 1 else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.question.2", ["questions": "\(questions.count)"])) }
                question = questions[0]
            }
            let selected = (object["selected"]?.arrayValue ?? []).compactMap(\.stringValue)
            let answer = AskAnswer(questionID: question.id, selected: selected, freeText: object["free_text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
            guard answer.isAnswered else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.answer", ["id": "\(question.id)"])) }
            return answer
        }
    }

    // MARK: tool

    /// `#12 題` の形。タスクが無ければ番号だけ
    static func taskLabel(_ number: Int, in snapshot: StateSnapshot) -> String {
        "#\(number)" + (snapshot.tasks.first { $0.number == number }.map { " \($0.title)" } ?? "")
    }

    func conversationLines(_ snapshot: StateSnapshot) -> [String] {
        let conversations = snapshot.conversations.filter { !$0.isClosed }.sorted { ($0.phase == .stopped ? 1 : 0, $1.updatedAt) < ($1.phase == .stopped ? 1 : 0, $0.updatedAt) }
        return conversations.map { "- " + Self.describe(conversation: $0, tasks: snapshot.tasks, own: conversationID) + " ・ \(TaskboardLink.conversation($0.key).url.absoluteString)" }
    }

    func conversationPrompt(_ given: String, text: String) async throws -> String {
        let conversation = try Self.conversation(given, in: try await client.snapshot().conversations)
        if conversation.id == conversationID { throw ToolError.invalid(Copy.text("agent.mcp.conversations.conversation")) }
        let response = try await client.sendConversation(conversation.id, ConversationSendRequest(text: try await sessionPromptText(text)))
        switch response.outcome {
        case "duplicate": return Copy.text("agent.mcp.conversations.response", ["id": "\(conversation.id)"])
        case "unknown": return Copy.text("agent.mcp.conversations.response.2", ["id": "\(conversation.id)"])
        default:
            var lines = [Copy.text("agent.mcp.conversations.lines"), "- conversation_id: \(conversation.id)", Copy.text("agent.mcp.conversations.lines.2", ["value": "\(text.count)"])]
            if conversation.phase == .stopped {
                lines.append(Copy.text("agent.mcp.conversations.lines.3"))
            } else if conversation.phase == .running || conversation.phase == .waiting {
                lines.append(Copy.text("agent.mcp.conversations.lines.4"))
            }
            return lines.joined(separator: "\n")
        }
    }

    func sessionAnswer(_ args: [String: Value]) async throws -> String {
        guard let given = args.string("conversation_id"), !given.isEmpty else { throw ToolError.missing("conversation_id") }
        let conversation = try Self.conversation(given, in: try await client.snapshot().conversations)
        if conversation.id == conversationID { throw ToolError.invalid(Copy.text("agent.mcp.conversations.conversation.2")) }
        let requests = conversation.requests
        guard !requests.isEmpty else { return Copy.text("agent.mcp.conversations.requests", ["id": "\(conversation.id)"]) }
        let request: ConversationRequest
        if let id = args.string("request_id"), !id.isEmpty {
            guard let found = requests.first(where: { $0.id == id }) else {
                throw ToolError.invalid(Copy.text("agent.mcp.conversations.request", ["id": "\(id)"]) + requests.map(\.id).joined(separator: ", "))
            }
            request = found
        } else if requests.count == 1 {
            request = requests[0]
        } else {
            return ([Copy.text("agent.mcp.conversations.request.2", ["requests": "\(requests.count)"])] + requests.flatMap(\.lines)).joined(separator: "\n")
        }
        var body = ConversationAnswerRequest(requestID: request.id)
        let suggestionID = args.string("suggestion_id").flatMap { $0.isEmpty ? nil : $0 }
        if let suggestionID {
            guard request.kind == .permission, args.bool("allow") == true else {
                throw ToolError.invalid(Copy.text("agent.mcp.conversations.suggestionID"))
            }
            let offered = PermissionSuggestion.shown(request.suggestions)
            guard offered.contains(where: { $0.id == suggestionID }) else {
                throw ToolError.invalid(Copy.text("agent.mcp.core.invalidChoice", ["name": "suggestion_id", "choices": offered.map(\.id).joined(separator: "・")]))
            }
        }
        switch request.kind {
        case .question:
            guard let values = args.array("answers"), !values.isEmpty else {
                return ([Copy.text("agent.mcp.conversations.question.3")] + request.lines).joined(separator: "\n")
            }
            body.answers = try Self.answers(values, for: request.waiting.questions ?? [])
        case .permission, .plan:
            guard let allow = args.bool("allow") else {
                return ([Copy.text("agent.mcp.conversations.permission")] + request.lines).joined(separator: "\n")
            }
            body.allow = allow
            body.message = args.string("message").flatMap { $0.isEmpty ? nil : $0 }
            body.suggestionID = suggestionID
        case .elicitation:
            guard let given = args.string("action") else {
                return ([Copy.text("agent.mcp.conversations.elicitation")] + request.lines).joined(separator: "\n")
            }
            guard let action = ElicitationAction(rawValue: given) else { throw ToolError.invalid(Copy.text("agent.mcp.core.invalidChoice", ["name": "action", "choices": ElicitationAction.allCases.map(\.rawValue).joined(separator: "・")])) }
            let content = try args["content"].map(Self.elicitationContent)
            do {
                try request.elicitation?.check(action, content: content)
            } catch {
                throw ToolError.invalid(error.description)
            }
            body.action = action
            body.content = content
        case .unknown:
            return Copy.text("agent.mcp.conversations.unknown", ["toolName": "\(request.toolName)"])
        }
        try await client.answerConversation(conversation.id, body)
        return Copy.text("agent.mcp.conversations.unknown.2", ["id": "\(conversation.id)", "id2": "\(request.id)"])
    }

    func sessionFork(_ args: [String: Value]) async throws -> String {
        guard let given = args.string("conversation_id"), !given.isEmpty else { throw ToolError.missing("conversation_id") }
        let snapshot = try await client.snapshot()
        let source = try Self.conversation(given, in: snapshot.conversations)
        let messageID = args.string("message_id").flatMap { $0.isEmpty ? nil : $0 }
        let prompt = args.string("prompt").flatMap { $0.isEmpty ? nil : $0 }
        let fork = try await client.forkConversation(source.id, ConversationForkRequest(messageID: messageID, prompt: prompt))
        return [
            Copy.text("agent.mcp.conversations.fork"), Copy.text("agent.mcp.conversations.fork.2", ["id": "\(source.id)"]), "- conversation_id: \(fork.id)", Copy.text("agent.mcp.conversations.fork.3") + (messageID.map { Copy.text("agent.mcp.conversations.fork.4", ["value": "\($0)"]) } ?? Copy.text("agent.mcp.conversations.fork.5")),
            Copy.text("agent.mcp.conversations.fork.6") + (fork.taskNumber.map { Self.taskLabel($0, in: snapshot) } ?? Copy.text("agent.mcp.conversations.fork.7")),
            Copy.text("agent.mcp.conversations.fork.8"),
        ].joined(separator: "\n")
    }

    func conversationStop(_ given: String, _ args: [String: Value]) async throws -> String {
        let snapshot = try await client.snapshot()
        let conversation = try Self.conversation(given, in: snapshot.conversations)
        if conversation.id == conversationID { throw ToolError.invalid(Copy.text("agent.mcp.conversations.conversation.3")) }
        guard conversation.phase != .stopped else {
            // 止まっていても、利用枠の上限の後・ネットワークが戻った後に続きを送る予定があれば取り消す
            guard conversation.limitResumeAt != nil || conversation.networkResume == true else { return Copy.text("agent.mcp.conversations.conversation.4", ["id": "\(conversation.id)"]) }
            _ = try await client.controlConversation(conversation.id, ConversationControlRequest(kind: .cancelLimitResume))
            let wait = conversation.limitResumeAt != nil ? Copy.text("agent.mcp.conversations.wait") : Copy.text("agent.mcp.conversations.wait.2")
            return Copy.text("agent.mcp.conversations.wait.3", ["wait": "\(wait)", "id": "\(conversation.id)"])
        }
        let busy = conversation.interruptedByStop
        if busy, args.bool("force") != true {
            throw ToolError.invalid(Copy.text("agent.mcp.conversations.busy", ["id": "\(conversation.id)", "phase": "\(conversation.phase.rawValue)"]))
        }
        let unbound = conversation.removedOnStop
        if busy || unbound, !Self.isConfirmed(args) {
            var lines = [Self.describe(conversation: conversation, tasks: snapshot.tasks, own: conversationID)]
            if busy { lines.append(Copy.text("agent.mcp.conversations.lines.5")) }
            lines.append(unbound ? Copy.text("agent.mcp.conversations.lines.6") : Copy.text("agent.mcp.conversations.lines.7"))
            return Self.confirmation(lines, stopping: true)
        }
        try await client.stopConversation(conversation.id)
        var lines = [Copy.text("agent.mcp.conversations.lines.8"), "- conversation_id: \(conversation.id)", unbound ? Copy.text("agent.mcp.conversations.lines.9") : Copy.text("agent.mcp.conversations.lines.10")]
        if !unbound { lines.append(Copy.text("agent.mcp.conversations.lines.11")) }
        return lines.joined(separator: "\n")
    }

    /// 会話の終了（`session_stop` の `close`）。記録は消さないので、生成中に止めるときだけ confirm: true を求める
    func conversationClose(_ given: String, _ args: [String: Value]) async throws -> String {
        let snapshot = try await client.snapshot()
        let conversation = try Self.conversation(given, in: snapshot.conversations)
        if conversation.id == conversationID { throw ToolError.invalid(Copy.text("agent.mcp.conversations.conversation.5")) }
        let busy = conversation.interruptedByStop
        if busy, args.bool("force") != true {
            throw ToolError.invalid(Copy.text("agent.mcp.conversations.busy.2", ["id": "\(conversation.id)", "phase": "\(conversation.phase.rawValue)"]))
        }
        if busy, !Self.isConfirmed(args) {
            return Self.confirmation([Self.describe(conversation: conversation, tasks: snapshot.tasks, own: conversationID), Copy.text("agent.mcp.conversations.lines.5")], stopping: true)
        }
        try await client.closeConversation(conversation.id)
        return [
            Copy.text("agent.mcp.conversations.busy.3"), "- conversation_id: \(conversation.id)", Copy.text("agent.mcp.conversations.busy.4"), Copy.text("agent.mcp.conversations.lines.11"),
        ].joined(separator: "\n")
    }

    func conversationResume(_ given: String, account: String? = nil) async throws -> String {
        let conversation = try Self.conversation(given, in: try await client.snapshot().conversations)
        guard conversation.phase == .stopped else { return Copy.text("agent.mcp.conversations.conversation.6", ["id": "\(conversation.id)", "phase": "\(conversation.phase.rawValue)"]) }
        if let account { _ = try await client.switchAccount(SessionAccountRequest(conversationID: conversation.id, account: account)) }
        let resumed = try await client.resumeConversation(conversation.id)
        return [
            Copy.text("agent.mcp.conversations.resumed"), "- conversation_id: \(resumed.id)", Copy.text("agent.mcp.conversations.resumed.2", ["phase": "\(resumed.phase.rawValue)"]), Copy.text("agent.mcp.conversations.resumed.3", ["cwd": "\(resumed.cwd)"]),
            Copy.text("agent.mcp.conversations.fork.8"),
        ].joined(separator: "\n")
    }

    /// `codex` を渡すと codex の会話（モデルと effort は codex の名前）。nil なら `choice` の Claude の会話
    func conversationStart(
        task number: Int, cwd: String, choice: LaunchChoice, prompt: String, delegating: Bool,
        args: [String: Value], snapshot: StateSnapshot
    ) async throws -> String {
        let disallowed = ConversationInput.disallowedToolsArguments(args.strings("disallowed_tools") ?? [])
        if choice.kind == .codex, !disallowed.isEmpty { throw ToolError.invalid(Copy.text("agent.mcp.conversations.disallowed")) }
        let parent = session.parent
        let orchestrator = snapshot.orchestrator
        let fromOrchestrator =
            conversationID != nil && orchestrator?.conversationID == conversationID
        let notify = args.bool("notify") ?? (parent != nil && delegating && !fromOrchestrator)
        if notify, parent == nil { throw ToolError.invalid(Copy.text("agent.mcp.conversations.notify")) }
        var request = ConversationStartRequest(
            cwd: cwd, taskNumber: number, model: choice.kind == .codex ? choice.codexModel : choice.model, effort: choice.kind == .codex ? choice.codexEffort : choice.effort?.rawValue,
            prompt: prompt.isEmpty ? nil : prompt, extraArgs: disallowed.isEmpty ? nil : disallowed, parent: notify ? parent : nil,
            notifyParent: notify ? true : nil, engine: choice.kind == .codex ? .codex : nil, account: try Self.account(args, kind: choice.kind))
        let models = await claudeModels()
        // 案件の起動の既定がモデルと effort の形に合わない引数なら、wake と同じく会話の引数に読み替える
        if let custom = choice.custom {
            guard choice.kind == .claude, let converted = ConversationArguments.convert(custom, models: models) else {
                let options = custom.filter { $0.hasPrefix("-") }.map { String($0.prefix { $0 != "=" }) }
                throw ToolError.invalid(Copy.text("agent.mcp.conversations.options", ["options": "\(options.joined(separator: " "))"]))
            }
            request.model = converted.model
            request.effort = converted.effort
            request.permissionMode = converted.permissionMode
            let extra = converted.extraArgs + disallowed
            request.extraArgs = extra.isEmpty ? nil : extra
        }
        if let branch = args.string("worktree_branch"), !branch.isEmpty {
            request.worktree = LaunchRequest.WorktreeSpec(branch: branch, base: args.string("worktree_base"))
        }
        let conversation = try await client.startConversation(request)
        var lines = [
            Copy.text("agent.mcp.conversations.lines.12"), "- conversation_id: \(conversation.id)", Copy.text("agent.mcp.conversations.fork.6") + Self.taskLabel(number, in: snapshot), Copy.text("agent.mcp.conversations.lines.13", ["summary": "\(choice.summary(models))"]),
            Copy.text("agent.mcp.conversations.resumed.3", ["cwd": "\(conversation.cwd)"]),
        ]
        if notify { lines.append(Copy.text("agent.mcp.conversations.lines.14")) }
        lines.append(Copy.text("agent.mcp.conversations.lines.15"))
        return lines.joined(separator: "\n")
    }

    func sessionControl(_ args: [String: Value]) async throws -> String {
        guard let given = args.string("conversation_id"), !given.isEmpty else { throw ToolError.missing("conversation_id") }
        let conversation = try Self.conversation(given, in: try await client.snapshot().conversations)
        var requests: [(String, ConversationControlRequest)] = []
        if let model = args.string("model") {
            let argument: String
            if conversation.engine == .codex {
                guard ConversationInput.acceptsCodexName(model) else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.argument", ["model": "\(model)"])) }
                argument = model
            } else {
                argument = try claudeModel(model, in: await claudeModels())
            }
            requests.append((Copy.text("agent.mcp.conversations.argument.2", ["model": "\(model)"]), ConversationControlRequest(kind: .setModel, value: argument)))
        }
        if let effort = args.string("effort") {
            if conversation.engine == .codex {
                guard ConversationInput.acceptsCodexName(effort) else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.argument.3", ["effort": "\(effort)"])) }
            } else {
                guard Effort(rawValue: effort) != nil else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.argument.4", ["effort": "\(effort)"]) + Effort.allCases.map(\.rawValue).joined(separator: ", ")) }
            }
            requests.append((Copy.text("agent.mcp.conversations.argument.5", ["effort": "\(effort)"]), ConversationControlRequest(kind: .setEffort, value: effort)))
        }
        if let mode = args.string("permission_mode") {
            requests.append((Copy.text("agent.mcp.conversations.argument.6", ["mode": "\(mode)"]), ConversationControlRequest(kind: .setPermissionMode, value: mode)))
        }
        if let notify = args.bool("notify") {
            requests.append((notify ? Copy.text("agent.mcp.conversations.argument.7") : Copy.text("agent.mcp.conversations.argument.8"), ConversationControlRequest(kind: .setNotifyParent, value: notify ? "on" : "off")))
        }
        if args.bool("interrupt") == true {
            if conversation.id == conversationID { throw ToolError.invalid(Copy.text("agent.mcp.conversations.argument.9")) }
            requests.append((Copy.text("agent.mcp.conversations.argument.10"), ConversationControlRequest(kind: .interrupt)))
        }
        guard !requests.isEmpty else { throw ToolError.invalid(Copy.text("agent.mcp.conversations.argument.11")) }
        var done: [String] = []
        for (label, request) in requests {
            _ = try await client.controlConversation(conversation.id, request)
            done.append(label)
        }
        var lines = [Copy.text("agent.mcp.conversations.lines.16"), "- conversation_id: \(conversation.id)", Copy.text("agent.mcp.conversations.lines.17") + done.joined(separator: "、")]
        if conversation.phase == .stopped { lines.append(Copy.text("agent.mcp.conversations.lines.18")) }
        return lines.joined(separator: "\n")
    }

    /// 会話の直近の発言（`session_history` の `conversation_id`）。文は 1 件 2,000 字まで、tool の結果は名前だけ
    func conversationHistory(_ given: String, limit: Int) async throws -> String {
        let conversation = try Self.conversation(given, in: try await client.snapshot().conversations)
        let history = try await client.conversationHistory(conversation.id, limit: max(1, min(limit, ConversationHistoryResponse.maxLimit)))
        guard !history.messages.isEmpty else { return Copy.text("agent.mcp.conversations.history", ["id": "\(conversation.id)"]) }
        var lines = [Copy.text("agent.mcp.conversations.lines.19", ["id": "\(conversation.id)", "messages": "\(history.messages.count)"])]
        let toolNames = Dictionary(
            history.messages.compactMap { message in message.kind == .toolUse ? message.toolID.map { ($0, message.toolName ?? "?") } : nil },
            uniquingKeysWith: { first, _ in first })
        for message in history.messages {
            let who = message.role == .user ? "user" : "assistant"
            switch message.kind {
            case .text where message.isInjected:
                // Skill の本文などは長く、人の発言でもないので先頭の 1 行だけ
                lines.append(Copy.text("agent.mcp.conversations.text", ["split": "\(message.text.split(separator: "\n").first.map { String($0.prefix(200)) } ?? "")"]))
            case .text where message.isThinking:
                // 返事ではないので、返事と取り違えないよう印を付けて先頭の 1 行だけ
                lines.append(Copy.text("agent.mcp.conversations.text.2", ["split": "\(message.text.split(separator: "\n").first.map { String($0.prefix(200)) } ?? "")"]))
            case .text:
                let text = message.text.count > Self.historyTextLimit ? String(message.text.prefix(Self.historyTextLimit)) + "…" : message.text
                lines.append("- \(who): \(text)")
            case .toolUse: lines.append(Copy.text("agent.mcp.conversations.toolUse", ["who": "\(who)", "toolName": "\(message.toolName ?? "?")"]))
            case .toolResult:
                let name = message.toolName ?? message.toolID.flatMap { toolNames[$0] } ?? "?"
                lines.append(Copy.text("agent.mcp.conversations.name", ["name": "\(name)"]) + (message.isError ? "（error）" : ""))
            case .notice: continue
            }
        }
        return lines.joined(separator: "\n")
    }

    static let historyTextLimit = 2000

    /// アプリの［名前を変更…］と同じ口（`.rename`）。空なら名前を外し、自動の題に戻す
    func conversationRename(_ given: String, title: String) async throws -> String {
        let conversation = try Self.conversation(given, in: try await client.snapshot().conversations)
        let name = ConversationInput.title(title)
        if let name, !ConversationInput.acceptsTitle(name) {
            throw ToolError.invalid(Copy.text("agent.mcp.conversations.name.2", ["titleLimit": "\(ConversationInput.titleLimit)"]))
        }
        _ = try await client.controlConversation(conversation.id, ConversationControlRequest(kind: .rename, value: name))
        guard let name else { return Copy.text("agent.mcp.conversations.name.3", ["id": "\(conversation.id)"]) }
        return Copy.text("agent.mcp.conversations.name.4", ["id": "\(conversation.id)", "name": "\(name)"])
    }

    // MARK: health

    static func describe(agentHost: AgentHostInfo, conversations: [Conversation]) -> String {
        if agentHost.draining {
            let names = agentHost.remaining.map { id in
                conversations.first { $0.id == id }.flatMap { $0.title.map { "\(id.prefix(8))「\($0)」" } } ?? String(id.prefix(8))
            }
            return Copy.text("agent.mcp.conversations.names", ["names": "\(names.count)"])
                + (names.isEmpty ? "" : ": " + names.joined(separator: "、") + Copy.text("agent.mcp.conversations.names.2"))
        }
        guard agentHost.connected else { return Copy.text("agent.mcp.conversations.names.3") }
        let live = conversations.filter { $0.phase != .stopped }
        let counts = [Conversation.Phase.starting, .idle, .running, .waiting].compactMap { phase -> String? in
            let n = live.filter { $0.phase == phase }.count
            return n == 0 ? nil : "\(phase.rawValue) \(n)"
        }
        return Copy.text("agent.mcp.conversations.n", ["live": "\(live.count)"]) + (counts.isEmpty ? "" : "（" + counts.joined(separator: " / ") + "）")
    }

    static func describe(waiting conversation: Conversation, tasks: [BoardTask]) -> String {
        var line = Copy.text("agent.mcp.conversations.line", ["id": "\(conversation.id.prefix(8))"])
        if let title = conversation.title, !title.isEmpty { line += " 「\(title)」" }
        if let number = conversation.taskNumber, let task = tasks.first(where: { $0.number == number }) { line += " → #\(number) \(task.title)" }
        let kinds = conversation.requests.map(\.kindLabel)
        return line + ": " + kinds.joined(separator: "、") + Copy.text("agent.mcp.conversations.kinds")
    }
}
