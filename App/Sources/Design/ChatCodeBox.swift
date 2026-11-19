import SwiftUI

/// チャットのコードの塊の箱。幅は中身に合わせ（`ChatMetrics.codeMinWidth` から列の幅まで。長い行は折り返す）、
/// 地は 1 段上の面、1pt の枠、角丸 8。右上の文の横に［実行］（シェルの塊だけ）と［コピー］
struct ChatCodeBox<Content: View>: View {
    let code: String
    let actions: ChatCodeActions
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.box, style: .continuous)
        FitWidth(minimum: ChatMetrics.codeMinWidth) {
            HStack(alignment: .top, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 文に重ねると、行の末尾が隠れる
                HStack(spacing: Space.inline / 2) {
                    if let run = actions.run {
                        ChatIconButton(label: "実行", symbol: "play", help: String(localized: "会話のシェルで実行"), action: run)
                            .disabled(actions.running)
                    }
                    ChatCopyButton(text: code)
                }
                .padding(Space.inline / 2)
            }
        }
        .background(ChatPalette.raised, in: shape)
        .overlay(shape.strokeBorder(ChatPalette.border))
    }
}

/// コードの塊の［実行］。シェルの塊だけ `run` を持つ
struct ChatCodeActions {
    var run: (() -> Void)?
    var running: Bool
}

/// チャットの小さなアイコンのボタン（コードの塊・発言の操作の帯）。文字は補足の色で、ホバーで地を付ける。
/// `help` を渡すと、ポインタを置いたときに名前の代わりに出す（押せない理由など）
struct ChatIconButton: View {
    let label: LocalizedStringResource
    let symbol: String
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? ChatPalette.text : ChatPalette.secondaryText)
                .frame(width: HitTarget.size, height: HitTarget.size)
                .background(hovering ? ChatPalette.fill : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(label))
        .help(help.map { Text(verbatim: $0) } ?? Text(label))
    }
}

/// 文をコピーするボタン。押すと 1.2 秒だけ印を✓にする
struct ChatCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        ChatIconButton(label: copied ? "コピーしました" : "コピー", symbol: copied ? "checkmark" : "doc.on.doc") {
            Pasteboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        }
    }
}

/// 中身の理想の幅に合わせ、`minimum` より狭くせず、置かれた幅より広くしない入れ物
struct FitWidth: Layout {
    let minimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = self.width(subview, proposal: proposal)
        return CGSize(width: width, height: subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    private func width(_ subview: LayoutSubview, proposal: ProposedViewSize) -> CGFloat {
        let ideal = subview.sizeThatFits(.unspecified).width
        let available = proposal.width ?? ideal
        return min(max(ideal, minimum), available)
    }
}
