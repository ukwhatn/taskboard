// ui-copy:ignore-file
// このファイルの文（Devin の失敗の文（LinkStatus.error・MCP の応答））は、MCP の応答・保存される状態・ログに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation
import Logging
import TaskboardKit

/// タスクにリンクした Devin のセッション（`DevinSession`）を Devin の API（v1）で取る。
///
/// - 対象は終端列以外のタスクのリンク。60 秒ごと。終わった・期限が切れたセッションは 10 分ごと（メッセージを送ると動き直すため、取るのはやめない）
/// - 様子は `DaemonState` のリンクの状態（カードのチップ）に入れ、前の様子（`taskLinkSnapshot`）と比べてリンクの知らせにする（`Store.recordDevinSnapshot`）。
///   返答を待ち始めた・PR を出した・終わった・期限が切れた。届けるのは `LinkNotices`（lead へ。止まった会話も起こす）
/// - 出した PR はタスクにリンクする（`Store.linkIfUnlinked`。ほかのタスクにあれば足さない）
/// - アカウント（org ごとのトークン）は `devin.json` に並べる。セッションの URL では org が分からないので、前に通ったアカウント（リンクの様子に残す） → タスクの案件に割り当てたアカウント → 残り、の順に試す
/// - 401 はそのアカウントを 30 分使わない。429 は `Retry-After`（無ければ 5 分）あける
/// - `devin.json` が無ければ何もしない（置かれたら次の回から取る）
public actor DevinSync {
    static let refreshInterval: Duration = .seconds(60)
    static let unauthorizedInterval: TimeInterval = 1800
    static let rateLimitedInterval: Duration = .seconds(300)
    static let settledInterval: TimeInterval = 600

    private let store: Store
    private let state: DaemonState
    private let configFile: URL
    private let session: URLSession
    private let home: String
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.whatn.taskboardd.devin")
    private var reportedMissing = false
    private var lastFetched: [String: Date] = [:]
    private var settled: Set<String> = []
    /// セッションの id → 通ったアカウントの名前
    private var known: [String: String] = [:]
    /// 401 を返したアカウント → 次に使ってよい時刻
    private var rejected: [String: Date] = [:]
    private var noticeHandler: (@Sendable ([Int]) async -> Void)?

    public init(
        store: Store, state: DaemonState, configFile: URL, session: URLSession = .shared,
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) {
        self.init(store: store, state: state, configFile: configFile, session: session, home: home, now: { Date() })
    }

    init(store: Store, state: DaemonState, configFile: URL, session: URLSession, home: String, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.state = state
        self.configFile = configFile
        self.session = session
        self.home = home
        self.now = now
    }

    /// 知らせを足したタスクの番号を受ける（`LinkNotices`）
    func onNotices(_ handler: @escaping @Sendable ([Int]) async -> Void) { noticeHandler = handler }

    public func run() async {
        while !Task.isCancelled {
            let wait = await refresh()
            try? await Task.sleep(for: wait)
        }
    }

    struct Connection: Sendable {
        var name: String
        var boards: Set<String>
        var client: DevinClient
    }

    /// devin.json の各アカウントの接続。トークンを読めないアカウントは除く。1 つも使えなければ理由を投げる（`devin_*` の tool が返す）
    func connections() throws(DevinError) -> [Connection] {
        let config: DevinConfig
        do {
            guard let loaded = try DevinConfig.load(from: configFile) else { throw DevinError.notConfigured }
            config = loaded
        } catch let error as DevinError {
            throw error
        } catch {
            throw .unreadableConfig
        }
        var result: [Connection] = []
        for account in config.accounts {
            guard let token = account.readToken(home: home) else {
                logger.warning("devin token file is unreadable or empty", metadata: ["account": .string(account.name)])
                continue
            }
            guard let base = URL(string: account.apiBase ?? DevinConfig.defaultAPIBase) else { throw .unreadableConfig }
            result.append(Connection(name: account.name, boards: Set(account.boards ?? []), client: DevinClient(apiBase: base, token: token, session: session)))
        }
        guard !result.isEmpty else { throw config.accounts.isEmpty ? .unreadableConfig : .unreadableToken }
        return result
    }

    /// 試す順：前に通ったアカウント、`boards`（案件の id か名前）に割り当てたアカウント、残り。401 を返して 30 分経っていないものは除く
    private func ordered(_ connections: [Connection], id: String, boards: Set<String>) -> [Connection] {
        let at = now()
        let usable = connections.filter { (rejected[$0.name] ?? .distantPast) <= at }
        func rank(_ c: Connection) -> Int { c.name == known[id] ? 0 : c.boards.isDisjoint(with: boards) ? 2 : 1 }
        return usable.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// `id` のセッションに順に試す。見つからない・401 なら次のアカウントへ。どれも通らなければ、見つからなかったか 401 を投げる
    private func call<T: Sendable>(
        _ connections: [Connection], id: String, boards: Set<String>, _ body: (DevinClient) async throws(DevinError) -> T
    ) async throws(DevinError) -> (T, String) {
        var failure = DevinError.unauthorized
        for connection in ordered(connections, id: id, boards: boards) {
            do {
                let value = try await body(connection.client)
                known[id] = connection.name
                return (value, connection.name)
            } catch .notFound {
                failure = .notFound
            } catch .unauthorized {
                rejected[connection.name] = now().addingTimeInterval(Self.unauthorizedInterval)
                logger.warning("devin token rejected", metadata: ["account": .string(connection.name)])
            }
        }
        throw failure
    }

    /// 1 回分。次の回までの待ち時間を返す
    func refresh(force: Bool = false) async -> Duration {
        let targets: [String: Target]
        do {
            targets = try Self.targets(tasks: store.tasks(), boards: store.boards())
            for (url, account) in try store.devinAccounts() {
                if let id = DevinSession.id(fromURL: url), known[id] == nil { known[id] = account }
            }
        } catch {
            logger.warning("devin sync failed", metadata: ["error": .string(String(describing: error))])
            return Self.refreshInterval
        }
        guard !targets.isEmpty else { return Self.refreshInterval }
        let connections: [Connection]
        do {
            connections = try self.connections()
            reportedMissing = false
        } catch .notConfigured {
            if !reportedMissing {
                logger.info("devin.json not found; Devin session sync is off", metadata: ["path": .string(configFile.path)])
                reportedMissing = true
            }
            return Self.refreshInterval
        } catch {
            await state.record(links: targets.mapValues { _ in .failed(error.message) })
            return Self.refreshInterval
        }
        var results: [String: DaemonState.LinkFetch] = [:]
        var touched: Set<Int> = []
        var wait = Self.refreshInterval
        for (url, target) in targets.sorted(by: { $0.key < $1.key }) {
            guard let id = DevinSession.id(fromURL: url) else { continue }
            if !force, settled.contains(url), let last = lastFetched[url], now().timeIntervalSince(last) < Self.settledInterval { continue }
            do {
                let (state, numbers) = try await fetch(url: url, id: id, target: target, connections: connections)
                results[url] = .devin(state)
                touched.formUnion(numbers)
            } catch let error as DevinError {
                results[url] = .failed(error.message)
                if case .rateLimited(let retryAfter) = error {
                    wait = retryAfter ?? Self.rateLimitedInterval
                    break
                }
            } catch {
                logger.warning("devin snapshot not recorded", metadata: ["url": .string(url), "error": .string(String(describing: error))])
            }
        }
        await state.record(links: results)
        if !touched.isEmpty { await noticeHandler?(touched.sorted()) }
        return wait
    }

    /// 1 本取って、前の様子と比べて知らせを足し、出した PR をタスクにリンクする。知らせを足したタスクの番号も返す
    private func fetch(url: String, id: String, target: Target, connections: [Connection]) async throws -> (DevinLinkState, [Int]) {
        let start = now()
        let (response, account) = try await call(connections, id: id, boards: target.boards) { client throws(DevinError) in try await client.session(id) }
        let snapshot = DevinSnapshot(response, account: account)
        lastFetched[url] = start
        if [.finished, .expired].contains(snapshot.state.phase) { settled.insert(url) } else { settled.remove(url) }
        let numbers = try store.recordDevinSnapshot(url: url, snapshot: snapshot, tasks: target.tasks, at: start)
        if let pr = snapshot.state.pullRequestURL, TaskLink.kind(of: pr) == .githubPR {
            for number in target.tasks.sorted() {
                if case .linked = try store.linkIfUnlinked(task: number, url: pr) {
                    logger.info("devin pull request linked", metadata: ["task": .stringConvertible(number), "url": .string(pr)])
                }
            }
        }
        return (snapshot.state, numbers)
    }

    /// 作るアカウント：名前を渡せばそれ、無ければタスクの Devin のセッションで通った 1 つ、タスクの案件に割り当てた 1 つ、アカウントが 1 つならそれ
    private func account(for request: DevinStartRequest, in connections: [Connection]) throws -> Connection {
        let names = connections.map(\.name)
        if let name = request.account, !name.isEmpty {
            guard let found = connections.first(where: { $0.name == name }) else { throw DevinError.unknownAccount(name, names) }
            return found
        }
        if let number = request.taskNumber, let task = try store.task(number: number) {
            let used = Set(try store.devinAccounts(task: number).values)
            let previous = connections.filter { used.contains($0.name) }
            if previous.count == 1 { return previous[0] }
            let keys = try store.boards().keys(of: task.boardID)
            let matched = connections.filter { !$0.boards.isDisjoint(with: keys) }
            if matched.count == 1 { return matched[0] }
        }
        guard connections.count == 1 else { throw DevinError.ambiguousAccount(names) }
        return connections[0]
    }

    /// `POST /v1/devin/sessions`：作って、`taskNumber` のタスクにリンクし、元の様子を取る（作った直後の様子では知らせない）
    func start(_ request: DevinStartRequest) async throws -> DevinStarted {
        let connections = try self.connections()
        let connection = try account(for: request, in: connections)
        let created = try await connection.client.create(request)
        guard let id = DevinSession.id(from: created.session_id) else { throw DevinError.malformed }
        known[id] = connection.name
        var link: AutoLinkResult?
        if let number = request.taskNumber {
            link = try store.linkIfUnlinked(task: number, url: created.url)
            let target = Target(tasks: [number], boards: [])
            if let (state, numbers) = try? await fetch(url: created.url, id: id, target: target, connections: [connection]) {
                await self.state.record(links: [created.url: .devin(state)])
                if !numbers.isEmpty { await noticeHandler?(numbers) }
            }
        }
        return DevinStarted(sessionID: id, url: created.url, existing: created.is_new_session == false, link: link, account: connection.name)
    }

    static let detailMessages = 20
    static let messageLimit = 4000

    /// `GET /v1/devin/sessions/{id}`：様子と、新しい `detailMessages` 件の発言（1 件 `messageLimit` 字まで）
    func detail(_ id: String) async throws -> DevinSessionDetail {
        let (response, account) = try await call(try connections(), id: id, boards: []) { client throws(DevinError) in try await client.session(id) }
        let messages = response.messages ?? []
        let shown = messages.suffix(Self.detailMessages).map { message in
            let text = message.message ?? ""
            return DevinSessionDetail.Message(
                type: message.type ?? "", text: String(text.prefix(Self.messageLimit)), at: message.timestamp, clipped: text.count > Self.messageLimit)
        }
        return DevinSessionDetail(
            sessionID: id, url: nil, state: DevinSnapshot(response).state, messages: Array(shown), omitted: messages.count - shown.count, account: account)
    }

    /// `POST /v1/devin/sessions/{id}/message`。アカウントがまだ分からなければ、先に様子を取って決める（違う org に送って断られた理由を返さないため）
    func message(_ id: String, _ text: String) async throws -> DevinMessageSent {
        let connections = try self.connections()
        if known[id] == nil, connections.count > 1 { _ = try await call(connections, id: id, boards: []) { client throws(DevinError) in try await client.session(id) } }
        let (refused, _) = try await call(connections, id: id, boards: []) { client throws(DevinError) in try await client.message(id, text) }
        return DevinMessageSent(refused: refused)
    }

    struct Target: Equatable, Sendable {
        var tasks: Set<Int>
        /// タスクの案件の id と名前（アカウントの `boards` と比べる）
        var boards: Set<String>
    }

    /// 終端列以外のタスクの Devin のセッションのリンク
    static func targets(tasks: [BoardTask], boards: [Board]) -> [String: Target] {
        var result: [String: Target] = [:]
        for task in tasks {
            guard let column = boards.first(where: { $0.id == task.boardID })?.columns.first(where: { $0.id == task.columnID }),
                column.kind != .terminal
            else { continue }
            for link in task.links where DevinSession.id(fromURL: link.url) != nil {
                result[link.url, default: Target(tasks: [], boards: [])].tasks.insert(task.number)
                result[link.url]?.boards.formUnion(boards.keys(of: task.boardID))
            }
        }
        return result
    }
}

/// `devin.json`: `{"accounts": [{"name": "das", "tokenFile": "~/path/.env.local", "tokenVariable": "DEVIN_API_KEY", "boards": ["DAS"]}]}`。
/// アカウントは org ごと。`tokenVariable` があれば、ファイルの `NAME=value` の行から読む（無ければファイル全体がトークン）。
/// `boards` は、そのアカウントを先に試す案件（id か名前）。`apiBase` は省ける
struct DevinConfig: Decodable, Equatable {
    static let defaultAPIBase = "https://api.devin.ai"

    struct Account: Decodable, Equatable {
        var name: String
        var tokenFile: String
        var tokenVariable: String?
        var apiBase: String?
        var boards: [String]?

        /// 先頭の `~/` は HOME に。読めない・空・変数の行が無ければ nil
        func readToken(home: String) -> String? { SecretFile.read(tokenFile, variable: tokenVariable, home: home) }
    }

    var accounts: [Account]

    /// ファイルが無ければ nil
    static func load(from url: URL) throws -> DevinConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DevinConfig.self, from: Data(contentsOf: url))
    }
}

/// 失敗の理由。文面にトークン・認証ヘッダ・応答の本文を含めない
enum DevinError: Error, Equatable {
    case notConfigured
    case unreadableConfig
    case unreadableToken
    case unauthorized
    case notFound
    case rateLimited(retryAfter: Duration?)
    case status(Int)
    case transport
    case malformed
    case unknownAccount(String, [String])
    case ambiguousAccount([String])

    static func message(_ reason: String) -> String { "Devin に接続できません: \(reason)" }

    var message: String {
        switch self {
        case .notConfigured: Self.message("devin.json がありません")
        case .unreadableConfig: Self.message("devin.json を読めません")
        case .unreadableToken: Self.message("トークンのファイルを読めません")
        case .unauthorized: Self.message("トークンが無効か期限切れです")
        case .notFound: Self.message("セッションが見つかりません")
        case .rateLimited: Self.message("リクエストが多すぎるため、しばらく待ってから取り直します")
        case .status(let code): Self.message("HTTP \(code)")
        case .transport: Self.message("通信に失敗しました")
        case .malformed: Self.message("応答を読めません")
        case .unknownAccount(let name, let names): "Devin のアカウント \(name) は devin.json に無い（あるのは \(names.joined(separator: "・"))）"
        case .ambiguousAccount(let names): "Devin のアカウントを決められない。account に \(names.joined(separator: "・")) のどれかを渡す（そのタスクの次の起動からは、通ったアカウントを使う）"
        }
    }
}

/// `GET /v1/sessions/{id}` の応答のうち使う欄
struct DevinSessionResponse: Decodable, Sendable {
    struct PullRequest: Decodable, Sendable { var url: String? }
    struct Message: Decodable, Sendable {
        var type: String?
        var message: String?
        var timestamp: String?
    }

    var session_id: String
    var status_enum: String?
    var status: String?
    var title: String?
    var pull_request: PullRequest?
    var messages: [Message]?
}

/// 比べるための様子。`taskLinkSnapshot` に JSON で置く
struct DevinSnapshot: Codable, Equatable, Sendable {
    var state: DevinLinkState
    /// Devin の発言の数（返答を待ったまま、また発言したかを見る）
    var devinMessages: Int
    /// 通ったアカウントの名前（daemon を起動し直した後の試す順と、そのタスクで起動するときの既定）
    var account: String?

    init(state: DevinLinkState, devinMessages: Int = 0, account: String? = nil) {
        self.state = state
        self.devinMessages = devinMessages
        self.account = account
    }

    init(_ response: DevinSessionResponse, account: String? = nil) {
        let pr = response.pull_request?.url.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            state: DevinLinkState(status: response.status_enum ?? response.status ?? "unknown", title: response.title ?? "", pullRequestURL: pr),
            devinMessages: (response.messages ?? []).filter { $0.type == "devin_message" }.count, account: account)
    }

    /// 前の様子からの動き。Devin の発言は載せない（外から来た文が人の発言としてセッションに入るため。lead は devin_get で読む）
    static func notices(url: String, old: DevinSnapshot, new: DevinSnapshot) -> [LinkNotice] {
        var notices: [LinkNotice] = []
        if let pr = new.state.pullRequestURL, pr != old.state.pullRequestURL {
            notices.append(LinkNotice(kind: .devinPullRequest, url: url, targetURL: pr))
        }
        switch new.state.phase {
        case .waiting where old.state.phase != .waiting || new.devinMessages > old.devinMessages:
            notices.append(LinkNotice(kind: .devinWaiting, url: url))
        case .finished where old.state.phase != .finished:
            notices.append(LinkNotice(kind: .devinFinished, url: url))
        case .expired where old.state.phase != .expired:
            notices.append(LinkNotice(kind: .devinExpired, url: url))
        default:
            break
        }
        return notices
    }
}

struct DevinClient: Sendable {
    var apiBase: URL
    var token: String
    var session: URLSession

    func session(_ id: String) async throws(DevinError) -> DevinSessionResponse {
        let data = try await send("GET", "/v1/sessions/" + DevinSession.apiID(id), body: nil)
        guard let response = try? JSONDecoder().decode(DevinSessionResponse.self, from: data) else { throw .malformed }
        return response
    }

    struct Created: Decodable {
        var session_id: String
        var url: String
        var is_new_session: Bool?
    }

    /// 同じプロンプトのセッションが既にあれば、それを返す（`idempotent`）
    func create(_ request: DevinStartRequest) async throws(DevinError) -> Created {
        var body: [String: Any] = ["prompt": request.prompt, "max_acu_limit": request.maxAcuLimit, "idempotent": true]
        if let title = request.title, !title.isEmpty { body["title"] = title }
        if !request.tags.isEmpty { body["tags"] = request.tags }
        let data = try await send("POST", "/v1/sessions", body: body)
        guard let created = try? JSONDecoder().decode(Created.self, from: data) else { throw .malformed }
        return created
    }

    /// 届かなければ Devin の理由（`detail`）を返す
    func message(_ id: String, _ text: String) async throws(DevinError) -> String? {
        let data = try await send("POST", "/v1/sessions/\(DevinSession.apiID(id))/message", body: ["message": text], refusalOK: true)
        struct Refusal: Decodable { var detail: String? }
        return (try? JSONDecoder().decode(Refusal.self, from: data))?.detail
    }

    /// `refusalOK` なら 400・409・422 の本文も返す（Devin が届かなかった理由を `detail` で返す）
    private func send(_ method: String, _ path: String, body: [String: Any]?, refusalOK: Bool = false) async throws(DevinError) -> Data {
        var request = URLRequest(url: apiBase.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .transport
        }
        guard let http = response as? HTTPURLResponse else { throw .transport }
        switch http.statusCode {
        case 200..<300: return data
        case 400, 409, 422 where refusalOK: return data
        case 401, 403: throw .unauthorized
        case 404: throw .notFound
        case 429: throw .rateLimited(retryAfter: JiraClient.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default: throw .status(http.statusCode)
        }
    }
}
