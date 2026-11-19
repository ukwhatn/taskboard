import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話と問いの文（MCP・CLI・daemon の知らせ）")
struct ConversationLinesTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func request(_ kind: ConversationRequest.Kind, questions: [AskQuestion]? = nil, permission: RequestWaiting.Permission? = nil, plan: String? = nil)
        -> ConversationRequest
    {
        ConversationRequest(
            id: "r1", kind: kind, toolName: kind == .unknown ? "NewTool" : "AskUserQuestion", toolUseID: nil,
            waiting: RequestWaiting(id: "r1", since: t0, questions: questions, permission: permission), plan: plan)
    }

    @Test("質問は質問ごとに id・文・選択肢を、複数選択には印を付ける。選択肢の無い質問は選択肢を書かない")
    func question() {
        let questions = [
            AskQuestion(id: "q1", question: "色は？", header: nil, options: [AskOption(label: "赤"), AskOption(label: "青")], multiSelect: true),
            AskQuestion(id: "q2", question: "名前は?", header: nil, options: [], multiSelect: false),
        ]
        let value = request(.question, questions: questions)
        #expect(value.kindLabel == "質問")
        #expect(value.lines == ["回答待ち r1: 質問", "  - q1「色は？」 選択肢: 赤 / 青（複数選択）", "  - q2「名前は?」"])
    }

    @Test("権限の確認は tool と要約と詳しい中身を 1 行に。要約も中身も無ければ tool だけ")
    func permission() {
        let full = request(.permission, permission: .init(tool: "Bash", summary: "rm -rf build", detail: "/w で"))
        #expect(full.kindLabel == "権限の確認 Bash")
        #expect(full.lines == ["回答待ち r1: 権限の確認 Bash: rm -rf build（/w で）"])
        #expect(request(.permission, permission: .init(tool: "Edit", summary: "")).lines == ["回答待ち r1: 権限の確認 Edit"])
    }

    @Test("権限の確認に今後は聞かない候補があれば、候補の id と、何を許可しどこに残すかを 1 行ずつ足す。知らない種類は出さない")
    func suggestions() {
        var value = request(.permission, permission: .init(tool: "Bash", summary: "touch a"))
        value.suggestions = [
            PermissionSuggestion(id: "0", kind: .rule, subject: "Bash(touch a)", scope: .folder),
            PermissionSuggestion(id: "1", kind: .directory, subject: "/w", scope: .session),
            PermissionSuggestion(id: "2", kind: .mode, subject: "acceptEdits", scope: .user),
            PermissionSuggestion(id: "3", kind: .unknown, subject: "?", scope: .project),
        ]
        #expect(
            value.lines == [
                "回答待ち r1: 権限の確認 Bash: touch a",
                "  - 今後は聞かない候補 0: 規則 Bash(touch a) を許可（このフォルダの設定に保存）",
                "  - 今後は聞かない候補 1: 作業フォルダ /w へのアクセスを許可（この会話の間）",
                "  - 今後は聞かない候補 2: 権限のモードを acceptEdits に変更（すべてのプロジェクトで）",
            ])
    }

    @Test("計画の承認は本文の字数と、本文の頭 500 字を載せる（超えたら…）。本文が無ければ字数だけ")
    func plan() {
        let short = request(.plan, plan: "# 計画\n1. 直す")
        #expect(short.kindLabel == "計画の承認")
        #expect(short.lines == ["回答待ち r1: 計画の承認（本文 10 字）", "  # 計画\n1. 直す"])
        let long = request(.plan, plan: String(repeating: "あ", count: 501))
        #expect(long.lines[1] == "  " + String(repeating: "あ", count: 500) + "…")
        #expect(request(.plan, plan: String(repeating: "a", count: 500)).lines[1].hasSuffix("a"))
        #expect(request(.plan).lines == ["回答待ち r1: 計画の承認（本文 0 字）"])
    }

    @Test("知らない種類の回答待ちは tool の名前と、端末で答える案内")
    func unknown() {
        let value = request(.unknown)
        #expect(value.kindLabel == "知らない種類の回答待ち（NewTool）")
        #expect(value.lines == ["回答待ち r1: この版の taskboard が知らない種類の回答待ち（NewTool）。taskboard を新しい版にしてから答える"])
    }

    @Test("会話の行は id で始まり、止まった会話には終わった理由を、結んだタスクには題を添える")
    func conversationLine() {
        var conversation = Conversation(
            id: "c-1", machine: MachineID(rawValue: "m"), taskNumber: 3, agentSessionID: "s", cwd: "/w", model: "opus", runner: .none, phase: .stopped,
            lastExit: "止めた", createdAt: t0, updatedAt: t0)
        #expect(conversation.line(taskTitle: "直す") == "c-1 stopped（止めた） model=opus cwd=/w → #3 直す")
        #expect(conversation.line(taskTitle: nil) == "c-1 stopped（止めた） model=opus cwd=/w → #3")
        conversation.phase = .waiting
        conversation.taskNumber = nil
        conversation.purpose = .schedule
        conversation.pending = [request(.plan, plan: "x")]
        #expect(conversation.line(taskTitle: nil) == "c-1 waiting model=opus cwd=/w 定期起動の実行 回答待ち 1（session_answer）")
    }
}
