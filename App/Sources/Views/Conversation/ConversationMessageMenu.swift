import SwiftUI
import TaskboardKit

/// host の会話の発言のメニューの操作。会話の画面が `ChatTranscript` に渡す
struct ChatMessageActions {
    let fork: (ChatMessage) -> Void
    /// 巻き戻せない engine（Codex）は nil。メニューに出さない
    let rewind: ((ChatMessage) -> Void)?
    /// 巻き戻せないときの理由（生成中など）。nil なら押せる。フォークは発言を指せば生成中でも通る
    var rewindBlocked: String?
    /// 操作の帯を、ホバーしていなくても出す発言（snapshot 用）
    var revealed: String?
    /// フォークした会話の地点（`Conversation.forkAt`）と、押すと［状態］のフォークの節を開く口
    var forkPoints: [String] = []
    var showForks: (() -> Void)?
    /// 発言の id → そこから分けたフォークの数。一覧が `forkPoints` から数えて入れる（フォークのある発言は帯を出したままにする）
    var forkCounts: [String: Int] = [:]
}
