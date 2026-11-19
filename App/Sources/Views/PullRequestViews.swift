import SwiftUI
import TaskboardKit

extension PRCategory {
    var label: String {
        switch self {
        case .reviewRequested: String(localized: "レビュー依頼・未レビュー")
        case .reviewed: String(localized: "レビュー済み・未マージ")
        case .myDraft: String(localized: "自分のDraft")
        case .myReady: String(localized: "自分のReady")
        }
    }
}

/// CI の印。チェックが無い PR は出さない
struct CheckBadge: View {
    let state: CheckState?

    var body: some View {
        if let state {
            Image(systemName: state.symbol)
                .foregroundStyle(state.color)
                .accessibilityLabel(state.label)
                .help(state.label)
        }
    }
}

/// レビュー判定の短い印
struct ReviewBadge: View {
    let decision: PRReviewState?
    let reviews: [PRReviewState]

    var body: some View {
        if let (text, color) = Self.describe(decision: decision, reviews: reviews) {
            Text(text).lineLimit(1).chipStyle(tint: color)
        }
    }

    /// 判定が無い repo（保護ルールが無い）は、最新のレビューに承認か修正依頼があればそれを、無ければコメントの件数を出す
    static func describe(decision: PRReviewState?, reviews: [PRReviewState]) -> (String, Color)? {
        if let decision, decision != .other { return (decision.label, decision.color) }
        for state: PRReviewState in [.approved, .changesRequested] where reviews.contains(state) { return (state.label, state.color) }
        if !reviews.isEmpty { return (String(localized: "コメント\(reviews.count)件"), .secondary) }
        return nil
    }
}

/// 一覧の 1 行。1 行目に repo と番号・時刻、題、印（CI・レビュー・Draft・作者・増減）。区切り線は本文の列に置き、本文の左端に揃う
struct PRRow: View {
    @Environment(\.pageInset) private var inset
    let pr: PullRequestSummary
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Space.block) {
                Image(systemName: PullRequestLinkState.State.open.symbol)
                    .foregroundStyle(pr.isDraft ? Color.secondary : PullRequestLinkState.State.open.color)
                    .frame(width: ListRowMetrics.icon)
                    .padding(.top, Space.row)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    content.padding(.vertical, Space.row).padding(.trailing, inset)
                    Divider()
                }
            }
            .padding(.leading, inset)
            .background(selected ? Color.accentColor.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                Text(verbatim: pr.shortLabel).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.row)
                RelativeTime(date: pr.updatedAt).font(.caption).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
            }
            Text(pr.title).font(.callout.weight(.medium)).lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            FlowRow(spacing: Space.row, lineSpacing: 2) {
                CheckBadge(state: pr.checks)
                ReviewBadge(decision: pr.decision, reviews: pr.latestReviews.map(\.reviewState))
                if pr.isDraft { Text(verbatim: "Draft").font(.caption).foregroundStyle(.secondary) }
                Text(verbatim: pr.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(verbatim: "+\(pr.additions.formatted()) −\(pr.deletions.formatted())").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .accessibilityLabel(String(localized: "\(pr.additions)行追加、\(pr.deletions)行削除"))
            }
        }
    }
}
