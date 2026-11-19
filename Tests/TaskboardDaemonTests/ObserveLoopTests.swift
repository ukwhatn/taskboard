import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-observe")
private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
private let prURL = "https://github.com/o/r/pull/12"
private let issueURL = "https://github.com/o/r/issues/7"

private func eventually(_ condition: @Sendable () async -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private func openPR(comments: [PullRequestSnapshot.Comment] = []) -> LinkSnapshot {
    .pullRequest(PullRequestSnapshot(state: .open, headSHA: "a1", mergeable: .mergeable, comments: comments, inlineComments: []))
}

private func comment(_ id: Int) -> PullRequestSnapshot.Comment { .init(id: "IC\(id)", author: "bob", url: "\(prURL)#issuecomment-\(id)") }

/// 見回りを止めたら購読が外れる。`run` を止めて終わりを待ち、数を読む
private func stop(_ run: Task<Void, Never>, _ state: DaemonState) async -> Int {
    run.cancel()
    await run.value
    return await state.subscriberCount
}

/// 権限の確認を待っている host の会話（受信箱の対応待ちになる）
func waitingConversation(_ id: String, machine: MachineID) -> Conversation {
    let waiting = RequestWaiting(id: "r-\(id)", since: Date(), permission: .init(tool: "Bash", summary: "ls"))
    return Conversation(
        id: id, machine: machine, taskNumber: nil, agentSessionID: "s-\(id)", cwd: "/w", runner: .host, phase: .waiting,
        pending: [ConversationRequest(id: "r-\(id)", kind: .permission, toolName: "Bash", toolUseID: nil, waiting: waiting)], createdAt: Date(),
        updatedAt: Date())
}

/// PR を結んだタスク
private struct Lead {
    let store: Store
    let state: DaemonState
    let task: BoardTask

    init() async throws {
        store = try Store(inMemory: machine)
        state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let board = try store.createBoard(name: "a", columns: nil)
        task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x", links: [prURL]))
        await state.upsert(task)
    }
}

@Suite("見回りのループ（購読して出来事を受け、周期で見回り、止めたら購読を外す）", .serialized)
struct ObserveLoopTests {
    @Test("LinkNotices: 始めに見回って届けた古い知らせを消し、止めたら購読を外す")
    func linkNotices() async throws {
        let lead = try await Lead()
        try lead.store.recordLinkSnapshot(url: prURL, snapshot: openPR(), viewerLogin: "me", tasks: [lead.task.number], at: t0)
        try lead.store.recordLinkSnapshot(url: prURL, snapshot: openPR(comments: [comment(1), comment(2)]), viewerLogin: "me", tasks: [lead.task.number], at: t0 + 60)
        let first = try #require(try lead.store.undeliveredLinkNotices(task: lead.task.number).first)
        try lead.store.markLinkNoticesDelivered(ids: [first.id], at: t0 + 120)
        #expect(try lead.store.linkNotices(task: lead.task.number, limit: 100).notices.count == 2)

        let notices = LinkNotices(store: lead.store, state: lead.state, conversations: nil, now: { t0 + 120 + Store.finishedRowRetention + 1 })
        let run = Task { await notices.run() }
        #expect(await eventually { (try? lead.store.linkNotices(task: lead.task.number, limit: 100).notices.count) == 1 }, "始めに見回る")
        #expect(await stop(run, lead.state) == 0)
    }

    @Test("WatchNotices: 始めに見回って期限を過ぎた見張りを終え、止めたら購読を外す")
    func watchNotices() async throws {
        let lead = try await Lead()
        let live = try lead.store.createWatch(WatchCreateRequest(url: prURL, taskNumber: lead.task.number), now: t0).watch
        let expiring = try lead.store.createWatch(WatchCreateRequest(url: issueURL, taskNumber: lead.task.number, expiresAt: t0 + 60), now: t0).watch

        let notices = WatchNotices(store: lead.store, state: lead.state, conversations: nil, now: { t0 + 61 })
        let run = Task { await notices.run() }
        #expect(await eventually { (try? lead.store.watch(id: expiring.watchID))?.ending == .expired }, "始めに見回る")
        #expect(try lead.store.watch(id: live.watchID)?.state == .active)
        #expect(await stop(run, lead.state) == 0)
    }

    /// ターンを終えて静かになった定期起動の回の会話（`ScheduledRunCloser` が止めるもの）
    private func finishedRunConversation(_ world: ServiceWorld) async throws -> String {
        let scheduler = Scheduler(store: world.store, state: world.state, conversations: world.service, accounts: nil, isFullWake: { true }, isOnline: { true })
        let (schedule, _) = try world.store.createSchedule(
            ScheduleCreateRequest(name: "巡回", rule: .interval(minutes: 60), cwd: world.directory.path, kind: .claude, prompt: "棚卸し"), now: Date())
        let run = try await scheduler.runNow(id: schedule.scheduleID)
        let id = try #require(run.conversationID)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(Scheduler.firstMessageID(runID: run.id))","state":"started"}"#)
        await world.host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { (try? await world.service.get(id))?.phase == .idle })
        await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)
        return id
    }

    @Test("ScheduledRunCloser: 出来事が無くても、周期の見回りで終えた回の会話を止める")
    func closerSweepsConversations() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let id = try await finishedRunConversation(world)
        let closer = ScheduledRunCloser(
            store: world.store, state: world.state, conversations: world.service, sweepInterval: .milliseconds(50))
        let loop = Task { await closer.run() }
        #expect(await eventually { await !world.service.isLive(id) })
        #expect(await stop(loop, world.state) == 0)
    }

    @Test("ScheduledRunCloser: 止められたら、周期を待っていても最後にもう 1 回見回らない")
    func closerDoesNotSweepAfterCancel() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let id = try await finishedRunConversation(world)
        let closer = ScheduledRunCloser(
            store: world.store, state: world.state, conversations: world.service, sweepInterval: .seconds(3600))
        let loop = Task { await closer.run() }
        #expect(await eventually { await world.state.subscriberCount == 1 })
        #expect(await stop(loop, world.state) == 0)
        #expect(await world.service.isLive(id))
    }

    @Test("FeedbackService: 購読し、止められたら周期を待っていても最後にもう 1 回見回らない")
    func feedbackDoesNotSweepAfterCancel() async throws {
        let lead = try await Lead()
        let feedback = FeedbackService(store: lead.store, state: lead.state)
        let loop = Task { await feedback.run() }
        #expect(await eventually { await lead.state.subscriberCount == 1 })
        #expect(await stop(loop, lead.state) == 0)
    }
}

@Suite("見回りのループ: PushNotifier と OrchestratorKeeper（agent host に繋がるまで待つ）", .serialized)
struct ObserveLoopHostTests {
    private struct Push {
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let fake = FakeAPNs()
        let keys: TestKeys
        let notifier: PushNotifier

        init(debounce: Duration, resyncInterval: Duration) async throws {
            let store = try Store(inMemory: machine)
            keys = try TestKeys()
            try store.insertDevice(DeviceInfo(id: "d", name: "iPhone", platform: .ios, createdAt: Date()), tokenHash: "hash-d")
            _ = try store.setPushRegistration(
                deviceID: "d",
                PushRegistration(
                    token: String(repeating: "a", count: 64), environment: .sandbox, topic: "uk.whatn.taskboard.ios", kinds: NotifyKind.allCases, sound: true,
                    machineName: "Studio", connection: "conn-1"), at: Date())
            let push = PushService(store: store, sender: APNsSender(keys: keys.store, transport: fake))
            notifier = PushNotifier(state: state, push: push, debounce: debounce, resyncInterval: resyncInterval)
            await state.setAgentHost(AgentHostInfo(connected: true))
        }

        /// agent host に繋がっていて、待ちを終えて基準を取った
        func started(_ run: Task<Void, Never>) async -> Bool {
            guard await eventually({ await state.subscriberCount == 1 }, seconds: 10) else { return false }
            try? await Task.sleep(for: .milliseconds(300))
            return true
        }
    }

    @Test("PushNotifier: 出来事を受けたらまとめてから送り、止めたら購読を外す")
    func pushHandlesEvents() async throws {
        let push = try await Push(debounce: .milliseconds(100), resyncInterval: .seconds(3600))
        defer { push.keys.remove() }
        let run = Task { await push.notifier.run() }
        #expect(await push.started(run))
        await push.state.upsert(waitingConversation("c1", machine: machine))
        #expect(await eventually { push.fake.requests.value.count == 1 })
        #expect(await stop(run, push.state) == 0)
    }

    @Test("PushNotifier: 出来事が来なくても、周期で作り直して送る")
    func pushResyncs() async throws {
        let push = try await Push(debounce: .seconds(3600), resyncInterval: .milliseconds(100))
        defer { push.keys.remove() }
        let run = Task { await push.notifier.run() }
        #expect(await push.started(run))
        await push.state.upsert(waitingConversation("c1", machine: machine))
        #expect(await eventually { push.fake.requests.value.count == 1 })
        #expect(await stop(run, push.state) == 0)
    }

    @Test("PushNotifier: 止めたら、待っている送りも取り消す")
    func pushCancelsPendingFlush() async throws {
        let push = try await Push(debounce: .milliseconds(500), resyncInterval: .seconds(3600))
        defer { push.keys.remove() }
        let run = Task { await push.notifier.run() }
        #expect(await push.started(run))
        await push.state.upsert(waitingConversation("c1", machine: machine))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await stop(run, push.state) == 0)
        try await Task.sleep(for: .milliseconds(800))
        #expect(push.fake.requests.value.isEmpty)
    }

    @Test("OrchestratorKeeper: agent host に繋がるまで見に行かず、繋がったら始めに見回る。周期で見回り、止めたら購読を外す")
    func keeperWaitsThenObserves() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        _ = try world.store.updateSettings(MachineSettingsUpdate(orchestratorEnabled: false))
        let keeper = OrchestratorKeeper(store: world.store, state: world.state, conversations: world.service, interval: .milliseconds(100))
        let run = Task { await keeper.run() }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(await world.state.orchestratorInfo() == nil, "agent host に繋がるまでは見回らない")
        #expect(await world.state.subscriberCount == 0)

        await world.state.setAgentHost(AgentHostInfo(connected: true))
        #expect(await eventually({ await world.state.orchestratorInfo() != nil }, seconds: 10), "繋がったら始めに見回る")
        #expect(await world.state.orchestratorInfo()?.enabled == false)
        _ = try world.store.updateSettings(MachineSettingsUpdate(orchestratorEnabled: true))
        #expect(await eventually { await world.state.orchestratorInfo()?.enabled == true }, "周期で見回る")
        #expect(await stop(run, world.state) == 0)
    }
}

@Suite("DaemonState.observe: 6 本のループが使う口")
struct ObserveTests {
    private func state() -> DaemonState {
        DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
    }

    @Test("sweepFirst なら始めに 1 回見回ってから待つ。そうでなければ待ってから見回る")
    func sweepOrder() async {
        let state = state()
        let first = Locked(0)
        let loop = Task { await state.observe(every: .seconds(3600), sweepFirst: true, handle: { _ in }, sweep: { first.update { $0 += 1 } }) }
        #expect(await eventually { first.value == 1 })
        #expect(await stop(loop, state) == 0)
        #expect(first.value == 1)

        let later = Locked(0)
        let waiting = Task { await state.observe(every: .seconds(3600), sweepFirst: false, handle: { _ in }, sweep: { later.update { $0 += 1 } }) }
        #expect(await eventually { await state.subscriberCount == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(later.value == 0, "待ちが先")
        #expect(await stop(waiting, state) == 0)
        #expect(later.value == 0, "止められたら見回らない")

        let ticking = Locked(0)
        let periodic = Task { await state.observe(every: .milliseconds(30), sweepFirst: false, handle: { _ in }, sweep: { ticking.update { $0 += 1 } }) }
        #expect(await eventually { ticking.value >= 3 })
        #expect(await stop(periodic, state) == 0)
    }

    @Test("出来事を handle に渡す。購読した直後の `subscribed` が終わるまでの出来事は溜めて、その後に渡す")
    func handlesEventsAfterSubscribed() async {
        let state = state()
        let log = Locked<[String]>([])
        let loop = Task {
            await state.observe(
                every: .seconds(3600), sweepFirst: false,
                subscribed: {
                    try? await Task.sleep(for: .milliseconds(200))
                    log.update { $0.append("subscribed") }
                }, handle: { event in
                    if case .conversationUpdated(let conversation) = event { log.update { $0.append(conversation.id) } }
                }, sweep: {})
        }
        #expect(await eventually { await state.subscriberCount == 1 })
        await state.upsert(waitingConversation("c1", machine: machine))
        #expect(await eventually { log.value.count == 2 })
        #expect(log.value == ["subscribed", "c1"])
        #expect(await stop(loop, state) == 0)
    }

    @Test("waitForAgentHost は agent host に繋がるまで待ち、繋がったら settle 待って戻る")
    func waitsForAgentHost() async {
        let state = state()
        let done = Locked(false)
        let waiter = Task {
            await state.waitForAgentHost(poll: .milliseconds(10), settle: .milliseconds(50))
            done.update { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!done.value)
        await state.setAgentHost(AgentHostInfo(connected: true))
        #expect(await eventually { done.value })
        await waiter.value
    }
}
