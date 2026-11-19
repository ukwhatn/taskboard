import Foundation
import TaskboardKit

/// タスクの lead（回答・レビュー・リンクの知らせの届け先）。タスクに結ばれた会話（`conversation.taskNumber`。止まっていてもよい）から、
/// 委譲先（`MachineState.isDelegate`）を除き、残りで最後に結んだものを選ぶ。全部が委譲先なら全部から選ぶ。会話が無ければ、最後に結んだ止まった TUI
enum TaskDeliveryTarget: Hashable, Sendable {
    /// host の会話（止まっていてもよい）
    case conversation(String)
    /// 会話で動いていない TUI のセッション。親が分からないので委譲先とは見なさない。会話が無いときだけ選ぶ
    case stoppedTerminal(agentSessionID: String)

    /// daemon の今の会話から選ぶ（回答・レビュー・リンクの知らせの届け先）。タスクが無ければ nil
    static func lead(task number: Int, state: DaemonState, conversations: (any FeedbackConversations)?) async -> TaskDeliveryTarget? {
        guard let task = await state.task(number: number) else { return nil }
        return await lead(
            task: task, conversations: await state.allConversations(),
            conversationOwning: { await conversations?.conversationID(owning: $0) })
    }

    /// `conversationOwning` は Claude の会話 ID（`/clear` の前のものを含む）から host の会話の id を引く。会話の結んだ時刻は、
    /// その会話の ID の紐づけの記録のうち最後のもので、記録が無ければ会話を作った時刻
    static func lead(
        task: BoardTask, conversations: [Conversation], conversationOwning: (String) async -> String?
    ) async -> TaskDeliveryTarget? {
        var machine = MachineState()
        machine.conversations = Dictionary(conversations.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let claude = AgentKind.claude.rawValue
        var linkedAt: [String: Date] = [:]
        for ref in task.sessions where ref.agent == claude { linkedAt[ref.sessionID] = max(linkedAt[ref.sessionID] ?? .distantPast, ref.linkedAt) }
        var owners: [String: String] = [:]
        for sessionID in linkedAt.keys { owners[sessionID] = await conversationOwning(sessionID) }

        var candidates: [(target: TaskDeliveryTarget, linkedAt: Date, delegate: Bool)] = []
        for conversation in machine.conversations(of: task) {
            let linked = linkedAt.filter { owners[$0.key] == conversation.id }.values.max() ?? conversation.createdAt
            candidates.append((.conversation(conversation.id), linked, machine.isDelegate(conversation)))
        }
        if !candidates.isEmpty {
            let roots = candidates.filter { !$0.delegate }
            return (roots.isEmpty ? candidates : roots).max { a, b in
                (a.linkedAt, String(describing: a.target)) < (b.linkedAt, String(describing: b.target))
            }?.target
        }
        // 会話の /clear の前の ID は、その会話がほかのタスクに移っていても止まった TUI ではない
        return machine.stoppedSessions(of: task).first { $0.agent == claude && owners[$0.sessionID] == nil }.map { .stoppedTerminal(agentSessionID: $0.sessionID) }
    }
}
