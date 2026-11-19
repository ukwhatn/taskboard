import SwiftUI

/// ラベルを上に置き、欄を行の幅いっぱいに出す入力欄（題・備考・リンクのような文を書く欄）。
/// Mac の grouped Form でラベルの右に置くと、文が右に寄って末尾の空白が見えず、欄の範囲も分からなかった（起票のシートの備考）
struct StackedField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inline) {
            // Mac は左にラベルを置く行（案件・列）と同じ字にする。iOS は上にラベルを置くほかの欄（LabeledSegmentedPicker）と同じ
            #if os(macOS)
            Text(label).textRole(.body)
            #else
            Text(label).textRole(.secondary)
            #endif
            field
                .labelsHidden()
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #endif
        }
    }
}
