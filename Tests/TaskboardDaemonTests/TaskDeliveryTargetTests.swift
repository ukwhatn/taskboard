import Foundation
import Testing
import TaskboardKit

@testable import TaskboardDaemon

@Suite("タスクの lead（回答・レビュー・リンクの知らせの届け先）")
struct TaskDeliveryTargetTests {
    private let machine = MachineID(rawValue: "m")
    private let t0 = Date(timeIntervalSince1970: 0)

    private func conversation(_ id: String, task: Int? = 1, parent: String? = nil, created: TimeInterval = 0) -> Conversation {
        Conversation(
            id: id, machine: machine, taskNumber: task, agentSessionID: "a-\(id)", cwd: "/tmp", runner: .host, phase: .idle, parentConversationID: parent,
            createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: created))
    }

    private func ref(_ sessionID: String, linked: TimeInterval = 0) -> TaskSessionRef {
        TaskSessionRef(id: 1, agent: "claude", sessionID: sessionID, cwd: "/tmp", linkedAt: Date(timeIntervalSince1970: linked))
    }

    private func lead(
        _ refs: [TaskSessionRef], conversations: [Conversation] = [], owning: [String: String] = [:]
    ) async -> TaskDeliveryTarget? {
        let task = BoardTask(machine: machine, number: 1, boardID: "b", columnID: "working", title: "t", sessions: refs, createdAt: t0, updatedAt: t0)
        // 今の Claude の会話 ID も、/clear の前の ID と同じく会話を引ける
        var owners = owning
        for conversation in conversations { owners[conversation.agentSessionID] = conversation.id }
        return await TaskDeliveryTarget.lead(task: task, conversations: conversations, conversationOwning: { [owners] in owners[$0] })
    }

    @Test("会話は conversation.taskNumber で選ぶ。紐づけの記録が無くても結ばれた会話は届け先で、記録だけが残った別のタスクの会話は届け先にしない")
    func conversationsByTaskNumber() async {
        #expect(await lead([], conversations: [conversation("bound")]) == .conversation("bound"))
        #expect(await lead([ref("a-moved", linked: 5)], conversations: [conversation("moved", task: 2)]) == nil)
    }

    @Test("委譲先は、委譲先でない会話があれば選ばない。全部が委譲先なら全部から選ぶ")
    func skipsDelegates() async {
        // 起こした側の会話はほかのタスクに居る（委譲先と見なすには、起こした側が居ること）
        let parent = conversation("lead", task: 2)
        let child = conversation("child", parent: "lead", created: 9)
        #expect(await lead([], conversations: [conversation("root", created: 1), child, parent]) == .conversation("root"))
        #expect(await lead([], conversations: [parent, child]) == .conversation("child"))
    }

    @Test("止まった TUI は会話が無いときだけ、後に結んだもの。会話の /clear の前の ID は止まった TUI にしない")
    func stoppedTerminal() async {
        #expect(await lead([ref("tui", linked: 1), ref("tui2", linked: 2)]) == .stoppedTerminal(agentSessionID: "tui2"))
        #expect(await lead([ref("tui", linked: 1), ref("old-c", linked: 2)], conversations: [conversation("c", task: 2)], owning: ["old-c": "c"]) == .stoppedTerminal(agentSessionID: "tui"))
        #expect(await lead([ref("tui", linked: 1)], conversations: [conversation("c")]) == .conversation("c"))
    }
}
