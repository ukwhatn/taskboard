import Foundation

/// 受信箱で消した項目の記録（対応待ちの「無視」とお知らせの「既読にする」）。項目のマシンの daemon が持ち、全部の端末に配る。
/// 記録した `revision` と項目の今の `revision` が同じ間だけ隠す。項目が変わったら（もう一度応答待ちになった・PR が更新された）また出る
public struct InboxDismissal: Codable, Hashable, Sendable {
    /// 項目のマシンの中の id（`InboxItem.localID`）
    public var itemID: String
    public var revision: String
    public var dismissedAt: Date

    public init(itemID: String, revision: String, dismissedAt: Date) {
        self.itemID = itemID
        self.revision = revision
        self.dismissedAt = dismissedAt
    }

    public static let itemIDLimit = 1024
    public static let revisionLimit = 256
    /// 1 回の要求で送れる数（「すべて既読にする」）
    public static let batchLimit = 500

    /// 項目を、そのマシンの daemon に 1 回で送る組に分ける（記録は項目のマシンにだけ置く）。1 組は `batchLimit` 件まで。無視・既読と戻すの両方で使う
    public static func batches(_ items: [InboxItem]) -> [MachineID: [[InboxItem]]] {
        Dictionary(grouping: items, by: \.machine).mapValues { items in
            stride(from: 0, to: items.count, by: batchLimit).map { start in Array(items[start..<min(start + batchLimit, items.count)]) }
        }
    }
}

/// `POST /v1/inbox/dismiss`。同じ項目は revision を置き換える。応答は記録の全部
public struct InboxDismissRequest: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        public var itemID: String
        public var revision: String

        public init(itemID: String, revision: String) {
            self.itemID = itemID
            self.revision = revision
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}

/// `POST /v1/inbox/restore`。記録を消して項目を戻す。無い項目は無視する。応答は記録の全部
public struct InboxRestoreRequest: Codable, Hashable, Sendable {
    public var itemIDs: [String]

    public init(itemIDs: [String]) {
        self.itemIDs = itemIDs
    }
}

extension InboxItem {
    /// 「変わったらまた出る」を決める値。項目の id は同じまま中身が変わるものだけ値を持つ。
    /// お知らせは版・回・時刻が id に入っているので空（新しい版は別の項目になる）
    public var revision: String {
        switch kind {
        // 新しい質問の束は別の askID（別の項目）になる。会話の問いも問いの id が項目の id に入る
        case .question, .conversationRequest: ""
        case .reviewRequest(let request): Self.stamp(request.requestedAt)
        // 頼む文が変われば別の依頼として出し直す
        case .manualWork(let item): item.blockerText
        case .pullRequestTurn(let pr, let reason): "\(reason.rawValue)@\(Self.stamp(pr.updatedAt))"
        // 失敗が続く間は同じ文。別の理由で落ちたらまた出す
        case .prSync(let account): account.failureMessage ?? ""
        // 動けば消え、また止まれば別の起点で出直す
        case .stalled(_, let stall): Self.stamp(stall.since)
        case .document, .pullRequest, .scheduleRun, .orchestratorReply: ""
        // 会話が本文を書き直したら、非表示にしていても出直す
        case .panelDraft(_, let part): Self.stamp(part.updatedAt)
        case .docDraft(_, let draft): Self.stamp(draft.updatedAt)
        }
    }

    /// 秒で切る。JSON（ISO 8601）を通った時刻は秒より細かい桁を持たないので、端末と daemon で同じ値になる
    static func stamp(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970.rounded(.down)))
    }

    public var dismissRequestItem: InboxDismissRequest.Item {
        InboxDismissRequest.Item(itemID: localID, revision: revision)
    }
}

/// 受信箱の中身。`items` が出す項目、`dismissed` が無視・既読にした項目（「無視した項目を表示」で出す）。どちらも受信箱の並び
public struct InboxContents: Hashable, Sendable {
    public var items: [InboxItem]
    public var dismissed: [InboxItem]

    public init(items: [InboxItem] = [], dismissed: [InboxItem] = []) {
        self.items = items
        self.dismissed = dismissed
    }

    /// 項目ごとに消したかを決めて分ける。`isDismissed` は項目のマシンの記録を引く
    public static func split(_ items: [InboxItem], isDismissed: (InboxItem) -> Bool) -> InboxContents {
        var contents = InboxContents()
        for item in items.sorted(by: InboxItem.inboxOrder) {
            if isDismissed(item) { contents.dismissed.append(item) } else { contents.items.append(item) }
        }
        return contents
    }
}

extension MachineState {
    /// この記録で隠す項目か
    public func isDismissed(_ item: InboxItem) -> Bool {
        guard let record = inboxDismissals[item.localID] else { return false }
        return record.revision == item.revision
    }

    /// 消した記録を効かせた受信箱。`inboxItems` は記録を見ない（daemon の APNs が差分を取るのに使う）
    public func inbox(now: Date = Date(), noticeWindow: TimeInterval = 24 * 3600) -> InboxContents {
        InboxContents.split(inboxItems(now: now, noticeWindow: noticeWindow), isDismissed: isDismissed)
    }
}
