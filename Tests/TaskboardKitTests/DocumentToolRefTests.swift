import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話の doc_publish・ask_user の結果から文書と質問を読む")
struct DocumentToolRefTests {
    @Test("ask_user の結果: 質問の束・数・文書名・開く URL")
    func askUser() throws {
        let result = """
            質問を出した
            - ask_id: 167
            - 質問: 2 問
            - 文書: [41] 9t_requests_ux_proposal.html ・ rev 3
            - タスク: #172
            - アプリ: taskboard://task/studio/172/doc/41
            - 回答: ブロックしない。taskboard がこのセッションに届ける。届かなければ feedback_list で取る
            """
        let ref = try #require(DocumentToolRef.parse(toolName: "mcp__taskboard__ask_user", result: result))
        #expect(ref == DocumentToolRef(url: URL(string: "taskboard://task/studio/172/doc/41")!, docName: "9t_requests_ux_proposal.html", askID: 167, questionCount: 2))
    }

    @Test("質問を付けない doc_publish は文書だけ")
    func publishWithoutQuestions() throws {
        let result = """
            文書を publish した
            - 文書: [3] 計画 フェーズ 3.md ・ rev 1 ・ 新規
            - タスク: #9
            - アプリ: taskboard://task/m1/9/doc/3
            """
        let ref = try #require(DocumentToolRef.parse(toolName: "mcp__taskboard__doc_publish", result: result))
        #expect(ref.docName == "計画 フェーズ 3.md")
        #expect(ref.askID == nil)
        #expect(ref.questionCount == nil)
    }

    @Test("ほかのツール・失敗の結果・URL の行の無い前の版は読まない")
    func ignored() {
        let old = "質問を出した\n- ask_id: 1\n- 質問: 1 問\n- 文書: [2] q.md ・ rev 1\n- タスク: #3"
        #expect(DocumentToolRef.parse(toolName: "mcp__taskboard__ask_user", result: old) == nil)
        #expect(DocumentToolRef.parse(toolName: "mcp__other__ask_user", result: old + "\n- アプリ: taskboard://task/m/3/doc/2") == nil)
        #expect(DocumentToolRef.parse(toolName: nil, result: "") == nil)
        #expect(DocumentToolRef.parse(toolName: "mcp__taskboard__doc_publish", result: "path か content が要る") == nil)
    }

    @Test("発言から呼び出しと結果を組にして読む。失敗した結果とほかのツールの結果は外す")
    func refsInMessages() {
        let ok = "質問を出した\n- ask_id: 4\n- 質問: 1 問\n- 文書: [2] q.md ・ rev 1\n- タスク: #3\n- アプリ: taskboard://task/m/3/doc/2"
        let messages = [
            ChatMessage(id: "a1", role: .assistant, kind: .toolUse, text: "{}", toolName: "mcp__taskboard__ask_user", toolID: "t1"),
            ChatMessage(id: "a2", role: .assistant, kind: .toolUse, text: "{}", toolName: "Bash", toolID: "t2"),
            ChatMessage(id: "a3", role: .assistant, kind: .toolUse, text: "{}", toolName: "mcp__taskboard__ask_user", toolID: "t3"),
            ChatMessage(id: "r2", role: .user, kind: .toolResult, text: ok, toolID: "t2"),
            ChatMessage(id: "r3", role: .user, kind: .toolResult, text: ok, toolID: "t3", isError: true),
            ChatMessage(id: "r1", role: .user, kind: .toolResult, text: ok, toolID: "t1"),
        ]
        #expect(DocumentToolRef.refs(in: messages).map(\.askID) == [4])
    }
}
