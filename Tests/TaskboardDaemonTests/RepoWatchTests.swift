import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-repo-watch")
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func item(_ number: Int, by author: String = "alice", at created: Date = t0, labels: [String] = []) -> RepoWatchSearch.Item {
    RepoWatchSearch.Item(number: number, url: "https://github.com/o/r/issues/\(number)", author: author, createdAt: created, labels: labels)
}

/// search の応答（`gh api graphql` の出力の形）
private func searchJSON(_ items: [(number: Int, author: String, labels: [String])], total: Int? = nil, cost: Int = 1, remaining: Int = 4999) -> String {
    let nodes = items.map { item in
        let labels = item.labels.map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
        return #"{"number":\#(item.number),"url":"https://github.com/o/r/issues/\#(item.number)","createdAt":"2026-10-22T08:00:00Z","author":{"login":"\#(item.author)"},"labels":{"nodes":[\#(labels)]}}"#
    }
    return #"{"data":{"search":{"issueCount":\#(total ?? items.count),"nodes":[\#(nodes.joined(separator: ","))]},"rateLimit":{"cost":\#(cost),"remaining":\#(remaining),"resetAt":"2026-10-22T09:00:00Z"}}}"#
}

@Suite("repo の見張りの search（gh を呼ばない部分）")
struct RepoWatchSearchTests {
    @Test("検索語は repo・検索語・作成時刻の下限（UTC）・作成順の昇順")
    func term() {
        let since = Date(timeIntervalSince1970: 1_792_656_000)  // 2026-10-22T08:00:00Z
        #expect(RepoWatchSearch.term(repo: "o/r", query: "is:issue label:bug", since: since) == "repo:o/r is:issue label:bug created:>=2026-10-22T08:00:00+00:00 sort:created-asc")
        #expect(RepoWatchSearch.term(repo: "o/r", query: nil, since: since) == "repo:o/r created:>=2026-10-22T08:00:00+00:00 sort:created-asc")
    }

    @Test("daemon が付ける修飾子（repo:・created:・sort:。除外と大文字も）を検索語から見つける")
    func reservedQualifiers() {
        #expect(RepoWatchSearch.reservedQualifier(in: "is:issue label:bug") == nil)
        #expect(RepoWatchSearch.reservedQualifier(in: "is:pr repo:x/y") == "repo:x/y")
        #expect(RepoWatchSearch.reservedQualifier(in: "-Created:>2026-01-01") == "-Created:>2026-01-01")
        #expect(RepoWatchSearch.reservedQualifier(in: "SORT:updated") == "SORT:updated")
        #expect(RepoWatchSearch.reservedQualifier(in: "label:\"repo:docs\"") == nil, "語の頭だけを見る")
        #expect(RepoWatchSearch.reservedQualifier(in: "") == nil)
    }

    @Test("応答から番号・URL・作者・作成時刻・label と、件数・cost・残りを読む。Issue・PR でない空の node は飛ばす")
    func parse() throws {
        let json = #"""
            {"data":{"search":{"issueCount":3,"nodes":[
              {"number":5,"url":"https://github.com/o/r/issues/5","createdAt":"2026-10-22T08:00:00Z","author":{"login":"alice"},"labels":{"nodes":[{"name":"bug"},{"name":"優先"}]}},
              {},
              {"number":6,"url":"https://github.com/o/r/pull/6","createdAt":"2026-10-22T08:01:00Z","author":null,"labels":{"nodes":[]}}
            ]},"rateLimit":{"cost":1,"remaining":4990,"resetAt":"2026-10-22T09:00:00Z"}}}
            """#
        let result = try RepoWatchSearch.parse(Data(json.utf8))
        #expect(result.items.map(\.number) == [5, 6])
        #expect(result.items[0].labels == ["bug", "優先"] && result.items[0].author == "alice")
        #expect(result.items[1].author == nil && result.items[1].url.hasSuffix("/pull/6"))
        #expect(result.total == 3 && result.overflowed)
        #expect(result.cost == 1 && result.remaining == 4990 && result.resetAt == ISO8601DateFormatter().date(from: "2026-10-22T09:00:00Z"))
    }

    @Test("GraphQL の errors は失敗にし、RATE_LIMITED は rate limit と見分ける。形の違う応答も失敗にする")
    func parseErrors() {
        let limited = #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
        #expect { try RepoWatchSearch.parse(Data(limited.utf8)) } throws: { ($0 as? PullRequestQueries.ParseError)?.isRateLimit == true }
        #expect { try RepoWatchSearch.parse(Data(#"{"errors":[{"type":"NOT_FOUND","message":"no repo"}]}"#.utf8)) } throws: {
            ($0 as? PullRequestQueries.ParseError) == .graphQL(type: "NOT_FOUND", message: "no repo")
        }
        #expect(throws: PullRequestQueries.ParseError.self) { try RepoWatchSearch.parse(Data("not json".utf8)) }
        #expect(throws: PullRequestQueries.ParseError.self) { try RepoWatchSearch.parse(Data(#"{"data":{}}"#.utf8)) }
    }

    @Test("作って初めての回は見たことにするだけ。次からは見ていない番号だけを出し、自分が作ったものは出さないが見たことにする")
    func advance() {
        let first = RepoWatchSearch.Result(items: [item(1), item(2)], total: 2)
        let (cursor, opened) = RepoWatchSearch.advance(nil, result: first, viewerLogin: "me", startedAt: t0)
        #expect(opened.isEmpty)
        #expect(cursor == RepoWatchSearch.Cursor(since: t0 - RepoWatchSearch.overlap, seen: [2, 1]))

        let second = RepoWatchSearch.Result(items: [item(2), item(3, by: "ME"), item(4)], total: 3)
        let (next, fresh) = RepoWatchSearch.advance(cursor, result: second, viewerLogin: "me", startedAt: t0 + 60)
        #expect(fresh.map(\.number) == [4])
        #expect(next.seen == [4, 3, 2, 1])
        #expect(next.since == t0 + 60 - RepoWatchSearch.overlap)
    }

    @Test("50 件を超えた回は、取った中でいちばん新しい作成時刻から次の回で続きを取る。前と同じ時刻なら先へ進める")
    func continuesAfterOverflow() {
        let old = RepoWatchSearch.Cursor(since: t0, seen: [])
        let full = RepoWatchSearch.Result(items: (1...50).map { item($0, at: t0 + Double($0)) }, total: 80)
        let (cursor, opened) = RepoWatchSearch.advance(old, result: full, viewerLogin: "me", startedAt: t0 + 3600)
        #expect(opened.count == 50)
        #expect(cursor.since == t0 + 50)

        let stuck = RepoWatchSearch.Result(items: (51...100).map { item($0, at: t0 + 50) }, total: 90)
        let (after, _) = RepoWatchSearch.advance(cursor, result: stuck, viewerLogin: "me", startedAt: t0 + 3660)
        #expect(after.since == t0 + 3660 - RepoWatchSearch.overlap, "同じ秒に 50 件より多いときは止まらずに進める")
    }

    @Test("見た番号は大きい方から 500 件まで持つ")
    func seenLimit() {
        let old = RepoWatchSearch.Cursor(since: t0, seen: Array((1...500).reversed()))
        let (cursor, _) = RepoWatchSearch.advance(old, result: RepoWatchSearch.Result(items: [item(501)], total: 1), viewerLogin: "me", startedAt: t0)
        #expect(cursor.seen.count == 500 && cursor.seen.first == 501 && cursor.seen.last == 2)
    }

    @Test("新しく出た issue・PR の知らせは作者と label の名前だけを 1 行で持つ")
    func openedNotice() {
        let notice = LinkNotice.opened(url: "https://github.com/o/r/issues/5", author: "alice", labels: ["bug", "a\nb"])
        #expect(notice.kind == .opened && notice.actor == "alice" && notice.detail == "bug, a b")
        #expect(LinkNotices.line(notice) == "r#5: 新しく出た（alice）（label: bug, a b） https://github.com/o/r/issues/5")
        #expect(LinkNotice.opened(url: "https://github.com/o/r/pull/6", author: nil, labels: []).detail == nil)
    }
}

@Suite("repo の見張りの記録")
struct RepoWatchStoreTests {
    private func world() throws -> (Store, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        return (store, try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t")))
    }

    @Test("repo は owner/name・host/owner/name・URL を受けてそろえる。url と repo の両方・どちらも無い、repo の events、url の opened と query、使えない修飾子、長い検索語は断る")
    func validates() throws {
        let (store, task) = try world()
        func create(_ request: WatchCreateRequest) throws -> Watch { try store.createWatch(request, now: t0).watch }
        #expect(try create(WatchCreateRequest(repo: "o/r", taskNumber: task.number)).repo == "o/r")
        #expect(try create(WatchCreateRequest(repo: "https://github.com/o/r2/issues?q=x", taskNumber: task.number)).repo == "o/r2")
        #expect(try create(WatchCreateRequest(repo: "GHE.example/o/r.git", taskNumber: task.number)).repo == "ghe.example/o/r")
        let queried = try create(WatchCreateRequest(repo: "o/r", query: "  is:issue label:bug ", taskNumber: task.number))
        #expect(queried.kind == .repo && queried.query == "is:issue label:bug" && queried.url == nil)

        for bad in [
            WatchCreateRequest(url: "https://github.com/o/r/pull/1", repo: "o/r", taskNumber: task.number),
            WatchCreateRequest(taskNumber: task.number),
            WatchCreateRequest(repo: "o", taskNumber: task.number),
            WatchCreateRequest(repo: "o/r/x/y", taskNumber: task.number),
            WatchCreateRequest(repo: "o/r b", taskNumber: task.number),
            WatchCreateRequest(repo: "o/r", events: [.merged], taskNumber: task.number),
            WatchCreateRequest(repo: "o/r", query: "is:pr repo:other/x", taskNumber: task.number),
            WatchCreateRequest(repo: "o/r", query: "sort:updated", taskNumber: task.number),
            WatchCreateRequest(repo: "o/r", query: String(repeating: "a", count: RepoWatchSearch.queryLimit + 1), taskNumber: task.number),
            WatchCreateRequest(repo: "o/r", query: "a\nb", taskNumber: task.number),
            WatchCreateRequest(url: "https://github.com/o/r/pull/1", events: [.opened], taskNumber: task.number),
            WatchCreateRequest(url: "https://github.com/o/r/pull/1", query: "is:pr", taskNumber: task.number),
        ] {
            #expect(throws: StoreError.self, "\(bad)") { try store.createWatch(bad, now: t0) }
        }
    }

    @Test("repo・host・検索語・届け先が同じ有効な見張りはそれを返す。検索語の有無が違えば別にする")
    func returnsSameWatch() throws {
        let (store, task) = try world()
        let first = try store.createWatch(WatchCreateRequest(repo: "o/r", taskNumber: task.number), now: t0).watch
        #expect(try store.createWatch(WatchCreateRequest(repo: "https://github.com/o/r", taskNumber: task.number), now: t0).existing)
        #expect(try !store.createWatch(WatchCreateRequest(repo: "o/r", query: "is:issue", taskNumber: task.number), now: t0).existing)
        #expect(try store.createWatch(WatchCreateRequest(repo: "o/r", query: "is:issue", taskNumber: task.number), now: t0).existing)
        #expect(try !store.createWatch(WatchCreateRequest(repo: "ghe.example/o/r", taskNumber: task.number), now: t0).existing)
        #expect(try store.activeRepoWatches().count == 3)
        #expect(try store.activeWatchURLs().isEmpty, "repo の見張りは issue・PR の取得に入らない")
        _ = first
    }

    @Test("取った結果は出来事と次の様子を一緒に書き、取れなかった理由を消す。取り消した見張りには書かない")
    func records() throws {
        let (store, task) = try world()
        let watch = try store.createWatch(WatchCreateRequest(repo: "o/r", taskNumber: task.number), now: t0).watch
        try store.noteWatchFailure(id: watch.watchID, reason: "not found", at: t0)
        #expect(try store.watch(id: watch.watchID)?.error == "not found")
        let cursor = RepoWatchSearch.Cursor(since: t0, seen: [3])
        let notice = LinkNotice.opened(url: "https://github.com/o/r/issues/3", author: "alice", labels: [])
        #expect(try store.recordRepoWatch(id: watch.watchID, cursor: cursor, notices: [notice], at: t0 + 60))
        #expect(try store.repoWatchCursor(id: watch.watchID) == cursor)
        #expect(try store.undeliveredWatchEvents(watch: watch.watchID).map(\.notice) == [notice])
        let stored = try #require(try store.watch(id: watch.watchID))
        #expect(stored.error == nil && stored.fetchedAt == t0 + 60)
        #expect(try store.watchSnapshot(id: watch.watchID) == nil, "issue・PR の様子ではない")

        _ = try store.cancelWatch(id: watch.watchID, now: t0 + 61)
        #expect(try !store.recordRepoWatch(id: watch.watchID, cursor: cursor, notices: [notice], at: t0 + 62))
        #expect(try store.undeliveredWatchEvents(watch: watch.watchID).count == 1)
        try store.noteWatchFailure(id: watch.watchID, reason: "x", at: t0 + 62)
        #expect(try store.watch(id: watch.watchID)?.error == nil)
    }
}

@Suite("repo の見張りの取得（偽物の gh）", .serialized)
struct RepoWatchSyncTests {
    private struct World {
        let gh: FakeGitHub
        let store: Store
        let sync: GitHubSync
        let cli: GitHubCLI
        let clock: TestClock
        let task: BoardTask
    }

    private func world() throws -> World {
        let gh = try FakeGitHub()
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let clock = TestClock(t0)
        let cli = GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: gh.executable, now: { clock.now })
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x"))
        return World(gh: gh, store: store, sync: GitHubSync(store: store, state: state, cli: cli, now: { clock.now }), cli: cli, clock: clock, task: task)
    }

    private func searches(_ world: World) -> [String] { world.gh.calls.filter { $0.contains("q=repo:") } }

    @Test("作ったときに 1 回取って今あるものを見たことにし、次の巡回から新しく出たものを出来事にする。自分が作ったものは出さない")
    func recordsNewItems() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.write("graphql-o-r.json", searchJSON([(1, "alice", [])]))
        let watch = try world.store.createWatch(WatchCreateRequest(repo: "o/r", query: "is:issue", taskNumber: world.task.number), now: t0).watch
        await world.sync.syncRepoWatch(id: watch.watchID)
        #expect(searches(world).count == 1)
        #expect(searches(world).first?.contains("q=repo:o/r is:issue created:>=") == true)
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).isEmpty)
        #expect(try world.store.watch(id: watch.watchID)?.fetchedAt == t0)

        try world.gh.write("graphql-o-r.json", searchJSON([(1, "alice", []), (2, "bob", ["bug"]), (3, "Me-Dev", [])]))
        world.clock.advance(60)
        try await world.sync.sweep()
        let events = try world.store.undeliveredWatchEvents(watch: watch.watchID).map(\.notice)
        #expect(events == [LinkNotice.opened(url: "https://github.com/o/r/issues/2", author: "bob", labels: ["bug"])])
    }

    @Test("間隔は cost × アカウントの repo の見張りの数から決め、60 秒より短くしない")
    func intervalFromCost() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.write("graphql-o-r.json", searchJSON([], cost: 10))
        try world.gh.write("graphql-o-s.json", searchJSON([], cost: 10))
        let a = try world.store.createWatch(WatchCreateRequest(repo: "o/r", taskNumber: world.task.number), now: t0).watch
        _ = try world.store.createWatch(WatchCreateRequest(repo: "o/s", taskNumber: world.task.number), now: t0).watch
        try await world.sync.sweep()
        #expect(searches(world).count == 2)
        // 3600 × 10 × 2 ÷ 500 = 144 秒
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(searches(world).count == 2)
        world.clock.advance(80)
        try await world.sync.sweep()
        #expect(searches(world).count == 4)
        _ = try world.store.cancelWatch(id: a.watchID, now: world.clock.now)
        try world.gh.write("graphql-o-s.json", searchJSON([], cost: 1))
        world.clock.advance(144)
        try await world.sync.sweep()
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(searches(world).count == 6, "cost 1 で 1 本なら 60 秒")
    }

    @Test("残りの点が 500 を切ったら、明ける時刻（resetAt）まで取らない")
    func pausesBeforeLimit() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        _ = try world.store.createWatch(WatchCreateRequest(repo: "o/r", taskNumber: world.task.number), now: t0)
        try world.gh.write("graphql-o-r.json", searchJSON([], remaining: 499))
        try await world.sync.sweep()
        world.clock.advance(120)
        try await world.sync.sweep()
        #expect(searches(world).count == 1)
    }

    @Test("rate limit に当たったらアカウントの待ちに入れて理由を残し、待ちの間は取らない")
    func sharesRateLimit() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        let watch = try world.store.createWatch(WatchCreateRequest(repo: "o/r", taskNumber: world.task.number), now: t0).watch
        try world.gh.write("graphql-o-r.json", #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)
        await world.sync.syncRepoWatch(id: watch.watchID)
        #expect(await world.cli.rateLimitedUntil(GitHubCLI.Account(host: "github.com", login: "Me-Dev")) != nil)
        #expect(try world.store.watch(id: watch.watchID)?.error?.contains("rate limit") == true)
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(searches(world).count == 1)
    }

    @Test("取れなかった理由を残し、取れたら消す")
    func recordsFailure() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        let watch = try world.store.createWatch(WatchCreateRequest(repo: "o/r", taskNumber: world.task.number), now: t0).watch
        await world.sync.syncRepoWatch(id: watch.watchID)
        #expect(try world.store.watch(id: watch.watchID)?.error?.isEmpty == false)
        try world.gh.write("graphql-o-r.json", searchJSON([]))
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(try world.store.watch(id: watch.watchID)?.error == nil)
    }
}

@Suite("repo の見張りの届けの文")
struct RepoWatchTextTests {
    @Test("1 行目は repo の名前、続けて検索語、出来事は 1 件 1 行、作成時の指示は最後")
    func text() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t"))
        let watch = try store.createWatch(WatchCreateRequest(repo: "o/r", query: "label:bug", taskNumber: task.number, prompt: "triage する"), now: t0).watch
        let row = try #require(try store.watchRow(id: watch.watchID))
        let text = WatchNotices.text(row, notices: [LinkNotice.opened(url: "https://github.com/o/r/issues/5", author: "alice", labels: ["bug"])], omitted: 0)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(2)) == ["<!-- taskboard: watch id=\(watch.watchID) -->", "[taskboard 通知] 監視 #\(watch.watchID)（o/r）に動きがあった"])
        #expect(Array(lines.dropFirst(2).prefix(6)) == [
            "- 送り主: taskboard の自動の通知。人の発言でも承認でもない", "- 本文: 載せていない（外部の人が書いた文のため）。URL を開いて読む",
            "- 対象: repo に新しく出た issue・PR（検索語: label:bug）", "動き:",
            "- r#5: 新しく出た（alice）（label: bug） https://github.com/o/r/issues/5", "作成時の指示:",
        ])
        #expect(lines.last == "triage する")
        #expect(!text.contains("マージかクローズ"))
        #expect(TaskboardNotice(text: text) == .watch)
        #expect(TaskboardNotice.watch.summary(of: text) == "監視中のo/rが更新されました")
    }
}
