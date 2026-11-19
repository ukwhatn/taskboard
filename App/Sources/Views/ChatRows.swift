import SwiftUI
import TaskboardKit

/// 畳む行の見出しの文
enum ChatRowTitle {
    /// 続いたツールの呼び出しと差し込んだ文の組
    static func toolRun(calls: Int, injected: Int) -> String {
        if calls == 0 { return String(localized: "Claude Codeが追加したメッセージ（\(injected)件）") }
        if injected == 0 { return String(localized: "ツールを\(calls)回実行") }
        return String(localized: "ツールを\(calls)回実行、追加したメッセージ\(injected)件")
    }

    static func subagent(count: Int) -> String { String(localized: "サブエージェントの作業（\(count)件）") }

    static var injected: String { String(localized: "Claude Codeが追加したメッセージ") }
}

/// ツールの呼び出しの様子の見せ方
struct ToolStatusAppearance {
    enum Tone { case generating, muted, danger }

    /// nil は回る印
    let symbol: String?
    let tone: Tone
    /// 印の読み上げ
    let label: String
    /// ツールの行の見出しの札（裏のタスクだけ）
    let tag: String?

    init(_ status: ChatToolStatus) {
        switch status {
        case .running: (symbol, tone, label, tag) = ("circle.dotted", .generating, String(localized: "実行中"), nil)
        case .completed: (symbol, tone, label, tag) = ("checkmark.circle", .muted, String(localized: "完了"), nil)
        case .failed: (symbol, tone, label, tag) = ("xmark.circle.fill", .danger, String(localized: "失敗"), nil)
        case .background(let state):
            switch state {
            case .running: (symbol, tone, label) = (nil, .generating, String(localized: "バックグラウンドで実行中"))
            case .completed: (symbol, tone, label) = ("checkmark.circle", .muted, String(localized: "バックグラウンドで完了"))
            case .failed: (symbol, tone, label) = ("xmark.circle.fill", .danger, String(localized: "バックグラウンドで失敗"))
            case .stopped: (symbol, tone, label) = ("stop.circle", .muted, String(localized: "バックグラウンドで停止"))
            case .ended: (symbol, tone, label) = ("stop.circle", .muted, String(localized: "バックグラウンドで終了"))
            case nil: (symbol, tone, label) = ("arrow.down.right.circle", .muted, String(localized: "バックグラウンドで実行"))
            }
            tag = state == nil ? String(localized: "バックグラウンド") : label
        }
    }

    /// 会話の一覧の AppKit・UIKit の行の色
    var platformColor: PlatformColor {
        switch tone {
        case .generating: ChatPalette.Platform.generating
        case .muted: ChatPalette.Platform.mutedText
        case .danger: ChatPalette.Platform.danger
        }
    }
}

extension TaskboardNotice {
    /// 知らせの行の頭の印
    var symbol: String {
        switch self {
        case .delegate: "person.2"
        case .link: "link"
        case .review: "text.bubble"
        case .limitResume: "arrow.clockwise"
        case .networkResume: "wifi"
        case .wake: "alarm"
        case .watch: "eye"
        case .answer: "checkmark.bubble"
        case .finished: "hand.thumbsup"
        case .draft: "paperplane"
        case .sessionPrompt: "arrow.left.arrow.right"
        case .slack: "number"
        }
    }
}

/// チャットの文字。設定の pt（`AppPreferences.chatFontSizeKey`）を基準に、注記やツールの行を比で小さくする。
/// 行の高さは Claude Desktop と同じ 1.43 倍（14pt で 20pt）、コードは 2pt 小さくして 1.42 倍（12pt で 17pt）
struct ChatFonts {
    let size: Double

    var body: Font { .system(size: size) }
    var subheadline: Font { .system(size: size * 0.92) }
    var caption: Font { .system(size: size * 0.85) }
    var caption2: Font { .system(size: size * 0.77) }
    var code: Font { .system(size: size - 2, design: .monospaced) }
    /// 畳める行の開閉の印（`ChatRowChevron`・`ChatChevron`）
    var chevron: CGFloat { size * 0.72 }
    var line: CGFloat { (size * 1.43).rounded() }
    var codeLine: CGFloat { ((size - 2) * 1.42).rounded() }
    /// 発言どうし（ターンの切れ目）と、続く行どうしの間（本文の行の高さの 0.75 倍と 0.5 倍）
    var turnGap: CGFloat { (line * 0.75).rounded() }
    var itemGap: CGFloat { (line * 0.5).rounded() }
}
