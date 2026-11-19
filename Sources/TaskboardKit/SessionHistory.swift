import Foundation

/// タスクに紐づいたセッションの会話の様子。止まったセッションを題で見分けるのに使う（`GET /v1/tasks/{n}/sessions/history`）。
/// daemon が Claude Code の transcript の末尾から読む。Codex のセッションと、transcript が見つからないものは値が空
public struct SessionHistory: Codable, Hashable, Sendable {
    public var sessionID: String
    /// `/rename` か hook で付けた題
    public var customTitle: String?
    /// Claude Code が会話から付けた題
    public var aiTitle: String?
    /// 最後の指示
    public var lastPrompt: String?
    /// 最後の発言のときのブランチ
    public var branch: String?
    /// 最後の発言の時刻
    public var updatedAt: Date?

    public init(
        sessionID: String, customTitle: String? = nil, aiTitle: String? = nil, lastPrompt: String? = nil, branch: String? = nil, updatedAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.customTitle = customTitle
        self.aiTitle = aiTitle
        self.lastPrompt = lastPrompt
        self.branch = branch
        self.updatedAt = updatedAt
    }

    /// 一覧に出す題。付けた題がタスクの題と同じ（hook がタスクの番号と題を付けた）なら、会話から付いた題を使う
    public func title(taskTitle: String) -> String? {
        let custom = customTitle.flatMap { $0.isEmpty || (!taskTitle.isEmpty && $0.contains(taskTitle)) ? nil : $0 }
        return custom ?? aiTitle.flatMap { $0.isEmpty ? nil : $0 } ?? lastPrompt.flatMap { $0.isEmpty ? nil : Self.firstLine($0) }
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}
