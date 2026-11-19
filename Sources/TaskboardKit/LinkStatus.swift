import Foundation

/// タスクに付いたリンク（PR・Jira・Devin のセッション）の今の状態。daemon が URL ごとに取り、`links.updated` で丸ごと配る。
/// カードのチップと待ち理由に使う。まだ取っていないリンクは含めない（チップは名前だけを出す）。
/// 一度も取れずに失敗したリンクは、`pullRequest` / `jira` が nil で `error` だけを持つ。
public struct LinkStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: String { url }

    /// `TaskLink.url` と同じ文字列
    public var url: String
    public var fetchedAt: Date
    public var pullRequest: PullRequestLinkState?
    public var jira: JiraLinkState?
    public var devin: DevinLinkState?
    /// 最後の取得が失敗した理由（前回の値は残す）。トークン・認証ヘッダを含めない
    public var error: String?

    public init(
        url: String, fetchedAt: Date, pullRequest: PullRequestLinkState? = nil, jira: JiraLinkState? = nil, devin: DevinLinkState? = nil, error: String? = nil
    ) {
        self.url = url
        self.fetchedAt = fetchedAt
        self.pullRequest = pullRequest
        self.jira = jira
        self.devin = devin
        self.error = error
    }
}

public struct PullRequestLinkState: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case open = "OPEN"
        case merged = "MERGED"
        case closed = "CLOSED"
    }

    public var state: State
    public var isDraft: Bool
    /// `statusCheckRollup.state`。チェックが無い PR は nil
    public var checks: CheckState?
    /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED。保護ルールが無い repo では nil
    public var reviewDecision: String?

    public init(state: State, isDraft: Bool = false, checks: CheckState? = nil, reviewDecision: String? = nil) {
        self.state = state
        self.isDraft = isDraft
        self.checks = checks
        self.reviewDecision = reviewDecision
    }
}

public struct JiraLinkState: Codable, Hashable, Sendable {
    /// Jira の `statusCategory.key`
    public enum Category: String, Codable, Hashable, Sendable {
        case new
        case indeterminate
        case done
        /// 上の 3 つ以外（Jira が増やしたとき）
        case unknown

        public init(from decoder: Decoder) throws {
            self = Category(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// 課題キー（`ABC-123`）
    public var key: String
    /// Jira に設定された状態の名前（「進行中」「In Review」など）
    public var statusName: String
    public var category: Category
    public var summary: String

    public init(key: String, statusName: String, category: Category, summary: String = "") {
        self.key = key
        self.statusName = statusName
        self.category = category
        self.summary = summary
    }
}

extension LinkStatus {
    /// 終わったリンク（マージ済み・クローズの PR、完了の Jira、終了・期限切れの Devin）
    public var isSettled: Bool {
        if let pr = pullRequest, pr.state != .open { return true }
        if jira?.category == .done { return true }
        if let phase = devin?.phase, phase == .finished || phase == .expired { return true }
        return false
    }
}

extension TaskLink {
    /// 終わっていないリンクと終わったリンクに分ける。それぞれの中は足した順のまま。状態が取れていないリンクは終わっていないとみなす
    public static func ordered(_ links: [TaskLink], statuses: [String: LinkStatus]) -> (active: [TaskLink], settled: [TaskLink]) {
        var active: [TaskLink] = []
        var settled: [TaskLink] = []
        for link in links {
            if statuses[link.url]?.isSettled == true { settled.append(link) } else { active.append(link) }
        }
        return (active, settled)
    }
}
