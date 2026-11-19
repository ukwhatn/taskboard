import SwiftUI

/// チャットの畳める行（ツール・サブエージェント・差し込まれた文）の見出しの先頭の開閉の印。本文の大きさの正方形の真ん中に置き、
/// 開くと右向きから下向きへ回す（視差効果を減らす設定では回さずに替える）
struct ChatRowChevron: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let open: Bool
    let fonts: ChatFonts

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: fonts.chevron, weight: .semibold))
            .rotationEffect(.degrees(open ? 90 : 0))
            .animation(ChatMotion.fast(reduceMotion), value: open)
            .frame(width: fonts.size, height: fonts.size)
            .accessibilityHidden(true)
    }
}

/// 畳める行の見出し。押すと開閉する。文字は補足の色で、ホバーで本文の色（中の補足は `hovering` を受けて薄い色から補足の色）にする
struct ChatRowHeader<Label: View>: View {
    let open: Bool
    let fonts: ChatFonts
    let toggle: () -> Void
    @ViewBuilder let label: (_ hovering: Bool) -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.row) {
                ChatRowChevron(open: open, fonts: fonts)
                label(hovering)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? ChatPalette.text : ChatPalette.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(open ? "展開済み" : "折りたたみ済み")
    }
}

extension View {
    /// 畳める行の中身（開いた中身・ファイルの札・入れ子の行）を、見出しの開閉の印の後ろ、状態の印の左端に揃えて置く。
    /// 見出しは `ChatRowHeader`
    func chatRowIndented(fonts: ChatFonts) -> some View {
        HStack(alignment: .top, spacing: Space.row) {
            ChatRowChevron(open: false, fonts: fonts).hidden()
            self
        }
    }
}

/// 開いた行の中身のカード。1pt の枠と角丸 8 で囲み、行どうしに区切り線を引く。各行の内側は 10×8
struct ChatOutlineCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.box, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Rectangle().fill(ChatPalette.border).frame(height: 1) }
                    rows[index]
                        .padding(.horizontal, ChatMetrics.toolBodyPadding.width)
                        .padding(.vertical, ChatMetrics.toolBodyPadding.height)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(ChatPalette.border))
    }
}

/// チャットの動き（Claude Desktop の `--cds-dur-fast`・`--cds-dur-snap` と `--cds-ease-snap`）。視差効果を減らす設定では動かさない（nil）
enum ChatMotion {
    /// 消える・開閉の印の回転
    static func fast(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.06)
    }

    /// ホバーの帯が出る（0.1 秒待ってから）
    static func reveal(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.12).delay(0.1)
    }
}
