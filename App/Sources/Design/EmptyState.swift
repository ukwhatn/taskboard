import SwiftUI
import TaskboardKit

/// 空状態（docs/ui-copy.md「空状態と読み込み中」）。「{対象}はありません」と、あれば次の操作
struct EmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    var message: String?
    @ViewBuilder var actions: Actions

    /// 記号の大きさと、中身の最大の幅（ContentUnavailableView の見た目に合わせる）
    private static var symbolSize: CGFloat { 36 }
    private static var maxWidth: CGFloat { 400 }

    /// ContentUnavailableView と同じ並びを自前で組む。ContentUnavailableView は 1 つ出すのに 100 ms 近くかかり、タスクを開く時間の半分を占めた
    var body: some View {
        EmptyStateLayout(spacing: Space.block) {
            Image(systemName: symbol)
                .font(.system(size: Self.symbolSize))
                .foregroundStyle(.tertiary)
                // 高さ 0 で置かれたら（欄が低いとき）何も描かない
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipped()
                .accessibilityHidden(true)
            VStack(spacing: Space.inline) {
                Text(title).font(.largeTitle.bold()).foregroundStyle(.secondary)
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.row) { actions }
        }
        .padding(Space.section)
        .frame(maxWidth: Self.maxWidth)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, symbol: String, message: String? = nil) {
        self.init(title: title, symbol: symbol, message: message) { EmptyView() }
    }
}

/// 空状態の縦の並び。高さが足りなければ先頭の記号を置かない（ContentUnavailableView と同じ。置いたままだと、低い欄で上の帯を押し出した）
private struct EmptyStateLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = arrange(proposal: proposal, subviews: subviews)
        return CGSize(width: sizes.compactMap { $0?.width }.max() ?? 0, height: height(of: sizes))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = arrange(proposal: proposal, subviews: subviews)
        var y = bounds.midY - height(of: sizes) / 2
        for (subview, size) in zip(subviews, sizes) {
            guard let size else {
                subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: ProposedViewSize(size))
            y += size.height + spacing
        }
    }

    /// 各部品の大きさ。置かない部品（中身の無い操作の並びと、高さが足りないときの記号）は nil
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [CGSize?] {
        var sizes: [CGSize?] = subviews.map { subview in
            let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            return size.height > 0 ? size : nil
        }
        if let limit = proposal.height, height(of: sizes) > limit, !sizes.isEmpty { sizes[0] = nil }
        return sizes
    }

    private func height(of sizes: [CGSize?]) -> CGFloat {
        let shown = sizes.compactMap { $0 }
        return shown.map(\.height).reduce(0, +) + spacing * CGFloat(max(shown.count - 1, 0))
    }
}
