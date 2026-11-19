import SwiftUI

/// ラベル付きの複数行の入力欄（起動プロンプトなど）。iOS の Form は TextField のラベルを出さないので、ラベルを欄の上に置く。
/// macOS の grouped Form はラベルを左に出すので、そのまま渡す
struct LabeledTextEditor: View {
    let label: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 3...10
    var monospaced = true

    var body: some View {
        #if os(macOS)
        field(label)
        #else
        VStack(alignment: .leading, spacing: Space.inline) {
            Text(label).textRole(.secondary)
            field(label).labelsHidden()
        }
        #endif
    }

    @ViewBuilder
    private func field(_ label: String) -> some View {
        let font: MultilineTextFont = monospaced ? .calloutMonospaced : .body
        #if os(macOS)
        // grouped Form の行の形（左にラベル、文は右寄せ）。TextField の題と同じく、欄はラベルの右の残りの幅を全部使い、空の欄にラベルは出さない
        // （`LabeledContent` は中身を理想の幅で置くので、欄が行の半分ほどに縮むか、ラベルの下の段に落ちる）
        HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
            Text(label)
                .accessibilityHidden(true)
            MultilineTextField(label: label, text: $text, lines: lines, font: font, style: .automatic, alignment: .trailing)
        }
        #else
        MultilineTextField(label: label, placeholder: label, text: $text, lines: lines, font: font, style: .automatic, literal: true)
        #endif
    }
}
