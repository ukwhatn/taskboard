import SwiftUI

/// チャット（発言・ツールの行・コード・入力欄・カード）の色。Claude Desktop の Code の画面の色（v2 の tokens）に合わせた、黄みのある灰色 1 系統。
/// 地と枠は墨（ライトは #0b0b0b、ダークは白）を重ねる濃さで分け、色は状態と差分にだけ使う。窓の枠・サイドバー・ボードはシステムの色のまま。
/// 値は `ChatTone` に 1 つずつ置き、SwiftUI の色（ここ）と会話の一覧の AppKit・UIKit の色（`ChatPalette.Platform`）を同じ値から作る
enum ChatPalette {
    /// 会話の列の地（`--cds-surface-1`）
    static let surface = Color(ChatTone.surface)
    /// 地より 1 段上の面：コードの塊・入力欄（`--cds-surface-2`）
    static let raised = Color(ChatTone.raised)
    static let text = Color(ChatTone.text)
    /// ツールの行・補足の文
    static let secondaryText = Color(ChatTone.secondaryText)
    /// 時刻・印・押す前のツールの補足
    static let mutedText = Color(ChatTone.mutedText)
    /// 吹き出し・インラインのコード・表の中身・ボタンのホバー（墨 5%）
    static let fill = Color(ChatTone.fill)
    /// 枠・表の見出し・ホバーした吹き出し・選んだもの（墨 10%）
    static let fillStrong = Color(ChatTone.fillStrong)
    /// 区切り線（墨 20%）
    static let fillStronger = Color(ChatTone.fillStronger)
    static let border = fillStrong
    static let accent = Color(ChatTone.accent)
    /// 行内のコードの文字（Claude Desktop のコードの配色の色。画面で測って #8C2929）
    static let inlineCode = Color(ChatTone.inlineCode)
    /// 人の答えを待つ印と地
    static let warning = Color(ChatTone.warning)
    static let warningText = Color(ChatTone.warningText)
    static let danger = Color(ChatTone.danger)
    static let dangerText = Color(ChatTone.dangerText)
    /// 生成中の印（Claude のブランドの色）
    static let generating = Color(ChatTone.generating)
}

/// チャットの色の値。ライトとダークの 16 進の RGB と、重ねる濃さ
struct ChatTone: Sendable {
    let light: UInt32
    let dark: UInt32
    var opacity: Double = 1

    static let surface = ChatTone(light: 0xFCFCFB, dark: 0x151515)
    static let raised = ChatTone(light: 0xFFFFFF, dark: 0x1A1A19)
    static let text = ChatTone(light: 0x0B0B0B, dark: 0xF0EFEC)
    static let secondaryText = ChatTone(light: 0x52514E, dark: 0xC3C2B7)
    static let mutedText = ChatTone(light: 0x898781, dark: 0x898781)
    static let fill = ink(0.05)
    static let fillStrong = ink(0.10)
    static let fillStronger = ink(0.20)
    static let accent = ChatTone(light: 0x2A78D6, dark: 0x2A78D6)
    static let inlineCode = ChatTone(light: 0x8C2929, dark: 0xEC7E7E)
    static let warning = ChatTone(light: 0xFAB219, dark: 0xFAB219)
    static let warningText = ChatTone(light: 0x734500, dark: 0xDB9300)
    static let danger = ChatTone(light: 0xD03B3B, dark: 0xD03B3B)
    static let dangerText = ChatTone(light: 0x8E2626, dark: 0xEC7E7E)
    static let generating = ChatTone(light: 0xD97757, dark: 0xD97757)

    private static func ink(_ opacity: Double) -> ChatTone {
        ChatTone(light: 0x0B0B0B, dark: 0xFFFFFF, opacity: opacity)
    }
}

extension Color {
    /// ライトとダークで値を替える色（16 進の RGB）
    init(light: UInt32, dark: UInt32) {
        self.init(ChatTone(light: light, dark: dark))
    }

    init(_ tone: ChatTone) {
        #if os(macOS)
        self.init(nsColor: PlatformColor(tone))
        #else
        self.init(uiColor: PlatformColor(tone))
        #endif
    }
}

extension PlatformColor {
    convenience init(_ tone: ChatTone) {
        #if os(macOS)
        self.init(name: nil) { appearance in
            NSColor(rgb: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? tone.dark : tone.light).withAlphaComponent(tone.opacity)
        }
        #else
        self.init { traits in UIColor(rgb: traits.userInterfaceStyle == .dark ? tone.dark : tone.light).withAlphaComponent(tone.opacity) }
        #endif
    }
}

extension ChatPalette {
    /// 会話の一覧の AppKit・UIKit の行が使う、上と同じ色と、システムの色
    enum Platform {
        static let surface = PlatformColor(ChatTone.surface)
        static let raised = PlatformColor(ChatTone.raised)
        static let text = PlatformColor(ChatTone.text)
        static let secondaryText = PlatformColor(ChatTone.secondaryText)
        static let mutedText = PlatformColor(ChatTone.mutedText)
        static let fill = PlatformColor(ChatTone.fill)
        static let fillStrong = PlatformColor(ChatTone.fillStrong)
        static let fillStronger = PlatformColor(ChatTone.fillStronger)
        static let border = fillStrong
        static let accent = PlatformColor(ChatTone.accent)
        static let inlineCode = PlatformColor(ChatTone.inlineCode)
        static let danger = PlatformColor(ChatTone.danger)
        static let dangerText = PlatformColor(ChatTone.dangerText)
        static let generating = PlatformColor(ChatTone.generating)
        #if os(macOS)
        static var label: PlatformColor { .labelColor }
        static var secondaryLabel: PlatformColor { .secondaryLabelColor }
        static var tertiaryLabel: PlatformColor { .tertiaryLabelColor }
        /// システムの強調の色（SwiftUI の `Color.accentColor`）
        static var controlAccent: PlatformColor { .controlAccentColor }
        #else
        static var label: PlatformColor { .label }
        static var secondaryLabel: PlatformColor { .secondaryLabel }
        static var tertiaryLabel: PlatformColor { .tertiaryLabel }
        /// アプリの強調の色（SwiftUI の `Color.accentColor`）
        static var controlAccent: PlatformColor { .tintColor }
        #endif
    }
}

private extension PlatformColor {
    convenience init(rgb: UInt32) {
        let (red, green, blue) = (CGFloat(rgb >> 16 & 0xFF) / 255, CGFloat(rgb >> 8 & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
        #if os(macOS)
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
        self.init(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }
}
