import Foundation

/// 一覧の 4 区分。1 つの PR は 1 区分にだけ入る（レビュー依頼が再度来たものは「未レビュー」を優先）。
public enum PRCategory: String, Codable, CaseIterable, Hashable, Sendable {
    /// レビューを頼まれていて、まだ返していない
    case reviewRequested
    /// 自分がレビューした、まだマージされていない他人の PR
    case reviewed
    case myDraft
    case myReady
}

/// `statusCheckRollup.state`。チェックが無い PR は nil。
public enum CheckState: String, Codable, Hashable, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"

    public var isFailing: Bool { self == .failure || self == .error }
    public var isRunning: Bool { self == .pending || self == .expected }
}

public struct PRReviewer: Codable, Hashable, Sendable {
    public var login: String
    /// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING
    public var state: String

    public init(login: String, state: String) {
        self.login = login
        self.state = state
    }
}

/// 一覧の 1 行。daemon が gh の GraphQL search から作る。
public struct PullRequestSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String { url }

    public var machine: MachineID
    public var host: String
    /// 取ったアカウント（gh の login）
    public var account: String
    public var category: PRCategory
    public var url: String
    public var repository: String
    public var number: Int
    public var title: String
    public var author: String
    /// 作者が bot（Dependabot・Renovate などの GitHub App）か。この項目が無い daemon の分は nil で、人として扱う
    public var authorIsBot: Bool?
    public var isDraft: Bool
    public var headRef: String
    public var createdAt: Date
    public var updatedAt: Date
    /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED。保護ルールが無い repo では nil
    public var reviewDecision: String?
    public var checks: CheckState?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var latestReviews: [PRReviewer]
    public var requestedReviewers: [String]

    public init(
        machine: MachineID, host: String, account: String, category: PRCategory, url: String, repository: String, number: Int, title: String,
        author: String, isDraft: Bool, headRef: String, createdAt: Date, updatedAt: Date, reviewDecision: String? = nil, checks: CheckState? = nil,
        additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0, latestReviews: [PRReviewer] = [], requestedReviewers: [String] = [],
        authorIsBot: Bool? = nil
    ) {
        self.machine = machine
        self.host = host
        self.account = account
        self.category = category
        self.url = url
        self.repository = repository
        self.number = number
        self.title = title
        self.author = author
        self.authorIsBot = authorIsBot
        self.isDraft = isDraft
        self.headRef = headRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.latestReviews = latestReviews
        self.requestedReviewers = requestedReviewers
    }

    /// `owner/repo#123`
    public var shortLabel: String { "\(repository)#\(number)" }

    /// 自分が何かしないと進まない理由。レビューを頼まれている、自分の PR の CI が落ちている、自分の PR に修正を頼まれている。
    /// 両方当たる自分の PR は修正依頼を先に出す（直すと CI も回り直す）
    public var turn: PRNotice.Kind? {
        switch category {
        case .reviewRequested: return isDraft ? nil : .reviewRequested
        case .reviewed: return nil
        case .myDraft, .myReady:
            if decision == .changesRequested { return .changesRequested }
            if checks?.isFailing == true { return .ciFailed }
            return nil
        }
    }
}

/// アカウントごとの取得の状態。
public struct PRAccountStatus: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(host)|\(account)" }

    public var host: String
    public var account: String
    public var fetchedAt: Date?
    /// 最後の取得が失敗したときの理由（token は含まない）
    public var error: String?
    public var rateLimited: Bool
    public var nextFetchAt: Date?

    public init(host: String, account: String, fetchedAt: Date? = nil, error: String? = nil, rateLimited: Bool = false, nextFetchAt: Date? = nil) {
        self.host = host
        self.account = account
        self.fetchedAt = fetchedAt
        self.error = error
        self.rateLimited = rateLimited
        self.nextFetchAt = nextFetchAt
    }
}

/// CI・レビューの変化。受信箱の「お知らせ」に出る。
public struct PRNotice: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case ciFailed, ciPassed, approved, changesRequested, newReview, reviewRequested
    }

    /// 「今要るもの」に PR の今の状態で出す種類。お知らせには出さない
    public static let turnKinds: Set<Kind> = [.ciFailed, .changesRequested, .reviewRequested]

    /// `<url>#<kind>#<時刻>`
    public var id: String
    public var machine: MachineID
    public var url: String
    public var label: String
    public var title: String
    public var kind: Kind
    /// レビューした人など
    public var detail: String
    public var at: Date

    public init(machine: MachineID, url: String, label: String, title: String, kind: Kind, detail: String = "", at: Date) {
        id = "\(url)#\(kind.rawValue)#\(Int(at.timeIntervalSince1970))"
        self.machine = machine
        self.url = url
        self.label = label
        self.title = title
        self.kind = kind
        self.detail = detail
        self.at = at
    }

    /// 前回と今回の一覧の差から、知らせる変化を出す。前回が無い（起動直後の初回）ときは何も出さない。
    /// - チェック: 失敗に変わった / 失敗・実行中から成功に変わった（自分の PR だけ）
    /// - レビュー判定: approve / changes requested に変わった（自分の PR だけ）。判定の無い repo では、新しいレビューを 1 件ずつ
    /// - 新しくレビューを頼まれた
    public static func diff(old: [PullRequestSummary]?, new: [PullRequestSummary], at now: Date) -> [PRNotice] {
        guard let old else { return [] }
        let before = Dictionary(old.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var notices: [PRNotice] = []
        for pr in new {
            func notice(_ kind: Kind, _ detail: String = "") -> PRNotice {
                PRNotice(machine: pr.machine, url: pr.url, label: pr.shortLabel, title: pr.title, kind: kind, detail: detail, at: now)
            }
            guard let prev = before[pr.url] else {
                if pr.category == .reviewRequested { notices.append(notice(.reviewRequested, pr.author)) }
                continue
            }
            if pr.category == .reviewRequested, prev.category != .reviewRequested {
                notices.append(notice(.reviewRequested, pr.author))
            }
            let mine = pr.category == .myDraft || pr.category == .myReady
            guard mine else { continue }
            if let checks = pr.checks, checks != prev.checks {
                if checks.isFailing, !(prev.checks?.isFailing ?? false) { notices.append(notice(.ciFailed)) }
                if checks == .success, prev.checks != nil { notices.append(notice(.ciPassed)) }
            }
            if pr.reviewDecision != prev.reviewDecision {
                if pr.decision == .approved { notices.append(notice(.approved, reviewers(pr, .approved))) }
                if pr.decision == .changesRequested { notices.append(notice(.changesRequested, reviewers(pr, .changesRequested))) }
            } else if pr.reviewDecision == nil {
                let seen = Set(prev.latestReviews.map { "\($0.login)|\($0.state)" })
                let fresh = pr.latestReviews.filter { !seen.contains("\($0.login)|\($0.state)") && $0.reviewState != .pending }
                if !fresh.isEmpty { notices.append(notice(.newReview, fresh.map(\.login).joined(separator: ", "))) }
            }
        }
        return notices
    }

    private static func reviewers(_ pr: PullRequestSummary, _ state: PRReviewState) -> String {
        pr.latestReviews.filter { $0.reviewState == state }.map(\.login).joined(separator: ", ")
    }
}

extension PRAccountStatus {
    /// 取得の失敗を画面に出す文（事象・原因・対処）。失敗していなければ nil。gh のエラーの文（英語）は出さない。原因が分かるのは利用の上限だけ
    public var failureMessage: String? {
        guard error != nil else { return nil }
        return rateLimited
            ? String(localized: "PRを取得できませんでした。GitHubの利用の上限に達しています。時間をおいて、再読み込みしてください。")
            : String(localized: "PRを取得できませんでした。接続先のMacのghのログインと、ネットワークを確認してください。")
    }
}

/// マシンの PR の今。`prs.updated` で丸ごと配る。
public struct PRSnapshot: Codable, Hashable, Sendable {
    public var accounts: [PRAccountStatus]
    public var pullRequests: [PullRequestSummary]
    /// 24 時間以内の変化（新しい順）
    public var notices: [PRNotice]

    public init(accounts: [PRAccountStatus] = [], pullRequests: [PullRequestSummary] = [], notices: [PRNotice] = []) {
        self.accounts = accounts
        self.pullRequests = pullRequests
        self.notices = notices
    }

    public static let noticeWindow: TimeInterval = 24 * 3600
    public static let noticeLimit = 50
}

/// PR の中身。差分本文は持たない（「GitHub で開く」）。
public struct PullRequestDetail: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var path: String
        public var additions: Int
        public var deletions: Int
        /// ADDED / MODIFIED / DELETED / RENAMED / COPIED / CHANGED
        public var changeType: String

        public init(path: String, additions: Int, deletions: Int, changeType: String) {
            self.path = path
            self.additions = additions
            self.deletions = deletions
            self.changeType = changeType
        }
    }

    public struct Check: Codable, Hashable, Sendable {
        public var name: String
        public var workflow: String?
        /// 終わったものは conclusion（SUCCESS / FAILURE / SKIPPED …）、途中は status（IN_PROGRESS / QUEUED …）。StatusContext は state
        public var state: String
        public var url: String?

        public init(name: String, workflow: String? = nil, state: String, url: String? = nil) {
            self.name = name
            self.workflow = workflow
            self.state = state
            self.url = url
        }
    }

    public struct Review: Codable, Hashable, Sendable {
        public var author: String
        public var state: String
        public var body: String
        public var submittedAt: Date?

        public init(author: String, state: String, body: String, submittedAt: Date? = nil) {
            self.author = author
            self.state = state
            self.body = body
            self.submittedAt = submittedAt
        }
    }

    public var url: String
    public var repository: String
    public var number: Int
    public var title: String
    public var author: String
    /// OPEN / MERGED / CLOSED
    public var state: String
    public var isDraft: Bool
    public var body: String
    public var baseRef: String
    public var headRef: String
    public var createdAt: Date
    public var updatedAt: Date
    public var mergedAt: Date?
    /// MERGEABLE / CONFLICTING / UNKNOWN
    public var mergeable: String?
    public var reviewDecision: String?
    public var checkState: CheckState?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var files: [File]
    public var checks: [Check]
    public var reviews: [Review]
    public var commentCount: Int
    public var fetchedAt: Date

    public init(
        url: String, repository: String, number: Int, title: String, author: String, state: String, isDraft: Bool, body: String, baseRef: String,
        headRef: String, createdAt: Date, updatedAt: Date, mergedAt: Date? = nil, mergeable: String? = nil, reviewDecision: String? = nil,
        checkState: CheckState? = nil, additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0, files: [File] = [], checks: [Check] = [],
        reviews: [Review] = [], commentCount: Int = 0, fetchedAt: Date
    ) {
        self.url = url
        self.repository = repository
        self.number = number
        self.title = title
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.body = body
        self.baseRef = baseRef
        self.headRef = headRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.mergeable = mergeable
        self.reviewDecision = reviewDecision
        self.checkState = checkState
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.files = files
        self.checks = checks
        self.reviews = reviews
        self.commentCount = commentCount
        self.fetchedAt = fetchedAt
    }

    public var shortLabel: String { "\(repository)#\(number)" }
}

/// GitHub のレビューの判定（`reviewDecision`）と、1 件のレビューの状態。知らない値は `other`
public enum PRReviewState: Hashable, Sendable {
    case approved, changesRequested, reviewRequired, commented, dismissed, pending, other

    public init(github value: String) {
        switch value {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        case "COMMENTED": self = .commented
        case "DISMISSED": self = .dismissed
        case "PENDING": self = .pending
        default: self = .other
        }
    }
}

/// ファイルの変更の種類。用語表の A・D・R・M に合わせ、複製と未追跡は追加、型の変更と衝突は変更に含める
public enum FileChangeKind: Hashable, Sendable {
    case added, deleted, renamed, modified

    /// GitHub の `changeType`（ADDED / MODIFIED / DELETED / RENAMED / COPIED / CHANGED）
    public init(github value: String) {
        switch value {
        case "ADDED", "COPIED": self = .added
        case "DELETED": self = .deleted
        case "RENAMED": self = .renamed
        default: self = .modified
        }
    }

    public init(_ change: ConversationDiffFile.Change) {
        switch change {
        case .added, .untracked, .copied: self = .added
        case .deleted: self = .deleted
        case .renamed: self = .renamed
        case .modified, .typeChanged, .unmerged: self = .modified
        }
    }
}

/// PR の中身の 1 件のチェックの状態（`PullRequestDetail.Check.state`）
public enum CheckRunState: Hashable, Sendable {
    case success, failure, timedOut, startupFailure, actionRequired, cancelled, skipped, neutral, stale, queued, running

    public init(github value: String) {
        switch value {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "TIMED_OUT": self = .timedOut
        case "STARTUP_FAILURE": self = .startupFailure
        case "ACTION_REQUIRED": self = .actionRequired
        case "CANCELLED": self = .cancelled
        case "SKIPPED": self = .skipped
        case "NEUTRAL": self = .neutral
        case "STALE": self = .stale
        case "QUEUED", "WAITING", "REQUESTED", "PENDING", "EXPECTED": self = .queued
        default: self = .running
        }
    }

    /// PR 全体の CI の状態に寄せたもの。結果を数えないもの（取り消し・スキップ・中立・古い結果）は nil
    public var rollup: CheckState? {
        switch self {
        case .success: .success
        case .failure, .timedOut, .startupFailure, .actionRequired: .failure
        case .queued, .running: .pending
        case .cancelled, .skipped, .neutral, .stale: nil
        }
    }
}

extension PullRequestSummary {
    public var decision: PRReviewState? { reviewDecision.map(PRReviewState.init(github:)) }
}

extension PullRequestLinkState {
    public var decision: PRReviewState? { reviewDecision.map(PRReviewState.init(github:)) }
}

extension PRReviewer {
    public var reviewState: PRReviewState { PRReviewState(github: state) }
}

extension PullRequestDetail {
    public var decision: PRReviewState? { reviewDecision.map(PRReviewState.init(github:)) }
}

extension PullRequestDetail.File {
    public var kind: FileChangeKind { FileChangeKind(github: changeType) }
}

extension PullRequestDetail.Check {
    public var runState: CheckRunState { CheckRunState(github: state) }
}

extension PullRequestDetail.Review {
    public var reviewState: PRReviewState { PRReviewState(github: state) }
}
