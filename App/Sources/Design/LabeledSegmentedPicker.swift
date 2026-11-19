import SwiftUI

/// 2〜5 個から選ぶ横並び（docs/ui-system.md「選択の形」）にラベルを付ける。iOS の Form は segmented の Picker のラベルを出さないので、
/// ラベルを上に置く。macOS の grouped Form はラベルを左に出すので、そのまま渡す
struct LabeledSegmentedPicker<Value: Hashable, Options: View>: View {
    let label: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    init(_ label: String, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.label = label
        _selection = selection
        self.options = options()
    }

    var body: some View {
        #if os(macOS)
        Picker(label, selection: $selection) { options }
            .pickerStyle(.segmented)
        #else
        VStack(alignment: .leading, spacing: Space.inline) {
            Text(label).textRole(.secondary)
            // iOS の横並びは札を一番長い札の幅に揃えるので、入り切らないと先頭から「停止し…」のように切れる。そのときはメニューにする
            ViewThatFits(in: .horizontal) {
                SegmentedFit {
                    Picker(label, selection: $selection) { options }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    Group { options }
                        .font(SegmentedFit.labelFont)
                        .hidden()
                }
                Picker(label, selection: $selection) { options }
                    .pickerStyle(.menu)
                    .labelsHidden()
            }
        }
        #endif
    }
}

#if os(iOS)
/// 横並びの選択（先頭の子）が、札を切らずに入る幅を理想の幅として答える入れ物。2 番目からの子は測るための札の文字で、描かない。
/// 札は一番長い札の幅に揃うので、要る幅は（一番長い札の文字 + 札の内側の余白）× 札の数。
/// 選択そのものの理想の幅は余白を広く取っていて、切れずに入る幅でも入らないと答えた（effort の 5 つ）
private struct SegmentedFit: Layout {
    /// 札の文字の書体（UISegmentedControl の既定）
    static let labelFont = Font.footnote.weight(.medium)
    /// 札の左右の内側の余白の合計。iPhone 17e で、余白 14.9pt の「medium」は切れず、4.6pt の「停止しない」は切れた
    static let labelPadding: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let picker = subviews.first else { return .zero }
        let height = picker.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)).height
        if let width = proposal.width { return CGSize(width: width, height: height) }
        let labels = subviews.dropFirst()
        let widest = labels.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: (widest + Self.labelPadding) * CGFloat(labels.count), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            subview.place(at: bounds.origin, proposal: index == 0 ? ProposedViewSize(bounds.size) : .zero)
        }
    }
}
#endif
