// ui-copy:ignore-file
// このファイルの文（gh の失敗の文）は、MCP の応答・保存される状態・ログに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation
import Logging

/// `gh` の呼び出し口。アカウントの token を `gh auth token --user` で取ってメモリにだけ持ち、子プロセスの環境変数だけに渡す。
/// 失敗の文面からは token を消してから投げる（gh や GitHub が stderr に何を書くかは制御できない）。
/// gh が名乗るアカウント（`identity`）と rate limit の待ちもここに持ち、PR の一覧（`PullRequestSync`）とリンク（`GitHubSync`）が同じものを読む
public actor GitHubCLI {
    /// rate limit の初めの待ち。当たるたびに倍にする
    static let firstRateLimitWait: TimeInterval = 120
    static let maxRateLimitWait: TimeInterval = 3600
    /// ホストの既定のアカウントを `gh auth status` で引き直すまで（`gh auth switch` で替わる）
    static let identityLifetime: TimeInterval = 600

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notInstalled
        /// gh が 0 以外で終わった。文面は token を伏せたもの
        case failed(String)

        public var description: String {
            switch self {
            case .notInstalled: "gh が見つからない"
            case .failed(let message): message
            }
        }

        /// GitHub の rate limit（REST の 403 / 429、GraphQL の RATE_LIMITED）
        public var isRateLimit: Bool {
            guard case .failed(let message) = self else { return false }
            let lower = message.lowercased()
            return lower.contains("rate limit") || lower.contains("rate_limited") || lower.contains("http 429")
        }
    }

    public struct Account: Hashable, Sendable {
        public var host: String
        public var login: String

        public init(host: String, login: String) {
            self.host = host
            self.login = login
        }
    }

    public let executable: URL?
    private let baseEnvironment: [String: String]
    private let accountsFile: URL?
    private(set) var accounts = GitHubAccounts()
    /// `host|login` → token
    private var tokens: [String: String] = [:]
    private var tokenFailures: Set<String> = []
    /// host → 既定（active）の login と、引いた時刻
    private var activeLogins: (logins: [String: String], at: Date)?
    private var rateLimits: [Account: (wait: TimeInterval, until: Date)] = [:]
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.whatn.taskboardd.github")

    public init(
        accountsFile: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, executable: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountsFile = accountsFile
        baseEnvironment = environment
        self.executable = executable ?? Self.resolve(environment: environment)
        self.now = now
        if let accountsFile { accounts = GitHubAccounts.load(from: accountsFile) }
    }

    static func resolve(environment: [String: String]) -> URL? {
        let path = environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { String($0) + "/gh" } + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// 対応表を読み直す（import や手編集の後に daemon を再起動しなくてよい）。変わったら token も取り直す
    public func reloadAccounts() {
        guard let accountsFile else { return }
        let loaded = GitHubAccounts.load(from: accountsFile)
        if loaded != accounts {
            accounts = loaded
            tokens.removeAll()
            tokenFailures.removeAll()
            logger.info("github accounts reloaded", metadata: ["entries": .stringConvertible(loaded.mapping.count)])
        }
    }

    public func match(url: String) -> GitHubAccounts.Match? { accounts.match(url: url) }
    public func match(remote: String) -> GitHubAccounts.Match? { accounts.match(remote: remote) }

    /// このマシンの gh にログインできているアカウント（`gh auth status --json hosts` の state が success のもの）
    public func loggedInAccounts() async -> [Account] {
        await accountListing()?.usable ?? []
    }

    /// gh に載っているアカウント。`usable` は token を確かめられたもの、`unconfirmed` は確かめが時間切れになったもの
    /// （gh はネットで token を確かめるので、負荷やネットの遅さで timeout になる。ログアウトではない）。auth status を読めなければ nil
    public func accountListing() async -> (usable: [Account], unconfirmed: [Account])? {
        guard let status = await authStatus() else { return nil }
        func accounts(_ state: String) -> [Account] {
            status.hosts.flatMap { host, entries in entries.filter { $0.state == state }.map { Account(host: host, login: $0.login) } }
                .sorted { ($0.host, $0.login) < ($1.host, $1.login) }
        }
        return (accounts("success"), accounts("timeout"))
    }

    /// gh を `account` で呼んだときに実際に名乗るアカウント。対応表のアカウントの token が取れればそれ、
    /// 取れないか `account` が nil なら、その host の gh の既定のアカウント（`auth status` の active）。分からなければ nil
    public func identity(_ account: Account?, host: String) async -> Account? {
        if let account, await environment(for: account) != nil { return account }
        if activeLogins.map({ now().timeIntervalSince($0.at) >= Self.identityLifetime }) ?? true { _ = await authStatus() }
        return activeLogins?.logins[host].map { Account(host: host, login: $0) }
    }

    /// 引くたびに既定のアカウントも覚え直す。引けなければ忘れる（前の login で自分を見分けない）
    private func authStatus() async -> AuthStatus? {
        guard let executable,
            let out = try? await Subprocess.run(executable, ["auth", "status", "--json", "hosts"], environment: baseEnvironment),
            let status = try? JSONDecoder().decode(AuthStatus.self, from: Data(out.utf8))
        else {
            activeLogins = nil
            return nil
        }
        var logins: [String: String] = [:]
        for (host, entries) in status.hosts {
            if let active = entries.first(where: { $0.active == true }) { logins[host] = active.login }
        }
        activeLogins = (logins, now())
        return status
    }

    private struct AuthStatus: Decodable {
        struct Entry: Decodable {
            var login: String
            var state: String
            var active: Bool?
        }
        var hosts: [String: [Entry]]
    }

    // MARK: rate limit

    /// 待ちが明ける時刻。待っていなければ nil
    public func rateLimitedUntil(_ account: Account) -> Date? {
        guard let limit = rateLimits[account], now() < limit.until else { return nil }
        return limit.until
    }

    /// rate limit に当たった。待ちを倍にして（初めは 2 分、1 時間まで）明ける時刻を返す
    @discardableResult
    public func noteRateLimit(_ account: Account) -> Date {
        let wait = rateLimits[account].map { min($0.wait * 2, Self.maxRateLimitWait) } ?? Self.firstRateLimitWait
        let until = now().addingTimeInterval(wait)
        rateLimits[account] = (wait, until)
        logger.warning("github rate limited", metadata: ["host": .string(account.host), "account": .string(account.login), "wait": .stringConvertible(Int(wait))])
        return until
    }

    /// 呼び手の 1 回分が全部通った。待ちを初めに戻す
    public func clearRateLimit(_ account: Account) {
        rateLimits.removeValue(forKey: account)
    }

    /// `gh` を呼ぶ。`account` があればその token で、無ければ gh の既定アカウントで。
    public func run(_ arguments: [String], account: Account?, cwd: URL? = nil, timeout: Duration = .seconds(25)) async throws -> String {
        guard let executable else { throw Failure.notInstalled }
        let env = await environment(for: account)
        do {
            return try await Subprocess.run(executable, arguments, cwd: cwd, environment: env ?? baseEnvironment, timeout: timeout)
        } catch SubprocessError.commandFailed(_, let stderr) {
            throw Failure.failed(redact(stderr.isEmpty ? "gh \(arguments.first ?? "") が失敗した" : stderr))
        } catch {
            throw Failure.failed(redact(String(describing: error)))
        }
    }

    /// 対応表の `Match` から。
    public func run(_ arguments: [String], match: GitHubAccounts.Match?, cwd: URL? = nil) async throws -> String {
        try await run(arguments, account: match.map { Account(host: $0.host, login: $0.account) }, cwd: cwd)
    }

    /// GraphQL。`variables` は `-f name=value` で渡す（gh が JSON に組む）。
    public func graphQL(_ query: String, variables: [String: String], account: Account) async throws -> Data {
        var arguments = ["api", "graphql", "--hostname", account.host, "-f", "query=\(query)"]
        for (name, value) in variables.sorted(by: { $0.key < $1.key }) { arguments += ["-f", "\(name)=\(value)"] }
        let out = try await run(arguments, account: account, timeout: .seconds(40))
        return Data(out.utf8)
    }

    /// token を伏せる。取得済みの token と、`gh` の token の形（`gh[pousr]_…`、`github_pat_…`）を消す
    func redact(_ text: String) -> String {
        var result = text
        for token in tokens.values where !token.isEmpty { result = result.replacingOccurrences(of: token, with: "<token>") }
        if let pattern = try? NSRegularExpression(pattern: "(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})") {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<token>")
        }
        return result
    }

    private func environment(for account: Account?) async -> [String: String]? {
        guard let executable, let account else { return nil }
        let key = "\(account.host)|\(account.login)"
        if tokenFailures.contains(key) { return nil }
        if tokens[key] == nil {
            do {
                let out = try await Subprocess.run(executable, ["auth", "token", "--hostname", account.host, "--user", account.login], environment: baseEnvironment)
                let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { throw Failure.failed("empty token") }
                tokens[key] = token
                logger.info("github account resolved", metadata: ["host": .string(account.host), "account": .string(account.login)])
            } catch {
                tokenFailures.insert(key)
                logger.warning("gh auth token failed; falling back to gh default account", metadata: ["host": .string(account.host), "account": .string(account.login)])
                return nil
            }
        }
        var env = baseEnvironment
        env["GH_TOKEN"] = tokens[key]
        env["GH_ENTERPRISE_TOKEN"] = tokens[key]
        return env
    }
}
