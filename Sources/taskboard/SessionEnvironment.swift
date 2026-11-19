import Foundation
import TaskboardDaemon
import TaskboardKit

/// MCP の process と CLI のシェルが、環境から読む「自分がどのセッションの中か」
struct SessionEnvironment: Sendable {
    /// Claude Code のセッション ID。`/clear` の後も起動したときの ID のまま変わらない（再開では MCP ごと起動し直されて揃う）
    let agentSessionID: String?
    /// host の会話（daemon が stream-json で動かす会話）の中なら、その会話の id。`/clear` の後も会話ごと結び直されるので、結んだときの注意が要らない
    let conversationID: String?

    init(environment: [String: String]) {
        agentSessionID = environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        conversationID = environment["TASKBOARD_CONVERSATION_ID"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 会話を起こした側にするときの値。host の会話の中ならその会話
    var parent: ConversationParent? {
        conversationID.map { ConversationParent(conversationID: $0, agentSessionID: agentSessionID) }
    }
}
