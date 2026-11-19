import Foundation
import TaskboardKit

/// 今のターンで配った発言から拾う、見張り盤の札の値（最後の応答の文と、使っているツール）。主の流れの発言だけを見る（サブエージェントの分は札に出さない）
struct ConversationTurnActivity: Sendable {
    /// 今のターンの最後の応答の文
    private(set) var reply: String?
    /// 始めてまだ終わっていないツール（始めた順）
    private var tools: [(id: String, name: String)] = []

    /// 最後に始めて、まだ終わっていないツール
    var toolName: String? { tools.last?.name }

    /// 配った発言を読む。使っているツールが変わったら true
    mutating func note(_ messages: [ChatMessage]) -> Bool {
        let before = toolName
        for message in messages where !message.isSubagent {
            switch message.kind {
            case .text where message.role == .assistant && !message.isThinking:
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { reply = text }
            case .toolUse:
                guard let id = message.toolID, let name = message.toolName, !tools.contains(where: { $0.id == id }) else { continue }
                tools.append((id, name))
            case .toolResult:
                guard let id = message.toolID else { continue }
                tools.removeAll { $0.id == id }
            default:
                continue
            }
        }
        return toolName != before
    }

    /// ターンが始まった・終わった（前のターンの応答とツールを捨てる）。使っているツールが変わったら true
    mutating func reset() -> Bool {
        let before = toolName
        self = ConversationTurnActivity()
        return before != nil
    }
}
