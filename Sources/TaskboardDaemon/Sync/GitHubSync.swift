// ui-copy:ignore-file
// このファイルの文（リンクの状態の失敗の文（LinkStatus.error））は、MCP の応答・保存される状態・ログに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation
import Logging
import TaskboardKit

/// タスクにリンクした GitHub の PR・issue を `gh` で取る。PR の状態で列を前へ進め（taskherd-sync.py と同じ規則）、前の様子と比べてリンクの知らせを作る。
///
/// - open で draft でない PR があれば `review`、merged だけで open が無ければ案件の「マージしたら」の列（`Board.mergeTarget`。既定は `deploying`。消していれば `done`）
/// - `review_req`（他人の PR の受け口）は、紐づく PR の全部がマージかクローズになったら `done`
/// - 前進方向だけ（`BoardColumn.progressIndex` の順。表示の並びではない）。終端列（kind = terminal）・足した列・常設は触らない。進める先の列が案件に無ければ動かさない
/// - 同じ `gh pr view` で CI・レビューの状態も取り、`DaemonState` のリンクの状態に入れる。こちらは終端列以外の全列が対象
/// - 取るのは URL ごとに 1 回。間隔は open の PR と issue なら、セッションを結んだタスクのリンクは 60 秒、ほかは 180 秒。マージ・クローズしたものは 30 分。
///   rate limit に当たったら、そのアカウントは待ちを倍にしていく（`GitHubCLI` が PR の一覧と共有して持つ。1 時間まで、メモリだけ）。Stop hook からは `syncNow` で間隔を待たずに
/// - 取った様子は、その URL を結んだ全部のリンク（終端列以外のタスクのもの）の前の様子と比べ、知らせを `taskLinkNotice` に残す（`Store.recordLinkSnapshot`）。
///   自分（gh が名乗るアカウント、`GitHubCLI.identity`）のレビューとコメントは知らせない
/// - 有効な見張り（`watch`）の issue・PR も 60 秒ごとに取り、見張りの前の様子と比べて出来事を `watchEvent` に残す（`Store.recordWatchSnapshot`）。
///   リンクと同じ URL なら 1 回の取得で両方に使う
/// - repo の見張り（repo に新しく出た issue・PR）は GraphQL の search を 1 本ずつ（`RepoWatchSearch`）。間隔はアカウントごとに、
///   repo の見張りに 1 時間 500 点を使う割り振り（その回の cost × そのアカウントの repo の見張りの数）で、60 秒より短くしない。
///   残りの点が 500 を切ったら明けるまで取らない。rate limit の待ちはリンクと PR の一覧と共有する
/// - タグを待つ見張り（マージした PR が型に合うタグに入ったら知らせる）は、repo ごとにタグの一覧を GraphQL で 1 本（`TagWatch`）取り、
///   見ていない型に合うタグを `compare` で merge commit と比べる。間隔と点の割り振りは repo の見張りと同じ枠（数えるのは repo の見張りとタグの repo の和）
public actor GitHubSync {
    public static let reviewRequestColumn = "review_req"
    static let linkedInterval: TimeInterval = 60
    static let unlinkedInterval: TimeInterval = 180
    static let finishedInterval: TimeInterval = 1800
    static let branchLookupTTL: TimeInterval = 60
    /// 行のコメントを取り直す範囲を、前に取った時刻からこれだけ前に広げる（GitHub と手元の時計のずれ）
    static let inlineOverlap: TimeInterval = 600
    /// repo の見張りに使う、アカウントごとの 1 時間あたりの点（5,000 の 1 割。PR の一覧とリンクの取得の分を残す）
    static let repoBudgetPerHour: Double = 500
    /// 残りの点がこれを切ったら、明けるまで repo の見張りを取らない
    static let repoReserve = 500

    private let store: Store
    private let state: DaemonState
    private let cli: GitHubCLI
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.whatn.taskboardd.github")
    private var lastFetched: [String: Date] = [:]
    /// ブランチ（cwd とブランチ名）ごとの、最後に引いた PR と時刻
    private var branchLookups: [String: (pr: PullRequest?, at: Date)] = [:]
    /// 最後に見たときマージかクローズだった URL
    private var finished: Set<String> = []
    private var noticeHandler: (@Sendable ([Int]) async -> Void)?
    private var watchHandler: (@Sendable ([Int64]) async -> Void)?
    /// repo の見張りごとの、最後に取り始めた時刻
    private var repoFetched: [Int64: Date] = [:]
    /// アカウントごとの、repo の見張りの最後の cost と、残りが少なくて取らない期限
    private var repoCost: [GitHubCLI.Account: Int] = [:]
    private var repoPausedUntil: [GitHubCLI.Account: Date] = [:]
    /// アカウントごとの、repo の見張りの数と、タグを待つ見張りの repo の数（点の割り振りに使う）
    private var repoWatchCount: [GitHubCLI.Account: Int] = [:]
    private var tagRepoCount: [GitHubCLI.Account: Int] = [:]
    /// repo（`host/owner/name`）ごとの、タグの一覧を最後に取り始めた時刻
    private var tagsFetched: [String: Date] = [:]

    public init(store: Store, state: DaemonState, cli: GitHubCLI) {
        self.init(store: store, state: state, cli: cli, now: { Date() })
    }

    init(store: Store, state: DaemonState, cli: GitHubCLI, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.state = state
        self.cli = cli
        self.now = now
    }

    /// 知らせを足したタスクの番号を受ける（`LinkNotices`）
    func onNotices(_ handler: @escaping @Sendable ([Int]) async -> Void) { noticeHandler = handler }

    /// 出来事を足した見張りの id を受ける（`WatchNotices`）
    func onWatchEvents(_ handler: @escaping @Sendable ([Int64]) async -> Void) { watchHandler = handler }

    /// 定期巡回。gh が無ければ何もしないで寝る。
    public func run() async {
        guard cli.executable != nil else {
            logger.warning("gh not found in PATH; PR state sync is off")
            return
        }
        while !Task.isCancelled {
            await cli.reloadAccounts()
            do {
                try await sweep()
            } catch {
                logger.warning("github sync failed", metadata: ["error": .string(String(describing: error))])
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// 1 タスクを今すぐ見る（間隔を待たない）。列が動いたら新しいタスクを返す。
    /// マージかクローズを見たリンクは取り直さず、巡回の間隔に任せる（Stop hook が毎ターン呼び、リンクの多いタスクでは gh を何十回も呼んでいた）
    public func syncNow(task: BoardTask) async throws -> BoardTask? {
        await cli.reloadAccounts()
        guard cli.executable != nil, let watched = try watchedTasks().first(where: { $0.task.number == task.number }) else { return nil }
        let urls = Self.linkURLs(of: [watched]).filter { !finished.contains($0.key) }
        let fetched = try await fetch(urls: urls, tasks: [watched.task.number], force: true)
        return try await advance(watched, fetched: fetched)
    }

    /// 見張りを作った直後に、その URL を 1 回取って元の様子を記録する。gh が無ければ見張りに理由を残す
    func syncWatch(url: String) async {
        guard let kind = Store.watchURL(url)?.kind else { return }
        await cli.reloadAccounts()
        guard cli.executable != nil else {
            try? store.noteWatchFetchFailure(url: url, reason: "gh が PATH に無い", at: now())
            return
        }
        do {
            let watched = try watchedTasks()
            _ = try await fetch(urls: [url: (kind, true)], tasks: Set(watched.map(\.task.number)), force: true)
        } catch {
            logger.warning("watch not fetched", metadata: ["url": .string(url), "error": .string(String(describing: error))])
        }
        await sweepTagWatches(only: url)
    }

    /// 巡回の 1 回：間隔の来た URL を取り、取ったリンクのタスクの列を見直す
    func sweep() async throws {
        let watched = try watchedTasks()
        var urls = Self.linkURLs(of: watched)
        for url in try store.activeWatchURLs() {
            guard let kind = Store.watchURL(url)?.kind else { continue }
            urls[url] = (kind, true)
        }
        let fetched = try await fetch(urls: urls, tasks: Set(watched.map(\.task.number)), force: false)
        for entry in watched where entry.task.pullRequestLinks.contains(where: { fetched[$0.url] != nil }) {
            _ = try await advance(entry, fetched: fetched)
        }
        await sweepTagWatches()
        await sweepRepoWatches()
    }

    /// repo の見張りを作った。1 回取って元にする（間隔を待たない。rate limit の待ちと残りの点の止めは守る）
    func syncRepoWatch(id: Int64) async {
        guard cli.executable != nil else {
            try? store.noteWatchFailure(id: id, reason: "gh が PATH に無い", at: now())
            return
        }
        await sweepRepoWatches(only: id)
    }

    /// 間隔の来た repo の見張り（`only` ならそれだけを、間隔を待たずに）を取り、新しく出たものを出来事にする
    private func sweepRepoWatches(only: Int64? = nil) async {
        let rows: [Store.WatchRow]
        do {
            rows = try store.activeRepoWatches()
        } catch {
            logger.warning("repo watches not read", metadata: ["error": .string(String(describing: error))])
            return
        }
        var identities: [Int64: GitHubCLI.Account?] = [:]
        for row in rows {
            guard let id = row.id, let repo = row.repo else { continue }
            let host = row.host ?? "github.com"
            let match = await cli.match(url: "https://\(host)/\(repo)")
            identities[id] = await cli.identity(match.map { GitHubCLI.Account(host: $0.host, login: $0.account) }, host: host)
        }
        var counts: [GitHubCLI.Account: Int] = [:]
        for case let identity? in identities.values { counts[identity, default: 0] += 1 }
        if only == nil { repoWatchCount = counts }
        var touched: [Int64] = []
        for row in rows {
            guard let id = row.id, let repo = row.repo, only == nil || only == id else { continue }
            guard let identity = identities[id] ?? nil else {
                try? store.noteWatchFailure(id: id, reason: Self.noIdentity, at: now())
                continue
            }
            guard await budgetAllows(identity) else { continue }
            if only == nil, let last = repoFetched[id], now().timeIntervalSince(last) < budgetInterval(identity) - 5 { continue }
            if await fetchRepoWatch(row, id: id, repo: repo, identity: identity) { touched.append(id) }
        }
        if !touched.isEmpty {
            logger.info("watch events recorded", metadata: ["watches": .string(touched.map(String.init).joined(separator: ","))])
            await watchHandler?(touched)
        }
    }

    /// 1 本取って記録する。出来事を足したら true
    private func fetchRepoWatch(_ row: Store.WatchRow, id: Int64, repo: String, identity: GitHubCLI.Account) async -> Bool {
        let started = now()
        repoFetched[id] = started
        do {
            let cursor = try store.repoWatchCursor(id: id)
            let term = RepoWatchSearch.term(repo: repo, query: row.query, since: cursor?.since ?? started.addingTimeInterval(-RepoWatchSearch.overlap))
            let data = try await cli.graphQL(RepoWatchSearch.query, variables: ["q": term], account: identity)
            let result = try RepoWatchSearch.parse(data)
            await cli.clearRateLimit(identity)
            noteBudget(identity, cost: result.cost, remaining: result.remaining, resetAt: result.resetAt)
            let (next, opened) = RepoWatchSearch.advance(cursor, result: result, viewerLogin: identity.login, startedAt: started)
            let notices = opened.map { LinkNotice.opened(url: $0.url, author: $0.author, labels: $0.labels) }
            return try store.recordRepoWatch(id: id, cursor: next, notices: notices, at: started)
        } catch {
            let reason = await failureReason(error, identity: identity)
            logger.warning("repo watch not fetched", metadata: ["watch": .stringConvertible(id), "error": .string(reason)])
            try? store.noteWatchFailure(id: id, reason: reason, at: started)
            return false
        }
    }

    /// タグを待つ見張り（`only` ならその URL のものを、間隔を待たずに）を repo ごとに見る。
    /// 見始めの回に入っていたタグは、見張りを作る前から PR がマージされていたなら前からの様子として届けずに終える
    private func sweepTagWatches(only url: String? = nil) async {
        let waiting: [Store.TagWaiting]
        do {
            waiting = try store.tagWaitingWatches().filter { url == nil || $0.url == url }
        } catch {
            logger.warning("tag watches not read", metadata: ["error": .string(String(describing: error))])
            return
        }
        var byRepo: [String: [Store.TagWaiting]] = [:]
        for entry in waiting {
            guard let host = URL(string: entry.url)?.host()?.lowercased(), let (owner, name) = TagWatch.repository(of: entry.url) else { continue }
            byRepo["\(host)/\(owner)/\(name)", default: []].append(entry)
        }
        var repos: [(key: String, entries: [Store.TagWaiting], identity: GitHubCLI.Account?)] = []
        for (key, entries) in byRepo.sorted(by: { $0.key < $1.key }) {
            let match = await cli.match(url: entries[0].url)
            let host = String(key.prefix { $0 != "/" })
            repos.append((key, entries, await cli.identity(match.map { GitHubCLI.Account(host: $0.host, login: $0.account) }, host: host)))
        }
        if url == nil {
            tagRepoCount = [:]
            for case let identity? in repos.map(\.identity) { tagRepoCount[identity, default: 0] += 1 }
        }
        var touched: [Int64] = []
        for (key, entries, identity) in repos {
            guard let identity else {
                for entry in entries { try? store.noteWatchFailure(id: entry.id, reason: Self.noIdentity, at: now()) }
                continue
            }
            guard await budgetAllows(identity) else { continue }
            if url == nil, let last = tagsFetched[key], now().timeIntervalSince(last) < budgetInterval(identity) - 5 { continue }
            touched += await checkTags(key: key, entries: entries, identity: identity)
        }
        if !touched.isEmpty {
            logger.info("watch events recorded", metadata: ["watches": .string(touched.map(String.init).joined(separator: ","))])
            await watchHandler?(touched)
        }
    }

    /// 1 つの repo のタグの一覧を取り、見張りごとに見ていない型に合うタグを古い順に比べて記録する。出来事を足した見張りの id を返す
    private func checkTags(key: String, entries: [Store.TagWaiting], identity: GitHubCLI.Account) async -> [Int64] {
        let started = now()
        tagsFetched[key] = started
        let parts = key.split(separator: "/").map(String.init)
        var touched: [Int64] = []
        var pending = entries
        do {
            let data = try await cli.graphQL(TagWatch.query, variables: ["owner": parts[1], "name": parts[2]], account: identity)
            let listing = try TagWatch.parse(data)
            await cli.clearRateLimit(identity)
            noteBudget(identity, cost: listing.cost, remaining: listing.remaining, resetAt: listing.resetAt)
            // 同じ PR を見張る見張りどうしで、同じ比べ方を 2 回しない
            var compared: [String: Bool] = [:]
            while let entry = pending.first {
                let (candidates, seen) = TagWatch.plan(entry.state, tags: listing.tags, pattern: entry.pattern)
                var found: TagWatch.Tag?
                for tag in candidates {
                    let pair = "\(entry.mergeCommit)...\(tag.commit)"
                    let inside: Bool
                    if let known = compared[pair] {
                        inside = known
                    } else {
                        inside = try await tagContains(entry, tagCommit: tag.commit, host: parts[0], identity: identity)
                        compared[pair] = inside
                    }
                    if inside {
                        found = tag
                        break
                    }
                }
                var next = entry.state
                next.seen = seen
                next.tag = found?.name
                let quiet = entry.state.seen == nil && entry.state.mergedBeforeWatch
                let notice = found.flatMap { tag in
                    quiet ? nil : LinkNotice.tagged(url: entry.url, tag: tag.name, releaseURL: TagWatch.releaseURL(pullRequest: entry.url, tag: tag.name))
                }
                if try store.recordTagCheck(id: entry.id, state: next, notice: notice, at: started) { touched.append(entry.id) }
                pending.removeFirst()
            }
        } catch {
            let reason = await failureReason(error, identity: identity)
            logger.warning("tags not fetched", metadata: ["repo": .string(key), "error": .string(reason)])
            for entry in pending { try? store.noteWatchFailure(id: entry.id, reason: reason, at: started) }
        }
        return touched
    }

    /// タグのコミットが PR の merge commit を含むか（`compare/{merge commit}...{タグ}` の status）
    private func tagContains(_ entry: Store.TagWaiting, tagCommit: String, host: String, identity: GitHubCLI.Account) async throws -> Bool {
        guard let path = TagWatch.comparePath(pullRequest: entry.url, mergeCommit: entry.mergeCommit, tagCommit: tagCommit) else {
            throw PullRequestQueries.ParseError.malformed("PR の URL から repo を取れない")
        }
        let out = try await cli.run(["api", "--hostname", host, path, "--jq", ".status"], account: identity)
        return TagWatch.contains(status: out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// repo の見張りとタグの一覧に使える回か（rate limit の待ちと、残りの点が少なくて止めている間は取らない）
    private func budgetAllows(_ identity: GitHubCLI.Account) async -> Bool {
        if await cli.rateLimitedUntil(identity) != nil { return false }
        if let paused = repoPausedUntil[identity], paused > now() { return false }
        return true
    }

    /// repo の見張りとタグの一覧の 1 本あたりの間隔。アカウントの 1 時間 500 点を、その回の cost × 本数（repo の見張りとタグの repo の和）で割る
    private func budgetInterval(_ identity: GitHubCLI.Account) -> TimeInterval {
        let count = max(1, (repoWatchCount[identity] ?? 0) + (tagRepoCount[identity] ?? 0))
        return max(Self.linkedInterval, 3600 * Double(repoCost[identity] ?? 1) * Double(count) / Self.repoBudgetPerHour)
    }

    private func noteBudget(_ identity: GitHubCLI.Account, cost: Int?, remaining: Int?, resetAt: Date?) {
        if let cost { repoCost[identity] = max(1, cost) }
        if let remaining, remaining < Self.repoReserve, let resetAt {
            repoPausedUntil[identity] = resetAt
            logger.info("repo watches paused until rate limit reset", metadata: ["account": .string(identity.login), "remaining": .stringConvertible(remaining)])
        }
    }

    /// 取れなかった理由。rate limit なら、そのアカウントの待ちを延ばす
    private func failureReason(_ error: any Error, identity: GitHubCLI.Account) async -> String {
        if (error as? PullRequestQueries.ParseError)?.isRateLimit == true { _ = await cli.noteRateLimit(identity) }
        if let failure = error as? GitHubCLI.Failure {
            if failure.isRateLimit { _ = await cli.noteRateLimit(identity) }
            return Self.firstLine(failure.description)
        }
        return Self.firstLine(String(describing: error))
    }

    struct Watched {
        var task: BoardTask
        var board: Board
        var column: BoardColumn
    }

    /// 終端列以外のタスク
    private func watchedTasks() throws -> [Watched] {
        let boards = Dictionary(uniqueKeysWithValues: try store.boards().map { ($0.id, $0) })
        return try store.tasks().compactMap { task in
            guard let board = boards[task.boardID], let column = board.columns.first(where: { $0.id == task.columnID }), column.kind != .terminal else {
                return nil
            }
            return Watched(task: task, board: board, column: column)
        }
    }

    /// `gh pr view` の結果。
    public struct PullRequest: Decodable, Sendable {
        public var number: Int
        public var title: String
        public var url: String
        public var state: String
        public var isDraft: Bool
    }

    /// cwd のブランチに紐づく open な PR（無ければ nil）。Stop hook が毎ターン呼ぶので、既定のブランチと detached HEAD では gh を呼ばず、
    /// 同じブランチは `branchLookupTTL` の間、前の結果を返す（git のリポジトリでない cwd は、ブランチが分からないまま gh に任せる）
    public func openPullRequest(cwd: String) async -> PullRequest? {
        guard cli.executable != nil, !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else { return nil }
        let branch = await Self.git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])
        if let branch {
            let remoteHead = await Self.git(cwd, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
            if branch == "HEAD" || remoteHead == "origin/" + branch { return nil }
        }
        let key = cwd + "\u{0}" + (branch ?? "")
        if let last = branchLookups[key], now().timeIntervalSince(last.at) < Self.branchLookupTTL { return last.pr }
        let pr = await fetchOpenPullRequest(cwd: cwd)
        branchLookups[key] = (pr, now())
        return pr
    }

    private static func git(_ cwd: String, _ arguments: [String]) async -> String? {
        let out = try? await Subprocess.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", cwd] + arguments, timeout: .seconds(5))
        let value = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func fetchOpenPullRequest(cwd: String) async -> PullRequest? {
        await cli.reloadAccounts()
        do {
            let remote = try? await Subprocess.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", cwd, "remote", "get-url", "origin"])
            var match: GitHubAccounts.Match?
            if let remote { match = await cli.match(remote: remote) }
            let out = try await cli.run(["pr", "view", "--json", "number,title,url,isDraft,state"], match: match, cwd: URL(fileURLWithPath: cwd))
            let pr = try JSONDecoder().decode(PullRequest.self, from: Data(out.utf8))
            return pr.state.uppercased() == "OPEN" ? pr : nil
        } catch {
            return nil
        }
    }

    /// 1 つの URL を取った結果
    struct Fetch {
        /// カードのチップと列の動きに使う PR の状態（issue は持たない）
        var status: DaemonState.LinkFetch?
        /// 比べるための様子。取りきれなかった（行のコメントを取れなかった・自分の login が分からない）ときは nil で、前の様子のまま比べない
        var snapshot: LinkSnapshot?
        var viewerLogin: String?
        /// マージ・クローズしたか（取れたときだけ。30 分の間隔にする）
        var finished: Bool?
        /// 取り始めた時刻。様子の時刻にする（次の行のコメントの `since` の元）
        var startedAt = Date.distantPast
        /// 取れなかった理由（見張りに残す）
        var failure: String?
    }

    /// タスクのリンクの GitHub の URL と、セッションを結んだタスクのものか（60 秒ごとに取る）
    private static func linkURLs(of watched: [Watched]) -> [String: (kind: TaskLink.Kind, linked: Bool)] {
        var urls: [String: (kind: TaskLink.Kind, linked: Bool)] = [:]
        for entry in watched {
            for link in entry.task.links where link.kind == .githubPR || link.kind == .githubIssue {
                urls[link.url] = (link.kind, urls[link.url]?.linked == true || !entry.task.sessions.isEmpty)
            }
        }
        return urls
    }

    /// 間隔の来た URL（`force` なら全部）を 1 回ずつ取り、PR の状態を state に入れ、様子を記録して知らせと見張りの出来事を作る。
    /// `numbers` は比べるリンクのタスク（終端列以外）
    private func fetch(urls: [String: (kind: TaskLink.Kind, linked: Bool)], tasks numbers: Set<Int>, force: Bool) async throws -> [String: Fetch] {
        var fetched: [String: Fetch] = [:]
        for (url, entry) in urls.sorted(by: { $0.key < $1.key }) {
            let match = await cli.match(url: url)
            let account = match.map { GitHubCLI.Account(host: $0.host, login: $0.account) }
            let host = account?.host ?? URLComponents(string: url)?.host?.lowercased() ?? "github.com"
            let identity = await cli.identity(account, host: host)
            guard await isDue(url, linked: entry.linked, identity: identity, force: force) else { continue }
            let started = now()
            lastFetched[url] = started
            var result = await fetch(url, kind: entry.kind, host: host, account: account, identity: identity, tasks: numbers)
            result.startedAt = started
            fetched[url] = result
        }
        // 取っている間に、同じ URL を後から取り始めた（巡回と Stop hook の syncNow が重なった）なら、こちらの古い結果は捨てる
        // 捨てるかを決めてから次の await までに様子を書く
        fetched = fetched.filter { lastFetched[$0.key] == $0.value.startedAt }
        for (url, result) in fetched {
            guard let done = result.finished else { continue }
            if done { finished.insert(url) } else { finished.remove(url) }
        }
        var touched: Set<Int> = []
        var watches: [Int64] = []
        for (url, result) in fetched.sorted(by: { $0.key < $1.key }) {
            guard let snapshot = result.snapshot, let viewer = result.viewerLogin else {
                if let failure = result.failure { try store.noteWatchFetchFailure(url: url, reason: failure, at: result.startedAt) }
                continue
            }
            touched.formUnion(try store.recordLinkSnapshot(url: url, snapshot: snapshot, viewerLogin: viewer, tasks: numbers, at: result.startedAt))
            watches += try store.recordWatchSnapshot(url: url, snapshot: snapshot, viewerLogin: viewer, at: result.startedAt)
        }
        let statuses = fetched.compactMapValues(\.status)
        if !statuses.isEmpty { await state.record(links: statuses, at: now()) }
        if !touched.isEmpty {
            logger.info("link notices recorded", metadata: ["tasks": .string(touched.sorted().map(String.init).joined(separator: ","))])
            await noticeHandler?(touched.sorted())
        }
        if !watches.isEmpty {
            logger.info("watch events recorded", metadata: ["watches": .string(watches.map(String.init).joined(separator: ","))])
            await watchHandler?(watches)
        }
        return fetched
    }

    private func isDue(_ url: String, linked: Bool, identity: GitHubCLI.Account?, force: Bool) async -> Bool {
        if let identity, await cli.rateLimitedUntil(identity) != nil { return false }
        guard !force, let last = lastFetched[url] else { return true }
        let interval = finished.contains(url) ? Self.finishedInterval : linked ? Self.linkedInterval : Self.unlinkedInterval
        // 巡回は 60 秒ごとなので、取るのにかかった分の数秒は待たない
        return now().timeIntervalSince(last) >= interval - 5
    }

    /// `identity` が分からない（gh がその host で誰を名乗るか引けない）回は、自分のコメントを見分けられないので比べない
    private func fetch(
        _ url: String, kind: TaskLink.Kind, host: String, account: GitHubCLI.Account?, identity: GitHubCLI.Account?, tasks: Set<Int>
    ) async -> Fetch {
        do {
            if kind == .githubIssue {
                let out = try await call(["issue", "view", url, "--json", IssueView.fields], account: account, identity: identity)
                let issue = try JSONDecoder().decode(IssueView.self, from: Data(out.utf8))
                let done = issue.state.uppercased() != "OPEN"
                guard let identity else { return Fetch(finished: done, failure: Self.noIdentity) }
                await cli.clearRateLimit(identity)
                return Fetch(snapshot: .issue(issue.snapshot), viewerLogin: identity.login, finished: done)
            }
            let out = try await call(["pr", "view", url, "--json", PullRequestView.fields], account: account, identity: identity)
            let view = try PullRequestView.parse(Data(out.utf8))
            guard let linkState = view.linkState else {
                return Fetch(status: .failed("PR の状態を取得できません: 知らない状態です"), failure: "PR の状態が知らない値")
            }
            var result = Fetch(status: .pullRequest(linkState), finished: linkState.state != .open)
            guard let identity else {
                result.failure = Self.noIdentity
                return result
            }
            var inline: [PullRequestSnapshot.Comment]?
            if linkState.state == .open {
                let since = (try? store.oldestLinkSnapshot(url: url, tasks: tasks))?.addingTimeInterval(-Self.inlineOverlap)
                guard let path = ReviewCommentView.path(pullRequest: url, since: since) else { return result }
                do {
                    let out = try await call(["api", "--hostname", host, path], account: account, identity: identity)
                    inline = try JSONDecoder().decode([ReviewCommentView].self, from: Data(out.utf8)).map(\.comment)
                } catch {
                    let reason = Self.firstLine(String(describing: error))
                    logger.info("review comments not fetched", metadata: ["url": .string(url), "error": .string(reason)])
                    result.failure = "行のコメントを取れない: \(reason)"
                    return result
                }
            }
            result.snapshot = view.snapshot(inline: inline).map(LinkSnapshot.pullRequest)
            result.viewerLogin = identity.login
            // 待ちを消すのは全部が通ったときだけ（GraphQL の `gh pr view` が通っても、REST の枠は尽きたままのことがある）
            await cli.clearRateLimit(identity)
            return result
        } catch let failure as GitHubCLI.Failure {
            // issue の状態は state に載せない（取れなかったら、その回は比べないだけ）
            let reason = Self.firstLine(failure.description)
            return Fetch(status: kind == .githubPR ? .failed("PR の状態を取得できません: \(reason)") : nil, failure: reason)
        } catch {
            return Fetch(status: kind == .githubPR ? .failed("PR の状態を取得できません: 応答を読めません") : nil, failure: "gh の応答を読めない")
        }
    }

    /// 自分のコメントを見分けられないので比べない回の理由
    private static let noIdentity = "gh がこの host で名乗るアカウントが分からない（gh auth status）"

    /// gh を呼ぶ。rate limit に当たったら、gh が名乗るアカウントの待ちを延ばす
    private func call(_ arguments: [String], account: GitHubCLI.Account?, identity: GitHubCLI.Account?) async throws -> String {
        do {
            return try await cli.run(arguments, account: account)
        } catch let failure as GitHubCLI.Failure where failure.isRateLimit {
            if let identity { await cli.noteRateLimit(identity) }
            throw failure
        }
    }

    /// 列を見直す。今回取った PR はその結果、取らなかった PR は state にある前の結果で決める
    private func advance(_ entry: Watched, fetched: [String: Fetch]) async throws -> BoardTask? {
        let (task, board, column) = (entry.task, entry.board, entry.column)
        let links = task.pullRequestLinks
        guard !links.isEmpty, column.kind == .open else { return nil }
        let known = Dictionary(await state.linkStatuses().map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let states: [PullRequestLinkState] = links.compactMap { link in
            if let status = fetched[link.url]?.status {
                if case .pullRequest(let pr) = status { return pr }
                return nil
            }
            guard let status = known[link.url], status.error == nil else { return nil }
            return status.pullRequest
        }
        guard let target = Self.target(for: column.id, states: states, fetched: states.count == links.count, board: board),
            board.columns.contains(where: { $0.id == target }),
            let targetIndex = BoardColumn.progressIndex(of: target), let currentIndex = BoardColumn.progressIndex(of: column.id),
            targetIndex > currentIndex
        else { return nil }
        let updated = try store.updateTask(number: task.number, TaskUpdateRequest(columnID: target))
        logger.info("advanced task by PR state", metadata: ["task": .stringConvertible(task.number), "to": .string(target)])
        return updated
    }

    /// PR の状態から進める先の列。nil なら動かさない。
    /// - レビュー依頼（他人の PR の受け口）: 紐づく PR の全部がマージかクローズになったら `done`。1 本でも取れていないか open なら動かさない
    /// - それ以外: open で draft でない PR があれば `review`、マージ済みだけで open が無ければ案件の「マージしたら」の列
    static func target(for column: String, states: [PullRequestLinkState], fetched: Bool, board: Board) -> String? {
        guard !states.isEmpty else { return nil }
        let hasOpen = states.contains { $0.state == .open }
        if column == reviewRequestColumn {
            return fetched && !hasOpen ? "done" : nil
        }
        var target: String?
        if states.contains(where: { $0.state == .open && !$0.isDraft }) { target = "review" }
        if states.contains(where: { $0.state == .merged }), !hasOpen { target = board.mergeTargetColumnID }
        return target
    }

    /// gh の stderr は複数行になる。画面に出すのは最初の行だけ
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.isEmpty ? "gh が失敗しました" : String(line.prefix(200))
    }
}
