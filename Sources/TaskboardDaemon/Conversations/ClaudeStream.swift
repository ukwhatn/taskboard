import Foundation
import TaskboardKit

/// Claude Code を stream-json で動かしたときの出力の 1 行（`claude -p --output-format stream-json --verbose --include-partial-messages`）。
/// 形は 2.1.302 の実測（`system/init`・`stream_event`・`control_request` など）と Agent SDK の型に合わせる。
/// 知らない種類は `.other` にして読み飛ばす。`system` の subtype と最上位の種類は版ごとに増え（2.1.302 で `system` だけで 60 種類）、
/// `/clear` も最上位の `conversation_reset` で届くので、知らない種類で会話を止めると普段の操作で止まる
enum ClaudeStreamLine: Equatable, Sendable {
    /// `system/init`。会話が始まったときと `--resume` で戻ったとき
    case initialized(ClaudeSessionInfo)
    /// `system/session_state_changed`
    case phase(ClaudeTurnPhase)
    /// `system/session_title_changed`
    case titleChanged(String)
    /// `/` で使えるコマンドの一覧が変わった（plugin の読み込みなど）
    case commandsChanged([ConversationCommand])
    /// `/clear` で Claude の会話 ID が変わった
    case conversationReset(sessionID: String)
    /// `system/compact_boundary`。会話を圧縮した。区切りの行を添える（transcript の区切りと同じ id）
    case compacted(ChatMessage)
    /// `system/status` の `compacting`。自動の圧縮では要約の字数（`compact_output_chars`）が増えるたびに届く（2.1.304 の型の説明）
    case compacting(outputChars: Int?)
    /// `system/status` の `status: null`。圧縮の後なら `compact_result`（`success`・`failed`）と `compact_error` が付く
    case statusCleared(compactFailed: Bool, error: String?)
    /// `system/api_retry`：API に届かず（または断られ）CLI が送り直す。利用枠の待ちの間の心拍も同じ形で届く（2.1.304 の型の説明）。
    /// `kind` は CLI の `error`（`overloaded`・`rate_limit`・`authentication_failed`・`server_error`・`cloud_credential_error`・`unknown`）。`status` は HTTP の status で、つながらないときは nil
    case apiRetry(attempt: Int, maxRetries: Int?, delayMs: Int, status: Int?, kind: String)
    /// 裏のタスク（`run_in_background` の Bash など）。`system/task_started` で始まり、`task_updated` の `patch.status` か
    /// `task_notification` の `status` が終わりの値になったら `finished`（2.1.302 で実測。ターンの後に届き、CLI が自分で次のターンを起こす）。
    /// 種類と説明と始めた tool_use は始まりの行にだけ載る。`foreground` は、主の流れの tool が前景で結果を待っている task
    /// （`is_backgrounded` が false で、subagent の中でない。`background_tasks` で裏に回せる）。`status` は終わりの値（`completed`・`failed`・`killed`・`stopped`）
    case backgroundTask(
        id: String, finished: Bool, type: String? = nil, description: String? = nil, toolUseID: String? = nil, foreground: Bool = false,
        backgrounded: Bool? = nil, status: String? = nil)
    /// `background_tasks_changed`：CLI の主の流れの task の一覧そのもの（前景のものも入り、subagent の中のものは入らない。裏に回ったかは載らない）
    case backgroundTaskList([ConversationBackgroundTasks.Task])
    /// 前景の task が裏に回った（`task_updated` の `patch.is_backgrounded`）
    case taskBackgrounded(id: String)
    /// 送った発言の受付（`command_lifecycle`）。`messageID` は送ったときに振った uuid
    case accepted(messageID: String, state: String)
    /// 直前に `started` になった発言を、UserPromptSubmit の hook が答えを出せないまま（時間切れ・失敗）CLI が捨てた
    /// （`system/informational` の `prompt_submit_outcome` が `no_verdict` で `prompt_kept` が false。発言の uuid は載らない。2.1.304 で実測）。
    /// hook が止めた（`no_verdict` でない）発言は含めない
    case promptDropped(reason: String?)
    /// 生成中の差分
    case stream(ClaudeStreamEvent)
    /// 終わった発言（`assistant`・`user`）。`parentToolUseID` はサブエージェントの中の発言
    /// `apiMessageID` は assistant の行の API の message の id（差分の `messageID` と同じ）
    case messages([ChatMessage], parentToolUseID: String?, apiMessageID: String?)
    /// `user`・`assistant` なのに `message` を読めない。読み飛ばすと会話の中身を取り違えるので、会話を止める
    case incompatible(type: String)
    case result(ClaudeTurnResult)
    /// `rate_limit_event`。鍵は `five_hour`・`seven_day`。`limit` は今の状態（`rejected` なら上限で断られている）と戻る時刻
    case rateLimits([String: UsageWindow], limit: ClaudeRateLimit?)
    /// CLI からの制御要求。応答を返すまで CLI は待つ
    case request(ClaudeControlRequest)
    /// CLI が制御要求を取り下げた（interrupt で問いが消えたときなど）
    case cancelRequest(requestID: String)
    /// こちらの制御要求への応答
    case response(ClaudeControlResponse)
    case other(type: String, subtype: String?)
    case unreadable
}

struct ClaudeSessionInfo: Equatable, Sendable {
    var sessionID: String
    var model: String?
    var permissionMode: String?
    var cwd: String?
    var version: String?
    var capabilities: [String]
    var tools: [String]
    var slashCommands: [String]
    var mcpServers: [ClaudeMCPServer]
}

struct ClaudeMCPServer: Equatable, Sendable {
    var name: String
    var status: String
}

/// `session_state_changed` の state。`requiresAction` は権限か質問の答えを待っている
enum ClaudeTurnPhase: String, Equatable, Sendable {
    case running
    case requiresAction = "requires_action"
    case idle
}

struct ClaudeStreamEvent: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case text
        case thinking
        case toolUse(id: String, name: String)
        case other(String)
    }

    enum Kind: Equatable, Sendable {
        case messageStart(model: String?)
        case blockStart(index: Int, Block)
        case textDelta(index: Int, String)
        case thinkingDelta(index: Int, String)
        case toolInputDelta(index: Int, String)
        case blockStop(index: Int)
        case messageDelta(stopReason: String?)
        case messageStop
        case other(String)
    }

    /// API の message の id（`api_message_id`）。同じ発言の差分をまとめる
    var messageID: String?
    var parentToolUseID: String?
    var kind: Kind
}

/// `rate_limit_info` の `status` が `rejected` か（ほかは `allowed`・`allowed_warning`）と `resetsAt`。断られている間は前の値が残る
struct ClaudeRateLimit: Equatable, Sendable {
    var rejected: Bool
    var resetsAt: Date?
}

struct ClaudeTurnResult: Equatable, Sendable {
    /// `success`・`error_during_execution`・`error_max_turns` など
    var subtype: String
    var isError: Bool
    var stopReason: String?
    var terminalReason: String?
    var text: String?
    var sessionID: String?
    var durationMs: Int?
    var ttftMs: Int?
    var costUSD: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    /// `modelUsage` のモデルごとの値の和（その Claude の会話の累計。サブエージェントのモデルも入る。`usage` はそのターンの分）
    var tokens: ConversationStats.Tokens?
    var userMessageIDs: [String]
    /// PreToolUse の hook が `defer` を返して終わったときの、止めたツールの呼び出し
    var deferred: ClaudeDeferredTool?
    /// API に繋がらずに終わった（送り直しを使い切った）。HTTP の応答が無いので `api_error_status` が null（2.1.310 で実測。
    /// 利用枠の上限・認証の失敗・過負荷は status が付き、人の中断は `terminal_reason` が違う）
    var connectionFailed = false
}

/// defer で止めたツールの呼び出し。`--resume` で戻すと、同じ `toolUseID` の PreToolUse がもう一度来る
struct ClaudeDeferredTool: Codable, Equatable, Sendable {
    var toolUseID: String
    var name: String
    /// ツールの入力の JSON（答えを足して `updatedInput` で返す）
    var inputJSON: String
}

struct ClaudeControlRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case canUseTool(ClaudeToolPermission)
        case hookCallback(ClaudeHookCall)
        case elicitation(ClaudeElicitationRequest)
        case other(String)
    }

    var requestID: String
    var kind: Kind
}

/// `elicitation`：MCP の server が人に聞く問い。`url` は全文を持つので、ログ・state・DB に出さない
struct ClaudeElicitationRequest: Equatable, Sendable {
    var serverName: String
    var message: String
    /// form・url。省いたら form（MCP の仕様）
    var mode: String
    var url: String?
    var elicitationID: String?
    /// `requested_schema` の JSON
    var schemaJSON: Data?
    var title: String?
}

/// `can_use_tool`。AskUserQuestion と ExitPlanMode も、権限の確認と同じ形で届く
struct ClaudeToolPermission: Equatable, Sendable {
    var toolName: String
    var toolUseID: String?
    var inputJSON: String
    /// CLI が付けた説明（Bash のコマンドの説明、書くファイルの名前など）
    var description: String?
    var suggestionsJSON: String?
    /// 「常に許可」の規則が確認の範囲より広くなるので、候補を出さない確認（`suppress_always_allow_rule`）
    var suppressAlwaysAllowRule = false
}

struct ClaudeHookCall: Equatable, Sendable {
    var callbackID: String
    var event: String?
    var sessionID: String?
    var toolName: String?
    var toolUseID: String?
    var toolInputJSON: String?
    var transcriptPath: String? = nil
    var cwd: String? = nil
    /// サブエージェントの中から来た hook だけ
    var agentID: String? = nil
    /// Stop だけ：ターンの最後の応答の文（transcript はこの時点でまだ書けていないことがある）
    var lastAssistantMessage: String? = nil
}

struct ClaudeControlResponse: Equatable, Sendable {
    var requestID: String
    var isSuccess: Bool
    var payloadJSON: String?
    var error: String?
    /// `initialize` の応答だけ：CLI が答えを待っている `can_use_tool`（`response` の外、`subtype` と同じ階層に載る）。無い版は nil
    var pendingRequests: [ClaudeControlRequest]? = nil
    /// この応答の行の host の控えの番号（行を読んだ会話が入れる）
    var seq = 0
}

enum ClaudeStreamParser {
    static func parse(_ line: Data, index: Int = 0) -> ClaudeStreamLine {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = object["type"] as? String else {
            return .unreadable
        }
        switch type {
        case "system": return system(object)
        case "conversation_reset":
            guard let id = object["new_conversation_id"] as? String else { return .other(type: type, subtype: nil) }
            return .conversationReset(sessionID: id)
        case "command_lifecycle":
            guard let id = object["command_uuid"] as? String, let state = object["state"] as? String else { return .other(type: type, subtype: nil) }
            return .accepted(messageID: id, state: state)
        case "stream_event": return stream(object)
        case "user", "assistant":
            switch TranscriptParser.parse(object: object, index: index) {
            case .messages(let messages):
                return .messages(
                    messages, parentToolUseID: object["parent_tool_use_id"] as? String,
                    apiMessageID: type == "assistant" ? (object["message"] as? [String: Any])?["id"] as? String : nil)
            case .ignored: return .messages([], parentToolUseID: object["parent_tool_use_id"] as? String, apiMessageID: nil)
            case .incompatible: return .incompatible(type: type)
            }
        case "result": return .result(result(object))
        case "rate_limit_event": return rateLimits(object)
        case "control_request": return request(object, line: line)
        case "control_cancel_request":
            guard let id = object["request_id"] as? String else { return .other(type: type, subtype: nil) }
            return .cancelRequest(requestID: id)
        case "control_response": return response(object)
        default: return .other(type: type, subtype: object["subtype"] as? String)
        }
    }

    /// 裏のタスクの終わりでない状態（SDK 0.2.132 の型の終わりは `completed`・`failed`・`stopped`。知らない値は終わりとして数から外す）
    static let runningTaskStatuses: Set<String> = ["pending", "running"]

    private static func system(_ object: [String: Any]) -> ClaudeStreamLine {
        let subtype = object["subtype"] as? String
        switch subtype {
        case "init":
            guard let sessionID = object["session_id"] as? String else { return .other(type: "system", subtype: subtype) }
            let servers = (object["mcp_servers"] as? [[String: Any]] ?? []).compactMap { server -> ClaudeMCPServer? in
                guard let name = server["name"] as? String else { return nil }
                return ClaudeMCPServer(name: name, status: server["status"] as? String ?? "")
            }
            return .initialized(
                ClaudeSessionInfo(
                    sessionID: sessionID, model: object["model"] as? String, permissionMode: object["permissionMode"] as? String,
                    cwd: object["cwd"] as? String, version: object["claude_code_version"] as? String,
                    capabilities: object["capabilities"] as? [String] ?? [], tools: object["tools"] as? [String] ?? [],
                    slashCommands: object["slash_commands"] as? [String] ?? [], mcpServers: servers))
        case "session_state_changed":
            guard let phase = (object["state"] as? String).flatMap(ClaudeTurnPhase.init(rawValue:)) else { return .other(type: "system", subtype: subtype) }
            return .phase(phase)
        case "session_title_changed":
            guard let title = object["title"] as? String else { return .other(type: "system", subtype: subtype) }
            return .titleChanged(title)
        case "compact_boundary":
            return .compacted(TranscriptParser.compactBoundary(object, index: 0))
        case "status":
            if object["status"] as? String == "compacting" { return .compacting(outputChars: object["compact_output_chars"] as? Int) }
            guard object["status"] is NSNull else { return .other(type: "system", subtype: subtype) }
            return .statusCleared(compactFailed: object["compact_result"] as? String == "failed", error: object["compact_error"] as? String)
        case "api_retry":
            guard let attempt = object["attempt"] as? Int else { return .other(type: "system", subtype: subtype) }
            return .apiRetry(
                attempt: attempt, maxRetries: object["max_retries"] as? Int, delayMs: object["retry_delay_ms"] as? Int ?? 0,
                status: object["error_status"] as? Int, kind: object["error"] as? String ?? "unknown")
        case "commands_changed":
            guard let commands = ClaudeControls.commands(object["commands"]) else { return .other(type: "system", subtype: subtype) }
            return .commandsChanged(commands)
        case "task_started":
            guard let id = object["task_id"] as? String else { return .other(type: "system", subtype: subtype) }
            let foreground = object["is_backgrounded"] as? Bool == false && object["parent_task_id"] == nil && object["owned_by_subagent"] as? Bool != true
            return .backgroundTask(
                id: id, finished: false, type: object["task_type"] as? String, description: object["description"] as? String,
                toolUseID: object["tool_use_id"] as? String, foreground: foreground, backgrounded: object["is_backgrounded"] as? Bool)
        case "background_tasks_changed":
            guard let tasks = object["tasks"] as? [[String: Any]] else { return .other(type: "system", subtype: subtype) }
            return .backgroundTaskList(tasks.compactMap { task in
                (task["task_id"] as? String).map {
                    ConversationBackgroundTasks.Task(id: $0, type: task["task_type"] as? String, description: task["description"] as? String)
                }
            })
        case "informational":
            guard let outcome = object["prompt_submit_outcome"] as? [String: Any], outcome["kind"] as? String == "no_verdict",
                outcome["prompt_kept"] as? Bool == false
            else { return .other(type: "system", subtype: subtype) }
            return .promptDropped(reason: outcome["no_verdict_kind"] as? String)
        case "task_updated", "task_notification":
            let patch = object["patch"] as? [String: Any]
            let status = subtype == "task_updated" ? patch?["status"] as? String : object["status"] as? String
            guard let id = object["task_id"] as? String else { return .other(type: "system", subtype: subtype) }
            if let status, !runningTaskStatuses.contains(status) { return .backgroundTask(id: id, finished: true, status: status) }
            if subtype == "task_updated", patch?["is_backgrounded"] as? Bool == true { return .taskBackgrounded(id: id) }
            return .other(type: "system", subtype: subtype)
        default:
            return .other(type: "system", subtype: subtype)
        }
    }

    private static func stream(_ object: [String: Any]) -> ClaudeStreamLine {
        guard let event = object["event"] as? [String: Any], let type = event["type"] as? String else {
            return .other(type: "stream_event", subtype: nil)
        }
        let index = event["index"] as? Int ?? 0
        let kind: ClaudeStreamEvent.Kind
        switch type {
        case "message_start":
            kind = .messageStart(model: (event["message"] as? [String: Any])?["model"] as? String)
        case "content_block_start":
            let block = event["content_block"] as? [String: Any] ?? [:]
            switch block["type"] as? String {
            case "text": kind = .blockStart(index: index, .text)
            case "thinking": kind = .blockStart(index: index, .thinking)
            case "tool_use": kind = .blockStart(index: index, .toolUse(id: block["id"] as? String ?? "", name: block["name"] as? String ?? ""))
            case let other: kind = .blockStart(index: index, .other(other ?? ""))
            }
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta": kind = .textDelta(index: index, delta["text"] as? String ?? "")
            case "thinking_delta": kind = .thinkingDelta(index: index, delta["thinking"] as? String ?? "")
            case "input_json_delta": kind = .toolInputDelta(index: index, delta["partial_json"] as? String ?? "")
            case let other: kind = .other(other ?? "content_block_delta")
            }
        case "content_block_stop": kind = .blockStop(index: index)
        case "message_delta": kind = .messageDelta(stopReason: (event["delta"] as? [String: Any])?["stop_reason"] as? String)
        case "message_stop": kind = .messageStop
        default: kind = .other(type)
        }
        return .stream(
            ClaudeStreamEvent(messageID: object["api_message_id"] as? String, parentToolUseID: object["parent_tool_use_id"] as? String, kind: kind))
    }

    private static func result(_ object: [String: Any]) -> ClaudeTurnResult {
        let usage = object["usage"] as? [String: Any] ?? [:]
        let deferred = (object["deferred_tool_use"] as? [String: Any]).flatMap { tool -> ClaudeDeferredTool? in
            guard let id = tool["id"] as? String, let name = tool["name"] as? String else { return nil }
            return ClaudeDeferredTool(toolUseID: id, name: name, inputJSON: json(tool["input"]) ?? "{}")
        }
        return ClaudeTurnResult(
            subtype: object["subtype"] as? String ?? "", isError: object["is_error"] as? Bool ?? false, stopReason: object["stop_reason"] as? String,
            terminalReason: object["terminal_reason"] as? String, text: object["result"] as? String, sessionID: object["session_id"] as? String,
            durationMs: object["duration_ms"] as? Int, ttftMs: object["ttft_ms"] as? Int, costUSD: object["total_cost_usd"] as? Double,
            inputTokens: usage["input_tokens"] as? Int, outputTokens: usage["output_tokens"] as? Int,
            tokens: modelUsageTotal(object["modelUsage"]), userMessageIDs: object["user_message_uuids"] as? [String] ?? [], deferred: deferred,
            connectionFailed: object["is_error"] as? Bool == true && object["terminal_reason"] as? String == "api_error" && object["api_error_status"] is NSNull)
    }

    static func modelUsageTotal(_ value: Any?) -> ConversationStats.Tokens? {
        guard let models = value as? [String: Any], !models.isEmpty else { return nil }
        var total = ConversationStats.Tokens(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        for case let usage as [String: Any] in models.values {
            func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            total.input += count("inputTokens")
            total.output += count("outputTokens")
            total.cacheRead += count("cacheReadInputTokens")
            total.cacheWrite += count("cacheCreationInputTokens")
        }
        return total
    }

    /// `utilization` は 0〜1。窓の長さは statusline の利用枠と同じ値にする
    private static func rateLimits(_ object: [String: Any]) -> ClaudeStreamLine {
        let windows = ((object["rate_limit_info"] as? [String: Any])?["unifiedWindows"] as? [String: Any]) ?? [:]
        let lengths = ["five_hour": 18_000, "seven_day": 604_800]
        var result: [String: UsageWindow] = [:]
        for (kind, seconds) in lengths {
            guard let window = windows[kind] as? [String: Any], let utilization = window["utilization"] as? Double else { continue }
            let resets = (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            result[kind] = UsageWindow(usedPercent: utilization * 100, resetsAt: resets, windowSeconds: seconds)
        }
        let info = object["rate_limit_info"] as? [String: Any]
        let limit = (info?["status"] as? String).map { status in
            ClaudeRateLimit(rejected: status == "rejected", resetsAt: (info?["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
        // 断られたときは unifiedWindows が来ず、断った窓は `rateLimitType` にしか載らない。使い切った窓として入れ、アカウントを選ぶときに外せるようにする
        if let limit, limit.rejected, let kind = info?["rateLimitType"] as? String, let seconds = lengths[kind], result[kind] == nil {
            result[kind] = UsageWindow(usedPercent: 100, resetsAt: limit.resetsAt, windowSeconds: seconds)
        }
        return .rateLimits(result, limit: limit)
    }

    /// `line` は書いたままの行（form の欄の順を `requested_schema` の文から取る）
    private static func request(_ object: [String: Any], line: Data? = nil) -> ClaudeStreamLine {
        guard let id = object["request_id"] as? String, let request = object["request"] as? [String: Any], let subtype = request["subtype"] as? String
        else { return .other(type: "control_request", subtype: nil) }
        switch subtype {
        case "can_use_tool":
            return .request(
                ClaudeControlRequest(
                    requestID: id,
                    kind: .canUseTool(
                        ClaudeToolPermission(
                            toolName: request["tool_name"] as? String ?? "", toolUseID: request["tool_use_id"] as? String,
                            inputJSON: json(request["input"]) ?? "{}", description: request["description"] as? String,
                            suggestionsJSON: json(request["permission_suggestions"]),
                            suppressAlwaysAllowRule: request["suppress_always_allow_rule"] as? Bool ?? false))))
        case "hook_callback":
            let input = request["input"] as? [String: Any] ?? [:]
            return .request(
                ClaudeControlRequest(
                    requestID: id,
                    kind: .hookCallback(
                        ClaudeHookCall(
                            callbackID: request["callback_id"] as? String ?? "", event: input["hook_event_name"] as? String,
                            sessionID: input["session_id"] as? String, toolName: input["tool_name"] as? String,
                            toolUseID: input["tool_use_id"] as? String ?? request["tool_use_id"] as? String, toolInputJSON: json(input["tool_input"]),
                            transcriptPath: input["transcript_path"] as? String, cwd: input["cwd"] as? String, agentID: input["agent_id"] as? String,
                            lastAssistantMessage: input["last_assistant_message"] as? String))))
        case "elicitation":
            return .request(
                ClaudeControlRequest(
                    requestID: id,
                    kind: .elicitation(
                        ClaudeElicitationRequest(
                            serverName: request["mcp_server_name"] as? String ?? "", message: request["message"] as? String ?? "",
                            mode: request["mode"] as? String ?? "form", url: request["url"] as? String, elicitationID: request["elicitation_id"] as? String,
                            schemaJSON: line.flatMap { JSONKeyOrder.value(at: ["request", "requested_schema"], in: $0) }
                                ?? json(request["requested_schema"]).map { Data($0.utf8) },
                            title: request["title"] as? String ?? request["display_name"] as? String))))
        default:
            return .request(ClaudeControlRequest(requestID: id, kind: .other(subtype)))
        }
    }

    private static func response(_ object: [String: Any]) -> ClaudeStreamLine {
        guard let response = object["response"] as? [String: Any], let id = response["request_id"] as? String else {
            return .other(type: "control_response", subtype: nil)
        }
        let pending = (response["pending_permission_requests"] as? [[String: Any]])?.compactMap { entry -> ClaudeControlRequest? in
            if case .request(let request) = Self.request(entry) { return request }
            return nil
        }
        return .response(
            ClaudeControlResponse(
                requestID: id, isSuccess: response["subtype"] as? String == "success", payloadJSON: json(response["response"]),
                error: response["error"] as? String, pendingRequests: pending))
    }

    static func json(_ value: Any?) -> String? {
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// CLI の入力に書く 1 行。どれも末尾の改行を含む
enum ClaudeStreamInput {
    struct Image: Equatable, Sendable {
        var mediaType: String
        var base64: String
    }

    /// 人の発言。`uuid` は `command_lifecycle` と `--replay-user-messages` の写しで同じ発言かを見分けるのに使う。
    /// `later` は priority "later"：生成中なら区切りでも取り込まず、今のターンの result の後に新しいターンで始める（2.1.310 で実測）
    static func user(text: String, images: [Image] = [], uuid: String, later: Bool = false) -> Data {
        let content: Any =
            images.isEmpty
            ? text
            : ([["type": "text", "text": text]] as [[String: Any]])
                + images.map { ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.base64]] }
        var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": NSNull(), "uuid": uuid]
        if later { object["priority"] = "later" }
        return line(object)
    }

    static func request(id: String, subtype: String, _ fields: [String: Any] = [:]) -> Data {
        line(["type": "control_request", "request_id": id, "request": fields.merging(["subtype": subtype]) { $1 }])
    }

    static func success(id: String, _ response: [String: Any]) -> Data {
        line(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
    }

    static func failure(id: String, _ message: String) -> Data {
        line(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": message]])
    }

    /// `user` で書いた行を、uuid だけ替えて書き直す（CLI は同じ uuid の発言を 2 回目から処理しない）。`sooner` なら priority も外す
    static func reissued(_ line: Data, uuid: String, sooner: Bool = false) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["type"] as? String == "user" else { return nil }
        object["uuid"] = uuid
        if sooner { object["priority"] = nil }
        return self.line(object)
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
