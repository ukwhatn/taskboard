import Foundation

/// タスクにリンクした GitHub の PR・issue の、前と比べるための様子。daemon がリンク（`TaskLink.id`）ごとに DB に持ち、
/// 取り直すたびに `LinkNotice.diff` で比べる。GitHub の本文は持たない（知らせに載せないので）
public enum LinkSnapshot: Codable, Hashable, Sendable {
    case pullRequest(PullRequestSnapshot)
    case issue(IssueSnapshot)

    /// マージかクローズした
    public var isFinished: Bool {
        switch self {
        case .pullRequest(let pr): pr.state != .open
        case .issue(let issue): issue.state.uppercased() != "OPEN"
        }
    }

    /// 今回取らなかった・分からなかった値を前の様子から持ち越す（mergeable の UNKNOWN、取らなかった行のコメント）
    public func merged(over previous: LinkSnapshot?) -> LinkSnapshot {
        guard case .pullRequest(var current) = self, case .pullRequest(let old) = previous else { return self }
        if current.mergeable == nil { current.mergeable = old.mergeable }
        if let fetched = current.inlineComments {
            var byID: [String: PullRequestSnapshot.Comment] = [:]
            for comment in (old.inlineComments ?? []) + fetched { byID[comment.id] = comment }
            current.inlineComments = Array(
                byID.values.sorted { (Int64($0.id) ?? 0) > (Int64($1.id) ?? 0) }.prefix(PullRequestSnapshot.inlineCommentLimit).reversed())
        } else {
            current.inlineComments = old.inlineComments
        }
        return .pullRequest(current)
    }
}

public struct PullRequestSnapshot: Codable, Hashable, Sendable {
    /// GitHub の `mergeable`。UNKNOWN（GitHub がまだ計算していない）は nil にし、前の値を持ち越す
    public enum Mergeable: String, Codable, Hashable, Sendable {
        case mergeable = "MERGEABLE"
        case conflicting = "CONFLICTING"
    }

    public struct Review: Codable, Hashable, Sendable {
        public var id: String
        public var author: String
        /// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING
        public var state: String
        /// 本文が空の COMMENTED は、行のコメント（`inlineComments` で別に知らせる）の入れ物
        public var hasBody: Bool

        public init(id: String, author: String, state: String, hasBody: Bool) {
            self.id = id
            self.author = author
            self.state = state
            self.hasBody = hasBody
        }
    }

    public struct Comment: Codable, Hashable, Sendable {
        /// 会話のコメントは GraphQL の node ID、行のコメントは REST の数の ID
        public var id: String
        public var author: String
        public var url: String?
        /// 行のコメントの返信先
        public var replyTo: String?

        public init(id: String, author: String, url: String?, replyTo: String? = nil) {
            self.id = id
            self.author = author
            self.url = url
            self.replyTo = replyTo
        }
    }

    public static let inlineCommentLimit = 100

    public var state: PullRequestLinkState.State
    public var isDraft: Bool
    public var headSHA: String?
    public var checks: CheckState?
    /// 落ちたチェックの名前（同じチェックは最新の run だけ）
    public var failedChecks: [String]
    public var mergeable: Mergeable?
    public var mergedBy: String?
    /// マージした PR の merge commit（タグに入ったかを比べる元）
    public var mergeCommit: String?
    public var reviews: [Review]
    public var comments: [Comment]
    /// 行に付くレビューコメント（新しい 100 件まで）。nil は取っていない（open でない PR）
    public var inlineComments: [Comment]?

    public init(
        state: PullRequestLinkState.State, isDraft: Bool = false, headSHA: String? = nil, checks: CheckState? = nil, failedChecks: [String] = [],
        mergeable: Mergeable? = nil, mergedBy: String? = nil, mergeCommit: String? = nil, reviews: [Review] = [], comments: [Comment] = [],
        inlineComments: [Comment]? = nil
    ) {
        self.state = state
        self.isDraft = isDraft
        self.headSHA = headSHA
        self.checks = checks
        self.failedChecks = failedChecks
        self.mergeable = mergeable
        self.mergedBy = mergedBy
        self.mergeCommit = mergeCommit
        self.reviews = reviews
        self.comments = comments
        self.inlineComments = inlineComments
    }
}

public struct IssueSnapshot: Codable, Hashable, Sendable {
    /// OPEN / CLOSED
    public var state: String
    /// COMPLETED / NOT_PLANNED / DUPLICATE / REOPENED。gh は無いとき空文字を返す
    public var stateReason: String?
    public var comments: [PullRequestSnapshot.Comment]

    public init(state: String, stateReason: String? = nil, comments: [PullRequestSnapshot.Comment] = []) {
        self.state = state
        self.stateReason = stateReason
        self.comments = comments
    }
}

/// リンクの動き 1 つ。セッションに知らせる。外の人が書いた本文は載せず、種類・作者・URL・id と、落ちたチェックの名前（1 行・80 字）だけを持つ
public struct LinkNotice: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case merged
        case closed
        case reopened
        case ready
        case draft
        case commits
        case checksPassed = "checks_passed"
        case checksFailed = "checks_failed"
        case approved
        case changesRequested = "changes_requested"
        /// 本文のあるコメントのレビュー
        case reviewed
        case comment
        case inlineComment = "inline_comment"
        case inlineReply = "inline_reply"
        case conflict
        case conflictResolved = "conflict_resolved"
        /// repo に新しく出た issue・PR（repo の見張りだけ）
        case opened
        /// マージした PR が、名前が型に合うタグに入った（PR の見張りで選んだときだけ）
        case tagged
        /// Devin のセッション（`DevinSync`）。返答を待ち始めた・PR を出した（`targetURL`）・終わった・期限が切れた
        case devinWaiting = "devin_waiting"
        case devinPullRequest = "devin_pull_request"
        case devinFinished = "devin_finished"
        case devinExpired = "devin_expired"

        /// Devin のセッションの動き（PR・issue の見張りでは選べない）
        public var isDevin: Bool { [.devinWaiting, .devinPullRequest, .devinFinished, .devinExpired].contains(self) }
    }

    public var kind: Kind
    /// リンクの URL（`TaskLink.url`）
    public var url: String
    /// GitHub の login（マージした人・レビュー・コメントの作者）
    public var actor: String?
    /// レビュー・コメントの id、CI と新しいコミットは head の SHA
    public var target: String?
    /// 落ちたチェックの名前、issue を閉じた理由
    public var detail: String?
    /// コメントそのものの URL
    public var targetURL: String?

    public init(kind: Kind, url: String, actor: String? = nil, target: String? = nil, detail: String? = nil, targetURL: String? = nil) {
        self.kind = kind
        self.url = url
        self.actor = actor
        self.target = target
        self.detail = detail
        self.targetURL = targetURL
    }

    public static let detailLimit = 80

    /// 止まったセッションを起こしてでも届けるもの。CI が通った・新しいコミット・ready・draft・開き直し・conflict が消えた、は次に動いたときに渡す
    public var needsAction: Bool {
        switch kind {
        case .checksFailed, .approved, .changesRequested, .reviewed, .comment, .inlineComment, .inlineReply, .conflict, .merged, .closed, .opened, .tagged,
            .devinWaiting, .devinPullRequest, .devinFinished, .devinExpired:
            true
        case .checksPassed, .commits, .ready, .draft, .reopened, .conflictResolved: false
        }
    }

    /// 状態の移り（新しい方だけを残す）の組。レビューとコメントは 1 つずつが出来事なので nil
    var stateGroup: String? {
        switch kind {
        case .merged, .closed, .reopened: "state"
        case .ready, .draft: "draft"
        case .commits: "head"
        case .checksPassed, .checksFailed: "checks"
        case .conflict, .conflictResolved: "conflict"
        case .devinFinished, .devinExpired: "devin"
        case .approved, .changesRequested, .reviewed, .comment, .inlineComment, .inlineReply, .opened, .tagged, .devinWaiting, .devinPullRequest: nil
        }
    }

    /// repo に新しく出た issue・PR。題と本文は載せず、作者と label の名前（1 行・80 字）だけ
    public static func opened(url: String, author: String?, labels: [String]) -> LinkNotice {
        LinkNotice(kind: .opened, url: url, actor: author, detail: labels.isEmpty ? nil : oneLine(labels.map(oneLine).joined(separator: ", ")))
    }

    /// PR が入ったタグ。`targetURL` はタグのリリースの画面（リリースの無いタグでもタグの画面が開く）
    public static func tagged(url: String, tag: String, releaseURL: String?) -> LinkNotice {
        LinkNotice(kind: .tagged, url: url, detail: oneLine(tag), targetURL: releaseURL)
    }

    /// 前の様子と今の様子の差。`viewerLogin`（gh を呼ぶアカウント）のレビューとコメントは除く（大文字小文字を区別しない）。
    /// `new` は `merged(over: old)` を通したもの
    public static func diff(url: String, old: LinkSnapshot, new: LinkSnapshot, viewerLogin: String) -> [LinkNotice] {
        let viewer = viewerLogin.lowercased()
        func others(_ author: String) -> Bool { author.lowercased() != viewer }
        switch (old, new) {
        case (.pullRequest(let old), .pullRequest(let new)):
            return pullRequestDiff(url: url, old: old, new: new, others: others)
        case (.issue(let old), .issue(let new)):
            var notices: [LinkNotice] = []
            if old.state != new.state {
                if new.state == "CLOSED" {
                    notices.append(LinkNotice(kind: .closed, url: url, detail: new.stateReason.flatMap { $0.isEmpty ? nil : oneLine($0) }))
                } else if new.state == "OPEN" {
                    notices.append(LinkNotice(kind: .reopened, url: url))
                }
            }
            notices += newComments(url: url, old: old.comments, new: new.comments, others: others)
            return notices
        default:
            return []
        }
    }

    private static func pullRequestDiff(url: String, old: PullRequestSnapshot, new: PullRequestSnapshot, others: (String) -> Bool) -> [LinkNotice] {
        var notices: [LinkNotice] = []
        if old.state != new.state {
            switch new.state {
            case .merged: notices.append(LinkNotice(kind: .merged, url: url, actor: new.mergedBy))
            case .closed: notices.append(LinkNotice(kind: .closed, url: url))
            case .open: notices.append(LinkNotice(kind: .reopened, url: url))
            }
        }
        if old.isDraft != new.isDraft, new.state == .open {
            notices.append(LinkNotice(kind: new.isDraft ? .draft : .ready, url: url))
        }
        let headChanged = old.headSHA != nil && new.headSHA != nil && old.headSHA != new.headSHA
        if headChanged { notices.append(LinkNotice(kind: .commits, url: url, target: new.headSHA)) }
        if let checks = new.checks, !checks.isRunning, headChanged || checks != old.checks {
            notices.append(
                checks.isFailing
                    ? LinkNotice(kind: .checksFailed, url: url, target: new.headSHA, detail: oneLine(new.failedChecks.map(oneLine).joined(separator: ", ")))
                    : LinkNotice(kind: .checksPassed, url: url, target: new.headSHA))
        }
        if new.state == .open, let mergeable = new.mergeable, let before = old.mergeable, mergeable != before {
            notices.append(LinkNotice(kind: mergeable == .conflicting ? .conflict : .conflictResolved, url: url))
        }
        let seenReviews = Set(old.reviews.map(\.id))
        for review in new.reviews where !seenReviews.contains(review.id) && others(review.author) {
            let kind: Kind? =
                switch PRReviewState(github: review.state) {
                case .approved: .approved
                case .changesRequested: .changesRequested
                case .commented where review.hasBody: .reviewed
                default: nil
                }
            if let kind { notices.append(LinkNotice(kind: kind, url: url, actor: review.author, target: review.id)) }
        }
        notices += newComments(url: url, old: old.comments, new: new.comments, others: others)
        if let before = old.inlineComments, let after = new.inlineComments {
            let seen = Set(before.map(\.id))
            // 編集されたコメントは前より古い id で戻ってくる
            let newest = before.compactMap { Int64($0.id) }.max() ?? 0
            for comment in after where !seen.contains(comment.id) && (Int64(comment.id) ?? 0) > newest && others(comment.author) {
                notices.append(
                    LinkNotice(
                        kind: comment.replyTo == nil ? .inlineComment : .inlineReply, url: url, actor: comment.author, target: comment.id,
                        targetURL: comment.url))
            }
        }
        return notices
    }

    private static func newComments(
        url: String, old: [PullRequestSnapshot.Comment], new: [PullRequestSnapshot.Comment], others: (String) -> Bool
    ) -> [LinkNotice] {
        let seen = Set(old.map(\.id))
        return new.filter { !seen.contains($0.id) && others($0.author) }.map {
            LinkNotice(kind: .comment, url: url, actor: $0.author, target: $0.id, targetURL: $0.url)
        }
    }

    /// 記録した知らせ（リンクの知らせ・見張りの出来事）を 1 通にまとめる前に、同じ URL の同じ組の状態の移りを新しい方だけにする。並びは古い順のまま
    public static func collapsed<Record>(_ records: [Record], notice: (Record) -> LinkNotice, id: (Record) -> Int64) -> [Record] {
        var latest: [String: Int64] = [:]
        for record in records {
            if let group = notice(record).stateGroup { latest[notice(record).url + "|" + group] = id(record) }
        }
        return records.filter { record in
            guard let group = notice(record).stateGroup else { return true }
            return latest[notice(record).url + "|" + group] == id(record)
        }
    }

    /// 改行と制御文字を空白にして 80 字で切る（チェックの名前は repo に書ける人が付ける）
    static func oneLine(_ text: String) -> String {
        let flattened = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        return String(flattened.trimmingCharacters(in: .whitespaces).prefix(detailLimit))
    }
}

/// 記録したリンクの知らせ（`taskLinkNotice` 表の 1 行）
public struct TaskLinkNotice: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64
    public var taskNumber: Int
    public var notice: LinkNotice
    public var createdAt: Date
    public var deliveredAt: Date?

    public init(id: Int64, taskNumber: Int, notice: LinkNotice, createdAt: Date, deliveredAt: Date? = nil) {
        self.id = id
        self.taskNumber = taskNumber
        self.notice = notice
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
    }

    /// 1 通にまとめる前に、同じリンクの同じ組の状態の移りを新しい方だけにする（draft の往復など）。並びは古い順のまま
    public static func collapsed(_ records: [TaskLinkNotice]) -> [TaskLinkNotice] {
        LinkNotice.collapsed(records, notice: \.notice, id: \.id)
    }
}

/// `GET /v1/tasks/{n}/link-notices`：届けていない数と、新しい 20 件（届けたものも含む）
public struct LinkNoticeList: Codable, Hashable, Sendable {
    public var undelivered: Int
    public var notices: [TaskLinkNotice]

    public init(undelivered: Int, notices: [TaskLinkNotice]) {
        self.undelivered = undelivered
        self.notices = notices
    }
}
