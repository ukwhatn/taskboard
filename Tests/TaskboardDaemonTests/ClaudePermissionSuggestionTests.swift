import Foundation
import Testing
import TaskboardKit

@testable import TaskboardDaemon

@Suite("権限の確認の「今後は聞かない」候補")
struct ClaudePermissionSuggestionTests {
    /// Claude Code 2.1.304 の Bash の `can_use_tool` が実際に出した候補（`touch probe-a.txt`）
    static let bashSuggestions = #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch probe-a.txt"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/private/tmp/work"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#

    private func request(suggestions: String?) -> ConversationRequest {
        ClaudeRequests.make(
            id: "r1", toolName: "Bash", toolUseID: "toolu_b", inputJSON: #"{"command":"touch probe-a.txt"}"#, description: nil, suggestionsJSON: suggestions,
            since: Date(timeIntervalSince1970: 0))
    }

    @Test("規則・フォルダ・モードの候補を、何を・どこに残すかで読む。id は CLI の並びの番号")
    func reads() {
        let suggestions = request(suggestions: Self.bashSuggestions).suggestions
        #expect(
            suggestions == [
                PermissionSuggestion(id: "0", kind: .rule, subject: "Bash(touch probe-a.txt)", scope: .folder),
                PermissionSuggestion(id: "1", kind: .directory, subject: "/private/tmp/work", scope: .session),
                PermissionSuggestion(id: "2", kind: .mode, subject: "acceptEdits", scope: .session),
            ])
    }

    @Test("ツール全体の規則は括弧なし、複数の規則は読点でつなぐ。残す先が無ければ会話の間だけ")
    func ruleSubjects() {
        let json = #"[{"type":"addRules","rules":[{"toolName":"WebFetch"},{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow"}]"#
        #expect(request(suggestions: json).suggestions == [PermissionSuggestion(id: "0", kind: .rule, subject: "WebFetch, Bash(npm test:*)", scope: .session)])
    }

    @Test("出さない候補：許可でない規則・知らない種類・知らない残す先・確認なしへのモード。番号は元の並びのまま")
    func skipped() {
        let json =
            #"[{"type":"removeRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"session"},{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls"}],"behavior":"deny","destination":"session"},{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls"}],"behavior":"allow","destination":"cliArg"},{"type":"setMode","mode":"bypassPermissions","destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"userSettings"},{"type":"newKind"}]"#
        #expect(request(suggestions: json).suggestions == [PermissionSuggestion(id: "4", kind: .mode, subject: "acceptEdits", scope: .user)])
        #expect(request(suggestions: "[]").suggestions == nil)
        #expect(request(suggestions: nil).suggestions == nil)
        #expect(request(suggestions: "not json").suggestions == nil)
    }

    @Test("選んだ候補は、CLI が出した JSON のまま updatedPermissions に入れる（daemon が作り直さない）")
    func answerReturnsOriginal() throws {
        let made = request(suggestions: Self.bashSuggestions)
        let answer = ConversationAnswerRequest(requestID: "r1", allow: true, suggestionID: "0")
        let decision = try ClaudeRequests.decide(made, inputJSON: #"{"command":"touch probe-a.txt"}"#, suggestionsJSON: Self.bashSuggestions, answer: answer)
        let response = ClaudeRequests.permissionResponse(decision)
        #expect(response["behavior"] as? String == "allow")
        let updated = try #require(response["updatedPermissions"] as? [[String: Any]])
        #expect(updated.count == 1 && updated[0]["type"] as? String == "addRules" && updated[0]["destination"] as? String == "localSettings")
        #expect(((updated[0]["rules"] as? [[String: Any]])?.first)?["ruleContent"] as? String == "touch probe-a.txt")
        // 選ばなければ updatedPermissions を付けない
        let plain = try ClaudeRequests.decide(
            made, inputJSON: "{}", suggestionsJSON: Self.bashSuggestions, answer: ConversationAnswerRequest(requestID: "r1", allow: true))
        #expect(ClaudeRequests.permissionResponse(plain)["updatedPermissions"] == nil)
    }

    @Test("無い候補・出していない候補・拒否に添えた候補は断る")
    func rejects() {
        let made = request(suggestions: Self.bashSuggestions)
        for answer in [
            ConversationAnswerRequest(requestID: "r1", allow: true, suggestionID: "9"),
            ConversationAnswerRequest(requestID: "r1", allow: true, suggestionID: "x"),
            ConversationAnswerRequest(requestID: "r1", allow: false, suggestionID: "0"),
            ConversationAnswerRequest(requestID: "r1", suggestionID: "0"),
        ] {
            #expect(throws: ClaudeRequests.AnswerError.self) {
                try ClaudeRequests.decide(made, inputJSON: "{}", suggestionsJSON: Self.bashSuggestions, answer: answer)
            }
        }
        // 出していない候補（確認なしへのモード）は、番号が合っていても断る
        let hidden = #"[{"type":"setMode","mode":"bypassPermissions","destination":"session"}]"#
        #expect(throws: ClaudeRequests.AnswerError.self) {
            try ClaudeRequests.decide(
                request(suggestions: hidden), inputJSON: "{}", suggestionsJSON: hidden, answer: ConversationAnswerRequest(requestID: "r1", allow: true, suggestionID: "0"))
        }
    }

    @Test("CLI が「常に許可を出さない」確認（suppress_always_allow_rule）は、候補を問いに載せない")
    func suppressed() {
        let line = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf /"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"localSettings"}],"suppress_always_allow_rule":true}}"#
        guard case .request(let parsed) = ClaudeStreamParser.parse(Data(line.utf8)), case .canUseTool(let permission) = parsed.kind else {
            Issue.record("読めない")
            return
        }
        #expect(permission.suppressAlwaysAllowRule)
        let open = line.replacingOccurrences(of: #","suppress_always_allow_rule":true"#, with: "")
        guard case .request(let plain) = ClaudeStreamParser.parse(Data(open.utf8)), case .canUseTool(let allowed) = plain.kind else {
            Issue.record("読めない")
            return
        }
        #expect(!allowed.suppressAlwaysAllowRule)
    }
}
