import SwiftUI
import TaskboardKit

/// 短いラベル（PR、列、件数）。1 行で省略する
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .chipStyle(tint: tint)
    }
}

/// 押せるチップ（横並びの選択、リンク）。選んだ状態は色と読み上げの両方で示す
struct ChipButton: View {
    let text: String
    var symbol: String?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Chip(text: text, symbol: symbol, tint: selected ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .hitTarget()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
