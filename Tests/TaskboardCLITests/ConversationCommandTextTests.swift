import Foundation
import MCP
import Synchronization
import TaskboardKit
import Testing

@testable import taskboard

// MARK: - CLI の会話

@Suite("taskboard conversation: 会話と問いの文")
struct ConversationCommandTextTests {
    @Test("watch の状態の行は MCP と同じ会話の行と問いの行。止まった問い（defer）も出す")
    func renderState() {
        var value = conversation(conversationA, phase: .waiting, requests: [question("r1")], title: "実装")
        value.deferred = permission("r2")
        let (text, inline) = ConversationCommand.render(ConversationEvent(seq: 7, conversationID: conversationA, at: t0, kind: .conversation(value)))
        #expect(!inline)
        #expect(
            text == """
                [状態 7] \(conversationA) waiting model=opus cwd=/w 「実装」 → #1 回答待ち 2（session_answer）
                回答待ち r1: 質問
                  - q0「色は？」 選択肢: 赤 / 青
                回答待ち r2: 権限の確認 Bash: ls
                """)
    }
}
