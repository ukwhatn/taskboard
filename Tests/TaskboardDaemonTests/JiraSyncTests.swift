import Foundation
import Synchronization
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// Jira の代わりに応答する。テストごとに別の host を使い、並列に走っても応答が混ざらないようにする
private final class StubJira: URLProtocol {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: String = ""
    }

    private static let replies = Mutex<[String: @Sendable (URLRequest) -> Reply]>([:])

    static func session(host: String, _ reply: @escaping @Sendable (URLRequest) -> Reply) -> URLSession {
        replies.withLock { $0[host] = reply }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubJira.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let answer = reply(request)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let token = "stub-jira-token-0123456789"

private func issueBody(status: String, category: String, summary: String = "ログイン画面の修正") -> String {
    #"{"key":"X","fields":{"summary":"\#(summary)","updated":"2026-10-01T10:00:00.000+0900","status":{"name":"\#(status)","statusCategory":{"id":4,"key":"\#(category)","name":"x"}}}}"#
}

private func client(_ host: String, _ reply: @escaping @Sendable (URLRequest) -> StubJira.Reply) -> JiraClient {
    JiraClient(site: host, email: "me@example.com", token: token, session: StubJira.session(host: host, reply))
}

@Suite("Jira の状態")
struct JiraSyncTests {
    @Test("課題キーは /browse/<KEY> か selectedIssue=<KEY> から取る。大文字の形でなければ取らない")
    func issueKey() {
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/browse/ABC-123") == "ABC-123")
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/browse/ABC-123?focusedCommentId=1") == "ABC-123")
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/jira/software/projects/ABC/boards/1?selectedIssue=ABC-12") == "ABC-12")
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/browse/A2_B-7") == "A2_B-7")
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/jira/software/projects/ABC/boards/1") == nil)
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/browse/") == nil)
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/browse/abc-123") == nil)
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/browse/Abc-123") == nil)
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/browse/A-1") == nil)
        #expect(JiraIssueKey.extract(from: "https://example.atlassian.net/browse/ABC-") == nil)
        #expect(JiraIssueKey.extract(from: "") == nil)
    }

    @Test("応答の状態名・分類・件名を読む。知らない分類は unknown。Basic 認証で fields を絞って取る")
    func decode() async throws {
        let seen = Mutex<URLRequest?>(nil)
        let jira = client("decode.example") { request in
            seen.withLock { $0 = request }
            let category = request.url!.path.hasSuffix("ABC-2") ? "blocked" : "indeterminate"
            return .init(status: 200, body: issueBody(status: "進行中", category: category))
        }
        #expect(try await jira.issue("ABC-1") == JiraLinkState(key: "ABC-1", statusName: "進行中", category: .indeterminate, summary: "ログイン画面の修正"))
        #expect(try await jira.issue("ABC-2").category == .unknown)

        let request = try #require(seen.withLock { $0 })
        #expect(request.url?.absoluteString == "https://decode.example/rest/api/3/issue/ABC-2?fields=summary,status,updated")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me@example.com:\(token)".utf8).base64EncodedString())

        for (key, expected) in [("new", JiraLinkState.Category.new), ("done", .done)] {
            let c = client("decode-\(key).example") { _ in .init(status: 200, body: issueBody(status: "s", category: key)) }
            #expect(try await c.issue("ABC-1").category == expected)
        }
    }

    @Test("401 は全件に同じ理由を入れて 30 分あける。文面にトークンを含めない")
    func unauthorized() async {
        let jira = client("unauthorized.example") { _ in .init(status: 401, body: #"{"errorMessages":["token \#(token) is invalid"]}"#) }
        let targets = ["https://x.atlassian.net/browse/ABC-1": "ABC-1", "https://x.atlassian.net/browse/ABC-2": "ABC-2"]
        let round = await JiraSync.round(client: jira, targets: targets)
        #expect(round.wait == JiraSync.unauthorizedInterval)
        #expect(round.results.count == 2)
        for result in round.results.values {
            #expect(result == .failed("Jira に接続できません: トークンが無効か期限切れです"))
        }
    }

    @Test("429 は Retry-After だけ待ち、そこで止める。Retry-After が無ければ 5 分")
    func rateLimited() async {
        let calls = Mutex(0)
        let jira = client("ratelimit.example") { request in
            calls.withLock { $0 += 1 }
            return request.url!.path.hasSuffix("ABC-1")
                ? .init(status: 200, body: issueBody(status: "完了", category: "done")) : .init(status: 429, headers: ["Retry-After": "42"])
        }
        let targets = ["https://x/browse/ABC-1": "ABC-1", "https://x/browse/ABC-2": "ABC-2", "https://x/browse/ABC-3": "ABC-3"]
        let round = await JiraSync.round(client: jira, targets: targets)
        #expect(round.wait == .seconds(42))
        #expect(calls.withLock { $0 } == 2)
        #expect(round.results["https://x/browse/ABC-1"] == .jira(JiraLinkState(key: "ABC-1", statusName: "完了", category: .done, summary: "ログイン画面の修正")))
        #expect(round.results["https://x/browse/ABC-2"] == .failed(JiraError.rateLimited(retryAfter: nil).message))
        #expect(round.results["https://x/browse/ABC-3"] == nil)

        let bare = client("ratelimit-bare.example") { _ in .init(status: 429) }
        #expect(await JiraSync.round(client: bare, targets: ["u": "ABC-1"]).wait == JiraSync.refreshInterval)
    }

    @Test("その他の非 2xx と読めない応答は、その課題だけ理由を入れて続ける。文面に応答本文もトークンも含めない")
    func otherFailures() async {
        let jira = client("other.example") { request in
            switch request.url!.lastPathComponent {
            case "ABC-1": .init(status: 404, body: #"{"errorMessages":["Issue does not exist \#(token)"]}"#)
            case "ABC-2": .init(status: 200, body: "<html>")
            default: .init(status: 200, body: issueBody(status: "To Do", category: "new"))
            }
        }
        let round = await JiraSync.round(client: jira, targets: ["a": "ABC-1", "b": "ABC-2", "c": "ABC-3"])
        #expect(round.wait == JiraSync.refreshInterval)
        #expect(round.results["a"] == .failed("Jira に接続できません: HTTP 404"))
        #expect(round.results["b"] == .failed("Jira に接続できません: 応答を読めません"))
        #expect(round.results["c"] == .jira(JiraLinkState(key: "ABC-3", statusName: "To Do", category: .new, summary: "ログイン画面の修正")))
        for case .failed(let message) in round.results.values { #expect(!message.contains(token)) }
    }

    @Test("jira.json: 無ければ nil。トークンは ~/ を HOME に展開し、前後の空白と改行を落とす")
    func config() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jira-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("jira.json")
        #expect(try JiraConfig.load(from: file) == nil)

        try #"{"site":"example.atlassian.net","email":"me@example.com","tokenFile":"~/.config/jira_token"}"#.write(to: file, atomically: true, encoding: .utf8)
        let config = try #require(try JiraConfig.load(from: file))
        #expect(config.site == "example.atlassian.net")
        #expect(config.readToken(home: home.path) == nil)
        try "  \(token)\n".write(to: home.appendingPathComponent(".config/jira_token"), atomically: true, encoding: .utf8)
        #expect(config.readToken(home: home.path) == token)
        try " \n".write(to: home.appendingPathComponent(".config/jira_token"), atomically: true, encoding: .utf8)
        #expect(config.readToken(home: home.path) == nil)
    }

    @Test("対象は終端列以外のタスクの Jira リンクで、キーが取れるものだけ")
    func targets() {
        let machine = MachineID(rawValue: "m")
        let board = Board(id: "b", machine: machine, name: "b", position: 0, columns: BoardColumn.standard, createdAt: Date())
        func task(_ number: Int, _ column: String, _ urls: [String]) -> BoardTask {
            BoardTask(
                machine: machine, number: number, boardID: "b", columnID: column, title: "t",
                links: urls.enumerated().map { TaskLink(id: Int64($0.offset), url: $0.element, kind: TaskLink.kind(of: $0.element), addedAt: Date()) },
                createdAt: Date(), updatedAt: Date())
        }
        let tasks = [
            task(1, "working", ["https://x.atlassian.net/browse/ABC-1", "https://github.com/o/r/pull/1"]),
            task(2, "review_req", ["https://x.atlassian.net/browse/ABC-2"]),
            task(3, "done", ["https://x.atlassian.net/browse/ABC-3"]),
            task(4, "todo", ["https://x.atlassian.net/browse/abc-4"]),
        ]
        #expect(JiraSync.targets(tasks: tasks, boards: [board]) == ["https://x.atlassian.net/browse/ABC-1": "ABC-1", "https://x.atlassian.net/browse/ABC-2": "ABC-2"])
    }
}
