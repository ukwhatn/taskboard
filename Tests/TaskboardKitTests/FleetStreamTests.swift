import Foundation
import Testing

@testable import TaskboardKit

/// テストが frame を流す接続。送られた 1 通を記録する
private final class FakeConnection: StreamConnection, @unchecked Sendable {
    let frames: AsyncThrowingStream<StreamServerFrame, any Error>
    let continuation: AsyncThrowingStream<StreamServerFrame, any Error>.Continuation
    private let lock = NSLock()
    private var stored: [StreamClientMessage] = []
    /// upgrade を断られた接続
    var refused = false

    init() {
        (frames, continuation) = AsyncThrowingStream<StreamServerFrame, any Error>.makeStream()
    }

    var sent: [StreamClientMessage] { lock.withLock { stored } }

    func send(_ message: StreamClientMessage) async throws { lock.withLock { stored.append(message) } }
    func close() { continuation.finish() }
}

/// 開くたびに新しい接続を作る。`refusal` があれば upgrade をその状態で断る
private final class FakeStreamSource: StreamSource, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [FakeConnection] = []
    private var refusalStatus: Int?
    var refusal: Int? {
        get { lock.withLock { refusalStatus } }
        set { lock.withLock { refusalStatus = newValue } }
    }

    init(refusal: Int? = nil) {
        refusalStatus = refusal
    }

    var connections: [FakeConnection] { lock.withLock { opened } }

    func openStateStream() -> any StreamConnection {
        let connection = FakeConnection()
        if let refusal {
            connection.refused = true
            connection.continuation.finish(throwing: SessionSourceError.httpStatus(refusal))
        }
        lock.withLock { opened.append(connection) }
        return connection
    }
}

@MainActor
private final class RecordingListener: ConversationListener {
    var resumePoint: (epoch: String?, after: Int) = (nil, 0)
    var events: [ConversationEvent] = []
    var subscribedEpochs: [String] = []
    var unsubscribedReasons: [String] = []
    var disconnects = 0

    func streamSubscribed(epoch: String, through: Int) { subscribedEpochs.append(epoch) }
    func streamEvent(_ event: ConversationEvent) { events.append(event) }
    func streamUnsubscribed(reason: String) { unsubscribedReasons.append(reason) }
    func streamDisconnected() { disconnects += 1 }
}

@MainActor
@Suite("1 本の接続で状態と会話を受ける")
struct FleetStreamTests {
    let info = MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t")
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    func usage(_ percent: Double) -> UsageSnapshot {
        UsageSnapshot(claude: ClaudeUsage(fiveHour: UsageWindow(usedPercent: percent, resetsAt: nil, windowSeconds: 18_000), sevenDay: nil, at: t0))
    }

    func conversation(_ id: String, phase: Conversation.Phase = .idle) -> Conversation {
        Conversation(id: id, machine: info.id, taskNumber: 1, agentSessionID: "a-\(id)", cwd: "/tmp", runner: .host, phase: phase, createdAt: t0, updatedAt: t0)
    }

    func task(_ number: Int, title: String = "題") -> BoardTask {
        BoardTask(machine: info.id, number: number, boardID: "b", columnID: "todo", title: title, createdAt: t0, updatedAt: t0)
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test("出来事を当てた後に全体を受けると、新しく取った全体と同じになり、利用枠は Fleet.usage にだけ入る")
    func stateReplacesEverything() async throws {
        var first = StateSnapshot(machine: info, tasks: [task(1), task(2)], usage: usage(10), generatedAt: t0)
        first.conversations = [conversation("c1"), conversation("c2")]
        let dismissal = InboxDismissal(itemID: "ask/1", revision: "r1", dismissedAt: t0)
        var fresh = StateSnapshot(machine: info, tasks: [task(2, title: "直した")], usage: usage(42), generatedAt: t0)
        fresh.conversations = [conversation("c2", phase: .running)]

        let source = FakeStreamSource()
        let fleet = Fleet()
        fleet.add(id: "local", source: source, reconnectDelay: .seconds(60))
        try await waitUntil { source.connections.count == 1 }
        let connection = source.connections[0]
        connection.continuation.yield(.state(epoch: "e1", rev: 1, snapshot: first))
        connection.continuation.yield(.event(rev: 2, event: .taskRemoved(TaskKey(machine: info.id, number: 1))))
        connection.continuation.yield(.event(rev: 3, event: .conversationRemoved(ConversationKey(machine: info.id, id: "c1"))))
        connection.continuation.yield(.event(rev: 4, event: .inboxDismissalsUpdated([dismissal])))
        connection.continuation.yield(.event(rev: 5, event: .usageUpdated(usage(20))))
        connection.continuation.yield(.state(epoch: "e1", rev: 6, snapshot: fresh))
        try await waitUntil { fleet.usage(fleetID: "local")?.claude?.fiveHour?.usedPercent == 42 }

        let other = Fleet()
        let otherSource = FakeStreamSource()
        other.add(id: "local", source: otherSource, reconnectDelay: .seconds(60))
        try await waitUntil { otherSource.connections.count == 1 }
        otherSource.connections[0].continuation.yield(.state(epoch: "e1", rev: 6, snapshot: fresh))
        try await waitUntil { other.allMachines["local"]?.machine != nil }

        #expect(fleet.allMachines["local"] == other.allMachines["local"])
        #expect(fleet.allMachines["local"]?.inboxDismissals.isEmpty == true)
        #expect(fleet.allMachines["local"]?.usage == nil)
        #expect(fleet.allMachines["local"]?.conversations.keys.map(\.id) == ["c2"])
        #expect(connection.sent == [.hello(epoch: nil, rev: nil)])
        fleet.remove(id: "local")
        other.remove(id: "local")
    }

    @Test("番号が飛んだら、番号を捨てて繋ぎ直し、全体を受ける")
    func revisionGapRestarts() async throws {
        let source = FakeStreamSource()
        let fleet = Fleet()
        fleet.add(id: "local", source: source, reconnectDelay: .seconds(60))
        try await waitUntil { source.connections.count == 1 }
        source.connections[0].continuation.yield(.state(epoch: "e1", rev: 3, snapshot: StateSnapshot(machine: info, generatedAt: t0)))
        // 重なった番号は読み捨てる
        source.connections[0].continuation.yield(.event(rev: 3, event: .taskUpdated(task(9))))
        source.connections[0].continuation.yield(.event(rev: 4, event: .taskUpdated(task(1))))
        source.connections[0].continuation.yield(.event(rev: 6, event: .taskUpdated(task(2))))
        try await waitUntil { source.connections.count == 2 }
        #expect(source.connections[1].sent.first == .hello(epoch: nil, rev: nil))
        let tasks = Set(fleet.allMachines["local"]?.tasks.keys.map(\.number) ?? [])
        #expect(tasks == [1])
        fleet.remove(id: "local")
    }

    @Test("繋がった回数は、切れてから繋ぎ直したときだけ増える（同じ接続の全体の受け直しと、番号が飛んだ繋ぎ直しでは増えない）")
    func countsReconnections() async throws {
        let source = FakeStreamSource()
        let fleet = Fleet()
        fleet.add(id: "local", source: source, reconnectDelay: .milliseconds(10))
        try await waitUntil { source.connections.count == 1 }
        #expect(fleet.allMachines["local"]?.connection == 0)
        let snapshot = StateSnapshot(machine: info, generatedAt: t0)
        source.connections[0].continuation.yield(.state(epoch: "e1", rev: 1, snapshot: snapshot))
        try await waitUntil { fleet.allMachines["local"]?.connected == true }
        source.connections[0].continuation.yield(.state(epoch: "e1", rev: 2, snapshot: snapshot))
        source.connections[0].continuation.yield(.event(rev: 4, event: .taskUpdated(task(1))))
        try await waitUntil { source.connections.count == 2 }
        source.connections[1].continuation.yield(.state(epoch: "e1", rev: 4, snapshot: snapshot))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fleet.allMachines["local"]?.connection == 1)

        // daemon を入れ替えた：接続が切れ、繋ぎ直す
        source.connections[1].close()
        try await waitUntil { source.connections.count == 3 }
        source.connections[2].continuation.yield(.state(epoch: "e2", rev: 0, snapshot: snapshot))
        try await waitUntil { fleet.allMachines["local"]?.connection == 2 }
        #expect(fleet.allMachines["local"]?.connected == true)
        fleet.remove(id: "local")
    }

    @Test("daemon が /v1/stream を断ったら（400）、繋がっていない扱いにして、間をおいて 1 本の接続を開き直す")
    func retriesStreamAfterRefusal() async throws {
        let source = FakeStreamSource(refusal: 400)
        let fleet = Fleet()
        fleet.add(id: "local", source: source, reconnectDelay: .milliseconds(10))
        try await waitUntil { source.connections.count >= 2 }
        #expect(fleet.allMachines["local"]?.connected == false)
        #expect(fleet.allMachines["local"]?.lastError == "httpStatus(400)")

        // daemon を入れ替えた：次の upgrade は通る
        source.refusal = nil
        try await waitUntil { source.connections.contains { !$0.refused } }
        let opened = try #require(source.connections.first { !$0.refused })
        opened.continuation.yield(.state(epoch: "e1", rev: 0, snapshot: StateSnapshot(machine: info, tasks: [task(1)], generatedAt: t0)))
        try await waitUntil { fleet.isStreaming(self.info.id) }
        #expect(fleet.allMachines["local"]?.tasks.count == 1)
        fleet.remove(id: "local")
    }

    @Test("同じ会話を 2 か所で開いても subscribe は 1 つ、両方が離れたら unsubscribe を 1 つ")
    func subscriptionsAreCounted() async throws {
        let source = FakeStreamSource()
        let fleet = Fleet()
        fleet.add(id: "local", source: source, reconnectDelay: .seconds(60))
        try await waitUntil { source.connections.count == 1 }
        let connection = source.connections[0]
        connection.continuation.yield(.state(epoch: "e1", rev: 1, snapshot: StateSnapshot(machine: info, generatedAt: t0)))
        try await waitUntil { fleet.isStreaming(info.id) }
        let key = ConversationKey(machine: info.id, id: "c1")
        let listener = RecordingListener()
        listener.resumePoint = ("e0", 7)
        fleet.retainConversation(key, listener: listener)
        fleet.retainConversation(key, listener: listener)
        try await waitUntil { connection.sent.count == 2 }
        #expect(connection.sent.last == .subscribe(conversation: "c1", epoch: "e0", after: 7, subagents: true))

        let event = ConversationEvent(seq: 8, conversationID: "c1", at: t0, kind: .notice("x"))
        connection.continuation.yield(.subscribed(conversation: "c1", epoch: "e1", through: 8))
        connection.continuation.yield(.conversation(event))
        connection.continuation.yield(.conversation(ConversationEvent(seq: 1, conversationID: "other", at: t0, kind: .gap)))
        try await waitUntil { listener.events.count == 1 }
        #expect(listener.subscribedEpochs == ["e1"])
        #expect(listener.events == [event])

        fleet.releaseConversation(key)
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.sent.count == 2)
        fleet.releaseConversation(key)
        try await waitUntil { connection.sent.count == 3 }
        #expect(connection.sent.last == .unsubscribe(conversation: "c1"))
        #expect(fleet.subscribedConversations.isEmpty)

        // 確かめ用の切り替えの間は unsubscribe を送らない
        fleet.keepsSubscriptions = true
        fleet.retainConversation(key, listener: listener)
        fleet.releaseConversation(key)
        try await waitUntil { connection.sent.count == 4 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.sent.count == 4)
        fleet.remove(id: "local")
    }

    @Test("繋ぎ直したら、前の番号で hello を送り、続きを受けてから購読していた会話を手元の seq から購読し直す")
    func reconnectResubscribes() async throws {
        let source = FakeStreamSource()
        let fleet = Fleet()
        fleet.add(id: "local", source: source, reconnectDelay: .milliseconds(10))
        try await waitUntil { source.connections.count == 1 }
        source.connections[0].continuation.yield(.state(epoch: "e1", rev: 4, snapshot: StateSnapshot(machine: info, generatedAt: t0)))
        try await waitUntil { fleet.isStreaming(info.id) }
        let listener = RecordingListener()
        fleet.retainConversation(ConversationKey(machine: info.id, id: "c1"), listener: listener)
        try await waitUntil { source.connections[0].sent.count == 2 }

        listener.resumePoint = ("e1", 12)
        source.connections[0].continuation.yield(.event(rev: 5, event: .taskUpdated(task(1))))
        source.connections[0].continuation.finish(throwing: SessionSourceError.disconnected)
        try await waitUntil { source.connections.count == 2 }
        #expect(listener.disconnects == 1)
        let second = source.connections[1]
        try await waitUntil { !second.sent.isEmpty }
        #expect(second.sent == [.hello(epoch: "e1", rev: 5)])
        second.continuation.yield(.resume(epoch: "e1", rev: 5))
        try await waitUntil { second.sent.count == 2 }
        #expect(second.sent.last == .subscribe(conversation: "c1", epoch: "e1", after: 12, subagents: true))

        // 読むのが遅れて購読を終えられたら、最後の seq から購読し直す
        listener.resumePoint = ("e1", 20)
        second.continuation.yield(.unsubscribed(conversation: "c1", reason: StreamServerFrame.behind))
        try await waitUntil { second.sent.count == 3 }
        #expect(second.sent.last == .subscribe(conversation: "c1", epoch: "e1", after: 20, subagents: true))
        second.continuation.yield(.unsubscribed(conversation: "c1", reason: StreamServerFrame.removed))
        try await waitUntil { listener.unsubscribedReasons == [StreamServerFrame.removed] }
        fleet.remove(id: "local")
    }

    @Test("会話の問いは受信箱に出て、答えて問いが無くなった会話の出来事で消える")
    func inboxRequestGoesAwayAfterAnswer() async throws {
        let waiting = RequestWaiting(id: "r1", since: t0, permission: RequestWaiting.Permission(tool: "Bash", summary: "ls"))
        let request = ConversationRequest(id: "r1", kind: .permission, toolName: "Bash", toolUseID: nil, waiting: waiting)
        var asking = conversation("c1", phase: .waiting)
        asking.pending = [request]
        var snapshot = StateSnapshot(machine: info, generatedAt: t0)
        snapshot.conversations = [asking]
        let source = FakeStreamSource()
        let fleet = Fleet(now: { self.t0 })
        fleet.add(id: "local", source: source, reconnectDelay: .seconds(60))
        try await waitUntil { source.connections.count == 1 }
        source.connections[0].continuation.yield(.state(epoch: "e1", rev: 1, snapshot: snapshot))
        try await waitUntil { fleet.inbox.items.contains { $0.localID == "conversation/c1/r1" } }
        source.connections[0].continuation.yield(.event(rev: 2, event: .conversationUpdated(conversation("c1", phase: .running))))
        try await waitUntil { !fleet.inbox.items.contains { $0.localID == "conversation/c1/r1" } }
        fleet.remove(id: "local")
    }
}
