import Foundation
import Observation
import Testing

@testable import TaskboardKit

/// テストが流したときにイベントを届ける供給元
private struct ScriptedSource: SnapshotSource {
    let snap: StateSnapshot
    let stream: AsyncThrowingStream<DaemonEvent, any Error>

    func snapshot() async throws -> StateSnapshot { snap }
    func events() -> AsyncThrowingStream<DaemonEvent, any Error> { stream }
}

@MainActor
@Suite("Fleet の描き直し")
struct FleetObservationTests {
    let machine = MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t")
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    func usage(_ percent: Double) -> UsageSnapshot {
        UsageSnapshot(claude: ClaudeUsage(fiveHour: UsageWindow(usedPercent: percent, resetsAt: nil, windowSeconds: 18_000), sevenDay: nil, at: t0))
    }

    /// snapshot を読み込ませてから `events` を流し、`done` を満たすまでに `allMachines` が書き換わったら true
    func machinesChange(_ fleet: Fleet, snap: StateSnapshot, events: [DaemonEvent], done: @escaping @MainActor () -> Bool) async throws -> Bool {
        let (stream, continuation) = AsyncThrowingStream<DaemonEvent, any Error>.makeStream()
        fleet.add(id: "local", source: ScriptedSource(snap: snap, stream: stream), reconnectDelay: .seconds(60))
        for _ in 0..<100 where fleet.allMachines["local"]?.machine == nil { try await Task.sleep(for: .milliseconds(10)) }
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = fleet.allMachines } onChange: { changed = true }
        for event in events { continuation.yield(event) }
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done())
        return changed
    }

    @Test("利用枠が届いても、マシンの状態を読む画面は描き直さない")
    func usageDoesNotTouchMachines() async throws {
        let fleet = Fleet()
        let changed = try await machinesChange(
            fleet, snap: StateSnapshot(machine: machine, usage: usage(10), generatedAt: t0), events: [.usageUpdated(usage(20))],
            done: { fleet.usage(fleetID: "local")?.claude?.fiveHour?.usedPercent == 20 })
        #expect(!changed)
        #expect(fleet.allMachines["local"]?.usage == nil, "利用枠は Fleet.usage だけに持つ")
        #expect(fleet.usage(for: machine.id)?.claude?.fiveHour?.usedPercent == 20)
        fleet.remove(id: "local")
        #expect(fleet.usage(fleetID: "local") == nil)
    }

    @Test("中身の変わらないイベントは書き込まない")
    func unchangedEventIsSkipped() async throws {
        let fleet = Fleet()
        let board = Board(id: "b", machine: machine.id, name: "ボード", position: 0, columns: [], createdAt: t0)
        // 利用枠は順に処理される最後の印。届いた時点で前の boardUpdated も処理済み
        let changed = try await machinesChange(
            fleet, snap: StateSnapshot(machine: machine, boards: [board], generatedAt: t0), events: [.boardUpdated(board), .usageUpdated(usage(30))],
            done: { fleet.usage(fleetID: "local") != nil })
        #expect(!changed)

        var renamed = board
        renamed.name = "改名"
        let other = Fleet()
        let written = try await machinesChange(
            other, snap: StateSnapshot(machine: machine, boards: [board], generatedAt: t0), events: [.boardUpdated(renamed), .usageUpdated(usage(30))],
            done: { other.usage(fleetID: "local") != nil })
        #expect(written, "変われば書く")
        #expect(other.allMachines["local"]?.boards["b"]?.name == "改名")
    }

    // MARK: 会話と接続先の引き方

    func conversation(_ id: String, title: String? = nil) -> Conversation {
        Conversation(id: id, machine: machine.id, taskNumber: 1, agentSessionID: "a-\(id)", cwd: "/", title: title, runner: .host, phase: .idle, createdAt: t0, updatedAt: t0)
    }

    /// snapshot（会話 c1・c2）を読み込ませ、流すための口を返す
    func loaded(_ fleet: Fleet) async throws -> AsyncThrowingStream<DaemonEvent, any Error>.Continuation {
        var snap = StateSnapshot(machine: machine, generatedAt: t0)
        snap.conversations = [conversation("c1", title: "一"), conversation("c2", title: "二")]
        let (stream, continuation) = AsyncThrowingStream<DaemonEvent, any Error>.makeStream()
        fleet.add(id: "local", source: ScriptedSource(snap: snap, stream: stream), reconnectDelay: .seconds(60))
        for _ in 0..<100 where fleet.allMachines["local"]?.machine == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(fleet.allMachines["local"]?.machine != nil)
        return continuation
    }

    /// `read` を見張り、`act` の後に `done` を満たすまで待って、見張りが知らせを受けたら true
    func notifies(_ read: @escaping @MainActor () -> Void, after act: () -> Void, done: @escaping @MainActor () -> Bool) async throws -> Bool {
        nonisolated(unsafe) var changed = false
        withObservationTracking { read() } onChange: { changed = true }
        act()
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done())
        return changed
    }

    var key1: ConversationKey { ConversationKey(machine: machine.id, id: "c1") }

    @Test("ほかの会話や作業項目の知らせでは、会話を読む画面と書き込めるかを読む画面を描き直さない。その会話が変われば描き直す")
    func conversationReadersFollowOnlyTheirConversation() async throws {
        let fleet = Fleet()
        let events = try await loaded(fleet)
        #expect(fleet.conversation(for: key1)?.title == "一")
        let other = try await notifies({ _ = fleet.conversation(for: key1); _ = fleet.writeAccess(machine.id) }, after: {
            events.yield(.conversationUpdated(conversation("c2", title: "二の改")))
        }, done: { fleet.allMachines["local"]?.conversations[ConversationKey(machine: machine.id, id: "c2")]?.title == "二の改" })
        #expect(!other)
        let own = try await notifies({ _ = fleet.conversation(for: key1) }, after: {
            events.yield(.conversationUpdated(conversation("c1", title: "一の改")))
        }, done: { fleet.conversation(for: key1)?.title == "一の改" })
        #expect(own)
        let removed = try await notifies({ _ = fleet.conversation(for: key1) }, after: {
            events.yield(.conversationRemoved(key1))
        }, done: { fleet.conversation(for: key1) == nil })
        #expect(removed)
    }

    @Test("1 台だけ表示・非表示・接続先の削除で、会話と書き込めるかが入れ直される")
    func conversationFollowsVisibility() async throws {
        let fleet = Fleet()
        _ = try await loaded(fleet)
        #expect(fleet.conversation(for: key1)?.title == "一")
        #expect(fleet.writeAccess(machine.id) == .readOnly)

        #expect(try await notifies({ _ = fleet.conversation(for: key1) }, after: { fleet.hiddenMachines = ["local"] }, done: { fleet.conversation(for: key1) == nil }))
        #expect(fleet.writeAccess(machine.id) == .hidden)
        #expect(try await notifies({ _ = fleet.conversation(for: key1) }, after: { fleet.hiddenMachines = [] }, done: { fleet.conversation(for: key1) != nil }))

        #expect(try await notifies({ _ = fleet.conversation(for: key1) }, after: { fleet.onlyMachine = "other" }, done: { fleet.conversation(for: key1) == nil }))
        #expect(try await notifies({ _ = fleet.conversation(for: key1) }, after: { fleet.onlyMachine = "local" }, done: { fleet.conversation(for: key1)?.title == "一" }))

        #expect(try await notifies({ _ = fleet.conversation(for: key1); _ = fleet.writeAccess(machine.id) }, after: { fleet.remove(id: "local") }, done: { fleet.conversation(for: key1) == nil }))
        #expect(fleet.writeAccess(machine.id) == .unknown)
        #expect(fleet.fleetID(for: machine.id) == nil)
    }

    @Test("フォーク・委譲先・モデルの一覧を読む画面は、ほかの会話の知らせでは描き直さず、その値が変わったときだけ描き直す")
    func derivedReadersFollowOnlyTheirValues() async throws {
        let fleet = Fleet()
        let events = try await loaded(fleet)
        let c1 = try #require(fleet.conversation(for: key1))
        let read: @MainActor () -> Void = {
            _ = fleet.forks(of: c1); _ = fleet.delegates(of: c1); _ = fleet.engines(on: machine.id)
            _ = fleet.conversationSource(for: machine.id); _ = fleet.usage(for: machine.id)
        }
        #expect(!(try await notifies(read, after: {
            events.yield(.conversationUpdated(conversation("c2", title: "二の改")))
        }, done: { fleet.conversation(for: ConversationKey(machine: machine.id, id: "c2"))?.title == "二の改" })))

        var fork = conversation("f1")
        fork.forkSource = "c1"
        #expect(try await notifies({ _ = fleet.forks(of: c1) }, after: { events.yield(.conversationUpdated(fork)) }, done: { fleet.forks(of: c1).map(\.id) == ["f1"] }))
        var child = conversation("d1")
        child.parentConversationID = "c1"
        #expect(try await notifies({ _ = fleet.delegates(of: c1) }, after: { events.yield(.conversationUpdated(child)) }, done: { fleet.delegates(of: c1).map(\.id) == ["d1"] }))
        let claude = ClaudeMachineInfo(models: [], version: "2")
        #expect(try await notifies({ _ = fleet.engines(on: machine.id) }, after: { fleet.setClaudeMachine(claude, for: machine.id) }, done: { fleet.engines(on: machine.id).claude == claude }))

        #expect(try await notifies({ _ = fleet.delegates(of: c1) }, after: { fleet.hiddenMachines = ["local"] }, done: { fleet.delegates(of: c1).isEmpty }))
        #expect(fleet.forks(of: c1).isEmpty)
    }

    @Test("多くの会話を引いて古い箱を捨てても、読んでいた画面は描き直されて今の値を引き直す")
    func evictedCellsNotifyTheirReaders() async throws {
        let fleet = Fleet()
        let events = try await loaded(fleet)
        let evicted = try await notifies({ _ = fleet.conversation(for: key1) }, after: {
            for n in 0..<1_000 { _ = fleet.conversation(for: ConversationKey(machine: machine.id, id: "x\(n)")) }
        }, done: { true })
        #expect(evicted)
        events.yield(.conversationUpdated(conversation("c1", title: "一の改")))
        for _ in 0..<100 where fleet.conversation(for: key1)?.title != "一の改" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fleet.conversation(for: key1)?.title == "一の改")
    }

    @Test("同じ接続先を足し直すと、読み込むまで前の会話を返さず、読み込んだら新しい会話を返す")
    func readdingReplacesConversations() async throws {
        let fleet = Fleet()
        _ = try await loaded(fleet)
        #expect(fleet.conversation(for: key1)?.title == "一")
        var snap = StateSnapshot(machine: machine, generatedAt: t0)
        snap.conversations = [conversation("c1", title: "新")]
        let (stream, _) = AsyncThrowingStream<DaemonEvent, any Error>.makeStream()
        fleet.add(id: "local", source: ScriptedSource(snap: snap, stream: stream), reconnectDelay: .seconds(60))
        #expect(fleet.conversation(for: key1) == nil)
        for _ in 0..<100 where fleet.conversation(for: key1) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fleet.conversation(for: key1)?.title == "新")
    }
}
