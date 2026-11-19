import Foundation
import TaskboardKit

/// CLI の `can_use_tool` と defer で止めたツールを、アプリが答える問い（`ConversationRequest`）にし、答えを CLI の応答の形に戻す。
/// 問いの形と権限の要約は mod（`claude-mod/hooks/register.js` の `ask`・`summarize`）と同じにする（アプリは同じカードで出す）
enum ClaudeRequests {
    /// `suggestionsJSON` は CLI の `permission_suggestions`。権限の確認にだけ載せる
    static func make(
        id: String, toolName: String, toolUseID: String?, inputJSON: String, description: String?, suggestionsJSON: String? = nil, since: Date
    ) -> ConversationRequest {
        let input = object(inputJSON)
        switch toolName {
        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]] ?? []).enumerated().map { index, question in
                AskQuestion(
                    id: "q\(index)", question: question["question"] as? String ?? "", header: question["header"] as? String,
                    options: (question["options"] as? [[String: Any]] ?? []).map {
                        AskOption(label: $0["label"] as? String ?? "", description: $0["description"] as? String, preview: $0["preview"] as? String)
                    },
                    multiSelect: question["multiSelect"] as? Bool ?? false)
            }
            return ConversationRequest(
                id: id, kind: .question, toolName: toolName, toolUseID: toolUseID, waiting: RequestWaiting(id: toolUseID ?? id, since: since, questions: questions))
        case "ExitPlanMode":
            return ConversationRequest(
                id: id, kind: .plan, toolName: toolName, toolUseID: toolUseID,
                waiting: RequestWaiting(id: toolUseID ?? id, since: since, permission: .init(tool: toolName, summary: "計画の承認", detail: nil)),
                plan: input["plan"] as? String)
        default:
            let offered = suggestions(suggestionsJSON).map(\.suggestion)
            return ConversationRequest(
                id: id, kind: .permission, toolName: toolName, toolUseID: toolUseID,
                waiting: RequestWaiting(
                    id: toolUseID ?? id, since: since, permission: .init(tool: toolName, summary: summarize(input), detail: description ?? input["description"] as? String)),
                suggestions: offered.isEmpty ? nil : offered)
        }
    }

    /// MCP の問い。開く先の全文（`OAuthLinks.openable` を通ったものだけ）は問いに載せずに返し、会話の actor がメモリにだけ持つ
    static func make(id: String, elicitation: ClaudeElicitationRequest, since: Date) -> (request: ConversationRequest, url: URL?) {
        let mode = Elicitation.Mode(rawValue: elicitation.mode) ?? .unknown
        let url = mode == .url ? elicitation.url.flatMap(OAuthLinks.openable) : nil
        let form = mode == .form ? Elicitation.Form(schema: elicitation.schemaJSON ?? Data()) : nil
        let made = Elicitation(
            serverName: elicitation.serverName, message: elicitation.message, title: elicitation.title, mode: mode, form: form,
            link: url.flatMap(Elicitation.Link.init(openable:)), elicitationID: elicitation.elicitationID)
        return (
            ConversationRequest(id: id, kind: .elicitation, toolName: "elicitation", toolUseID: nil, waiting: RequestWaiting(id: id, since: since), elicitation: made),
            made.link == nil ? nil : url
        )
    }

    /// MCP の問いへの答えを確かめて、CLI への応答の中身（MCP の `ElicitResult`）にする
    static func elicitationResponse(_ request: ConversationRequest, answer: ConversationAnswerRequest) throws -> [String: Any] {
        guard let elicitation = request.elicitation else { throw AnswerError.noDecision }
        guard let action = answer.action else { throw AnswerError.noDecision }
        do {
            try elicitation.check(action, content: answer.content)
        } catch {
            throw AnswerError.elicitation(error)
        }
        var response: [String: Any] = ["action": action.rawValue]
        if let content = answer.content {
            response["content"] = content.mapValues { value -> Any in
                switch value {
                case .string(let text): text
                case .number(let number): number
                case .bool(let flag): flag
                }
            }
        }
        return response
    }

    enum Decision: Equatable {
        /// 入力を（答えを足して）そのまま使って続ける。`remember` は一緒に返す「今後は聞かない」候補
        case allow(updatedInputJSON: String, remember: Remembered? = nil)
        case deny(message: String)
    }

    /// 選ばれた候補と、CLI が出した JSON（そのまま `updatedPermissions` に入れる）
    struct Remembered: Equatable {
        var suggestion: PermissionSuggestion
        var json: String
    }

    enum AnswerError: Error, Equatable {
        /// 質問に答えが 1 つも無い
        case unanswered
        /// 権限の確認と計画に、許可か拒否が無い
        case noDecision
        /// 答えが問いの選択肢に合わない
        case mismatch(question: AskQuestion, AskAnswerMismatch)
        /// MCP の問いの答えが schema に合わない
        case elicitation(ElicitationAnswerError)
        /// 選んだ「今後は聞かない」候補が無い・拒否に添えてある
        case suggestion(String)
    }

    /// 答えを CLI に返す決定にする。質問は入力に `answers`（問いの文 → 答え）を足す。
    /// `suggestionsJSON` は問いを作ったときの CLI の候補（答えの `suggestionID` で選ばれた 1 件を返す）
    static func decide(_ request: ConversationRequest, inputJSON: String, suggestionsJSON: String? = nil, answer: ConversationAnswerRequest) throws -> Decision {
        if answer.suggestionID != nil, request.kind != .permission || answer.allow != true {
            throw AnswerError.suggestion("今後は聞かない候補は、権限の確認の許可にだけ添えられる")
        }
        switch request.kind {
        case .question:
            for given in answer.answers ?? [] {
                guard let question = request.waiting.questions?.first(where: { $0.id == given.questionID }) else { continue }
                if let mismatch = question.mismatch(given) { throw AnswerError.mismatch(question: question, mismatch) }
            }
            let map = request.waiting.answerMap(answer.answers ?? [])
            guard !map.isEmpty else {
                if answer.allow == false { return .deny(message: answer.message ?? "User declined to answer.") }
                throw AnswerError.unanswered
            }
            var input = object(inputJSON)
            input["answers"] = map
            return .allow(updatedInputJSON: ClaudeStreamParser.json(input) ?? inputJSON)
        case .elicitation:
            // MCP の問いは can_use_tool でないので、許可と拒否では答えられない
            throw AnswerError.noDecision
        case .plan, .permission, .unknown:
            guard let allow = answer.allow else { throw AnswerError.noDecision }
            guard allow else { return .deny(message: answer.message ?? "User denied.") }
            guard let id = answer.suggestionID else { return .allow(updatedInputJSON: inputJSON) }
            // 出していない候補（問いに載せなかったもの）は、番号が合っていても返さない
            guard let chosen = suggestions(suggestionsJSON).first(where: { $0.suggestion.id == id }) else {
                throw AnswerError.suggestion("今後は聞かない候補 \(id) は無い")
            }
            return .allow(updatedInputJSON: inputJSON, remember: Remembered(suggestion: chosen.suggestion, json: chosen.json))
        }
    }

    /// `can_use_tool` への応答の中身
    static func permissionResponse(_ decision: Decision) -> [String: Any] {
        switch decision {
        case .allow(let updated, let remember):
            var response: [String: Any] = ["behavior": "allow", "updatedInput": object(updated)]
            if let remember { response["updatedPermissions"] = [object(remember.json)] }
            return response
        case .deny(let message): return ["behavior": "deny", "message": message]
        }
    }

    /// CLI の `permission_suggestions` から、画面に出せる候補（id は元の並びの番号）と、返すときの JSON。
    /// 許可の規則・作業フォルダ・権限のモード（確認なしは除く）で、残す先が分かるものだけ。残す先が無ければ会話の間だけ（CLI の既定）
    static func suggestions(_ json: String?) -> [(suggestion: PermissionSuggestion, json: String)] {
        guard let json, let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, entry in
            let scope: PermissionSuggestion.Scope
            switch entry["destination"] as? String {
            case nil, "session": scope = .session
            case "localSettings": scope = .folder
            case "projectSettings": scope = .project
            case "userSettings": scope = .user
            default: return nil
            }
            let kind: PermissionSuggestion.Kind
            let subject: String
            switch entry["type"] as? String {
            case "addRules":
                guard entry["behavior"] as? String == "allow", let rules = entry["rules"] as? [[String: Any]], !rules.isEmpty else { return nil }
                let names = rules.compactMap { rule -> String? in
                    guard let tool = rule["toolName"] as? String else { return nil }
                    return (rule["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool
                }
                guard names.count == rules.count else { return nil }
                (kind, subject) = (.rule, names.joined(separator: ", "))
            case "addDirectories":
                guard let directories = entry["directories"] as? [String], !directories.isEmpty else { return nil }
                (kind, subject) = (.directory, directories.joined(separator: ", "))
            case "setMode":
                guard let mode = entry["mode"] as? String, mode != ClaudeConversation.bypassMode, ConversationInput.acceptedPermissionModes.contains(mode) else { return nil }
                (kind, subject) = (.mode, mode)
            default:
                return nil
            }
            guard let raw = ClaudeStreamParser.json(entry) else { return nil }
            return (PermissionSuggestion(id: "\(index)", kind: kind, subject: subject, scope: scope), raw)
        }
    }

    /// defer で止めたツールを戻したときの、PreToolUse の hook_callback への応答の中身
    static func preToolUseResponse(_ decision: Decision) -> [String: Any] {
        switch decision {
        case .allow(let updated, _):
            ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": object(updated)]]
        case .deny(let message):
            ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": message]]
        }
    }

    static func summarize(_ input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        for key in ["file_path", "notebook_path", "path", "url", "pattern"] {
            if let value = input[key] as? String { return value }
        }
        return String((ClaudeStreamParser.json(input) ?? "").prefix(500))
    }

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }
}

/// defer で終えた問い。記録の `deferred` に JSON で置き、答えたら `--resume` で起こして同じ tool_use の PreToolUse に返す
struct DeferredQuestion: Codable, Equatable, Sendable {
    var request: ConversationRequest
    var inputJSON: String
}
