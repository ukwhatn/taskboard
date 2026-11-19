import Foundation
import TaskboardKit

/// taskboard が送る知らせ（リンクの知らせ・見張り・起こす予定）を、届け先に発言として入れる部分。何を・いつ・止まっているときにどうするか（`DeliveryKind`）と、
/// 入れられなかったときの扱いは呼ぶ側が決める。
///
/// - 会話への uuid は `uuidSeed` と、その知らせ（`Key`）が待ち行列で取り消された回数から決める。会話は受けた uuid を受け直さないので、
///   届けてから記録するまでに daemon が落ちても 2 回入らない。取り消されたら回数を進めて、次は別の uuid で入れる
/// - 止まった TUI は会話で戻すだけ。戻した会話が入力待ちに入ったら、呼ぶ側が届け直す
actor NoticeDelivery<Key: Hashable & Sendable> {
    enum Outcome: Equatable, Sendable {
        /// 入れた（会話なら、受けたと host が返した）。`to` はログに書く届け先
        case delivered(to: String)
        /// 待ち行列で取り消された
        case cancelled
        /// 会話が生成中か質問への回答を待っている、または `DeliveryKind` が起こさない止まり方
        case busy
        /// 届いたかを確かめられなかった
        case unknown
        /// 会話が無いか起こせない（会話に届けない設定を含む）
        case unavailable
        /// 止まった TUI を会話で戻すよう頼んだ（`DeliveryKind.resumesStoppedTerminal` でなければ何もしていない）
        case resuming
    }

    let state: DaemonState
    /// nil なら会話には届けない（テスト）
    let conversations: (any FeedbackConversations)?
    private var attempts: [Key: Int] = [:]

    init(state: DaemonState, conversations: (any FeedbackConversations)?) {
        self.state = state
        self.conversations = conversations
    }

    /// 次に会話へ入れるときの uuid
    func uuid(_ uuidSeed: String, key: Key) -> String {
        Self.uuid(uuidSeed, attempt: attempts[key] ?? 0)
    }

    static func uuid(_ uuidSeed: String, attempt: Int) -> String {
        StableUUID.make(uuidSeed + ".\(attempt)")
    }

    /// 届け終えた・やめた知らせの回数を捨てる
    func forget(_ key: Key) {
        attempts.removeValue(forKey: key)
    }

    /// タスクの今の lead（`TaskDeliveryTarget.lead`）
    func lead(task number: Int) async -> TaskDeliveryTarget? {
        await TaskDeliveryTarget.lead(task: number, state: state, conversations: conversations)
    }

    /// タスクの lead（`target`）に入れる
    func deliver(_ text: String, to target: TaskDeliveryTarget, task number: Int, key: Key, uuidSeed: String, kind: DeliveryKind) async -> Outcome {
        switch target {
        case .conversation(let id):
            return await deliver(text, toConversation: id, key: key, uuidSeed: uuidSeed, kind: kind)
        case .stoppedTerminal(let agentSessionID):
            await conversations?.resumeStoppedLead(task: number, agentSessionID: agentSessionID, for: kind)
            return .resuming
        }
    }

    func deliver(_ text: String, toConversation id: String, key: Key, uuidSeed: String, kind: DeliveryKind) async -> Outcome {
        guard let conversations else { return .unavailable }
        let attempt = attempts[key] ?? 0
        switch await conversations.deliver(conversationID: id, text: text, uuid: Self.uuid(uuidSeed, attempt: attempt), kind: kind) {
        case .delivered:
            attempts.removeValue(forKey: key)
            return .delivered(to: id)
        case .cancelled:
            attempts[key] = attempt + 1
            return .cancelled
        case .busy: return .busy
        case .unknown: return .unknown
        case nil: return .unavailable
        }
    }
}
