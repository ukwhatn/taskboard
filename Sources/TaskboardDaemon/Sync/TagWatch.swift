// ui-copy:ignore-file
// このファイルの文（タグの見張りの取得の失敗の文）は、MCP の応答・保存される状態・ログに出て、画面には出ない
import Foundation
import TaskboardKit

/// PR の見張りの `tagged`（マージした PR がタグに入った）の、タグの一覧の GraphQL と読み取り・比べるタグの選び方・compare の判定（gh を呼ばない純粋な部分）。
/// タグはコミットの新しい順に 50 件取り、名前が型に合うものだけを見る。見始めの回は、いちばん新しい型に合うタグだけと比べる
enum TagWatch {
    static let pageSize = 50
    /// 見た（型に合う）タグの名前を持つ上限
    static let seenLimit = 200
    static let patternLimit = 100

    /// `watch.tagState` の JSON
    struct State: Codable, Equatable {
        /// 比べた・見始めにあった型に合うタグ。nil はまだ見始めていない
        var seen: [String]?
        /// 入ったタグ
        var tag: String?
        /// 見張りを作ったときに PR がもうマージされていた（見始めの回に入っていたタグは、前からの様子なので届けない）
        var mergedBeforeWatch = false
    }

    struct Tag: Equatable {
        var name: String
        /// 注釈付きのタグは中のコミット
        var commit: String
    }

    struct Listing: Equatable {
        var tags: [Tag]
        var cost: Int?
        var remaining: Int?
        var resetAt: Date?
    }

    static let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            refs(refPrefix: "refs/tags/", first: \(pageSize), orderBy: { field: TAG_COMMIT_DATE, direction: DESC }) {
              nodes { name target { __typename oid ... on Tag { target { oid } } } }
            }
          }
          rateLimit { cost remaining resetAt }
        }
        """

    static func parse(_ data: Data) throws -> Listing {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw PullRequestQueries.ParseError.malformed(String(describing: error).prefix(200).description)
        }
        if let error = envelope.errors?.first { throw PullRequestQueries.ParseError.graphQL(type: error.type, message: error.message) }
        guard let refs = envelope.data?.repository?.refs else { throw PullRequestQueries.ParseError.malformed("repository が無い") }
        let tags = refs.nodes.compactMap { $0 }.compactMap { node -> Tag? in
            // 注釈付きのタグは Tag を 1 段たどって中の object にする
            let commit = node.target.typename == "Tag" ? node.target.target?.oid : node.target.oid
            return commit.map { Tag(name: node.name, commit: $0) }
        }
        let rate = envelope.data?.rateLimit
        return Listing(tags: tags, cost: rate?.cost, remaining: rate?.remaining, resetAt: rate?.resetAt)
    }

    /// タグの名前が型（glob。`*`・`?`・`[...]`）に合うか。型が nil なら全部
    static func matches(_ name: String, pattern: String?) -> Bool {
        guard let pattern else { return true }
        return fnmatch(pattern, name, 0) == 0
    }

    /// 比べるタグ（古い順）と、比べ終えた後の見たタグ。見始め（`state.seen` が nil）は、いちばん新しい型に合うタグだけを比べ、ほかは見たことにする
    static func plan(_ state: State, tags: [Tag], pattern: String?) -> (compare: [Tag], seen: [String]) {
        let matching = tags.filter { matches($0.name, pattern: pattern) }
        guard let seen = state.seen else {
            return (Array(matching.prefix(1)), Array(matching.map(\.name).prefix(seenLimit)))
        }
        let known = Set(seen)
        let fresh = matching.filter { !known.contains($0.name) }
        return (fresh.reversed(), Array((fresh.map(\.name) + seen).prefix(seenLimit)))
    }

    /// `compare/{merge commit}...{タグ}` の応答の `status`。タグが merge commit を含むのは、タグが先にある（ahead）か同じ（identical）ときだけ。
    /// diverged はタグが別の線にあって merge commit を含まない
    static func contains(status: String) -> Bool {
        status == "ahead" || status == "identical"
    }

    /// `repos/{owner}/{repo}/compare/{merge commit}...{タグのコミット}`。PR の URL から repo を取る
    static func comparePath(pullRequest url: String, mergeCommit: String, tagCommit: String) -> String? {
        guard let (owner, name) = repository(of: url) else { return nil }
        return "repos/\(owner)/\(name)/compare/\(mergeCommit)...\(tagCommit)?per_page=1"
    }

    /// タグのリリースの画面（`https://<host>/<owner>/<repo>/releases/tag/<タグ>`）
    static func releaseURL(pullRequest url: String, tag: String) -> String? {
        guard let parsed = URL(string: url), let host = parsed.host(), let (owner, name) = repository(of: url),
            let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
        else { return nil }
        return "https://\(host)/\(owner)/\(name)/releases/tag/\(encoded)"
    }

    static func repository(of url: String) -> (owner: String, name: String)? {
        guard let parts = URL(string: url)?.pathComponents.filter({ $0 != "/" }), parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
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
        var repository: Repository?
        var rateLimit: RateLimit?
    }

    private struct Repository: Decodable {
        var refs: Refs?
    }

    private struct Refs: Decodable {
        var nodes: [Node?]
    }

    private struct Node: Decodable {
        var name: String
        var target: Target
    }

    private struct Target: Decodable {
        var typename: String?
        var oid: String?
        var target: Inner?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case oid
            case target
        }
    }

    private struct Inner: Decodable {
        var oid: String?
    }

    private struct RateLimit: Decodable {
        var cost: Int?
        var remaining: Int?
        var resetAt: Date?
    }
}
