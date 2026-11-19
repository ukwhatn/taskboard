import Foundation

/// カードの待ち理由を決める材料。アプリが Fleet から集めて渡す。
public struct CardSignals: Hashable, Sendable {
    public var workItems: [WorkItem]
    /// このタスクのリンクの状態（取れたものだけ）
    public var links: [LinkStatus]
    /// このタスクの PR のどれかで、自分がレビューを頼まれている
    public var reviewRequested: Bool
    /// このタスクの PR のどれかに、自分がレビューを出した（頼まれ直していれば `reviewRequested` が先に立つ）
    public var reviewed: Bool
    /// 完了・見送りの列にある
    public var terminal: Bool
    /// タスクに結ばれた host の会話（止まっているものも）
    public var conversations: [Conversation]

    public init(
        workItems: [WorkItem] = [], links: [LinkStatus] = [], reviewRequested: Bool = false, reviewed: Bool = false,
        terminal: Bool = false, conversations: [Conversation] = []
    ) {
        self.conversations = conversations
        self.workItems = workItems
        self.links = links
        self.reviewRequested = reviewRequested
        self.reviewed = reviewed
        self.terminal = terminal
    }
}

extension BoardTask {
    /// カードの 1 行。出どころごとに候補を出し、自分の番 → 相手待ち → 情報の順で 1 つ選ぶ。
    /// 同じ重みなら、レビュー依頼 → 作業項目 → PR → 期日の順。会話の問いは受信箱の帯が出す。動いていない日数はカードの別の札（`BoardTask.stall`）
    public func waitLine(_ signals: CardSignals, today: Date = Date(), calendar: Calendar = .current) -> WaitLine? {
        guard !signals.terminal else { return nil }
        var candidates: [WaitLine] = []
        if signals.reviewRequested {
            candidates.append(WaitLine(text: String(localized: "レビュー依頼あり"), tone: .mine))
        } else if signals.reviewed {
            // 自分の分は済んで、相手のマージかクローズを待っている（済めば daemon が完了へ移す）
            candidates.append(WaitLine(text: String(localized: "レビュー済み"), tone: .theirs))
        }
        if let wait = TaskProgress.derive(signals.workItems)?.primaryWait {
            candidates.append(wait)
        }
        candidates += signals.links.compactMap(\.pullRequest).compactMap(Self.pullRequestWait)
        if let due = dueWait(today: today, calendar: calendar) {
            candidates.append(due)
        }
        // min は同じ重みなら先に来た方を返す
        return candidates.min { $0.tone.rank < $1.tone.rank }
    }

    private func dueWait(today: Date, calendar: Calendar) -> WaitLine? {
        guard let due, let dueDate = Self.dateFormatter.date(from: due) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: dueDate)).day ?? 0
        switch days {
        case ..<0: return WaitLine(text: String(localized: "期日超過\(-days)日"), tone: .mine)
        case 0: return WaitLine(text: String(localized: "期日は今日"), tone: .mine)
        case 1: return WaitLine(text: String(localized: "期日は明日"), tone: .theirs)
        default: return WaitLine(text: String(localized: "期日まで\(days)日"), tone: .quiet)
        }
    }

    /// 開いていて draft でない PR だけを見る。マージ・クローズ済みは列が語る
    static func pullRequestWait(_ pr: PullRequestLinkState) -> WaitLine? {
        guard pr.state == .open, !pr.isDraft else { return nil }
        if pr.checks?.isFailing == true { return WaitLine(text: String(localized: "CI失敗"), tone: .mine) }
        if pr.decision == .changesRequested { return WaitLine(text: String(localized: "修正依頼あり"), tone: .mine) }
        if pr.checks?.isRunning == true { return WaitLine(text: String(localized: "CI実行中"), tone: .quiet) }
        switch pr.decision {
        case .approved: return WaitLine(text: String(localized: "承認済み・マージ待ち"), tone: .mine)
        case .reviewRequired: return WaitLine(text: String(localized: "レビュー待ち"), tone: .theirs)
        default: return nil
        }
    }
}

extension WaitLine.Tone {
    var rank: Int {
        switch self {
        case .mine: 0
        case .theirs: 1
        case .quiet: 2
        }
    }
}
