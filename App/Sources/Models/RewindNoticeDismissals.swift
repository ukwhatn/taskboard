import Foundation
import TaskboardKit

/// 巻き戻した会話の入力欄の上に出る［元に戻す］のバーを、消した（×）か、巻き戻した後に送った会話の印。
/// 値は印を付けたときの会話の `agentSessionID`。巻き戻すたびに ID が替わるので、次の巻き戻しではまたバーが出る。
/// 画面の `@State` に持つと、タスクや右の欄を切り替えて画面が作り直されるたびにバーが出直したので、`AppModel` が持つ。
/// アプリを開き直しても出ないよう `AppDefaults.store` にも残す。残すのは新しい方から `limit` 件まで
struct RewindNoticeDismissals {
    static let limit = 100

    /// 古い順。同じ会話は 1 件だけ
    private var entries: [Entry]
    private let store: UserDefaults

    private struct Entry {
        var key: ConversationKey
        var sessionID: String

        var stored: String { "\(key.machine.rawValue)\n\(key.id)\n\(sessionID)" }

        init(key: ConversationKey, sessionID: String) {
            self.key = key
            self.sessionID = sessionID
        }

        init?(stored: String) {
            let parts = stored.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            self.init(key: ConversationKey(machine: MachineID(rawValue: parts[0]), id: parts[1]), sessionID: parts[2])
        }
    }

    init(store: UserDefaults) {
        self.store = store
        let saved = (store.stringArray(forKey: AppPreferences.rewindNoticeDismissalsKey) ?? []).compactMap(Entry.init(stored:))
        entries = Array(saved.suffix(Self.limit))
    }

    /// 入力欄の上にバーを出すか。巻き戻しを元に戻せる間は、印の ID が今の `agentSessionID` と違うときだけ出す
    func shows(for conversation: Conversation) -> Bool {
        guard conversation.canUndoRewind else { return false }
        return entries.first { $0.key == Self.key(conversation) }?.sessionID != conversation.agentSessionID
    }

    /// 今の巻き戻しのバーを出さない印を付ける。巻き戻しを元に戻せない会話には付けない（バーを出さないので要らない）
    mutating func dismiss(_ conversation: Conversation) {
        guard conversation.canUndoRewind else { return }
        let key = Self.key(conversation)
        entries.removeAll { $0.key == key }
        entries = Array((entries + [Entry(key: key, sessionID: conversation.agentSessionID)]).suffix(Self.limit))
        save()
    }

    /// 要らなくなった印を消す。`listed` は会話の一覧を読み終えたマシンの会話で、突き合わせるのはそのマシンの印だけ。
    /// 接続が切れている・まだ読んでいないマシンの印は、切れている間に全部消えないよう残す。
    /// 消すのは、一覧から無くなった会話と、巻き戻しを元に戻せなくなった会話（元に戻した）の印。消したら true
    @discardableResult
    mutating func reconcile(listed: [MachineID: [ConversationKey: Conversation]]) -> Bool {
        let kept = entries.filter { entry in
            guard let conversations = listed[entry.key.machine] else { return true }
            return conversations[entry.key]?.canUndoRewind == true
        }
        guard kept.count != entries.count else { return false }
        entries = kept
        save()
        return true
    }

    private static func key(_ conversation: Conversation) -> ConversationKey {
        ConversationKey(machine: conversation.machine, id: conversation.id)
    }

    private func save() {
        store.set(entries.map(\.stored), forKey: AppPreferences.rewindNoticeDismissalsKey)
    }
}
