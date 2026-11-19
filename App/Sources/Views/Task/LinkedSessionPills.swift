import SwiftUI
import TaskboardKit

/// 画面の札の並び（タスク・オーケストレーター・タスクなし）。lead と委譲先の会話を、起こした側の後に委譲先の順で並べ、委譲先は印で見分ける。
/// 押すとその場で切り替え（タスク画面では ⌘ を押しながら押すと右に並べる）、右クリックで「右に並べる」と会話の項目
struct LinkedSessionPills: View {
    @Environment(\.pageInset) private var inset
    let rows: [SessionMemberRow]
    let current: ConversationKey?
    /// 右に並べて出しているもの
    var second: ConversationKey?
    let select: (ConversationKey) -> Void
    /// nil ならメニューに「右に並べる」を出さない
    var selectSecond: ((ConversationKey) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.row) {
                ForEach(rows, id: \.conversation.id) { row in
                    HStack(spacing: Space.inline) {
                        if row.depth > 0 {
                            Image(systemName: "arrow.turn.down.right")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("委譲先")
                        }
                        pill(row.conversation)
                    }
                }
            }
            .padding(.vertical, Space.row)
            .padding(.leading, inset)
        }
    }

    private func pill(_ conversation: Conversation) -> some View {
        ConversationPill(conversation: conversation, selected: current == conversation.key || second == conversation.key) {
            select(conversation.key)
        }
        .contextMenu {
            if let selectSecond, current != conversation.key {
                Button("右に並べる", systemImage: "rectangle.split.2x1") { selectSecond(conversation.key) }
            }
            ConversationMenuItems(conversation: conversation)
        }
    }
}
