import SwiftUI

/// 子を左から並べ、幅が尽きたら次の行へ送る。子は本来の幅で置き、幅より広い子だけを幅に縮める
struct FlowRow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    /// 子の本来の大きさ。sizeThatFits は幅を替えて何度も呼ばれるので、子ごとに 1 回だけ測る
    struct Cache {
        var natural: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(natural: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews, natural: cache.natural)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min(width, $0) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews, natural: cache.natural) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews, natural: [CGSize]) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = natural[index]
            if size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            let next = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
