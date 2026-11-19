import Foundation
import Synchronization
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// Devin の代わりに応答する。テストごとに別の host を使い、並列に走っても応答が混ざらないようにする
private final class StubDevin: URLProtocol {
    struct Reply: Sendable {
        var status: Int
        var body: String = ""
    }

    private static let replies = Mutex<[String: @Sendable (URLRequest) -> Reply]>([:])

    static func session(host: String, _ reply: @escaping @Sendable (URLRequest) -> Reply) -> URLSession {
        replies.withLock { $0[host] = reply }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDevin.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            request.httpBody = data
        }
        let answer = reply(request)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let machine = MachineID(rawValue: "m-devin")
private let token = "apk_user_stub-devin-token-0123456789"
private let sessionURL = "https://example.devinenterprise.com/sessions/0a1b2c3d"

private func sessionBody(status: String, devinMessages: Int = 0, pr: String? = nil) -> String {
    let messages = (0..<devinMessages).map { #"{"type":"devin_message","message":"質問 \#($0)","timestamp":"2026-10-26T10:00:00Z"}"# }
    let initial = #"{"type":"initial_user_message","message":"直して","timestamp":"2026-10-26T09:00:00Z"}"#
    let prField = pr.map { #","pull_request":{"url":"\#($0)"}"# } ?? #","pull_request":null"#
    return #"{"session_id":"devin-0a1b2c3d","status_enum":"\#(status)","title":"ログインの修正"\#(prField),"messages":[\#(([initial] + messages).joined(separator: ","))]}"#
}

private struct World {
    var store: Store
    var state: DaemonState
    var sync: DevinSync
    var task: BoardTask
    var config: URL
    var session: URLSession
    var home: String

    /// daemon を起動し直したときの DevinSync（メモリの中身は空、DB はそのまま）
    func restarted() -> DevinSync { DevinSync(store: store, state: state, configFile: config, session: session, home: home) }
}

struct Account {
    var name: String
    var host: String
    var boards: [String] = []
}

/// devin.json とトークンのファイルを一時ディレクトリに置き、案件「a」に作業中のタスクを 1 つ作る
private func world(host: String, column: String = "working", link: Bool = true, _ reply: @escaping @Sendable (URLRequest) -> StubDevin.Reply) async throws -> World {
    try await world(accounts: [Account(name: "das", host: host)], column: column, link: link, reply)
}

private func world(
    accounts: [Account], column: String = "working", link: Bool = true, _ reply: @escaping @Sendable (URLRequest) -> StubDevin.Reply
) async throws -> World {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("devin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try "OTHER=x\nDEVIN_KEY=\"\(token)\"\n".write(to: home.appending(path: ".env.local"), atomically: true, encoding: .utf8)
    let config = home.appending(path: "devin.json")
    let entries = accounts.map { account in
        let boards = account.boards.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"name":"\#(account.name)","tokenFile":"~/.env.local","tokenVariable":"DEVIN_KEY","apiBase":"https://\#(account.host)","boards":[\#(boards)]}"#
    }
    try #"{"accounts":[\#(entries.joined(separator: ","))]}"#.write(to: config, atomically: true, encoding: .utf8)
    var session = URLSession.shared
    for account in accounts { session = StubDevin.session(host: account.host, reply) }
    let store = try Store(inMemory: machine)
    let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
    let publisher = store.statePublisher(state: state)
    let board = try store.createBoard(name: "a", columns: nil)
    let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: column, title: "t"))
    if link { _ = try store.updateTask(number: task.number, TaskUpdateRequest(addLinks: [sessionURL])) }
    await publisher.settled()
    let sync = DevinSync(store: store, state: state, configFile: config, session: session, home: home.path)
    return World(store: store, state: state, sync: sync, task: task, config: config, session: session, home: home.path)
}

@Suite("Devin のセッション")
struct DevinSyncTests {
    @Test("セッションの id は Devin の画面の URL・devin-<id>・<id> から取り、小文字にする。ほかの host・形は読まない")
    func sessionID() {
        #expect(DevinSession.id(fromURL: "https://example.devinenterprise.com/sessions/0A1b2c") == "0a1b2c")
        #expect(DevinSession.id(fromURL: "https://app.devin.ai/sessions/abc123") == "abc123")
        #expect(DevinSession.id(fromURL: "https://example.com/sessions/abc123") == nil)
        #expect(DevinSession.id(fromURL: "https://app.devin.ai/sessions/abc123/files") == nil)
        #expect(DevinSession.id(fromURL: "https://app.devin.ai/sessions/") == nil)
        #expect(DevinSession.id(fromURL: "https://app.devin.ai/sessions/xyz") == nil)
        #expect(DevinSession.id(from: "devin-abc123") == "abc123")
        #expect(DevinSession.id(from: " abc123\n") == "abc123")
        #expect(DevinSession.id(from: "") == nil)
        #expect(DevinSession.id(from: "devin-") == nil)
        #expect(DevinSession.id(from: "セッション") == nil)
        #expect(DevinSession.apiID("abc123") == "devin-abc123")
        #expect(TaskLink(id: 0, url: sessionURL, kind: TaskLink.kind(of: sessionURL), addedAt: .distantPast).shortLabel == "Devin")
    }

    @Test("トークンは tokenVariable の行（export・引用符つきも）から読む。行が無い・空なら読めない。tokenVariable が無ければファイル全体")
    func tokenFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("devin-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appending(path: "env")
        func read(_ text: String, variable: String? = "KEY") throws -> String? {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return DevinConfig.Account(name: "a", tokenFile: file.path, tokenVariable: variable).readToken(home: home.path)
        }
        #expect(try read("A=1\nKEY=abc\n") == "abc")
        #expect(try read("export KEY='abc'") == "abc")
        #expect(try read("KEY=\"abc\"") == "abc")
        #expect(try read("KEYS=abc") == nil)
        #expect(try read("KEY=") == nil)
        #expect(try read("  abc \n", variable: nil) == "abc")
        #expect(DevinConfig.Account(name: "a", tokenFile: "~/none", tokenVariable: nil).readToken(home: home.path) == nil)
    }

    @Test("初めて取った様子は元にするだけ。返答待ちに入る・待ったまま Devin がまた発言する・PR を出す・終わるで知らせ、作成した PR をタスクにリンクする")
    func notices() async throws {
        let replies = Mutex([
            sessionBody(status: "working"),
            sessionBody(status: "blocked", devinMessages: 1),
            sessionBody(status: "blocked", devinMessages: 1),
            sessionBody(status: "blocked", devinMessages: 2),
            sessionBody(status: "finished", devinMessages: 2, pr: "https://github.com/o/r/pull/7"),
        ])
        let seen = Mutex<URLRequest?>(nil)
        let w = try await world(host: "notices.example") { request in
            seen.withLock { $0 = request }
            return .init(status: 200, body: replies.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] })
        }
        var kinds: [[LinkNotice.Kind]] = []
        for _ in 0..<5 {
            _ = await w.sync.refresh(force: true)
            kinds.append(try w.store.undeliveredLinkNotices(task: w.task.number).map(\.notice.kind))
            try w.store.markLinkNoticesDelivered(ids: w.store.undeliveredLinkNotices(task: w.task.number).map(\.id), at: Date())
        }
        #expect(kinds == [[], [.devinWaiting], [], [.devinWaiting], [.devinPullRequest, .devinFinished]])
        #expect(try w.store.task(number: w.task.number)?.links.map(\.url) == [sessionURL, "https://github.com/o/r/pull/7"])
        let status = try #require(await w.state.linkStatuses().first { $0.url == sessionURL })
        #expect(status.devin == DevinLinkState(status: "finished", title: "ログインの修正", pullRequestURL: "https://github.com/o/r/pull/7"))

        let request = try #require(seen.withLock { $0 })
        #expect(request.url?.absoluteString == "https://notices.example/v1/sessions/devin-0a1b2c3d")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test("知らせの文に Devin の発言を載せない")
    func noticeLine() {
        let waiting = LinkNotices.line(LinkNotice(kind: .devinWaiting, url: sessionURL))
        #expect(waiting == "Devin: 返答を待っている（devin_get で発言を読み、devin_message で答える） \(sessionURL)")
        let pr = LinkNotices.line(LinkNotice(kind: .devinPullRequest, url: sessionURL, targetURL: "https://github.com/o/r/pull/7"))
        #expect(pr == "Devin: PR を作成した https://github.com/o/r/pull/7 \(sessionURL)")
    }

    @Test("終端列のタスクのセッションは取らない。終わったセッションは 10 分あけて取る")
    func skips() async throws {
        let calls = Mutex(0)
        let done = try await world(host: "skip-done.example", column: "done") { _ in
            calls.withLock { $0 += 1 }
            return .init(status: 200, body: sessionBody(status: "working"))
        }
        _ = await done.sync.refresh()
        #expect(calls.withLock { $0 } == 0)

        let finished = try await world(host: "skip-finished.example") { _ in
            calls.withLock { $0 += 1 }
            return .init(status: 200, body: sessionBody(status: "finished"))
        }
        _ = await finished.sync.refresh()
        _ = await finished.sync.refresh()
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("401 はリンクの状態に理由を入れ、そのアカウントを 30 分使わない。文面にトークンを含めない")
    func unauthorized() async throws {
        let calls = Mutex(0)
        let w = try await world(host: "unauthorized.example") { _ in
            calls.withLock { $0 += 1 }
            return .init(status: 401, body: #"{"detail":"token \#(token) is invalid"}"#)
        }
        _ = await w.sync.refresh()
        let status = try #require(await w.state.linkStatuses().first { $0.url == sessionURL })
        #expect(status.error == "Devin に接続できません: トークンが無効か期限切れです")
        _ = await w.sync.refresh()
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("起動は ACU の上限と idempotent を付けて作り、タスクにリンクして元の様子を取る（作った直後の様子では知らせない）")
    func start() async throws {
        let body = Mutex<[String: Any]?>(nil)
        let w = try await world(host: "start.example", link: false) { request in
            if request.httpMethod == "POST" {
                body.withLock { $0 = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] }
                return .init(status: 200, body: #"{"session_id":"devin-0a1b2c3d","url":"\#(sessionURL)","is_new_session":true}"#)
            }
            return .init(status: 200, body: sessionBody(status: "blocked", devinMessages: 1))
        }
        let started = try await w.sync.start(DevinStartRequest(prompt: "直して", title: "修正", tags: ["das"], maxAcuLimit: 20, taskNumber: w.task.number))
        #expect(started == DevinStarted(sessionID: "0a1b2c3d", url: sessionURL, existing: false, link: .linked(task: w.task.number), account: "das"))
        let sent = try #require(body.withLock { $0 })
        #expect(sent["prompt"] as? String == "直して")
        #expect(sent["max_acu_limit"] as? Int == 20)
        #expect(sent["idempotent"] as? Bool == true)
        #expect(sent["title"] as? String == "修正")
        #expect(sent["tags"] as? [String] == ["das"])
        #expect(try w.store.undeliveredLinkNotices(task: w.task.number).isEmpty)
        _ = await w.sync.refresh(force: true)
        #expect(try w.store.undeliveredLinkNotices(task: w.task.number).isEmpty)
    }

    @Test("発言は新しい 20 件を古い順に、1 件 4,000 字で切って返す")
    func detail() async throws {
        let long = String(repeating: "あ", count: 4001)
        let messages = (0..<22).map { #"{"type":"devin_message","message":"\#($0 == 21 ? long : "m\($0)")"}"# }
        let w = try await world(host: "detail.example") { _ in
            .init(status: 200, body: #"{"session_id":"devin-0a1b2c3d","status_enum":"blocked","messages":[\#(messages.joined(separator: ","))]}"#)
        }
        let detail = try await w.sync.detail("0a1b2c3d")
        #expect(detail.omitted == 2)
        #expect(detail.messages.count == 20)
        #expect(detail.messages.first?.text == "m2")
        #expect(detail.messages.last?.text.count == 4000)
        #expect(detail.messages.last?.clipped == true)
        #expect(detail.state.phase == .waiting)
    }

    @Test("止まったセッションへのメッセージは Devin の理由を返す")
    func message() async throws {
        let w = try await world(host: "message.example") { request in
            request.url!.path.hasSuffix("/message") ? .init(status: 400, body: #"{"detail":"Session is suspended"}"#) : .init(status: 404)
        }
        #expect(try await w.sync.message("0a1b2c3d", "続けて") == DevinMessageSent(refused: "Session is suspended"))
        await #expect(throws: DevinError.notFound) { try await w.sync.detail("0a1b2c3d") }
    }

    @Test("org ごとのアカウントは、前に通ったもの（daemon を起動し直しても覚えている）・タスクの案件に割り当てたもの・残りの順に試し、見つからなければ次へ進む")
    func accounts() async throws {
        let seen = Mutex<[String]>([])
        let reply: @Sendable (URLRequest) -> StubDevin.Reply = { request in
            let host = request.url!.host()!
            seen.withLock { $0.append(host) }
            return host.hasSuffix("-b.example") ? .init(status: 200, body: sessionBody(status: "working")) : .init(status: 404, body: #"{"detail":"not found"}"#)
        }
        let byBoard = try await world(
            accounts: [Account(name: "org-a", host: "accounts1-a.example"), Account(name: "org-b", host: "accounts1-b.example", boards: ["a"])], reply)
        _ = await byBoard.sync.refresh()
        #expect(seen.withLock { $0 } == ["accounts1-b.example"])

        seen.withLock { $0 = [] }
        let fallback = try await world(
            accounts: [Account(name: "org-a", host: "accounts2-a.example", boards: ["a"]), Account(name: "org-b", host: "accounts2-b.example")], reply)
        _ = await fallback.sync.refresh()
        #expect(seen.withLock { $0 } == ["accounts2-a.example", "accounts2-b.example"])
        #expect(try #require(await fallback.state.linkStatuses().first { $0.url == sessionURL }).devin?.status == "working")
        seen.withLock { $0 = [] }
        _ = await fallback.sync.refresh(force: true)
        #expect(seen.withLock { $0 } == ["accounts2-b.example"])
        #expect(try await fallback.sync.detail("0a1b2c3d").account == "org-b")

        seen.withLock { $0 = [] }
        _ = await fallback.restarted().refresh(force: true)
        #expect(seen.withLock { $0 } == ["accounts2-b.example"])
    }

    @Test("起動のアカウントは、名前を渡せばそれ、無ければタスクの Devin のセッションで通ったもの、タスクの案件に割り当てた 1 つ。決められなければ断る")
    func startAccount() async throws {
        let reply: @Sendable (URLRequest) -> StubDevin.Reply = { request in
            request.httpMethod == "POST"
                ? .init(status: 200, body: #"{"session_id":"devin-0a1b2c3d","url":"\#(sessionURL)","is_new_session":true}"#)
                : .init(status: 200, body: sessionBody(status: "working"))
        }
        let accounts = [Account(name: "org-a", host: "start2-a.example"), Account(name: "org-b", host: "start2-b.example")]
        let w = try await world(accounts: accounts, link: false, reply)
        let request = DevinStartRequest(prompt: "p", maxAcuLimit: 5, taskNumber: w.task.number)
        await #expect(throws: DevinError.ambiguousAccount(["org-a", "org-b"])) { try await w.sync.start(request) }
        var named = request
        named.account = "org-z"
        await #expect(throws: DevinError.unknownAccount("org-z", ["org-a", "org-b"])) { try await w.sync.start(named) }
        named.account = "org-b"
        #expect(try await w.sync.start(named).account == "org-b")
        #expect(try await w.restarted().start(request).account == "org-b")

        let mapped = try await world(
            accounts: [Account(name: "org-a", host: "start3-a.example"), Account(name: "org-b", host: "start3-b.example", boards: ["a"])], link: false, reply)
        #expect(try await mapped.sync.start(DevinStartRequest(prompt: "p", maxAcuLimit: 5, taskNumber: mapped.task.number)).account == "org-b")
    }
}
