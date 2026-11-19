import Foundation
import TaskboardKit

/// `gh pr view <url> --json <fields>` の応答の読み取り（gh を呼ばない純粋な部分）。
/// 列とカードのチップには状態・CI・レビューの判定を、リンクの知らせには head・mergeable・レビュー・会話のコメントも使う
struct PullRequestView: Decodable, Sendable {
    static let fields = "state,isDraft,statusCheckRollup,reviewDecision,headRefOid,mergedBy,mergeCommit,mergeable,reviews,comments"

    var state: String
    var isDraft: Bool
    /// gh は判定が無い PR に空文字を返す
    var reviewDecision: String?
    var statusCheckRollup: [CheckContext]?
    var headRefOid: String?
    var mergedBy: Actor?
    var mergeCommit: Commit?
    /// MERGEABLE / CONFLICTING / UNKNOWN
    var mergeable: String?
    var reviews: [Review]?
    var comments: [Comment]?

    struct Actor: Decodable, Sendable {
        var login: String?
    }

    struct Commit: Decodable, Sendable {
        var oid: String?
    }

    struct Review: Decodable, Sendable {
        var id: String
        /// 消えたアカウントは null
        var author: Actor?
        var state: String
        var body: String?
    }

    struct Comment: Decodable, Sendable {
        var id: String
        var author: Actor?
        var url: String?
    }

    static func parse(_ data: Data) throws -> PullRequestView {
        try JSONDecoder().decode(PullRequestView.self, from: data)
    }

    /// 開いた・マージ済み・閉じた以外の値（GitHub が増やしたとき）は nil
    var linkState: PullRequestLinkState? {
        guard let parsed = PullRequestLinkState.State(rawValue: state.uppercased()) else { return nil }
        let decision = reviewDecision.flatMap { $0.isEmpty ? nil : $0 }
        return PullRequestLinkState(state: parsed, isDraft: isDraft, checks: CheckRollup.state(statusCheckRollup ?? []), reviewDecision: decision)
    }

    /// 比べるための様子。`inline` は REST で取った行のコメント（open でない PR は nil）。知らない状態なら nil
    func snapshot(inline: [PullRequestSnapshot.Comment]?) -> PullRequestSnapshot? {
        guard let parsed = PullRequestLinkState.State(rawValue: state.uppercased()) else { return nil }
        let checks = statusCheckRollup ?? []
        return PullRequestSnapshot(
            state: parsed, isDraft: isDraft, headSHA: headRefOid.flatMap { $0.isEmpty ? nil : $0 }, checks: CheckRollup.state(checks),
            failedChecks: CheckRollup.failedNames(checks), mergeable: mergeable.flatMap { PullRequestSnapshot.Mergeable(rawValue: $0.uppercased()) },
            mergedBy: mergedBy?.login, mergeCommit: mergeCommit?.oid.flatMap { $0.isEmpty ? nil : $0 },
            reviews: (reviews ?? []).map {
                .init(id: $0.id, author: $0.author?.login ?? Self.ghost, state: $0.state.uppercased(), hasBody: !($0.body ?? "").isEmpty)
            },
            comments: (comments ?? []).map(Self.comment), inlineComments: inline)
    }

    /// gh は消えたアカウントの作者を null で返す（GitHub の画面の表記に合わせる）
    static let ghost = "ghost"

    static func comment(_ comment: Comment) -> PullRequestSnapshot.Comment {
        .init(id: comment.id, author: comment.author?.login ?? ghost, url: comment.url)
    }
}


/// `gh issue view <url> --json state,stateReason,comments` の応答
struct IssueView: Decodable, Sendable {
    static let fields = "state,stateReason,comments"

    var state: String
    var stateReason: String?
    var comments: [PullRequestView.Comment]?

    var snapshot: IssueSnapshot {
        IssueSnapshot(
            state: state.uppercased(), stateReason: stateReason.flatMap { $0.isEmpty ? nil : $0.uppercased() },
            comments: (comments ?? []).map(PullRequestView.comment))
    }
}

/// `gh api repos/{o}/{r}/pulls/{n}/comments`（行に付くレビューコメント）の 1 件
struct ReviewCommentView: Decodable, Sendable {
    struct User: Decodable, Sendable {
        var login: String
    }

    var id: Int64
    var user: User?
    var html_url: String?
    var in_reply_to_id: Int64?

    var comment: PullRequestSnapshot.Comment {
        .init(id: String(id), author: user?.login ?? PullRequestView.ghost, url: html_url, replyTo: in_reply_to_id.map(String.init))
    }

    /// PR の URL（`https://host/owner/repo/pull/1`）から REST の path。新しい順に 100 件、`since` より後に書いた・直したもの
    static func path(pullRequest url: String, since: Date?) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", Int(parts[3]) != nil else { return nil }
        var path = "repos/\(parts[0])/\(parts[1])/pulls/\(parts[3])/comments?per_page=100&sort=created&direction=desc"
        if let since { path += "&since=" + ISO8601DateFormatter().string(from: since) }
        return path
    }
}
