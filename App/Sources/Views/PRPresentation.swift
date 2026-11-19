import SwiftUI
import TaskboardKit

// PR の一覧・詳細・リンクのチップ・会話の差分で、PR の状態と CI とレビューと変更の種類を同じ語・記号・色で出す表（docs/ui-copy.md の用語表）

extension CheckState {
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure, .error: "xmark.circle.fill"
        case .pending, .expected: "circle.dotted"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .failure, .error: .red
        case .pending, .expected: .orange
        }
    }

    var label: String {
        switch self {
        case .success: String(localized: "CI成功")
        case .failure, .error: String(localized: "CI失敗")
        case .pending, .expected: String(localized: "CI実行中")
        }
    }
}

extension CheckRunState {
    /// 結果を数えないもの（取り消し・スキップなど）は横棒の印
    var symbol: String { rollup?.symbol ?? "minus.circle" }
    var color: Color { rollup?.color ?? .secondary }

    var label: String {
        switch self {
        case .success: String(localized: "成功")
        case .failure: String(localized: "失敗")
        case .timedOut: String(localized: "時間切れ")
        case .startupFailure: String(localized: "開始失敗")
        case .actionRequired: String(localized: "対応待ち")
        case .cancelled: String(localized: "キャンセル済み")
        case .skipped: String(localized: "スキップ")
        case .neutral: String(localized: "中立")
        case .stale: String(localized: "古い結果")
        case .queued: String(localized: "実行待ち")
        case .running: String(localized: "実行中")
        }
    }
}

extension PRReviewState {
    var label: String {
        switch self {
        case .approved: String(localized: "承認済み")
        case .changesRequested: String(localized: "修正依頼")
        case .reviewRequired: String(localized: "レビュー待ち")
        case .commented: String(localized: "コメント")
        case .dismissed: String(localized: "取り下げ")
        case .pending, .other: String(localized: "レビュー中")
        }
    }

    var color: Color {
        switch self {
        case .approved: .green
        case .changesRequested: .red
        case .reviewRequired, .commented, .dismissed, .pending, .other: .secondary
        }
    }

    /// リンクのチップに添える印。承認と修正依頼のときだけ
    var symbol: String? {
        switch self {
        case .approved: "person.fill.checkmark"
        case .changesRequested: "exclamationmark.bubble.fill"
        case .reviewRequired, .commented, .dismissed, .pending, .other: nil
        }
    }
}

extension PullRequestLinkState.State {
    /// GitHub の `state`（PR の詳細は生の文字列で持つ）。知らない値は開いている扱い
    init(github: String) { self = Self(rawValue: github) ?? .open }

    var label: String {
        switch self {
        case .open: "Open"
        case .merged: String(localized: "マージ済み")
        case .closed: String(localized: "クローズ済み")
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .open: .green
        case .merged: .purple
        case .closed: .red
        }
    }

    static let draftLabel = "Draft"

    /// 状態の語と色。Draft と出すのは開いている PR だけ
    static func badge(_ state: Self, isDraft: Bool) -> (String, Color) {
        state == .open && isDraft ? (draftLabel, .secondary) : (state.label, state.color)
    }
}

extension FileChangeKind {
    var mark: String {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .modified: "M"
        }
    }

    var name: String {
        switch self {
        case .added: String(localized: "追加")
        case .deleted: String(localized: "削除")
        case .renamed: String(localized: "名前変更")
        case .modified: String(localized: "変更")
        }
    }
}
