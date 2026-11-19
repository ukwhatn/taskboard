import Testing

@testable import TaskboardKit

@Suite("再開の予定が届かなかった理由")
struct WakeProblemTests {
    @Test("記録の文から理由を読み、同じ文に戻せる。24 時間で諦めたときは最後の回の理由を中に持つ")
    func roundTrip() {
        let cases: [(String, WakeProblem)] = [
            ("会話の記録がありません", .conversationMissing),
            ("タスクがありません", .taskMissing),
            ("会話が生成中か、質問への回答を待っています", .busy),
            ("届いたかを確認できませんでした", .unconfirmed),
            ("会話を再開できませんでした", .resumeFailed),
            ("タスクのセッションが応答待ちではありません", .paneNotReady),
            ("停止したセッションを再開しています", .resuming),
            ("会話を起動できませんでした", .startFailed),
            ("ターミナルで起動できません", .terminalUnavailable),
            ("ターミナルで起動できませんでした", .terminalFailed),
            ("24時間届けられませんでした。会話が生成中か、質問への回答を待っています。", .gaveUp(.busy)),
            ("24時間届けられませんでした。ターミナルで起動できません。", .gaveUp(.terminalUnavailable)),
        ]
        for (text, problem) in cases {
            #expect(WakeProblem(failure: text) == problem, "\(text)")
            #expect(problem.failure == text)
        }
    }

    @Test("知らない文はそのまま持つ。前置きだけが合う文も知らない文として扱う")
    func unknownText() {
        #expect(WakeProblem(failure: "接続が切れた") == .unexpected("接続が切れた"))
        #expect(WakeProblem(failure: "24時間届けられませんでした。") == .unexpected("24時間届けられませんでした。"))
        #expect(WakeProblem(failure: "24時間届けられませんでした。別の理由。") == .gaveUp(.unexpected("別の理由")))
        #expect(WakeProblem(failure: "") == .unexpected(""))
    }
}
