import SwiftUI
import TaskboardKit

/// タスクの帯の会話の札。状態の印と題
struct ConversationPill: View {
    @Environment(AppModel.self) private var model
    @Environment(\.today) private var today
    let conversation: Conversation
    let selected: Bool
    /// 状態の印の位置に［×］を重ねる間は印を隠す（幅を変えない）
    var hidesStatusGlyph = false
    let action: () -> Void

    var body: some View {
        let running = conversation.runningBackgroundTasks ?? 0
        // 再開の予定は札の幅を変えないよう、help と読み上げにだけ入れる
        let status = [model.statusText(of: conversation, now: today)] + (running > 0 ? [StatusAppearance.backgroundTasks(running).label] : [])
        Button(action: action) {
            HStack(spacing: Space.inline) {
                StatusGlyph(conversation: conversation).opacity(hidesStatusGlyph ? 0 : 1)
                Text(conversation.displayTitle)
                BackgroundTasksGlyph(count: running)
            }
            .pillStyle(selected: selected)
        }
        .buttonStyle(.plain)
        .help(([conversation.displayTitle, String(localized: "会話")] + status).joined(separator: "\n"))
        .accessibilityLabel(([conversation.displayTitle, String(localized: "会話")] + status).joined(separator: "、"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
