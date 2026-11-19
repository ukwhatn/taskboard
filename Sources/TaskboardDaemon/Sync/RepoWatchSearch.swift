// ui-copy:ignore-file
// このファイルの文（repo の見張りの取得の失敗の文）は、MCP の応答・保存される状態・ログに出て、画面には出ない
import Foundation
import TaskboardKit

/// repo の見張り（repo に新しく出た issue・PR）の GraphQL の search と、応答の読み取り・前の様子との差（gh を呼ばない純粋な部分）。
/// 作成順の昇順で 50 件取り、50 件を超えた回は、取った中でいちばん新しい作成時刻から次の回で続きを取る（取りこぼさない）
enum RepoWatchSearch {
    static let pageSize = 50
    /// 前に取った時刻からこれだけ前まで重ねて取る（search の index の遅れと時計のずれ）。重なった分は見た番号で除く
    static let overlap: TimeInterval = 600
    /// 見た番号を持つ上限（大きい番号から）
    static let seenLimit = 500
    /// daemon が付けるので、検索語には書かせない修飾子
    static let reservedQualifiers = ["repo:", "created:", "sort:"]
    static let queryLimit = 256

    /// 前の様子（`watch.snapshot` の JSON）
    struct Cursor: Codable, Equatable {
        /// 次の回の `created:>=`
        var since: Date
        var seen: [Int]
    }

    struct Item: Equatable {
        var number: Int
        var url: String
        var author: String?
        var createdAt: Date
        var labels: [String] = []
    }

    struct Result: Equatable {
        var items: [Item]
        /// 条件に合う件数（`issueCount`）。取った件数より多ければ続きがある
        var total: Int
        var cost: Int?
        var remaining: Int?
        var resetAt: Date?

        var overflowed: Bool { total > items.count }
    }

    static let query = """
        query($q: String!) {
          search(query: $q, type: ISSUE, first: \(pageSize)) {
            issueCount
            nodes {
              ... on Issue { number url createdAt author { login } labels(first: 10) { nodes { name } } }
              ... on PullRequest { number url createdAt author { login } labels(first: 10) { nodes { name } } }
            }
          }
          rateLimit { cost remaining resetAt }
        }
        """

    /// gh の検索語。`repo` は `owner/name`
    static func term(repo: String, query: String?, since: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+00:00'"
        return (["repo:\(repo)"] + (query.map { [$0] } ?? []) + ["created:>=\(formatter.string(from: since))", "sort:created-asc"]).joined(separator: " ")
    }

    /// 検索語に daemon が付ける修飾子があれば、その語を返す（`-repo:` のような除外も）
    static func reservedQualifier(in query: String) -> String? {
        query.split(whereSeparator: \.isWhitespace).map(String.init).first { word in
            let bare = word.hasPrefix("-") ? String(word.dropFirst()) : word
            return reservedQualifiers.contains { bare.lowercased().hasPrefix($0) }
        }
    }

    static func parse(_ data: Data) throws -> Result {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw PullRequestQueries.ParseError.malformed(String(describing: error).prefix(200).description)
        }
        if let error = envelope.errors?.first { throw PullRequestQueries.ParseError.graphQL(type: error.type, message: error.message) }
        guard let search = envelope.data?.search else { throw PullRequestQueries.ParseError.malformed("search が無い") }
        // 権限の無いものや、Issue・PullRequest でないものは空の node で返る
        let items = search.nodes.compactMap { $0 }.compactMap { node -> Item? in
            guard let number = node.number, let url = node.url, let createdAt = node.createdAt else { return nil }
            return Item(number: number, url: url, author: node.author?.login, createdAt: createdAt, labels: (node.labels?.nodes ?? []).compactMap { $0?.name })
        }
        let rate = envelope.data?.rateLimit
        return Result(items: items, total: search.issueCount, cost: rate?.cost, remaining: rate?.remaining, resetAt: rate?.resetAt)
    }

    /// 取った結果を前の様子と比べ、新しく出たもの（見ていない番号。`viewerLogin` が作ったものは除く）と次の様子を返す。
    /// 前の様子が無い（作った直後）ときは、取ったものを見たことにするだけ
    static func advance(_ old: Cursor?, result: Result, viewerLogin: String, startedAt: Date) -> (cursor: Cursor, opened: [Item]) {
        let seen = Set(old?.seen ?? [])
        let viewer = viewerLogin.lowercased()
        let opened = old == nil ? [] : result.items.filter { !seen.contains($0.number) && $0.author?.lowercased() != viewer }
        let numbers = Array(seen.union(result.items.map(\.number))).sorted(by: >).prefix(seenLimit)
        var since = startedAt.addingTimeInterval(-overlap)
        // 続きがあれば、取った中でいちばん新しい作成時刻から取る。そこが前の回と同じなら（同じ秒に 50 件より多い）、先へ進める
        if result.overflowed, let newest = result.items.map(\.createdAt).max(), newest > (old?.since ?? .distantPast) {
            since = newest
        }
        return (Cursor(since: since, seen: Array(numbers)), opened)
    }

    private struct Envelope: Decodable {
        var data: Payload?
        var errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        var type: String?
        var message: String
    }

    private struct Payload: Decodable {
        var search: Search?
        var rateLimit: RateLimit?
    }

    private struct Search: Decodable {
        var issueCount: Int
        var nodes: [Node?]
    }

    private struct Node: Decodable {
        var number: Int?
        var url: String?
        var createdAt: Date?
        var author: Author?
        var labels: Labels?
    }

    private struct Author: Decodable {
        var login: String
    }

    private struct Labels: Decodable {
        var nodes: [Label?]
    }

    private struct Label: Decodable {
        var name: String
    }

    private struct RateLimit: Decodable {
        var cost: Int?
        var remaining: Int?
        var resetAt: Date?
    }
}
