import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-tag-watch")
private let prURL = "https://github.com/o/r/pull/12"
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func tag(_ name: String, _ commit: String) -> TagWatch.Tag { TagWatch.Tag(name: name, commit: commit) }

/// タグの一覧（`gh api graphql` の出力の形。新しい順）。`annotated` は注釈付きのタグ
private func tagsJSON(_ tags: [(name: String, commit: String)], annotated: Set<String> = [], remaining: Int = 4999) -> String {
    let nodes = tags.map { tag in
        annotated.contains(tag.name)
            ? #"{"name":"\#(tag.name)","target":{"__typename":"Tag","oid":"obj-\#(tag.name)","target":{"oid":"\#(tag.commit)"}}}"#
            : #"{"name":"\#(tag.name)","target":{"__typename":"Commit","oid":"\#(tag.commit)"}}"#
    }
    return #"{"data":{"repository":{"refs":{"nodes":[\#(nodes.joined(separator: ","))]}},"rateLimit":{"cost":1,"remaining":\#(remaining),"resetAt":"2026-10-22T09:00:00Z"}}}"#
}

@Suite("タグの見張り（gh を呼ばない部分）")
struct TagWatchPureTests {
    @Test("タグの一覧から名前とコミットを読む。注釈付きのタグは中の object、空の node は飛ばす。GraphQL の errors は失敗にし、RATE_LIMITED を見分ける")
    func parse() throws {
        let listing = try TagWatch.parse(Data(tagsJSON([("v2-20261016-01-qa2", "c3"), ("v2-20261015-01-prod", "c2")], annotated: ["v2-20261015-01-prod"]).utf8))
        #expect(listing.tags == [tag("v2-20261016-01-qa2", "c3"), tag("v2-20261015-01-prod", "c2")])
        #expect(listing.cost == 1 && listing.remaining == 4999 && listing.resetAt != nil)
        let withNull = #"{"data":{"repository":{"refs":{"nodes":[null,{"name":"a","target":{"__typename":"Tree","oid":null}}]}}}}"#
        #expect(try TagWatch.parse(Data(withNull.utf8)).tags.isEmpty)
        #expect { try TagWatch.parse(Data(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#.utf8)) } throws: {
            ($0 as? PullRequestQueries.ParseError)?.isRateLimit == true
        }
        #expect(throws: PullRequestQueries.ParseError.self) { try TagWatch.parse(Data(#"{"data":{"repository":null}}"#.utf8)) }
        #expect(throws: PullRequestQueries.ParseError.self) { try TagWatch.parse(Data("not json".utf8)) }
    }

    @Test("型は glob で名前の全体に当てる。型が無ければ全部")
    func matches() {
        #expect(TagWatch.matches("v2-20261015-01-prod", pattern: "*-prod"))
        #expect(!TagWatch.matches("v2-20261015-01-prod-rc", pattern: "*-prod"))
        #expect(!TagWatch.matches("v2-20261016-01-qa2", pattern: "*-prod"))
        #expect(TagWatch.matches("v2-20261016-01-qa2", pattern: "v2-*-qa?"))
        #expect(!TagWatch.matches("v2-20261016-01-qa", pattern: "v2-*-qa?"))
        #expect(TagWatch.matches("リリース-1", pattern: "リリース-*"))
        #expect(TagWatch.matches("anything", pattern: nil))
    }

    @Test("見始めは、いちばん新しい型に合うタグだけを比べ、型に合うほかのタグは見たことにする。次からは見ていない型に合うタグを古い順に比べる")
    func plan() {
        let tags = [tag("d-qa", "c4"), tag("c-prod", "c3"), tag("b-prod", "c2"), tag("a-qa", "c1")]
        let start = TagWatch.plan(TagWatch.State(), tags: tags, pattern: "*-prod")
        #expect(start.compare == [tag("c-prod", "c3")])
        #expect(start.seen == ["c-prod", "b-prod"])
        #expect(TagWatch.plan(TagWatch.State(), tags: [tag("a-qa", "c1")], pattern: "*-prod") == ([], []))

        let later = [tag("f-prod", "c6"), tag("e-prod", "c5"), tag("d-qa", "c4"), tag("c-prod", "c3"), tag("b-prod", "c2")]
        let next = TagWatch.plan(TagWatch.State(seen: start.seen), tags: later, pattern: "*-prod")
        #expect(next.compare == [tag("e-prod", "c5"), tag("f-prod", "c6")])
        #expect(next.seen == ["f-prod", "e-prod", "c-prod", "b-prod"])
        #expect(TagWatch.plan(TagWatch.State(seen: next.seen), tags: later, pattern: "*-prod").compare.isEmpty, "見たタグは比べ直さない")

        let many = TagWatch.plan(TagWatch.State(seen: (0..<TagWatch.seenLimit).map { "old-\($0)" }), tags: [tag("new", "c")], pattern: nil)
        #expect(many.seen.count == TagWatch.seenLimit && many.seen.first == "new")
    }

    @Test("タグが merge commit を含むのは ahead と identical だけ。diverged（別の線のタグ）と behind は含まない")
    func contains() {
        #expect(TagWatch.contains(status: "ahead"))
        #expect(TagWatch.contains(status: "identical"))
        #expect(!TagWatch.contains(status: "behind"))
        // develop にマージした PR は、release ブランチの上のタグに対して diverged になる（2026-10-22 に実際の repo で確認）
        #expect(!TagWatch.contains(status: "diverged"))
        #expect(!TagWatch.contains(status: ""))
    }

    @Test("compare の path とリリースの画面の URL は PR の URL の repo から組む。タグの名前は path に使えない字を符号にする")
    func urls() {
        #expect(TagWatch.comparePath(pullRequest: prURL, mergeCommit: "m1", tagCommit: "c1") == "repos/o/r/compare/m1...c1?per_page=1")
        #expect(TagWatch.releaseURL(pullRequest: prURL, tag: "v2-20261015-01-prod") == "https://github.com/o/r/releases/tag/v2-20261015-01-prod")
        #expect(TagWatch.releaseURL(pullRequest: "https://ghe.example/o/r/pull/3", tag: "release/1.0 #2") == "https://ghe.example/o/r/releases/tag/release%2F1.0%20%232")
    }

    @Test("タグに入った知らせの 1 行は、タグの名前とリリースの画面")
    func line() {
        let notice = LinkNotice.tagged(url: prURL, tag: "v2-20261015-01-prod", releaseURL: "https://github.com/o/r/releases/tag/v2-20261015-01-prod")
        #expect(notice.needsAction)
        #expect(LinkNotices.line(notice) == "r#12: タグ v2-20261015-01-prod に含まれた https://github.com/o/r/releases/tag/v2-20261015-01-prod")
    }
}

@Suite("タグの見張りの記録")
struct TagWatchStoreTests {
    private func world() throws -> (Store, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        return (store, try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t")))
    }

    private func merged(_ commit: String? = "m1") -> LinkSnapshot {
        .pullRequest(PullRequestSnapshot(state: .merged, headSHA: "a1", mergedBy: "bob", mergeCommit: commit, inlineComments: []))
    }

    @Test("tag_pattern は PR の見張りだけで、events を省くか tagged を入れるときだけ。1 行・100 字まで。tagged は issue と repo では断る")
    func validates() throws {
        let (store, task) = try world()
        let watch = try store.createWatch(WatchCreateRequest(url: prURL, tagPattern: " *-prod ", taskNumber: task.number), now: t0).watch
        #expect(watch.tagPattern == "*-prod" && watch.events.isEmpty)
        #expect(try store.createWatch(WatchCreateRequest(url: prURL, events: [.tagged, .merged], tagPattern: "*-qa", taskNumber: task.number), now: t0).watch.tagPattern == "*-qa")
        for bad in [
            WatchCreateRequest(url: "https://github.com/o/r/issues/7", tagPattern: "*-prod", taskNumber: task.number),
            WatchCreateRequest(url: "https://github.com/o/r/issues/7", events: [.tagged], taskNumber: task.number),
            WatchCreateRequest(repo: "o/r", tagPattern: "*-prod", taskNumber: task.number),
            WatchCreateRequest(repo: "o/r", events: [.tagged], taskNumber: task.number),
            WatchCreateRequest(url: prURL, events: [.merged], tagPattern: "*-prod", taskNumber: task.number),
            WatchCreateRequest(url: prURL, tagPattern: "a\nb", taskNumber: task.number),
            WatchCreateRequest(url: prURL, tagPattern: String(repeating: "a", count: TagWatch.patternLimit + 1), taskNumber: task.number),
        ] {
            #expect(throws: StoreError.self, "\(bad)") { try store.createWatch(bad, now: t0) }
        }
        #expect(try !store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-sb", taskNumber: task.number), now: t0).existing, "型が違えば別の見張り")
        #expect(try store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-prod", taskNumber: task.number), now: t0).existing)
    }

    @Test("タグを待たない見張りは、events が空でも tagged を受けず、マージしたら終える")
    func plainWatchIgnoresTags() throws {
        let (store, task) = try world()
        let watch = try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number), now: t0).watch
        try store.recordWatchSnapshot(url: prURL, snapshot: merged(), viewerLogin: "me", at: t0)
        #expect(try store.watch(id: watch.watchID)?.state == .ended)
        #expect(try store.tagWaitingWatches().isEmpty)
    }

    @Test("タグを待つ見張りは、マージしてもタグに含まれるまで終えない。クローズ（マージなし）なら終える")
    func waitsForTagAfterMerge() throws {
        let (store, task) = try world()
        let waiting = try store.createWatch(WatchCreateRequest(url: prURL, events: [.tagged], taskNumber: task.number), now: t0).watch
        try store.recordWatchSnapshot(url: prURL, snapshot: .pullRequest(PullRequestSnapshot(state: .open, inlineComments: [])), viewerLogin: "me", at: t0)
        try store.recordWatchSnapshot(url: prURL, snapshot: merged(), viewerLogin: "me", at: t0 + 60)
        #expect(try store.watch(id: waiting.watchID)?.state == .active)
        #expect(try store.undeliveredWatchEvents(watch: waiting.watchID).isEmpty, "merged は選んでいない")
        #expect(try store.tagWaitingWatches() == [Store.TagWaiting(id: waiting.watchID, url: prURL, mergeCommit: "m1", pattern: nil, state: TagWatch.State())])

        let closedURL = "https://github.com/o/r/pull/13"
        let closed = try store.createWatch(WatchCreateRequest(url: closedURL, tagPattern: "*-prod", taskNumber: task.number), now: t0).watch
        try store.recordWatchSnapshot(url: closedURL, snapshot: .pullRequest(PullRequestSnapshot(state: .closed, inlineComments: [])), viewerLogin: "me", at: t0)
        #expect(try store.watch(id: closed.watchID)?.ending == .finished)
    }

    @Test("作ったときにもうマージされていたら、見始めの回に入っていたタグは前からの様子として印を付ける。merge commit が分からないうちは待たない")
    func marksMergedBeforeWatch() throws {
        let (store, task) = try world()
        let watch = try store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-prod", taskNumber: task.number), now: t0).watch
        try store.recordWatchSnapshot(url: prURL, snapshot: merged(nil), viewerLogin: "me", at: t0)
        #expect(try store.watch(id: watch.watchID)?.state == .active)
        #expect(try store.tagWaitingWatches().isEmpty)
        try store.recordWatchSnapshot(url: prURL, snapshot: merged(), viewerLogin: "me", at: t0 + 1800)
        #expect(try store.tagWaitingWatches().map(\.state) == [TagWatch.State(mergedBeforeWatch: true)])
    }

    @Test("入ったタグを出来事にして、届けたら終える。前から入っていたタグは出来事にせずに終える。取り消した見張りには書かない")
    func recordsTagCheck() throws {
        let (store, task) = try world()
        let watch = try store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-prod", taskNumber: task.number), now: t0).watch
        try store.recordWatchSnapshot(url: prURL, snapshot: .pullRequest(PullRequestSnapshot(state: .open, inlineComments: [])), viewerLogin: "me", at: t0)
        try store.recordWatchSnapshot(url: prURL, snapshot: merged(), viewerLogin: "me", at: t0)
        #expect(try !store.recordTagCheck(id: watch.watchID, state: TagWatch.State(seen: ["a-prod"]), notice: nil, at: t0))
        #expect(try store.tagWaitingWatches().first?.state.seen == ["a-prod"])
        let notice = LinkNotice.tagged(url: prURL, tag: "b-prod", releaseURL: nil)
        #expect(try store.recordTagCheck(id: watch.watchID, state: TagWatch.State(seen: ["b-prod", "a-prod"], tag: "b-prod"), notice: notice, at: t0 + 60))
        #expect(try store.watch(id: watch.watchID)?.state == .active && store.watch(id: watch.watchID)?.tag == "b-prod")
        #expect(try store.tagWaitingWatches().isEmpty)
        let events = try store.undeliveredWatchEvents(watch: watch.watchID)
        #expect(events.map(\.notice.kind) == [.merged, .tagged] && events.last?.notice == notice)
        try store.markWatchEventsDelivered(watch: watch.watchID, ids: events.map(\.id), at: t0 + 61)
        #expect(try store.watch(id: watch.watchID)?.ending == .finished)

        let before = try store.createWatch(WatchCreateRequest(url: "https://github.com/o/r/pull/14", tagPattern: "*-prod", taskNumber: task.number), now: t0).watch
        try store.recordWatchSnapshot(url: "https://github.com/o/r/pull/14", snapshot: merged(), viewerLogin: "me", at: t0)
        try store.recordTagCheck(id: before.watchID, state: TagWatch.State(seen: ["a-prod"], tag: "a-prod", mergedBeforeWatch: true), notice: nil, at: t0)
        #expect(try store.watch(id: before.watchID)?.ending == .finished && store.watch(id: before.watchID)?.tag == "a-prod")
        #expect(try store.undeliveredWatchEvents(watch: before.watchID).isEmpty)

        let cancelled = try store.createWatch(WatchCreateRequest(url: "https://github.com/o/r/pull/15", tagPattern: "*-prod", taskNumber: task.number), now: t0).watch
        _ = try store.cancelWatch(id: cancelled.watchID, now: t0)
        #expect(try !store.recordTagCheck(id: cancelled.watchID, state: TagWatch.State(tag: "a-prod"), notice: notice, at: t0))
        #expect(try store.undeliveredWatchEvents(watch: cancelled.watchID).isEmpty)
    }
}

@Suite("タグの見張りの取得（偽物の gh）", .serialized)
struct TagWatchSyncTests {
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
        try gh.write("inline-12.json", "[]")
        return World(gh: gh, store: store, sync: GitHubSync(store: store, state: state, cli: cli, now: { clock.now }), cli: cli, clock: clock, task: task)
    }

    private func tagLists(_ world: World) -> Int { world.gh.calls.filter { $0.contains("refPrefix") }.count }
    private func compares(_ world: World) -> [String] { world.gh.calls.filter { $0.contains("/compare/") } }

    @Test("マージ前は見ない。マージを見たら、いちばん新しい型に合うタグから見始め、後から出た型に合うタグに入ったらリリースの画面と一緒に出来事にし、届けたら終える")
    func deliversWhenTagged() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(12)
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-prod", taskNumber: world.task.number), now: t0).watch
        await world.sync.syncWatch(url: prURL)
        #expect(tagLists(world) == 0)

        try world.gh.pullRequest(12, state: "MERGED", mergedBy: #"{"login":"bob"}"#, mergeCommit: "m1")
        try world.gh.write("tags-o-r.json", tagsJSON([("v1-qa", "c2"), ("v1-prod", "c1")]))
        try world.gh.write("compare-m1...c1.txt", "behind")
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(tagLists(world) == 1 && compares(world).count == 1)
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).map(\.notice.kind) == [.merged])

        world.clock.advance(30)
        try await world.sync.sweep()
        #expect(tagLists(world) == 1, "60 秒の間隔を待つ")

        try world.gh.write("tags-o-r.json", tagsJSON([("v2-prod", "c4"), ("v2-qa", "c3"), ("v1-qa", "c2"), ("v1-prod", "c1")], annotated: ["v2-prod"]))
        try world.gh.write("compare-m1...c4.txt", "ahead")
        world.clock.advance(30)
        try await world.sync.sweep()
        #expect(tagLists(world) == 2 && compares(world).count == 2, "\(compares(world))")
        let events = try world.store.undeliveredWatchEvents(watch: watch.watchID)
        #expect(events.last?.notice == LinkNotice.tagged(url: prURL, tag: "v2-prod", releaseURL: "https://github.com/o/r/releases/tag/v2-prod"))
        #expect(try world.store.watch(id: watch.watchID)?.tag == "v2-prod")
        try world.store.markWatchEventsDelivered(watch: watch.watchID, ids: events.map(\.id), at: world.clock.now)
        #expect(try world.store.watch(id: watch.watchID)?.ending == .finished)

        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(tagLists(world) == 2, "終えた見張りのタグは取らない")
    }

    @Test("作る前からマージされていて、いちばん新しい型に合うタグにもう入っていたら、知らせずに終える")
    func alreadyTagged() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(12, state: "MERGED", mergedBy: #"{"login":"bob"}"#, mergeCommit: "m1")
        try world.gh.write("tags-o-r.json", tagsJSON([("v1-prod", "c1")]))
        try world.gh.write("compare-m1...c1.txt", "identical")
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-prod", taskNumber: world.task.number), now: t0).watch
        await world.sync.syncWatch(url: prURL)
        let stored = try #require(try world.store.watch(id: watch.watchID))
        #expect(stored.ending == .finished && stored.tag == "v1-prod")
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).isEmpty)
    }

    @Test("見張っている間に眠っていて、マージとタグを一度に見たときは、見始めの回に入っていたタグも知らせる。別の線のタグ（diverged）は知らせない")
    func mergedWhileAsleep() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(12)
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, events: [.tagged], taskNumber: world.task.number), now: t0).watch
        await world.sync.syncWatch(url: prURL)
        try world.gh.pullRequest(12, state: "MERGED", mergedBy: #"{"login":"bob"}"#, mergeCommit: "m1")
        try world.gh.write("tags-o-r.json", tagsJSON([("v1-prod", "c1")]))
        try world.gh.write("compare-m1...c1.txt", "diverged")
        world.clock.advance(3600)
        try await world.sync.sweep()
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).isEmpty)

        try world.gh.write("tags-o-r.json", tagsJSON([("v2-sb", "c2"), ("v1-prod", "c1")]))
        try world.gh.write("compare-m1...c2.txt", "ahead")
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).map(\.notice.detail) == ["v2-sb"], "型が無ければ全部のタグ")
    }

    @Test("同じ PR を見張る 2 つは、タグの一覧も比べ方も 1 回で済ませる")
    func sharesFetch() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(12)
        let a = try world.store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-prod", taskNumber: world.task.number), now: t0).watch
        let b = try world.store.createWatch(WatchCreateRequest(url: prURL, events: [.tagged, .merged], tagPattern: "*-prod", taskNumber: world.task.number), now: t0).watch
        try await world.sync.sweep()
        try world.gh.pullRequest(12, state: "MERGED", mergedBy: #"{"login":"bob"}"#, mergeCommit: "m1")
        try world.gh.write("tags-o-r.json", tagsJSON([("v1-prod", "c1")]))
        try world.gh.write("compare-m1...c1.txt", "ahead")
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(tagLists(world) == 1 && compares(world).count == 1)
        #expect(try world.store.watch(id: a.watchID)?.tag == "v1-prod" && world.store.watch(id: b.watchID)?.tag == "v1-prod")
    }

    @Test("タグの一覧で rate limit に当たったら、アカウントの待ちに入れて理由を残し、待ちの間は取らない")
    func sharesRateLimit() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(12, state: "MERGED", mergedBy: #"{"login":"bob"}"#, mergeCommit: "m1")
        try world.gh.write("tags-o-r.json", #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-prod", taskNumber: world.task.number), now: t0).watch
        await world.sync.syncWatch(url: prURL)
        #expect(await world.cli.rateLimitedUntil(GitHubCLI.Account(host: "github.com", login: "Me-Dev")) != nil)
        #expect(try world.store.watch(id: watch.watchID)?.error?.contains("rate limit") == true)
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(tagLists(world) == 1)
    }

    @Test("compare に失敗したら見たことにせず、次の回に比べ直す")
    func retriesFailedCompare() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(12, state: "MERGED", mergedBy: #"{"login":"bob"}"#, mergeCommit: "m1")
        try world.gh.write("tags-o-r.json", tagsJSON([("v1-prod", "c1")]))
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, tagPattern: "*-prod", taskNumber: world.task.number), now: t0).watch
        await world.sync.syncWatch(url: prURL)
        #expect(try world.store.watch(id: watch.watchID)?.error?.isEmpty == false)
        try world.gh.write("compare-m1...c1.txt", "behind")
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(compares(world).count == 2)
        #expect(try world.store.watch(id: watch.watchID)?.error == nil)
        #expect(try world.store.tagWaitingWatches().first?.state.seen == ["v1-prod"])
    }
}
