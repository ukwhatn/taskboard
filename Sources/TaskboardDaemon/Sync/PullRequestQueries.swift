// ui-copy:ignore-file
// このファイルの文（PR の取得の失敗の文）は、MCP の応答・保存される状態・ログに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation
import TaskboardKit

/// PR の一覧と中身を取る GraphQL と、その応答の読み取り（gh を呼ばない純粋な部分）。
/// 一覧は search 3 本（頼まれた / 自分がレビューした他人の / 自分の）で、1 本あたり rate limit の cost は 2 前後。
enum PullRequestQueries {
    /// 1 区分で取る上限。超えた分は一覧に出ない（GitHub で見る）
    static let pageSize = 50

    static let searchTerms: [(key: String, query: String)] = [
        ("requested", "is:pr is:open archived:false review-requested:@me"),
        ("reviewed", "is:pr is:open archived:false reviewed-by:@me -author:@me"),
        ("authored", "is:pr is:open archived:false author:@me"),
    ]

    static let search = """
        query($q: String!) {
          search(query: $q, type: ISSUE, first: \(pageSize)) {
            nodes { ... on PullRequest {
              number title url isDraft createdAt updatedAt headRefName reviewDecision additions deletions changedFiles
              repository { nameWithOwner }
              author { login __typename }
              \(CheckRollup.contextsQuery)
              latestReviews(first: 20) { nodes { author { login } state } }
              reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
            } }
          }
        }
        """

    static let detail = """
        query($url: URI!) { resource(url: $url) { ... on PullRequest {
          number title url state isDraft body createdAt updatedAt mergedAt baseRefName headRefName additions deletions changedFiles reviewDecision mergeable
          repository { nameWithOwner }
          author { login }
          files(first: 100) { nodes { path additions deletions changeType } }
          reviews(last: 30) { nodes { author { login } state body submittedAt } }
          comments { totalCount }
          \(CheckRollup.contextsQuery)
        } } }
        """

    enum ParseError: Error, CustomStringConvertible, Equatable {
        /// GraphQL の errors（type, message）
        case graphQL(type: String?, message: String)
        case notAPullRequest
        case malformed(String)

        var description: String {
            switch self {
            case .graphQL(_, let message): message
            case .notAPullRequest: "PR ではない URL"
            case .malformed(let what): "応答を読めない: \(what)"
            }
        }

        var isRateLimit: Bool {
            if case .graphQL(let type, let message) = self { return type == "RATE_LIMITED" || message.lowercased().contains("rate limit") }
            return false
        }
    }

    // MARK: 一覧

    /// search の応答から PR を読む。区分はまだ付けない（`classify` で決める）
    static func parseSearch(_ data: Data) throws -> [SearchNode] {
        let envelope = try decode(Envelope<SearchData>.self, data)
        if let error = envelope.errors?.first { throw ParseError.graphQL(type: error.type, message: error.message) }
        guard let search = envelope.data?.search else { throw ParseError.malformed("search が無い") }
        // 権限の無い repo の PR などは空の node で返る
        return search.nodes.compactMap { $0 }.filter { $0.url != nil }
    }

    /// 3 本の検索結果を 4 区分にまとめる。頼まれた PR は「未レビュー」を優先し、自分の PR は draft で分ける
    static func classify(
        requested: [SearchNode], reviewed: [SearchNode], authored: [SearchNode], machine: MachineID, host: String, account: String
    ) -> [PullRequestSummary] {
        var seen: Set<String> = []
        var result: [PullRequestSummary] = []
        func add(_ nodes: [SearchNode], _ category: (SearchNode) -> PRCategory) {
            for node in nodes {
                guard let summary = node.summary(category: category(node), machine: machine, host: host, account: account), !seen.contains(summary.url)
                else { continue }
                seen.insert(summary.url)
                result.append(summary)
            }
        }
        add(authored) { $0.isDraft == true ? .myDraft : .myReady }
        add(requested) { _ in .reviewRequested }
        add(reviewed) { _ in .reviewed }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    struct SearchData: Decodable {
        struct Search: Decodable { var nodes: [SearchNode?] }
        var search: Search?
    }

    struct SearchNode: Decodable {
        var number: Int?
        var title: String?
        var url: String?
        var isDraft: Bool?
        var createdAt: Date?
        var updatedAt: Date?
        var headRefName: String?
        var reviewDecision: String?
        var additions: Int?
        var deletions: Int?
        var changedFiles: Int?
        var repository: Repository?
        var author: Login?
        var commits: Commits?
        var latestReviews: Nodes<ReviewNode>?
        var reviewRequests: Nodes<RequestNode>?

        func summary(category: PRCategory, machine: MachineID, host: String, account: String) -> PullRequestSummary? {
            guard let url, let number, let repository else { return nil }
            return PullRequestSummary(
                machine: machine, host: host, account: account, category: category, url: url, repository: repository.nameWithOwner, number: number,
                title: title ?? "", author: author?.login ?? "ghost", isDraft: isDraft ?? false, headRef: headRefName ?? "",
                createdAt: createdAt ?? .distantPast, updatedAt: updatedAt ?? createdAt ?? .distantPast, reviewDecision: reviewDecision,
                checks: commits.flatMap { CheckRollup.state($0.contexts) }, additions: additions ?? 0, deletions: deletions ?? 0, changedFiles: changedFiles ?? 0,
                latestReviews: (latestReviews?.nodes ?? []).compactMap { $0 }.map { PRReviewer(login: $0.author?.login ?? "ghost", state: $0.state) },
                requestedReviewers: (reviewRequests?.nodes ?? []).compactMap { $0?.requestedReviewer?.name },
                authorIsBot: author?.__typename.map { $0 == "Bot" })
        }
    }

    struct ReviewNode: Decodable {
        var author: Login?
        var state: String
    }

    struct RequestNode: Decodable {
        struct Reviewer: Decodable {
            var login: String?
            var teamName: String?
            var name: String? { login ?? teamName }
            enum CodingKeys: String, CodingKey { case login, teamName = "name" }
        }
        var requestedReviewer: Reviewer?
    }

    // MARK: 中身

    static func parseDetail(_ data: Data, fetchedAt: Date) throws -> PullRequestDetail {
        let envelope = try decode(Envelope<DetailData>.self, data)
        if let error = envelope.errors?.first { throw ParseError.graphQL(type: error.type, message: error.message) }
        guard let pr = envelope.data?.resource, let url = pr.url, let number = pr.number, let repository = pr.repository else {
            throw ParseError.notAPullRequest
        }
        let contexts = pr.commits?.contexts ?? []
        let checks: [PullRequestDetail.Check] = contexts.map { node in
            if !node.isCheckRun {
                return PullRequestDetail.Check(name: node.context ?? "status", state: node.state ?? "PENDING", url: node.targetUrl)
            }
            return PullRequestDetail.Check(
                name: node.name ?? "check", workflow: node.workflow, state: node.conclusion ?? node.status ?? "PENDING", url: node.detailsUrl)
        }
        return PullRequestDetail(
            url: url, repository: repository.nameWithOwner, number: number, title: pr.title ?? "", author: pr.author?.login ?? "ghost",
            state: pr.state ?? "OPEN", isDraft: pr.isDraft ?? false, body: pr.body ?? "", baseRef: pr.baseRefName ?? "", headRef: pr.headRefName ?? "",
            createdAt: pr.createdAt ?? .distantPast, updatedAt: pr.updatedAt ?? .distantPast, mergedAt: pr.mergedAt, mergeable: pr.mergeable,
            reviewDecision: pr.reviewDecision, checkState: CheckRollup.state(contexts), additions: pr.additions ?? 0,
            deletions: pr.deletions ?? 0, changedFiles: pr.changedFiles ?? 0,
            files: (pr.files?.nodes ?? []).compactMap { $0 }.map {
                PullRequestDetail.File(path: $0.path, additions: $0.additions, deletions: $0.deletions, changeType: $0.changeType)
            },
            checks: checks,
            reviews: (pr.reviews?.nodes ?? []).compactMap { $0 }.map {
                PullRequestDetail.Review(author: $0.author?.login ?? "ghost", state: $0.state, body: $0.body ?? "", submittedAt: $0.submittedAt)
            },
            commentCount: pr.comments?.totalCount ?? 0, fetchedAt: fetchedAt)
    }

    struct DetailData: Decodable {
        var resource: DetailNode?
    }

    struct DetailNode: Decodable {
        struct File: Decodable {
            var path: String
            var additions: Int
            var deletions: Int
            var changeType: String
        }
        struct Review: Decodable {
            var author: Login?
            var state: String
            var body: String?
            var submittedAt: Date?
        }
        struct Count: Decodable { var totalCount: Int }

        var number: Int?
        var title: String?
        var url: String?
        var state: String?
        var isDraft: Bool?
        var body: String?
        var createdAt: Date?
        var updatedAt: Date?
        var mergedAt: Date?
        var baseRefName: String?
        var headRefName: String?
        var additions: Int?
        var deletions: Int?
        var changedFiles: Int?
        var reviewDecision: String?
        var mergeable: String?
        var repository: Repository?
        var author: Login?
        var files: Nodes<File>?
        var reviews: Nodes<Review>?
        var comments: Count?
        var commits: Commits?
    }

    // MARK: 共通

    struct Envelope<T: Decodable>: Decodable {
        struct GraphQLError: Decodable {
            var type: String?
            var message: String
        }
        var data: T?
        var errors: [GraphQLError]?
    }

    struct Nodes<T: Decodable>: Decodable { var nodes: [T?] }
    struct Login: Decodable {
        var login: String
        /// User・Bot・Organization など（`author { login __typename }` で取ったときだけ）
        var __typename: String?
    }
    struct Repository: Decodable { var nameWithOwner: String }

    struct Commits: Decodable {
        struct Node: Decodable {
            struct Commit: Decodable { var statusCheckRollup: Rollup? }
            var commit: Commit
        }
        var nodes: [Node?]

        /// head（最後のコミット）のチェック
        var contexts: [CheckContext] {
            (nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.contexts?.nodes ?? []).compactMap { $0 }
        }
    }

    struct Rollup: Decodable {
        var contexts: Nodes<CheckContext>?
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ParseError.malformed(String(describing: error).prefix(200).description)
        }
    }
}
