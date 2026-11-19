import SwiftUI
import TaskboardKit

/// セッション状態の見せ方。色は状態にだけ使う。
struct StatusAppearance {
    let label: String
    let color: Color
    let symbol: String

    /// 会話の状態の語・記号・色の表（docs/ui-copy.md の用語表）。サイドバーの状態の組の見出しもこれを使う
    static func of(_ status: SidebarStatus) -> StatusAppearance {
        switch status {
        case .waiting: StatusAppearance(label: String(localized: "応答待ち"), color: .orange, symbol: "exclamationmark.circle.fill")
        case .running: StatusAppearance(label: String(localized: "実行中"), color: .green, symbol: "circle.fill")
        case .starting: StatusAppearance(label: String(localized: "起動中"), color: .secondary, symbol: "circle.dotted")
        case .unread: StatusAppearance(label: String(localized: "未読"), color: .blue, symbol: "circle.fill")
        case .idle: StatusAppearance(label: String(localized: "待機"), color: .secondary, symbol: "circle")
        case .unknown: StatusAppearance(label: String(localized: "不明"), color: .secondary, symbol: "questionmark.circle")
        }
    }

    /// 止まりの異常は応答待ちの色と記号で、語は種類ごと（答える問いが無いので「応答待ち」と出さない）
    static func of(_ conversation: Conversation, now: Date = Date()) -> StatusAppearance {
        let state = ConversationTile.State.of(conversation, unread: false, now: now)
        let appearance = of(SidebarStatus(state))
        guard case .problem(let problem) = state else { return appearance }
        return StatusAppearance(label: problem.label, color: appearance.color, symbol: appearance.symbol)
    }

    /// 動いている裏のタスクがある会話・タスクに添える印。ツールの行の札「バックグラウンド」と同じ記号
    static func backgroundTasks(_ count: Int) -> StatusAppearance {
        StatusAppearance(label: String(localized: "バックグラウンドで実行中（\(count)件）"), color: .secondary, symbol: "arrow.down.right.circle")
    }
}

/// 状態の丸印。一覧の行頭に置く。
struct StatusGlyph: View {
    let appearance: StatusAppearance

    init(appearance: StatusAppearance) {
        self.appearance = appearance
    }

    init(conversation: Conversation) {
        self.init(appearance: .of(conversation))
    }

    var body: some View {
        Image(systemName: appearance.symbol)
            .foregroundStyle(appearance.color)
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 14, height: 14)
            .accessibilityLabel(appearance.label)
    }
}

/// 動いている裏のタスクがあるときだけ、状態の印の隣に添える印。一覧の行は数が多く常に見えているので回さない（回す印はツールの行と下の帯）
struct BackgroundTasksGlyph: View {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    init(conversation: Conversation) {
        self.init(count: conversation.runningBackgroundTasks ?? 0)
    }

    var body: some View {
        if count > 0 {
            let appearance = StatusAppearance.backgroundTasks(count)
            StatusGlyph(appearance: appearance).help(appearance.label)
        }
    }
}

/// diff の色。足した行と消した行にだけ使う（札の +n −m、ファイルの欄の行の地と印）
enum DiffPalette {
    static let added = Color.green
    static let removed = Color.red
    static let addedBackground = Color.green.opacity(0.12)
    static let removedBackground = Color.red.opacity(0.12)
}
