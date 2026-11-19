import Foundation

/// 委譲先の見分け。サイドバーとタスクの帯は委譲先を出さず、委譲先はセッションの一覧で開く
extension MachineState {
    /// 起こした会話が state にあり（止まっていてもよい）、オーケストレーターでない会話。起こした会話が state から消えた会話は根にする
    public func isDelegate(_ conversation: Conversation) -> Bool {
        guard let id = conversation.parentConversationID, id != conversation.id,
            let parent = conversations[ConversationKey(machine: conversation.machine, id: id)]
        else { return false }
        return parent.purpose != .orchestrator
    }

    /// その会話が起こした会話（lead の［状態］に並べる）。作った順
    public func delegates(of conversation: Conversation) -> [Conversation] {
        conversations.values.filter { $0.machine == conversation.machine && $0.parentConversationID == conversation.id && $0.id != conversation.id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// その会話からフォークした会話。作った順
    public func forks(of conversation: Conversation) -> [Conversation] {
        conversations.values.filter { $0.machine == conversation.machine && $0.forkSource == conversation.id && $0.id != conversation.id }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

/// タスクの会話の見分け。アプリのタスクのパネル・iPhone のタスクの画面と、daemon の届け先・MCP が同じ規則で引く
extension MachineState {
    /// タスクに結ばれた host の会話（止まっているもの・委譲先も）。作った順
    public func conversations(of task: BoardTask) -> [Conversation] {
        let byTask = derived.value(.conversationsByTask) {
            Dictionary(grouping: conversations.values.filter { $0.taskNumber != nil }) { TaskKey(machine: $0.machine, number: $0.taskNumber!) }
                .mapValues { $0.sorted(by: Conversation.listOrder) }
        }
        return byTask[task.id] ?? []
    }

    /// タスクの lead の会話（委譲先と終了した会話を除く。止まっていても残す）。作った順
    public func leadConversations(of task: BoardTask) -> [Conversation] {
        conversations(of: task).filter { !isDelegate($0) && !$0.isClosed }
    }

    /// タスクを開いたときに出す会話（人が帯で選んでいないとき）。止まっていない会話があればそのうち更新の新しいもの、無ければ更新の新しいもの。
    /// 別のタスクの lead が起こした委譲先は、このタスクでは lead として出す（起こした側がこのタスクに無いと、出す会話が無くなる）
    public func openingConversation(of task: BoardTask) -> Conversation? {
        let handedOver = conversations(of: task).filter { conversation in
            guard isDelegate(conversation), !conversation.isClosed, let id = conversation.parentConversationID else { return false }
            return conversations[ConversationKey(machine: conversation.machine, id: id)]?.taskNumber != task.number
        }
        let newest = (leadConversations(of: task) + handedOver).sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        return newest.first { $0.phase != .stopped } ?? newest.first
    }

    /// 止まったセッション（再開の候補）。紐づけの記録の Claude と Codex のうち、今ある会話（止まっていても札から開ける）の会話 ID を外す。
    /// 結んだのが新しい順に、会話 ID ごとに 1 つ
    public func stoppedSessions(of task: BoardTask) -> [TaskSessionRef] {
        let running = derived.value(.runningAgentSessionIDs) { Set(conversations.values.map(\.agentSessionID)) }
        var seen = Set<String>()
        return task.sessions
            .filter { [AgentKind.claude.rawValue, AgentKind.codex.rawValue].contains($0.agent) && !running.contains($0.sessionID) }
            // 結んだ時刻は store でミリ秒に丸まり、続けて結ぶと同じになる。同じなら後に結んだ（id の大きい）方を先にする
            .sorted { ($0.linkedAt, $0.id) > ($1.linkedAt, $1.id) }
            .filter { seen.insert($0.sessionID).inserted }
    }
}
