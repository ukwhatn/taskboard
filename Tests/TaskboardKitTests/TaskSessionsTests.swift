import Foundation
import Testing

@testable import TaskboardKit

@Suite("タスクの会話の見分け（lead・開いたときの会話・止まったセッション）")
struct TaskSessionsTests {
    private let machine = MachineID(rawValue: "m")
    private let t0 = Date(timeIntervalSince1970: 0)

    private func conversation(
        _ id: String, task: Int? = 1, phase: Conversation.Phase = .idle, parent: String? = nil, created: TimeInterval = 0, updated: TimeInterval = 0,
        lastExit: String? = nil
    ) -> Conversation {
        Conversation(
            id: id, machine: machine, taskNumber: task, agentSessionID: "a-\(id)", cwd: "/tmp", runner: phase == .stopped ? .none : .host, phase: phase,
            lastExit: lastExit, parentConversationID: parent, createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated))
    }

    private func ref(_ sessionID: String, agent: String = "claude", linked: TimeInterval = 0, id: Int64 = 1) -> TaskSessionRef {
        TaskSessionRef(id: id, agent: agent, sessionID: sessionID, cwd: "/tmp", linkedAt: Date(timeIntervalSince1970: linked))
    }

    private func task(_ refs: [TaskSessionRef]) -> BoardTask {
        BoardTask(machine: machine, number: 1, boardID: "b", columnID: "working", title: "t", sessions: refs, createdAt: t0, updatedAt: t0)
    }

    private func state(_ conversations: [Conversation] = []) -> MachineState {
        var state = MachineState()
        state.conversations = conversations.reduce(into: [:]) { $0[$1.key] = $1 }
        return state
    }

    @Test("lead の会話: conversation.taskNumber でタスクに結ばれ、委譲先でも終了したものでもないもの。止まっていても残す。作った順")
    func leadConversations() {
        let conversations = [
            conversation("later", phase: .stopped, created: 2), conversation("first", created: 1), conversation("child", parent: "first", created: 3),
            conversation("elsewhere", task: 2), conversation("loose", task: nil),
            conversation("closed", phase: .stopped, created: 4, lastExit: ConversationStopCause.closed.lastExit),
        ]
        let state = state(conversations)
        #expect(state.leadConversations(of: task([])).map(\.id) == ["first", "later"])
        #expect(state.conversations(of: task([])).map(\.id) == ["first", "later", "child", "closed"])
    }

    @Test("開いたときに出す会話: 止まっていない lead の会話があれば更新の新しいもの。全部止まっていれば更新の新しいもの")
    func openingPrefersLiveConversation() {
        let live = [conversation("old", updated: 1), conversation("new", updated: 5), conversation("stopped", phase: .stopped, updated: 9)]
        #expect(state(live).openingConversation(of: task([]))?.id == "new")
        let stopped = [conversation("a", phase: .stopped, updated: 1), conversation("b", phase: .stopped, updated: 3)]
        #expect(state(stopped).openingConversation(of: task([]))?.id == "b")
    }

    @Test("開いたときに出す会話: 委譲先の会話は選ばない。会話が無ければ nil")
    func openingSkipsDelegates() {
        let state = state([conversation("lead", phase: .stopped, updated: 1), conversation("child", parent: "lead", updated: 9)])
        #expect(state.openingConversation(of: task([]))?.id == "lead")
        #expect(self.state().openingConversation(of: task([])) == nil)
    }

    @Test("開いたときに出す会話: 別のタスクの lead が起こした委譲先は、このタスクの lead として選ぶ")
    func openingDelegateFromOtherTask() {
        let fromOtherTask = state([conversation("lead", task: 2, updated: 1), conversation("child", parent: "lead", updated: 9)])
        #expect(fromOtherTask.openingConversation(of: task([]))?.id == "child")
    }

    @Test("止まったセッション: Claude と Codex の紐づけのうち、今ある会話の会話 ID を外す。結んだのが新しい順に 1 回ずつ")
    func stoppedSessions() {
        var owned = conversation("c", phase: .stopped)
        owned.agentSessionID = "conv"
        let refs = [
            ref("ended", linked: 1), ref("conv", linked: 3), ref("codex", agent: "codex", linked: 4),
            ref("shell", agent: "shell", linked: 5), ref("ended", linked: 6),
        ]
        #expect(state([owned]).stoppedSessions(of: task(refs)).map(\.sessionID) == ["ended", "codex"])
        #expect(state([owned]).stoppedSessions(of: task(refs)).first?.linkedAt == Date(timeIntervalSince1970: 6))
    }

    @Test("止まったセッション: 結んだ時刻が同じなら、後に結んだ（id の大きい）方が先（store は時刻をミリ秒で持ち、続けて結ぶと同じになる）")
    func stoppedSessionsSameTime() {
        let refs = [ref("sess-1", linked: 7, id: 1), ref("sess-2", linked: 7, id: 2), ref("sess-0", linked: 3, id: 3)]
        #expect(state().stoppedSessions(of: task(refs)).map(\.sessionID) == ["sess-2", "sess-1", "sess-0"])
    }
}
