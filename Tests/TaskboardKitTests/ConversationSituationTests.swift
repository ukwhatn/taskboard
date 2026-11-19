import Foundation
import Testing

@testable import TaskboardKit

@Suite("タスクとカードの状況の 1 文")
struct ConversationSituationTests {
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    @Test("タスクの状況は、終了していない会話のうち最後にターンが終わったものの 1 文")
    func taskSituation() {
        let machine = MachineID(rawValue: "m")
        var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        let task = BoardTask(machine: machine, number: 1, boardID: "b", columnID: "working", title: "t", createdAt: t0, updatedAt: t0)
        func add(_ id: String, _ text: String, at offset: TimeInterval, closed: Bool = false) {
            var conversation = Conversation(
                id: id, machine: machine, taskNumber: 1, agentSessionID: id, cwd: "/", runner: .host, phase: closed ? .stopped : .idle, pending: [],
                lastExit: closed ? ConversationStopCause.closed.lastExit : nil, createdAt: t0, updatedAt: t0)
            conversation.lastReply = ConversationReply(text: text, at: t0.addingTimeInterval(offset))
            state.conversations[conversation.key] = conversation
        }
        #expect(state.situation(of: task) == nil)
        add("c1", "古い応答", at: 0)
        add("c2", "新しい応答", at: 60)
        add("c3", "終了した会話の応答", at: 120, closed: true)
        #expect(state.situation(of: task)?.text == "新しい応答")
        var done = task
        done.columnID = "done"
        #expect(state.situation(of: done) == nil, "完了の列では出さない")
        let conversations = Array(state.conversations.values)
        let signals = CardSignals(workItems: [], links: [], reviewRequested: false, reviewed: false, terminal: false, conversations: conversations)
        #expect(signals.situation?.text == "新しい応答")
        var finished = signals
        finished.terminal = true
        #expect(finished.situation == nil)
    }
}
