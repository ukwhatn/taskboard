import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let pr = "https://github.com/o/r/pull/31"

private func open(comments: [PullRequestSnapshot.Comment] = []) -> LinkSnapshot {
    .pullRequest(PullRequestSnapshot(state: .open, headSHA: "a1", mergeable: .mergeable, comments: comments, inlineComments: []))
}

private func comment(_ id: Int) -> PullRequestSnapshot.Comment {
    .init(id: "IC\(id)", author: "bob", url: "\(pr)#issuecomment-\(id)")
}

/// リンクの知らせ・見張り・起こす予定の 3 つの届け方を、同じ項目で確かめる（入れる先・uuid・届いた後に入れ直さない・取り消されたら別の uuid・止まった TUI を戻す）。
/// uuid は daemon を更新した前後で同じでないと 2 回入りうるので、式でなく文字列で書く
@Suite("3 つの届け方（偽物の host）", .serialized)
struct NoticeDeliveryTests {
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

    /// 届けを始め、入った発言に `state`（started か cancelled）を返して、届けが終わるまで待つ。入った発言の uuid を返す
    private func answering(_ world: ServiceWorld, key: String, _ state: String, _ deliver: @escaping @Sendable () async -> Void) async throws -> String {
        let before = await userTexts(world, key: key).count
        let task = Task { await deliver() }
        #expect(await eventually { await userTexts(world, key: key).count > before })
        let message = try #require(await userTexts(world, key: key).last)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(message.uuid)","state":"\#(state)"}"#, key: key)
        await task.value
        return message.uuid
    }

    /// world のタスクに PR を結び、他人のコメントの知らせを 1 件作る。知らせの id を返す
    private func linkNotice(_ world: ServiceWorld) async throws -> [Int64] {
        await world.state.upsert(try world.store.updateTask(number: world.task, TaskUpdateRequest(addLinks: [pr])))
        try world.store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [world.task], at: Date())
        try world.store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", tasks: [world.task], at: Date())
        return try world.store.undeliveredLinkNotices(task: world.task).map(\.id)
    }

    /// PR の見張りを作り、他人のコメントの出来事を 1 件作る。見張りの id と出来事の id を返す
    private func watchEvent(_ world: ServiceWorld, _ request: WatchCreateRequest) throws -> (watch: Int64, events: [Int64]) {
        let watch = try world.store.createWatch(request).watch.watchID
        try world.store.recordWatchSnapshot(url: pr, snapshot: open(), viewerLogin: "me", at: Date())
        try world.store.recordWatchSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", at: Date())
        return (watch, try world.store.undeliveredWatchEvents(watch: watch).map(\.id))
    }

    private func wakes(_ world: ServiceWorld, clock: TestClock) -> WakeService {
        WakeService(store: world.store, state: world.state, conversations: world.service, isFullWake: { true }, now: { clock.now })
    }

    /// 時刻を過ぎた起こす予定を作る
    private func dueWake(_ world: ServiceWorld, clock: TestClock, _ request: (Date) -> WakeCreateRequest) throws -> Int64 {
        let wake = try world.store.createWake(request(clock.now.addingTimeInterval(60)), now: clock.now)
        clock.advance(120)
        return wake.wakeID
    }

    // MARK: 会話の uuid と入れ直し

    @Test("リンクの知らせ：会話への uuid は知らせの id と取り消された回数から決め、取り消されたら次の回数で入れ直す。届いたら入れ直さない")
    func linkNoticeUUID() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let lead = try await world.service.start(world.request())
        let ids = try await linkNotice(world)
        let joined = ids.map(String.init).joined(separator: ",")
        let notices = LinkNotices(store: world.store, state: world.state, conversations: world.service)

        let first = try await answering(world, key: lead.id, "cancelled") { await notices.deliver(task: world.task) }
        #expect(first == StableUUID.make("taskboard-link-notice:\(joined).0"))
        #expect(try world.store.undeliveredLinkNotices(task: world.task).count == 1, "取り消された回は届けた扱いにしない")
        let second = try await answering(world, key: lead.id, "started") { await notices.deliver(task: world.task) }
        #expect(second == StableUUID.make("taskboard-link-notice:\(joined).1"))
        #expect(try world.store.undeliveredLinkNotices(task: world.task).isEmpty)

        await notices.deliver(task: world.task)
        #expect(await userTexts(world, key: lead.id).count == 2)
    }

    @Test("見張り：会話への uuid は見張りの id・出来事の id・取り消された回数から決め、取り消されたら次の回数で入れ直す。届いたら入れ直さない")
    func watchUUID() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let (watch, events) = try watchEvent(world, WatchCreateRequest(url: pr, conversationID: conversation.id))
        let joined = events.map(String.init).joined(separator: ",")
        let notices = WatchNotices(store: world.store, state: world.state, conversations: world.service)

        let first = try await answering(world, key: conversation.id, "cancelled") { await notices.deliver(watch: watch) }
        #expect(first == StableUUID.make("taskboard-watch:\(watch):\(joined).0"))
        #expect(try world.store.undeliveredWatchEvents(watch: watch).count == 1, "取り消された回は届けた扱いにしない")
        let second = try await answering(world, key: conversation.id, "started") { await notices.deliver(watch: watch) }
        #expect(second == StableUUID.make("taskboard-watch:\(watch):\(joined).1"))
        #expect(try world.store.undeliveredWatchEvents(watch: watch).isEmpty)

        await notices.deliver(watch: watch)
        #expect(await userTexts(world, key: conversation.id).count == 2)
    }

    @Test("起こす予定：会話への uuid は予定の id と取り消された回数から決め、取り消されたら次の回数で入れ直す。届いたら入れ直さない")
    func wakeUUID() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let clock = TestClock(Date())
        let wake = try dueWake(world, clock: clock) { WakeCreateRequest(at: $0, prompt: "続き", conversationID: conversation.id) }
        let service = wakes(world, clock: clock)

        let first = try await answering(world, key: conversation.id, "cancelled") { await service.tick() }
        #expect(first == StableUUID.make("taskboard-wake:\(wake).0"))
        #expect(try world.store.wake(id: wake)?.state == .pending, "取り消された回は届けた扱いにしない")
        let second = try await answering(world, key: conversation.id, "started") { await service.tick() }
        #expect(second == StableUUID.make("taskboard-wake:\(wake).1"))
        #expect(try world.store.wake(id: wake)?.state == .delivered)

        await service.tick()
        #expect(await userTexts(world, key: conversation.id).count == 2)
    }

    // MARK: 止まった TUI の lead

    /// world のタスクに、pane で動いていない Claude の TUI を結ぶ（transcript だけがある）
    private func stoppedTerminal(_ world: ServiceWorld) async throws -> String {
        let tui = "3c9e1f0a-7b2d-4e8a-a6f1-0d2c4b8e9a17"
        try world.append(tui, [("u1", "user", "作って"), ("a1", "assistant", "作った")])
        await world.state.upsert(try world.store.linkSession(task: world.task, agent: "claude", sessionID: tui, cwd: world.directory.path, label: ""))
        return tui
    }

    @Test("見張り：タスク宛てで lead が止まった TUI なら会話で戻し、戻している間は起こし直さない。出来事は戻した会話に渡すまで残す")
    func watchResumesStoppedTerminal() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let tui = try await stoppedTerminal(world)
        let (watch, _) = try watchEvent(world, WatchCreateRequest(url: pr, taskNumber: world.task))
        let notices = WatchNotices(store: world.store, state: world.state, conversations: world.service)

        await notices.deliver(watch: watch)
        let spawn = try #require(await world.host.requests.first { $0.op == .spawn })
        #expect((spawn.argv ?? []).contains(tui), "同じ Claude の会話を戻す")
        #expect(try world.store.undeliveredWatchEvents(watch: watch).count == 1)
        await notices.deliver(watch: watch)
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == 1, "戻している間は起こし直さない")
    }

    @Test("起こす予定：タスク宛てで lead が止まった TUI なら会話で戻して理由を残し、戻している間は起こし直さない")
    func wakeResumesStoppedTerminal() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let tui = try await stoppedTerminal(world)
        let clock = TestClock(Date())
        let wake = try dueWake(world, clock: clock) { WakeCreateRequest(at: $0, prompt: "続き", taskNumber: world.task) }
        let service = wakes(world, clock: clock)

        await service.tick()
        let spawn = try #require(await world.host.requests.first { $0.op == .spawn })
        #expect((spawn.argv ?? []).contains(tui), "同じ Claude の会話を戻す")
        let waiting = try #require(try world.store.wake(id: wake))
        #expect(waiting.state == .pending && waiting.failure == "停止したセッションを再開しています")
        #expect(waiting.conversationID == nil)
    }
}
