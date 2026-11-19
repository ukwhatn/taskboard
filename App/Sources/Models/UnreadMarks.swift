import Foundation
import TaskboardKit

/// サイドバーのタスクの行の「未読」。この端末で、画面に出していない間に終わったターン（端末をまたいで揃えない）。
/// 見回りで動いていた（起動中・生成中・回答待ち）会話が止まったと見たときに印を付ける。動いていたかは残さないので、
/// アプリを閉じている間に終わったターンは未読にしない。印は `AppDefaults.store` に残す
struct UnreadMarks {
    private var conversations: Set<ConversationKey>
    /// 前の見回りで動いていた会話
    private var busy: Set<ConversationKey> = []
    private let store: UserDefaults

    init(store: UserDefaults) {
        self.store = store
        conversations = Set((store.stringArray(forKey: AppPreferences.unreadConversationsKey) ?? []).compactMap(Self.conversationKey))
    }

    /// 未読の会話
    var unread: Set<ConversationKey> { conversations }

    func isUnread(_ conversation: Conversation) -> Bool {
        conversations.contains(conversation.key)
    }

    /// 見回りのたびに呼ぶ。`listed` は state を受けたマシンの分で、突き合わせるのはそのマシンの印だけ
    /// （接続が切れている間に印が全部消えないよう、ほかのマシンの印と動いていた記録は残す）。`shown` は画面に出している会話（印を付けず、付いていれば消す）。
    /// 動いていた記録を含めて変わったら true
    @discardableResult
    mutating func observe(_ listed: [MachineID: MachineState], shown: Set<ConversationKey>) -> Bool {
        let before = (conversations, busy)
        for (machine, state) in listed {
            let wasBusy = busy.filter { $0.machine == machine }
            busy.subtract(wasBusy)
            conversations = conversations.filter { $0.machine != machine || state.conversations[$0].map { !$0.isClosed } == true }
            for (key, conversation) in state.conversations {
                if [.starting, .running, .waiting].contains(conversation.phase) {
                    busy.insert(key)
                    conversations.remove(key)
                } else if shown.contains(key) {
                    conversations.remove(key)
                } else if wasBusy.contains(key), !conversation.isClosed {
                    conversations.insert(key)
                }
            }
        }
        if before.0 != conversations { save() }
        return before != (conversations, busy)
    }

    mutating func markRead(_ read: [Conversation]) {
        let before = conversations
        conversations.subtract(read.map(\.key))
        if before != conversations { save() }
    }

    private static func conversationKey(_ stored: String) -> ConversationKey? {
        let parts = stored.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return ConversationKey(machine: MachineID(rawValue: parts[0]), id: parts[1])
    }

    private func save() {
        store.set(conversations.map { "\($0.machine.rawValue)\n\($0.id)" }.sorted(), forKey: AppPreferences.unreadConversationsKey)
    }
}
