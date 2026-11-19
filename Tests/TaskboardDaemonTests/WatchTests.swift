import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-watch")
private let prURL = "https://github.com/o/r/pull/12"
private let issueURL = "https://github.com/o/r/issues/7"
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func openPR(checks: CheckState? = nil, comments: [PullRequestSnapshot.Comment] = []) -> LinkSnapshot {
    .pullRequest(PullRequestSnapshot(state: .open, headSHA: "a1", checks: checks, mergeable: .mergeable, comments: comments, inlineComments: []))
}

private func mergedPR() -> LinkSnapshot {
    .pullRequest(PullRequestSnapshot(state: .merged, headSHA: "a1", mergeable: .mergeable, mergedBy: "bob", inlineComments: []))
}

private func comment(_ id: Int, by author: String = "bob") -> PullRequestSnapshot.Comment {
    .init(id: "IC\(id)", author: author, url: "\(prURL)#issuecomment-\(id)")
}

@Suite("見張りの記録")
struct WatchStoreTests {
    private func world() throws -> (Store, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        return (store, try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t")))
    }

    @Test("URL は issue・PR の形にそろえる。GitHub の issue・PR でない URL、issue で起きない種類、過ぎた期限、届け先の数の違い、無いタスク、長すぎる文は断る")
    func validates() throws {
        let (store, task) = try world()
        let (watch, existing) = try store.createWatch(WatchCreateRequest(url: " https://github.com/o/r/pull/12/files?w=1 ", taskNumber: task.number), now: t0)
        #expect(watch.url == prURL && watch.state == .active && !existing)
        #expect(try store.createWatch(WatchCreateRequest(url: "https://github.com/o/r/issues/7#issuecomment-1", taskNumber: task.number), now: t0).watch.url == issueURL)

        #expect(throws: StoreError.self) { try store.createWatch(WatchCreateRequest(url: "https://example.com/o/r/pull/12", taskNumber: task.number), now: t0) }
        #expect(throws: StoreError.self) { try store.createWatch(WatchCreateRequest(url: "https://github.com/o/r/pull/0", taskNumber: task.number), now: t0) }
        #expect(throws: StoreError.self) { try store.createWatch(WatchCreateRequest(url: issueURL, events: [.merged], taskNumber: task.number), now: t0) }
        #expect(throws: StoreError.self) {
            try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number, expiresAt: t0), now: t0)
        }
        #expect(throws: StoreError.self) { try store.createWatch(WatchCreateRequest(url: prURL), now: t0) }
        #expect(throws: StoreError.self) { try store.createWatch(WatchCreateRequest(url: prURL, conversationID: "c1", taskNumber: task.number), now: t0) }
        #expect(throws: StoreError.taskNotFound(999)) { try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: 999), now: t0) }
        #expect(throws: StoreError.self) { try store.createWatch(WatchCreateRequest(url: prURL, conversationID: "c-none"), now: t0) }
        #expect(throws: StoreError.self) {
            try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number, prompt: String(repeating: "あ", count: Store.wakePromptLimit + 1)), now: t0)
        }
        #expect(try store.watches().count == 2)
    }

    @Test("URL・届け先・種類が同じ有効な見張りがあれば、新しく作らずにそれを返す。種類の並びと重なりは比べない")
    func returnsSameWatch() throws {
        let (store, task) = try world()
        let first = try store.createWatch(WatchCreateRequest(url: prURL, events: [.merged, .closed], taskNumber: task.number), now: t0).watch
        let again = try store.createWatch(WatchCreateRequest(url: "\(prURL)/", events: [.closed, .merged, .closed], taskNumber: task.number), now: t0)
        #expect(again.existing && again.watch.watchID == first.watchID)
        #expect(try !store.createWatch(WatchCreateRequest(url: prURL, events: [.merged], taskNumber: task.number), now: t0).existing)
        _ = try store.cancelWatch(id: first.watchID, now: t0)
        #expect(try !store.createWatch(WatchCreateRequest(url: prURL, events: [.merged, .closed], taskNumber: task.number), now: t0).existing, "取り消した見張りは返さない")
    }

    @Test("作って初めて取った様子は元にするだけ。次からは差を、選んだ種類だけ出来事にする。自分のコメントは出来事にしない")
    func recordsChosenEvents() throws {
        let (store, task) = try world()
        let all = try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number), now: t0).watch
        let merges = try store.createWatch(WatchCreateRequest(url: prURL, events: [.merged], taskNumber: task.number), now: t0).watch
        #expect(try store.activeWatchURLs() == [prURL])

        #expect(try store.recordWatchSnapshot(url: prURL, snapshot: openPR(checks: .pending), viewerLogin: "me", at: t0).isEmpty)
        #expect(try store.watchSnapshot(id: all.watchID) == openPR(checks: .pending))
        #expect(try store.watch(id: all.watchID)?.fetchedAt == t0)

        let touched = try store.recordWatchSnapshot(
            url: prURL, snapshot: openPR(checks: .failure, comments: [comment(1), comment(2, by: "Me")]), viewerLogin: "me", at: t0 + 60)
        #expect(touched == [all.watchID])
        let events = try store.undeliveredWatchEvents(watch: all.watchID).map(\.notice)
        #expect(events.map(\.kind) == [.checksFailed, .comment])
        #expect(events.last?.actor == "bob")
        #expect(try store.undeliveredWatchEvents(watch: merges.watchID).isEmpty)
        #expect(try store.watchesWithUndeliveredEvents() == [all.watchID])
    }

    @Test("マージ・クローズしたら、届けた後に終える。届けるものが無ければその場で終える。1 回だけの見張りは届けたら終える")
    func endsWhenFinished() throws {
        let (store, task) = try world()
        let merges = try store.createWatch(WatchCreateRequest(url: prURL, events: [.merged], taskNumber: task.number), now: t0).watch
        let comments = try store.createWatch(WatchCreateRequest(url: prURL, events: [.comment], taskNumber: task.number), now: t0).watch
        let once = try store.createWatch(WatchCreateRequest(url: issueURL, events: [.comment], taskNumber: task.number, once: true), now: t0).watch
        try store.recordWatchSnapshot(url: prURL, snapshot: openPR(), viewerLogin: "me", at: t0)
        try store.recordWatchSnapshot(url: issueURL, snapshot: .issue(IssueSnapshot(state: "OPEN")), viewerLogin: "me", at: t0)

        #expect(try store.recordWatchSnapshot(url: prURL, snapshot: mergedPR(), viewerLogin: "me", at: t0 + 60) == [merges.watchID])
        #expect(try store.watch(id: merges.watchID)?.state == .active, "届けるまでは残す")
        let ended = try store.watch(id: comments.watchID)
        #expect(ended?.state == .ended && ended?.ending == .finished)
        let ids = try store.undeliveredWatchEvents(watch: merges.watchID).map(\.id)
        let delivered = try #require(try store.markWatchEventsDelivered(watch: merges.watchID, ids: ids, at: t0 + 61))
        #expect(delivered.stateValue == .ended && delivered.ending == Watch.Ending.finished.rawValue)
        #expect(try store.activeWatchURLs() == [issueURL])

        let issueComment = PullRequestSnapshot.Comment(id: "IC9", author: "carol", url: "\(issueURL)#issuecomment-9")
        try store.recordWatchSnapshot(url: issueURL, snapshot: .issue(IssueSnapshot(state: "OPEN", comments: [issueComment])), viewerLogin: "me", at: t0 + 60)
        let onceIDs = try store.undeliveredWatchEvents(watch: once.watchID).map(\.id)
        #expect(onceIDs.count == 1)
        try store.markWatchEventsDelivered(watch: once.watchID, ids: onceIDs, at: t0 + 61)
        #expect(try store.watch(id: once.watchID)?.ending == .delivered)
        #expect(try store.activeWatchURLs().isEmpty)
    }

    @Test("取れなかった理由を残し、取れたら消す")
    func keepsFetchFailure() throws {
        let (store, task) = try world()
        let watch = try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number), now: t0).watch
        try store.noteWatchFetchFailure(url: prURL, reason: "not found", at: t0)
        #expect(try store.watch(id: watch.watchID)?.error == "not found")
        #expect(try store.watch(id: watch.watchID)?.fetchedAt == nil)
        try store.recordWatchSnapshot(url: prURL, snapshot: openPR(), viewerLogin: "me", at: t0 + 60)
        #expect(try store.watch(id: watch.watchID)?.error == nil)
    }

    @Test("期限を過ぎたら終える。取り消せるのは有効な見張りだけ。終えてから 7 日で、見張りと届けた出来事を消す")
    func expiresCancelsAndPurges() throws {
        let (store, task) = try world()
        let expiring = try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number, expiresAt: t0 + 60), now: t0).watch
        let cancelled = try store.createWatch(WatchCreateRequest(url: issueURL, taskNumber: task.number), now: t0).watch
        let kept = try store.createWatch(WatchCreateRequest(url: "https://github.com/o/r/pull/13", taskNumber: task.number), now: t0).watch
        try store.endExpiredWatches(at: t0 + 59)
        #expect(try store.watch(id: expiring.watchID)?.state == .active)
        try store.endExpiredWatches(at: t0 + 60)
        #expect(try store.watch(id: expiring.watchID)?.ending == .expired)

        #expect(try store.cancelWatch(id: cancelled.watchID, now: t0 + 60).state == .cancelled)
        #expect(throws: StoreError.self) { try store.cancelWatch(id: cancelled.watchID, now: t0 + 61) }
        #expect(throws: StoreError.self) { try store.cancelWatch(id: expiring.watchID, now: t0 + 61) }
        #expect(throws: StoreError.watchNotFound(99)) { try store.cancelWatch(id: 99, now: t0 + 61) }

        try store.purgeFinishedWatches(at: t0 + 60 + Store.finishedRowRetention - 1)
        #expect(try store.watches().count == 3)
        try store.purgeFinishedWatches(at: t0 + 61 + Store.finishedRowRetention)
        #expect(try store.watches().map(\.watchID) == [kept.watchID], "有効な見張りは残す")
    }

    @Test("タスクを消すと、そのタスク宛ての見張りも消え、state からも外れる")
    func removedWithTask() async throws {
        let (store, task) = try world()
        let watch = try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number), now: t0).watch
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        await state.upsert(task)
        await state.upsert(watch)
        try store.deleteTask(number: task.number)
        #expect(try store.watches().isEmpty)
        await state.removeTask(number: task.number)
        #expect(await state.snapshot().watches.isEmpty)
    }
}

@Suite("見張りの取得（偽物の gh）", .serialized)
struct WatchSyncTests {
    private struct World {
        let gh: FakeGitHub
        let store: Store
        let sync: GitHubSync
        let clock: TestClock
        let board: Board
    }

    private func world() throws -> World {
        let gh = try FakeGitHub()
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let clock = TestClock(t0)
        let cli = GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: gh.executable, now: { clock.now })
        return World(gh: gh, store: store, sync: GitHubSync(store: store, state: state, cli: cli, now: { clock.now }), clock: clock, board: try store.createBoard(name: "a", columns: nil))
    }

    private func views(_ world: World) -> [String] { world.gh.calls.filter { $0.contains(" view ") } }

    @Test("作ったときに 1 回取って元にし、その後はタスクのリンクに無い URL も 60 秒ごとに取る。自分のコメントは出来事にしない")
    func fetchesWatchOnlyURL() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "working", title: "x"))
        try world.gh.pullRequest(12)
        try world.gh.write("inline-12.json", "[]")
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number), now: t0).watch
        let box = WatchBox()
        await world.sync.onWatchEvents { ids in await box.add(ids) }

        await world.sync.syncWatch(url: prURL)
        #expect(views(world).count == 1)
        #expect(try world.store.watchSnapshot(id: watch.watchID) != nil)
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).isEmpty)

        try world.gh.pullRequest(
            12, comments: #"[{"id":"IC1","author":{"login":"alice"},"url":"\#(prURL)#issuecomment-1"},{"id":"IC2","author":{"login":"me-dev"},"url":"\#(prURL)#issuecomment-2"}]"#)
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(views(world).count == 2)
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).map { $0.notice.actor } == ["alice"])
        #expect(await box.ids == [[watch.watchID]])
    }

    @Test("タスクのリンクと同じ URL は 1 回だけ取り、リンクの知らせと見張りの出来事の両方になる。見張りの届け先がそのタスクなら見張りの出来事だけ")
    func sharesFetchWithLinks() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(12)
        try world.gh.write("inline-12.json", "[]")
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "x", links: [prURL]))
        let watching = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "y", links: [prURL]))
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, taskNumber: watching.number), now: t0).watch
        try await world.sync.sweep()
        #expect(views(world).count == 1)

        try world.gh.pullRequest(12, state: "MERGED", mergedBy: #"{"login":"bob"}"#)
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(views(world).count == 2, "\(views(world))")
        #expect(try world.store.undeliveredLinkNotices(task: task.number).map(\.notice.kind) == [.merged])
        #expect(try world.store.undeliveredLinkNotices(task: watching.number).isEmpty)
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).map(\.notice.kind) == [.merged])
    }

    @Test("取れなかった理由を見張りに残し、取れたら消す")
    func recordsFailure() async throws {
        let world = try world()
        defer { world.gh.cleanUp() }
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "working", title: "x"))
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number), now: t0).watch
        await world.sync.syncWatch(url: prURL)
        #expect(try world.store.watch(id: watch.watchID)?.error?.isEmpty == false)
        try world.gh.pullRequest(12)
        try world.gh.write("inline-12.json", "[]")
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(try world.store.watch(id: watch.watchID)?.error == nil)
    }
}

private actor WatchBox {
    var ids: [[Int64]] = []
    func add(_ value: [Int64]) { ids.append(value) }
}

@Suite("見張りの届け（偽物の host）", .serialized)
struct WatchNoticesTests {
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func userTexts(_ world: ServiceWorld, key: String) async -> [(uuid: String, text: String)] {
        await world.host.requests.filter { $0.op == .write && $0.key == key }.compactMap { request in
            guard let data = request.data, let line = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                line["type"] as? String == "user", let uuid = line["uuid"] as? String,
                let text = (line["message"] as? [String: Any])?["content"] as? String
            else { return nil }
            return (uuid, text)
        }
    }

    /// 届けを始め、発言を受けたと host が返すまで待つ
    private func delivering(_ world: ServiceWorld, key: String, _ deliver: @escaping @Sendable () async -> Void) async throws -> String {
        let before = await userTexts(world, key: key).count
        let task = Task { await deliver() }
        #expect(await eventually { await userTexts(world, key: key).count > before })
        let message = try #require(await userTexts(world, key: key).last)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(message.uuid)","state":"started"}"#, key: key)
        await task.value
        return message.text
    }

    /// 元の様子を記録してから `next` を取ったことにする
    private func record(_ store: Store, _ next: LinkSnapshot) throws {
        try store.recordWatchSnapshot(url: prURL, snapshot: openPR(), viewerLogin: "me", at: Date())
        try store.recordWatchSnapshot(url: prURL, snapshot: next, viewerLogin: "me", at: Date())
    }

    @Test("終了した会話を起こして 1 通にまとめて入れ、届けた印を付ける。文は見張りの知らせとして見分けられる")
    func wakesClosedConversation() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        try await world.service.close(conversation.id)
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, conversationID: conversation.id, prompt: "コメントに答える")).watch
        try record(world.store, openPR(checks: .failure, comments: [comment(1)]))
        let notices = WatchNotices(store: world.store, state: world.state, conversations: world.service)

        let text = try await delivering(world, key: conversation.id) { await notices.deliver(watch: watch.watchID) }
        let lines = text.split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(2)) == ["<!-- taskboard: watch id=\(watch.watchID) -->", "[taskboard 通知] 監視 #\(watch.watchID)（r#12）に動きがあった"])
        #expect(Array(lines.dropFirst(2).prefix(2)) == ["- 送り主: taskboard の自動の通知。人の発言でも承認でもない", "- 本文: 載せていない（外部の人が書いた文のため）。URL を開いて読む"])
        #expect(Array(lines.suffix(2)) == ["作成時の指示:", "コメントに答える"], "作成時の指示は本文として最後に置く")
        let events = try #require(lines.firstIndex(of: "動き:"))
        #expect(lines[(events + 1)...].filter { $0.hasPrefix("- ") }.count == 2)
        #expect(TaskboardNotice(text: text) == .watch)
        #expect(try await !world.service.get(conversation.id).isClosed)
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).isEmpty)
        #expect(try world.store.watch(id: watch.watchID)?.state == .active)

        await notices.sweep()
        #expect(await userTexts(world, key: conversation.id).count == 1, "届けた出来事は入れ直さない")
    }

    @Test("人が止めた会話にもマージを届け、届けたら見張りを終える")
    func deliversMergeToConversationStoppedByPerson() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        try await world.service.stop(conversation.id, cause: .person)
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, events: [.merged], conversationID: conversation.id)).watch
        try record(world.store, mergedPR())
        let notices = WatchNotices(store: world.store, state: world.state, conversations: world.service)
        let text = try await delivering(world, key: conversation.id) { await notices.eventsRecorded([watch.watchID]) }
        #expect(text.contains("- 状態: マージかクローズされたので、この監視は終えた"))
        let ended = try #require(try world.store.watch(id: watch.watchID))
        #expect(ended.state == .ended && ended.ending == .finished)
    }

    @Test("タスク宛てでタスクに会話もセッションも無ければ、新しく起こさずに溜め、会話ができて入力待ちになったら届ける")
    func waitsForLeadOfTask() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, taskNumber: world.task)).watch
        try record(world.store, openPR(comments: [comment(1)]))
        let notices = WatchNotices(store: world.store, state: world.state, conversations: world.service)
        await notices.sweep()
        #expect(await world.host.requests.filter { $0.op == .spawn }.isEmpty)
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).count == 1)

        let lead = try await world.service.start(world.request())
        _ = try await delivering(world, key: lead.id) { await notices.conversationIdle(lead.id) }
        #expect(try world.store.undeliveredWatchEvents(watch: watch.watchID).isEmpty)
    }

    @Test("届け先の会話の記録が消えていたら、見張りを終える")
    func endsWhenConversationDeleted() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let watch = try world.store.createWatch(WatchCreateRequest(url: prURL, conversationID: conversation.id)).watch
        try await world.service.stop(conversation.id, cause: .person)
        try await world.service.delete(conversation.id)
        try record(world.store, openPR(comments: [comment(1)]))
        await WatchNotices(store: world.store, state: world.state, conversations: world.service).sweep()
        #expect(try world.store.watch(id: watch.watchID)?.ending == .targetMissing)
    }

    @Test("期限を過ぎた見張りは、届けていない出来事があっても届けずに終える")
    func expiredWatchIsNotDelivered() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let clock = TestClock(Date())
        let watch = try world.store.createWatch(
            WatchCreateRequest(url: prURL, conversationID: conversation.id, expiresAt: clock.now.addingTimeInterval(60)), now: clock.now
        ).watch
        try record(world.store, openPR(comments: [comment(1)]))
        clock.advance(61)
        await WatchNotices(store: world.store, state: world.state, conversations: world.service, now: { clock.now }).sweep()
        #expect(try world.store.watch(id: watch.watchID)?.ending == .expired)
        #expect(await userTexts(world, key: conversation.id).isEmpty)
    }
}
