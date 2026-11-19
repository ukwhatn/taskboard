import Foundation
import Testing

@testable import TaskboardKit

@Suite("ツールの行の様子")
struct ChatToolStatusTests {
    let machine = MachineID(rawValue: "m")
    let t0 = Date(timeIntervalSince1970: 0)

    func conversation(runner: Conversation.Runner = .host, states: [ConversationBackgroundTaskState]?, known: Bool = true) -> Conversation {
        Conversation(
            id: "c1", machine: machine, taskNumber: 1, agentSessionID: "a1", cwd: "/", runner: runner, phase: runner == .host ? .idle : .stopped,
            backgroundTasksKnown: known, backgroundTaskStates: states, createdAt: t0, updatedAt: t0)
    }

    func result(background: String? = nil, error: Bool = false) -> ChatMessage {
        ChatMessage(id: "r", role: .user, kind: .toolResult, text: "", toolID: "t", isError: error, at: t0, backgroundTaskID: background)
    }

    @Test("結果が無ければ実行中、裏のタスクでなければ結果の成否")
    func foreground() {
        let tasks = ChatBackgroundTasks(conversation: nil)
        #expect(ChatToolStatus(result: nil, background: tasks) == .running)
        #expect(ChatToolStatus(result: result(), background: tasks) == .completed)
        #expect(ChatToolStatus(result: result(error: true), background: tasks) == .failed)
    }

    @Test("動いている会話：載っている id はその様子、載っていない id は終了。数が分からない間と前の版の daemon は分からない")
    func runningConversation() {
        let tasks = ChatBackgroundTasks(conversation: conversation(states: [.init(id: "b1", status: .running), .init(id: "b2", status: .stopped)]))
        #expect(ChatToolStatus(result: result(background: "b1"), background: tasks) == .background(.running))
        #expect(ChatToolStatus(result: result(background: "b2"), background: tasks) == .background(.stopped))
        #expect(ChatToolStatus(result: result(background: "b3"), background: tasks) == .background(.ended))

        let unknown = ChatBackgroundTasks(conversation: conversation(states: [.init(id: "b1", status: .running)], known: false))
        #expect(ChatToolStatus(result: result(background: "b1"), background: unknown) == .background(.running))
        #expect(ChatToolStatus(result: result(background: "b3"), background: unknown) == .background(nil))

        let old = ChatBackgroundTasks(conversation: conversation(states: nil))
        #expect(ChatToolStatus(result: result(background: "b1"), background: old) == .background(nil))
    }

    @Test("止まった会話の裏のタスクは動いていない。覚えている終わり方があればそれ、無ければ終了。pane のセッション（会話が無い）は分からない")
    func stoppedConversation() {
        let stopped = ChatBackgroundTasks(conversation: conversation(runner: .none, states: nil))
        #expect(ChatToolStatus(result: result(background: "b1"), background: stopped) == .background(.ended))
        let remembered = ChatBackgroundTasks(conversation: conversation(runner: .none, states: [.init(id: "b1", status: .failed)]))
        #expect(ChatToolStatus(result: result(background: "b1"), background: remembered) == .background(.failed))
        #expect(ChatToolStatus(result: result(background: "b1"), background: ChatBackgroundTasks(conversation: nil)) == .background(nil))
    }

    @Test("動いている裏のタスクの数：Claude Code の会話は裏に回って動いているものだけ、前の版の daemon と codex は daemon の数、数が分からなければ出さない")
    func runningBackgroundTasks() {
        var c = conversation(states: [.init(id: "b1", status: .running), .init(id: "b2", status: .completed), .init(id: "b3", status: .running)])
        c.backgroundTasks = 3  // 前景で結果を待っているタスクも数えている
        #expect(c.runningBackgroundTasks == 2)
        c.backgroundTaskStates = nil
        #expect(c.runningBackgroundTasks == 3)
        c.backgroundTasksKnown = false
        #expect(c.runningBackgroundTasks == nil)

        let codex = conversation(states: nil)
        var counted = codex
        counted.backgroundTasks = 1
        #expect([c, counted, codex].runningBackgroundTasks == 1)
        #expect([Conversation]().runningBackgroundTasks == 0)
    }

    @Test("組と最後の呼び出しの様子：実行中、失敗（裏のタスクの失敗を含む）、裏で実行中、裏の様子が分からない、の順に強い。全部終わっていれば出さない")
    func summary() {
        #expect(ChatToolStatus.summary([.completed, .background(.running), .running]) == .running)
        #expect(ChatToolStatus.summary([.background(.running), .background(.failed)]) == .failed)
        #expect(ChatToolStatus.summary([.background(.running), .failed]) == .failed)
        #expect(ChatToolStatus.summary([.background(nil), .background(.running)]) == .background(.running))
        #expect(ChatToolStatus.summary([.completed, .background(nil)]) == .background(nil))
        #expect(ChatToolStatus.summary([.completed, .background(.completed), .background(.stopped), .background(.ended)]) == nil)
        #expect(ChatToolStatus.summary([]) == nil)
    }
}
