import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話の置き場（タスク・オーケストレーター・タスクなし）と、置き場の中の並び")
struct SessionHomeTests {
    private let machine = MachineID(rawValue: "m")
    private let t0 = Date(timeIntervalSince1970: 0)

    private func conversation(
        _ id: String, task: Int? = nil, phase: Conversation.Phase = .idle, lastExit: String? = nil, parent: String? = nil,
        purpose: Conversation.Purpose? = nil, created: TimeInterval = 0
    ) -> Conversation {
        Conversation(
            id: id, machine: machine, taskNumber: task, agentSessionID: "a-\(id)", cwd: "/tmp", runner: phase == .stopped ? .none : .host, phase: phase,
            lastExit: lastExit, purpose: purpose, parentConversationID: parent,
            createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: created))
    }

    private func task(_ number: Int) -> BoardTask {
        BoardTask(machine: machine, number: number, boardID: "b", columnID: "working", title: "t\(number)", createdAt: t0, updatedAt: t0)
    }

    private func state(_ conversations: [Conversation], tasks: [BoardTask] = []) -> MachineState {
        var state = MachineState()
        state.conversations = conversations.reduce(into: [:]) { $0[$1.key] = $1 }
        state.tasks = tasks.reduce(into: [:]) { $0[$1.id] = $1 }
        return state
    }

    private func ids(_ rows: [SessionMemberRow]) -> [String] {
        rows.map { "\($0.depth):\($0.conversation.id)" }
    }

    private let closed = ConversationStopCause.closed.lastExit

    @Test("動いているものがあるタスクの番号は、members(of:) に終了していない会話が 1 つでもあるタスクと同じ（止まった会話は数え、終了した会話は数えない）")
    func activeTaskNumbers() {
        let state = state(
            [
                conversation("c1", task: 2), conversation("c2", task: 3, phase: .stopped, lastExit: closed),
                conversation("c3", task: 4, phase: .stopped, lastExit: "止めた"), conversation("c4", parent: "c2"),
            ],
            tasks: [task(1), task(2), task(3), task(4)])
        #expect(state.activeTaskNumbers() == [2, 3, 4])
        let byMembers = Set(state.tasks.values.map(\.number).filter { number in state.members(of: .task(number)).contains { !$0.conversation.isClosed } })
        #expect(state.activeTaskNumbers() == byMembers)
    }

    @Test("会話は taskNumber でタスクに入る。タスクの無い委譲先は起こした側の置き場（孫も同じ）。オーケストレーターの会話と、オーケストレーターが起こしたものはオーケストレーター")
    func homes() {
        let state = state(
            [
                conversation("bound", task: 1), conversation("child", parent: "bound"), conversation("grandchild", parent: "child"),
                conversation("orch", purpose: .orchestrator), conversation("orchChild", parent: "orch"), conversation("loose"), conversation("gone", task: 9),
            ], tasks: [task(1)])
        let home = { (id: String) in state.home(of: state.conversations[ConversationKey(machine: machine, id: id)]!) }
        #expect(home("bound") == .task(1))
        #expect(home("child") == .task(1))
        #expect(home("grandchild") == .task(1))
        #expect(home("orch") == .orchestrator)
        #expect(home("orchChild") == .orchestrator)
        #expect(home("loose") == .unassigned)
        // タスクが state に無い（消えた・届く途中）会話もタスクなしに出す（どこからも開けなくならないように）
        #expect(home("gone") == .unassigned)
    }

    @Test("親子が輪になっていても止まり、タスクなしにする")
    func cycle() {
        let state = state([conversation("a", parent: "b"), conversation("b", parent: "a")])
        #expect(state.home(of: state.conversations[ConversationKey(machine: machine, id: "a")]!) == .unassigned)
        #expect(ids(state.members(of: .unassigned)).sorted() == ["0:a", "1:b"])
    }

    @Test("置き場の中は、起こした側の後に委譲先を深さ付きで続ける。同じ親の中は作った順")
    func members() {
        let state = state(
            [
                conversation("c2", task: 1, created: 2), conversation("c1", task: 1, created: 1), conversation("c1b", parent: "c1", created: 5),
                conversation("c1a", parent: "c1", created: 3), conversation("c1a1", parent: "c1a", created: 4),
            ], tasks: [task(1)])
        #expect(ids(state.members(of: .task(1))) == ["0:c1", "1:c1a", "2:c1a1", "1:c1b", "0:c2"])
    }

    @Test("終了した会話も置き場に入れたまま、isClosed で見分ける")
    func closedStayInHome() {
        let state = state([conversation("closed", phase: .stopped, lastExit: closed, created: 1), conversation("stopped", phase: .stopped, created: 2)])
        let rows = state.members(of: .unassigned)
        #expect(ids(rows) == ["0:closed", "0:stopped"])
        #expect(rows.map(\.conversation.isClosed) == [true, false])
    }
}
