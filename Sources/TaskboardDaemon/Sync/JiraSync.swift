// ui-copy:ignore-file
// このファイルの文（Jira の失敗の文（LinkStatus.error））は、MCP の応答・保存される状態・ログに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation
import Logging
import TaskboardKit

/// タスクに付いた Jira 課題の状態を Jira Cloud REST v3 で取り、`DaemonState` のリンクの状態に入れる。
///
/// - 対象は終端列以外のタスクの `kind == .jira` のリンク。5 分ごとに全件
/// - 429 は `Retry-After`（無ければ 5 分）だけ、401 は 30 分あける
/// - 接続先は `jira.json`。無ければ何もしない（置かれたら次の回から取る）
public actor JiraSync {
    public static let refreshInterval: Duration = .seconds(300)
    public static let unauthorizedInterval: Duration = .seconds(1800)

    private let store: Store
    private let state: DaemonState
    private let configFile: URL
    private let session: URLSession
    private let home: String
    private let logger = Logger(label: "uk.whatn.taskboardd.jira")
    private var reportedMissing = false
    private var reportedTokenFailure = false

    public init(
        store: Store, state: DaemonState, configFile: URL, session: URLSession = .shared,
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) {
        self.store = store
        self.state = state
        self.configFile = configFile
        self.session = session
        self.home = home
    }

    public func run() async {
        while !Task.isCancelled {
            let wait = await refresh()
            try? await Task.sleep(for: wait)
        }
    }

    /// 1 回分。次の回までの待ち時間を返す
    func refresh() async -> Duration {
        guard let config = loadConfig() else { return Self.refreshInterval }
        let targets: [String: String]
        do {
            targets = try Self.targets(tasks: store.tasks(), boards: store.boards())
        } catch {
            logger.warning("jira sync failed", metadata: ["error": .string(String(describing: error))])
            return Self.refreshInterval
        }
        guard !targets.isEmpty else { return Self.refreshInterval }
        guard let token = config.readToken(home: home) else {
            if !reportedTokenFailure {
                logger.warning("jira token file is unreadable or empty", metadata: ["path": .string(config.tokenFile)])
                reportedTokenFailure = true
            }
            await state.record(links: targets.mapValues { _ in .failed(JiraError.message("トークンのファイルを読めません")) })
            return Self.refreshInterval
        }
        reportedTokenFailure = false
        let client = JiraClient(site: config.site, email: config.email, token: token, session: session)
        let round = await Self.round(client: client, targets: targets)
        await state.record(links: round.results)
        return round.wait
    }

    private func loadConfig() -> JiraConfig? {
        do {
            guard let config = try JiraConfig.load(from: configFile) else {
                if !reportedMissing {
                    logger.info("jira.json not found; Jira status sync is off", metadata: ["path": .string(configFile.path)])
                    reportedMissing = true
                }
                return nil
            }
            reportedMissing = false
            return config
        } catch {
            logger.warning("jira.json is unreadable", metadata: ["path": .string(configFile.path)])
            return nil
        }
    }

    /// 終端列以外のタスクの Jira リンク（URL → 課題キー）
    static func targets(tasks: [BoardTask], boards: [Board]) -> [String: String] {
        var result: [String: String] = [:]
        for task in tasks {
            guard let column = boards.first(where: { $0.id == task.boardID })?.columns.first(where: { $0.id == task.columnID }),
                column.kind != .terminal
            else { continue }
            for link in task.links where link.kind == .jira {
                if let key = JiraIssueKey.extract(from: link.url) { result[link.url] = key }
            }
        }
        return result
    }

    struct Round: Sendable {
        var results: [String: DaemonState.LinkFetch]
        var wait: Duration
    }

    /// 全件を順に取る。401 は全件に同じ理由を入れて止め、429 はそこで止める（残りは前回の値のまま）
    static func round(client: JiraClient, targets: [String: String]) async -> Round {
        var results: [String: DaemonState.LinkFetch] = [:]
        for (url, key) in targets.sorted(by: { $0.key < $1.key }) {
            do {
                results[url] = .jira(try await client.issue(key))
            } catch .unauthorized {
                for url in targets.keys { results[url] = .failed(JiraError.unauthorized.message) }
                return Round(results: results, wait: unauthorizedInterval)
            } catch .rateLimited(let retryAfter) {
                results[url] = .failed(JiraError.rateLimited(retryAfter: retryAfter).message)
                return Round(results: results, wait: retryAfter ?? refreshInterval)
            } catch {
                results[url] = .failed(error.message)
            }
        }
        return Round(results: results, wait: refreshInterval)
    }
}

/// `jira.json`: `{"site": "example.atlassian.net", "email": "...", "tokenFile": "~/path/to/token"}`
struct JiraConfig: Decodable, Equatable {
    var site: String
    var email: String
    var tokenFile: String

    /// ファイルが無ければ nil
    static func load(from url: URL) throws -> JiraConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(JiraConfig.self, from: Data(contentsOf: url))
    }

    /// 先頭の `~/` は HOME に。前後の空白と改行は落とす。読めない・空なら nil
    func readToken(home: String) -> String? { SecretFile.read(tokenFile, home: home) }
}

enum JiraIssueKey {
    /// `/browse/<KEY>` か `selectedIssue=<KEY>`。どちらも無ければ nil
    static func extract(from url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "browse"), index + 1 < parts.count, isKey(parts[index + 1]) { return parts[index + 1] }
        if let selected = components.queryItems?.first(where: { $0.name == "selectedIssue" })?.value, isKey(selected) { return selected }
        return nil
    }

    static func isKey(_ text: String) -> Bool { text.wholeMatch(of: /[A-Z][A-Z0-9_]+-[0-9]+/) != nil }
}

/// 失敗の理由。文面にトークン・認証ヘッダを含めない（含めうる応答本文も載せない）
enum JiraError: Error, Equatable {
    case unauthorized
    case rateLimited(retryAfter: Duration?)
    case status(Int)
    case transport
    case malformed

    static func message(_ reason: String) -> String { "Jira に接続できません: \(reason)" }

    var message: String {
        switch self {
        case .unauthorized: Self.message("トークンが無効か期限切れです")
        case .rateLimited: Self.message("リクエストが多すぎるため、しばらく待ってから取り直します")
        case .status(let code): Self.message("HTTP \(code)")
        case .transport: Self.message("通信に失敗しました")
        case .malformed: Self.message("応答を読めません")
        }
    }
}

struct JiraClient: Sendable {
    var site: String
    var email: String
    var token: String
    var session: URLSession

    func issue(_ key: String) async throws(JiraError) -> JiraLinkState {
        guard let url = endpoint(key) else { throw .malformed }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic " + Data("\(email):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .transport
        }
        guard let http = response as? HTTPURLResponse else { throw .transport }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw .unauthorized
        case 429: throw .rateLimited(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default: throw .status(http.statusCode)
        }
        guard let issue = try? JSONDecoder().decode(IssueResponse.self, from: data) else { throw .malformed }
        return JiraLinkState(
            key: key, statusName: issue.fields.status.name, category: issue.fields.status.statusCategory.key, summary: issue.fields.summary ?? "")
    }

    /// site は host だけ（`example.atlassian.net`）。scheme 付きならそのまま使う
    private func endpoint(_ key: String) -> URL? {
        let base = site.contains("://") ? site : "https://" + site
        var components = URLComponents(string: base.hasSuffix("/") ? String(base.dropLast()) : base)
        components?.path = "/rest/api/3/issue/\(key)"
        components?.queryItems = [URLQueryItem(name: "fields", value: "summary,status,updated")]
        return components?.url
    }

    /// 秒数の形だけを読む（HTTP-date の形は Jira の API では使われないので無いものとして扱う）
    static func retryAfter(_ value: String?) -> Duration? {
        guard let value, let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return .seconds(seconds)
    }

    private struct IssueResponse: Decodable {
        struct Fields: Decodable {
            struct Status: Decodable {
                struct Category: Decodable { var key: JiraLinkState.Category }
                var name: String
                var statusCategory: Category
            }
            var summary: String?
            var status: Status
        }
        var fields: Fields
    }
}
