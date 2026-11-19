import SwiftUI
import TaskboardKit

/// 止まった会話を起こしている間は読み込み中、起こせなかったらその理由を出し、そうでなければ `content` を出す（`ConversationFeed.load(waking:then:)`）。
/// 動いている会話には、前に起こせなかった失敗を出さない
struct ConversationWakeGate<Content: View>: View {
    let conversation: Conversation
    let feed: ConversationFeed
    @ViewBuilder let content: Content

    var body: some View {
        switch feed.wake {
        case .waking:
            Section { ProgressView("読み込み中…").controlSize(.small) }
        case .failed(let failure) where conversation.phase == .stopped:
            Section { Text(failure.text).foregroundStyle(.secondary) }
        default:
            content
        }
    }
}
