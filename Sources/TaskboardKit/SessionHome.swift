import Foundation

/// セッションと会話を開く画面。委譲先は起こした側と同じ画面に入る（アプリのタスク画面・サイドバーの「タスクなし」・オーケストレーター）
public enum SessionHome: Hashable, Sendable, Comparable {
    case task(Int)
    case orchestrator
    /// どのタスクにも結ばれていない（サイドバーのマシンの「タスクなし」）
    case unassigned
}

public struct SessionMemberRow: Hashable, Sendable {
    public var conversation: Conversation
    /// 0 が起こした側の無いもの（lead）。委譲先は 1、その委譲先は 2
    public var depth: Int

    public init(conversation: Conversation, depth: Int) {
        self.conversation = conversation
        self.depth = depth
    }
}

extension MachineState {
    /// 会話を開く置き場。オーケストレーターの会話はオーケストレーター、タスクに結ばれていればそのタスク、無ければ起こした側の置き場
    public func home(of conversation: Conversation) -> SessionHome {
        var seen: Set<String> = []
        var current = conversation
        while seen.insert(current.id).inserted {
            if current.purpose == .orchestrator { return .orchestrator }
            if let number = current.taskNumber, tasks[TaskKey(machine: current.machine, number: number)] != nil { return .task(number) }
            guard let id = current.parentConversationID, let parent = conversations[ConversationKey(machine: current.machine, id: id)] else { break }
            current = parent
        }
        return .unassigned
    }

    /// 終えていない会話が 1 つでもあるタスクの番号
    public func activeTaskNumbers() -> Set<Int> {
        var numbers: Set<Int> = []
        for (home, talks) in membersByHome {
            guard case .task(let number) = home, talks.contains(where: { !$0.isClosed }) else { continue }
            numbers.insert(number)
        }
        return numbers
    }

    /// 置き場ごとに入る会話。1 回で全部の置き場を数えて控えに覚える
    private var membersByHome: [SessionHome: [Conversation]] {
        derived.value(.membersByHome) { Dictionary(grouping: conversations.values) { home(of: $0) } }
    }

    /// 置き場に入る会話（終了したものも入れる。呼び手が `isClosed` で分ける）。起こした側のすぐ後に委譲先を深さ付きで続け、同じ親の中は作った順
    public func members(of home: SessionHome) -> [SessionMemberRow] {
        derived.value(.memberRows(home)) { memberRows(of: home) }
    }

    private func memberRows(of home: SessionHome) -> [SessionMemberRow] {
        let members = (membersByHome[home] ?? []).sorted(by: Conversation.listOrder)
        let ids = Set(members.map(\.id))
        var children: [String: [Conversation]] = [:]
        var roots: [Conversation] = []
        for member in members {
            if let parent = member.parentConversationID, parent != member.id, ids.contains(parent) {
                children[parent, default: []].append(member)
            } else {
                roots.append(member)
            }
        }
        var rows: [SessionMemberRow] = []
        var visited: Set<String> = []
        func walk(_ member: Conversation, depth: Int) {
            guard visited.insert(member.id).inserted else { return }
            rows.append(SessionMemberRow(conversation: member, depth: depth))
            for child in children[member.id] ?? [] { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        // 輪になっていて根に届かなかったものは、根として後ろに置く
        for member in members where !visited.contains(member.id) { walk(member, depth: 0) }
        return rows
    }
}
