// ui-copy:ignore-file
// このファイルの文（PR の取得の失敗の文（アカウントの error））は、MCP の応答・保存される状態・ログに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation
import Logging
import TaskboardKit

/// このマシンの gh にログインしているアカウントごとに、PR を 4 区分で取って state に載せる。
///
/// - 間隔は 5 分。アプリの「更新」（`refresh`）で即時に。rate limit の待ちは `GitHubCLI` がリンク（`GitHubSync`）と共有して持ち、
///   どちらで当たっても、明けるまで手動の更新でも取らない（明けるのが 5 分より早くても 5 分は空ける）
/// - 前回との差（CI・レビューの変化、新しいレビュー依頼）を `PRNotice` にして 24 時間持つ
/// - 最後に取れた一覧は SQLite に残し、起動直後や VPN が切れている間もそれを見せる
public actor PullRequestSync {
    public static let interval: TimeInterval = 300
    static let detailTTL: TimeInterval = 60

    private let store: Store
    private let state: DaemonState
    private let cli: GitHubCLI
    private let machine: MachineID
    private let logger = Logger(label: "uk.whatn.taskboardd.prs")
    private let now: @Sendable () -> Date

    private struct AccountState {
        var status: PRAccountStatus
        /// nil = まだ取っていない（初回の差分は知らせない）
        var pullRequests: [PullRequestSummary]?
        var cached: [PullRequestSummary] = []
    }

    private var accounts: [String: AccountState] = [:]
    private var notices: [PRNotice] = []
    private var details: [String: PullRequestDetail] = [:]
    private var refreshing = false
    private var lastLogins: Set<String> = []

    public init(store: Store, state: DaemonState, cli: GitHubCLI, machine: MachineID, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.state = state
        self.cli = cli
        self.machine = machine
        self.now = now
    }

    /// 保存してある一覧を先に配る（起動直後の空の画面を避ける）
    public func loadCache() async {
        do {
            for cached in try store.cachedPullRequests() {
                let key = "\(cached.host)|\(cached.login)"
                accounts[key] = AccountState(
                    status: PRAccountStatus(host: cached.host, account: cached.login, fetchedAt: cached.fetchedAt), pullRequests: nil,
                    cached: cached.pullRequests.map { var pr = $0; pr.machine = machine; return pr })
            }
            if !accounts.isEmpty { await publish() }
        } catch {
            logger.warning("pr cache unreadable", metadata: ["error": .string(String(describing: error))])
        }
    }

    public func run() async {
        guard cli.executable != nil else {
            logger.warning("gh not found in PATH; PR list is off")
            return
        }
        while !Task.isCancelled {
            await refresh(force: false)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    /// 期限が来たアカウントを取り直す。`force` は rate limit 以外の待ちを無視する（アプリの「更新」）
    @discardableResult
    public func refresh(force: Bool) async -> PRSnapshot {
        guard !refreshing else { return snapshot() }
        refreshing = true
        defer { refreshing = false }
        // 読めない・確かめが時間切れのアカウントは外さず、前の一覧と控えを残す（外すと、負荷の高い間に一覧が出たり消えたりした）
        guard let listing = await cli.accountListing() else { return snapshot() }
        let logins = listing.usable
        let live = Set((listing.usable + listing.unconfirmed).map { "\($0.host)|\($0.login)" })
        if live != lastLogins {
            lastLogins = live
            logger.info("gh accounts for PR list", metadata: ["accounts": .string(live.sorted().joined(separator: ", "))])
        }
        let dropped = accounts.keys.filter { !live.contains($0) }
        for key in dropped { accounts.removeValue(forKey: key) }
        if !dropped.isEmpty || !logins.isEmpty { try? store.deleteCachedPullRequests(keeping: live) }
        var changed = !dropped.isEmpty
        for login in logins {
            let key = "\(login.host)|\(login.login)"
            var entry = accounts[key] ?? AccountState(status: PRAccountStatus(host: login.host, account: login.login))
            let due = entry.status.nextFetchAt.map { $0 <= now() } ?? true
            let limited = await cli.rateLimitedUntil(login) != nil
            guard !limited, due || force else {
                accounts[key] = entry
                continue
            }
            await fetch(login, into: &entry)
            accounts[key] = entry
            changed = true
        }
        if changed { await publish() }
        return snapshot()
    }

    private func fetch(_ account: GitHubCLI.Account, into entry: inout AccountState) async {
        let started = now()
        do {
            var results: [String: [PullRequestQueries.SearchNode]] = [:]
            for term in PullRequestQueries.searchTerms {
                let data = try await cli.graphQL(PullRequestQueries.search, variables: ["q": term.query], account: account)
                results[term.key] = try PullRequestQueries.parseSearch(data)
            }
            let prs = PullRequestQueries.classify(
                requested: results["requested"] ?? [], reviewed: results["reviewed"] ?? [], authored: results["authored"] ?? [], machine: machine,
                host: account.host, account: account.login)
            let fresh = PRNotice.diff(old: entry.pullRequests, new: prs, at: started)
            notices = (fresh + notices).filter { started.timeIntervalSince($0.at) < PRSnapshot.noticeWindow }.prefix(PRSnapshot.noticeLimit).map { $0 }
            entry.pullRequests = prs
            entry.cached = prs
            await cli.clearRateLimit(account)
            entry.status = PRAccountStatus(host: account.host, account: account.login, fetchedAt: started, nextFetchAt: started.addingTimeInterval(Self.interval))
            try? store.savePullRequests(host: account.host, login: account.login, prs, fetchedAt: started)
            for pr in prs { details.removeValue(forKey: pr.url) }
        } catch {
            let rateLimited = (error as? GitHubCLI.Failure)?.isRateLimit == true || (error as? PullRequestQueries.ParseError)?.isRateLimit == true
            var next = started.addingTimeInterval(Self.interval)
            if rateLimited { next = max(next, await cli.noteRateLimit(account)) }
            entry.status.error = String(describing: error).prefix(300).description
            entry.status.rateLimited = rateLimited
            entry.status.nextFetchAt = next
            logger.warning(
                "pr fetch failed",
                metadata: [
                    "host": .string(account.host), "account": .string(account.login), "rateLimited": .stringConvertible(rateLimited),
                    "retryIn": .stringConvertible(Int(next.timeIntervalSince(started))), "error": .string(entry.status.error ?? ""),
                ])
        }
    }

    /// PR の中身。URL の host / owner からアカウントを選ぶ（対応表 → その host でログインしているアカウント）
    public func detail(url: String) async throws -> PullRequestDetail {
        if let cached = details[url], now().timeIntervalSince(cached.fetchedAt) < Self.detailTTL { return cached }
        guard let host = URLComponents(string: url)?.host?.lowercased() else { throw PullRequestQueries.ParseError.notAPullRequest }
        let account: GitHubCLI.Account
        if let match = await cli.match(url: url) {
            account = GitHubCLI.Account(host: match.host, login: match.account)
        } else if let known = accounts.values.map(\.status).first(where: { $0.host == host }) {
            account = GitHubCLI.Account(host: known.host, login: known.account)
        } else if let login = await cli.loggedInAccounts().first(where: { $0.host == host }) {
            account = login
        } else {
            throw GitHubCLI.Failure.failed("\(host) にログインしている gh のアカウントが無い")
        }
        let data = try await cli.graphQL(PullRequestQueries.detail, variables: ["url": url], account: account)
        let detail = try PullRequestQueries.parseDetail(data, fetchedAt: now())
        details[url] = detail
        return detail
    }

    public func snapshot() -> PRSnapshot {
        let ordered = accounts.values.sorted { $0.status.id < $1.status.id }
        return PRSnapshot(
            accounts: ordered.map(\.status),
            pullRequests: ordered.flatMap { $0.pullRequests ?? $0.cached }.sorted { $0.updatedAt > $1.updatedAt },
            notices: notices)
    }

    private func publish() async {
        await state.setPullRequests(snapshot())
    }
}
