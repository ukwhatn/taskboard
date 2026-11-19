import SwiftUI
import TaskboardKit

/// 入力欄の上に出す、engine の ToDo（`Conversation.plan`）。済んでいない項目がある間だけ出す。
/// 畳むと見出しに進行中の項目、開くと項目ごとの状態
struct ConversationPlanCard: View {
    let items: [ConversationPlanItem]
    let fonts: ChatFonts
    @State private var open: Bool

    init(items: [ConversationPlanItem], fonts: ChatFonts, open: Bool = false) {
        self.items = items
        self.fonts = fonts
        _open = State(initialValue: open)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        let done = items.count { $0.status == .completed }
        VStack(alignment: .leading, spacing: 0) {
            ChatRowHeader(open: open, fonts: fonts, toggle: { open.toggle() }) { hovering in
                Text("ToDo（\(done)/\(items.count)）").font(fonts.subheadline.weight(.medium))
                    .accessibilityLabel(Text("ToDo\(items.count)件中\(done)件完了"))
                if !open, let current = items.first(where: { $0.status == .inProgress }) {
                    Text(current.activeTitle ?? current.title).font(fonts.subheadline)
                        .foregroundStyle(hovering ? ChatPalette.secondaryText : ChatPalette.mutedText).lineLimit(1)
                }
            }
            .padding(.horizontal, ChatMetrics.bubblePadding.width)
            .frame(minHeight: ChatMetrics.queueHeader)
            if open {
                Rectangle().fill(ChatPalette.border).frame(height: 1)
                VStack(alignment: .leading, spacing: Space.inline) {
                    ForEach(items) { row($0) }
                }
                .padding(.horizontal, ChatMetrics.bubblePadding.width)
                .padding(.vertical, ChatMetrics.bubblePadding.height)
            }
        }
        .background(ChatPalette.fill, in: shape)
    }

    private func row(_ item: ConversationPlanItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
            Image(systemName: Self.symbol(item.status))
                .font(fonts.caption)
                .foregroundStyle(item.status == .inProgress ? ChatPalette.accent : ChatPalette.mutedText)
            Text(item.title).font(fonts.body)
                .foregroundStyle(item.status == .completed ? ChatPalette.mutedText : ChatPalette.text)
                .strikethrough(item.status == .completed)
                .fontWeight(item.status == .inProgress ? .medium : nil)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(item.title)、\(Self.statusLabel(item.status))"))
    }

    private static func symbol(_ status: ConversationPlanItem.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.inset.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    private static func statusLabel(_ status: ConversationPlanItem.Status) -> String {
        switch status {
        case .pending: String(localized: "未着手")
        case .inProgress: String(localized: "進行中")
        case .completed: String(localized: "完了")
        }
    }

    /// 出すか：済んでいない項目があるとき
    static func shows(_ plan: [ConversationPlanItem]?) -> Bool {
        plan?.contains { $0.status != .completed } == true
    }
}
