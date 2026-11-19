import TaskboardKit
import Testing
@testable import Taskboard

/// 会話の画面の真ん中に出すもの（`ConversationContent.of`）
@Suite struct ConversationContentTests {
    private func content(isEmpty: Bool, hasMessages: Bool, history: ConversationTimeline.HistoryState, failed: Bool = false) -> ConversationContent {
        ConversationContent.of(removed: false, openable: true, isEmpty: isEmpty, hasMessages: hasMessages, historyState: history, historyFailed: failed)
    }

    @Test("最初の履歴を待つ間は、生成中の差分や先に出した発言だけが届いていても読み込み中を出す")
    func loadingWhileFirstPage() {
        #expect(content(isEmpty: true, hasMessages: false, history: .notLoaded) == .loading)
        #expect(content(isEmpty: false, hasMessages: false, history: .notLoaded) == .loading)
    }

    @Test("最初の履歴を取れなければ失敗を出し、発言が出ていれば列のまま（失敗は下の帯）")
    func failedFirstPage() {
        #expect(content(isEmpty: false, hasMessages: false, history: .notLoaded, failed: true) == .loadFailed)
        #expect(content(isEmpty: false, hasMessages: true, history: .notLoaded, failed: true) == .transcript)
    }

    @Test("履歴を読んで何も無ければ空、何かあれば列")
    func loaded() {
        #expect(content(isEmpty: true, hasMessages: false, history: .complete) == .empty)
        #expect(content(isEmpty: false, hasMessages: false, history: .complete) == .transcript)
        #expect(content(isEmpty: false, hasMessages: true, history: .more) == .transcript)
    }

    @Test("消えた会話と開けない種類の会話は、履歴より先に決める")
    func missingAndUnopenable() {
        #expect(ConversationContent.of(removed: true, openable: true, isEmpty: true, hasMessages: false, historyState: .notLoaded, historyFailed: false) == .missing)
        #expect(ConversationContent.of(removed: false, openable: false, isEmpty: true, hasMessages: false, historyState: .notLoaded, historyFailed: false) == .unopenable)
    }
}
