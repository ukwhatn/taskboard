import Foundation

/// 会話がタスクの状態として出す短い文（サイドバーのタスクの行の 2 行目）。PR やリンクから taskboard が組み立てると、
/// GitHub を取り直すまで古い状態が残るので、それ以外の状態は会話が自分で書く。書いた会話が終了するか、タスクを完了・見送りに移すと外れる
public struct TaskStatusNote: Codable, Hashable, Sendable {
    public static let limit = 20

    public var text: String
    /// 書いた host の会話（daemon の id）。端末の会話が書いたときは nil
    public var conversationID: String?
    public var setAt: Date

    public init(text: String, conversationID: String?, setAt: Date) {
        self.text = text
        self.conversationID = conversationID
        self.setAt = setAt
    }
}

/// `TaskUpdateRequest.status`。空の文で外す
public struct TaskStatusUpdate: Codable, Hashable, Sendable {
    public var text: String
    public var conversationID: String?

    public init(text: String, conversationID: String? = nil) {
        self.text = text
        self.conversationID = conversationID
    }
}
