import Foundation

/// 会話の裏のタスクの様子を、ツールの結果の `backgroundTaskID` で引く表
public struct ChatBackgroundTasks: Hashable, Sendable {
    private var statuses: [String: ConversationBackgroundTaskState.Status]
    /// 表に無い id を終わったと見てよいか（会話のプロセスが無い、または daemon が裏のタスクを全部知っている）
    private var missingMeansEnded: Bool

    /// `conversation` が nil なら（pane のセッション）様子は分からない
    public init(conversation: Conversation?) {
        guard let conversation else {
            statuses = [:]
            missingMeansEnded = false
            return
        }
        statuses = Dictionary((conversation.backgroundTaskStates ?? []).map { ($0.id, $0.status) }, uniquingKeysWith: { $1 })
        missingMeansEnded = conversation.runner == .none || (conversation.backgroundTaskStates != nil && conversation.backgroundTasksKnown)
    }

    /// nil は分からない
    public func status(of id: String) -> ConversationBackgroundTaskState.Status? {
        statuses[id] ?? (missingMeansEnded ? .ended : nil)
    }
}

/// ツールの呼び出しの様子（ツールの行と、組・サブエージェントの見出しの印）
public enum ChatToolStatus: Hashable, Sendable {
    /// 結果がまだ無い
    case running
    case completed
    case failed
    /// 結果を待たずに裏で続けている。nil は今の様子が分からない（前の版の daemon・pane のセッション・数が分からない会話）
    case background(ConversationBackgroundTaskState.Status?)

    public init(result: ChatMessage?, background: ChatBackgroundTasks) {
        guard let result else {
            self = .running
            return
        }
        if let id = result.backgroundTaskID {
            self = .background(background.status(of: id))
        } else {
            self = result.isError ? .failed : .completed
        }
    }

    /// 組と最後の呼び出しの見出しに出す様子。実行中 → 失敗（裏のタスクの失敗を含む）→ 裏で実行中 → 裏の様子が分からない、の順に強い。
    /// 全部終わっていれば nil
    public static func summary(_ statuses: [ChatToolStatus]) -> ChatToolStatus? {
        if statuses.contains(.running) { return .running }
        if statuses.contains(where: { $0 == .failed || $0 == .background(.failed) }) { return .failed }
        if statuses.contains(.background(.running)) { return .background(.running) }
        if statuses.contains(.background(nil)) { return .background(nil) }
        return nil
    }
}
