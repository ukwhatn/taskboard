import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ConversationEvent.Kind] = []
    func add(_ value: ConversationEvent.Kind) { lock.withLock { values.append(value) } }

    /// uuid ごとの受付の状態（届いた順）
    func accepted(_ uuid: String) -> [String] {
        lock.withLock {
            values.compactMap { kind in
                if case .accepted(let id, let state) = kind, id == uuid { return state }
                return nil
            }
        }
    }

    private var paused: Bool?
    func published(_ conversation: Conversation) { lock.withLock { paused = conversation.queuePaused } }
    /// 最後に出した様子の待ち行列の止まり
    var queuePaused: Bool? { lock.withLock { paused } }

    var notices: [String] {
        lock.withLock {
            values.compactMap { kind in
                if case .notice(let text) = kind { return text }
                return nil
            }
        }
    }
}

/// codex の会話の待ち行列（`thread/queue/*`）と、［今すぐ送信］の `turn/steer` の断りの分け方。行の形は 0.162.1 のソース（`thread_queue_processor.rs`・`turn_processor.rs`）
@Suite("codex の会話の待ち行列（偽の app-server）", .serialized)
struct CodexConversationQueueTests {
    private let machine = MachineID(rawValue: "m-codex")

    private struct World {
        let conversation: CodexConversation
        let host: FakeHost
        let server: FakeThreadServer
        let store: Store
        let events: Events
        let id: String
        let context: CodexConversation.Context
    }

    private func make(thread: String? = nil) async throws -> World {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        let id = UUID().uuidString.lowercased()
        let saved = try store.createConversation(
            ConversationRecord(id: id, taskNumber: task.number, engine: .codex, agentSessionId: thread ?? id, cwd: "/w", runner: .none))
        let host = FakeHost()
        let server = FakeThreadServer()
        await host.setResponder(server.respond)
        var context = CodexConversation.Context(
            shared: ConversationContext(
                machine: machine, store: store, host: host, launch: { EngineLaunch(executable: "/x/codex", environment: ["PATH": "/usr/bin"]) },
                attachments: nil, guide: { _ in "案内" }, becameIdle: { _ in }, logger: LogLines().logger))
        var timing = ConversationTiming()
        timing.control = .seconds(2)
        timing.deltaBatch = .milliseconds(5)
        timing.replay = .seconds(2)
        context.timing = timing
        context.epoch = "e1"
        let events = Events()
        context.publish = { events.published($0) }
        let conversation = CodexConversation(record: saved, context: context)
        await host.connect(conversation.inbox, key: id)
        let stream = await conversation.events(after: 0)
        Task { for await event in stream { events.add(event.kind) } }
        return World(conversation: conversation, host: host, server: server, store: store, events: events, id: id, context: context)
    }

    /// 新しい daemon：記録から会話を作り直し、同じ host の控えを頭から読み直す
    private func restart(_ world: World) async throws -> (CodexConversation, Events) {
        let record = try #require(try world.store.conversation(id: world.id))
        let second = CodexConversation(record: record, context: world.context)
        await world.host.connect(second.inbox, key: world.id)
        let events = Events()
        let stream = await second.events(after: 0)
        Task { for await event in stream { events.add(event.kind) } }
        let lastSeq = await world.host.seq
        await second.attach(
            process: AgentHostProcessInfo(key: world.id, pid: 42, alive: true, exit: nil, lastSeq: lastSeq, firstSeq: 1, keptBytes: 0, startedAt: 0),
            prewarmed: false)
        return (second, events)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func sent(_ host: FakeHost, _ method: String) async -> [[String: Any]] {
        await host.written().filter { $0["method"] as? String == method }
    }

    private func params(_ host: FakeHost, _ method: String) async -> [String: Any]? {
        await sent(host, method).last?["params"] as? [String: Any]
    }

    private static func submission(_ id: String, _ uuid: String, _ text: String = "二つ目") -> String {
        #"{"id":"\#(id)","clientUserMessageId":"\#(uuid)","input":[{"type":"text","text":"\#(text)","text_elements":[]}]}"#
    }

    private static func added(_ id: String, _ uuid: String) -> String { #"{"queuedSubmission":\#(submission(id, uuid))}"# }

    private static func page(_ submissions: [String]) -> String { #"{"data":[\#(submissions.joined(separator: ","))],"nextCursor":null}"# }

    private static func userMessageStarted(_ uuid: String, turn: String) -> String {
        #"{"method":"item/started","params":{"threadId":"th-1","turnId":"\#(turn)","item":{"type":"userMessage","id":"u-\#(turn)","clientId":"\#(uuid)","content":[{"type":"text","text":"二つ目","text_elements":[]}]}}}"#
    }

    private static let queueChanged = #"{"method":"thread/queue/changed","params":{"threadId":"th-1"}}"#

    private static func refusal(_ message: String, data: String? = nil) -> String {
        #"{"error":{"code":-32600,"message":"\#(message)"\#(data.map { #","data":\#($0)"# } ?? "")},"id":"$ID"}"#
    }

    private static let compactRefusal = refusal(
        "cannot steer a compact turn",
        data: #"{"message":"cannot steer a compact turn","codexErrorInfo":{"activeTurnNotSteerable":{"turnKind":"compact"}},"additionalDetails":null,"misalignment":null}"#)

    /// 1 つ目の発言で turn を始め（終わらせない）、生成中に 2 つ目を送って待ち行列に入れる
    private func queueSecond(_ world: World) async throws -> String {
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "一つ目", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await eventually { await world.conversation.snapshot().phase == .running })
        let second = UUID().uuidString.lowercased()
        world.server.setResults("thread/queue/add", [Self.added("q-1", second)])
        #expect(try await world.conversation.send(ConversationSendRequest(text: "二つ目", clientMessageID: second)) == .accepted)
        return second
    }

    private func sendNow(_ world: World, _ uuid: String) async throws -> ConversationSendNow.Outcome {
        let response = try await world.conversation.control(ConversationControlRequest(kind: .sendNow, value: uuid))
        return try JSONDecoder().decode(ConversationSendNow.self, from: Data(try #require(response.payloadJSON).utf8)).outcome
    }

    private func cancel(_ world: World, _ uuid: String) async throws -> Bool {
        let response = try await world.conversation.control(ConversationControlRequest(kind: .cancelQueued, value: uuid))
        return try JSONDecoder().decode(ConversationQueuedCancel.self, from: Data(try #require(response.payloadJSON).utf8)).cancelled
    }

    @Test("生成中に送った発言は thread/queue/add で待ち行列に入れて待機中にし、steer も turn/start もしない。codex が始めたら受けた印にする")
    func queuesWhileGenerating() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        let add = await params(world.host, "thread/queue/add")
        #expect(add?["threadId"] as? String == "th-1")
        #expect(add?["clientUserMessageId"] as? String == second)
        #expect((add?["input"] as? [[String: Any]])?.first?["text"] as? String == "二つ目")
        #expect(await sent(world.host, "turn/steer").isEmpty)
        #expect(await sent(world.host, "turn/start").count == 1)
        #expect(await eventually { world.events.accepted(second) == ["queued"] })
        #expect(try world.store.conversation(id: world.id)?.recentMessages.contains(second) == true)
        #expect(try await world.conversation.send(ConversationSendRequest(text: "二つ目", clientMessageID: second)) == .duplicate)

        // 待ち行列が変わった（まだ残っている）：待機中のまま
        world.server.setResults("thread/queue/list", [Self.page([Self.submission("q-1", second)])])
        await world.host.emit(Self.queueChanged)
        #expect(await eventually { await sent(world.host, "thread/queue/list").count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await eventually { world.events.accepted(second) == ["queued"] })

        // 区切りで codex が始めた
        await world.host.emit(Self.userMessageStarted(second, turn: "turn-2"))
        #expect(await eventually { world.events.accepted(second) == ["queued", "started"] })
    }

    @Test("待ち行列から消えた発言は、codex が始めたとして受けた印にする（始まりの知らせより古い一覧で待機中に戻さない）")
    func listedAgainAfterStart() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        world.server.setResults("thread/queue/list", [Self.page([])])
        await world.host.emit(Self.queueChanged)
        #expect(await eventually { world.events.accepted(second) == ["queued", "started"] })
        // 古い一覧がまだ載せていても戻さない
        world.server.setResults("thread/queue/list", [Self.page([Self.submission("q-1", second)])])
        await world.host.emit(Self.queueChanged)
        #expect(await eventually { await sent(world.host, "thread/queue/list").count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await eventually { world.events.accepted(second) == ["queued", "started"] })
        #expect(try await sendNow(world, second) == .nothingWaiting)
    }

    @Test("［今すぐ送信］：生成中なら待ち行列の中身を今の turn に steer し、通ったら thread/queue/delete で待ち行列から消す")
    func sendNowSteers() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        world.server.setResults("turn/steer", [#"{"turnId":"turn-1"}"#])
        world.server.setResults("thread/queue/delete", [#"{"deleted":true}"#])
        #expect(try await sendNow(world, second) == .delivering)
        let steer = await params(world.host, "turn/steer")
        #expect(steer?["expectedTurnId"] as? String == "turn-1")
        #expect(steer?["clientUserMessageId"] as? String == second)
        #expect((steer?["input"] as? [[String: Any]])?.first?["text"] as? String == "二つ目")
        let delete = await params(world.host, "thread/queue/delete")
        #expect(delete?["queuedSubmissionId"] as? String == "q-1")
        #expect(await eventually { world.events.accepted(second) == ["queued", "started"] })
        #expect(await sent(world.host, "thread/queue/start").isEmpty)
    }

    @Test("［今すぐ送信］：空いていれば thread/queue/start でその 1 件を codex に始めさせる（turn/start で送り直さない）")
    func sendNowStartsWhenIdle() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        // 中断で空いた：codex は待ち行列を始めない
        await world.host.emit(
            #"{"method":"turn/completed","params":{"threadId":"th-1","turn":{"id":"turn-1","status":"interrupted","error":null,"durationMs":10}}}"#)
        #expect(await eventually { await world.conversation.snapshot().phase == .idle })
        #expect(await eventually { world.events.queuePaused == true })
        world.server.setResults("thread/queue/start", [#"{"turn":{"id":"turn-2","status":"inProgress","error":null,"durationMs":null}}"#])
        #expect(try await sendNow(world, second) == .delivering)
        let start = await params(world.host, "thread/queue/start")
        #expect(start?["queuedSubmissionId"] as? String == "q-1")
        #expect(await sent(world.host, "turn/steer").isEmpty)
        #expect(await sent(world.host, "turn/start").count == 1)
        #expect(await eventually { world.events.accepted(second) == ["queued", "started"] })
        #expect(await eventually { world.events.queuePaused == nil })
    }

    @Test("中断の後は、daemon も待ち行列を始めず、待っている発言を取り消さない（codex が止めたまま残す）")
    func interruptKeepsQueue() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        _ = try await world.conversation.control(ConversationControlRequest(kind: .interrupt))
        #expect(await eventually { await world.conversation.snapshot().phase == .idle })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await sent(world.host, "thread/queue/start").isEmpty)
        #expect(await sent(world.host, "thread/queue/delete").isEmpty)
        #expect(await sent(world.host, "turn/start").count == 1)
        #expect(await eventually { world.events.accepted(second) == ["queued"] })
        #expect(await eventually { world.events.queuePaused == true })
        #expect(await world.conversation.snapshot().queuePaused == true)
    }

    @Test("中断で止まった待ち行列は、次の turn が始まる・待っている発言が無くなると止まりの印を外す。普通に終わった・失敗で終わった turn では付けない")
    func pausedClears() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        await world.host.emit(Self.completed("turn-1", "completed"))
        #expect(await eventually { await world.conversation.snapshot().phase == .idle })
        #expect(await world.conversation.snapshot().queuePaused == nil)
        // 次の turn を中断すると止まる
        await world.host.emit(#"{"method":"turn/started","params":{"threadId":"th-1","turn":{"id":"turn-2","status":"inProgress","error":null,"durationMs":null}}}"#)
        await world.host.emit(Self.completed("turn-2", "interrupted"))
        #expect(await eventually { world.events.queuePaused == true })
        // 人の発言で turn が始まれば、codex はその後に待ち行列を始める
        await world.host.emit(#"{"method":"turn/started","params":{"threadId":"th-1","turn":{"id":"turn-3","status":"inProgress","error":null,"durationMs":null}}}"#)
        #expect(await eventually { world.events.queuePaused == nil })
        // 失敗で終わった turn では止めない（codex も Interrupted のときだけ止める）
        await world.host.emit(Self.completed("turn-3", "failed"))
        #expect(await eventually { await world.conversation.snapshot().phase == .idle })
        #expect(await world.conversation.snapshot().queuePaused == nil)
        await world.host.emit(#"{"method":"turn/started","params":{"threadId":"th-1","turn":{"id":"turn-4","status":"inProgress","error":null,"durationMs":null}}}"#)
        // thread が空いた知らせが turn の終わりより先に届いても、終わりで止まりを出す
        await world.host.emit(#"{"method":"thread/status/changed","params":{"threadId":"th-1","status":{"type":"idle"}}}"#)
        #expect(await eventually { await world.conversation.snapshot().phase == .idle })
        await world.host.emit(Self.completed("turn-4", "interrupted"))
        #expect(await eventually { world.events.queuePaused == true })
        // 取り消して待っている発言が無くなった
        world.server.setResults("thread/queue/delete", [#"{"deleted":true}"#])
        #expect(try await cancel(world, second))
        #expect(await eventually { world.events.queuePaused == nil })
        #expect(await world.conversation.snapshot().queuePaused == nil)
        // 止まっている間にほかの端末が入れた発言も、止まったまま待つ
        let other = UUID().uuidString.lowercased()
        world.server.setResults("thread/queue/list", [Self.page([Self.submission("q-9", other, "ほかの端末から")])])
        await world.host.emit(Self.queueChanged)
        #expect(await eventually { world.events.accepted(other) == ["queued"] })
        #expect(await eventually { world.events.queuePaused == true })
    }

    private static func completed(_ turn: String, _ status: String) -> String {
        #"{"method":"turn/completed","params":{"threadId":"th-1","turn":{"id":"\#(turn)","status":"\#(status)","error":null,"durationMs":10}}}"#
    }

    @Test("［取り消す］・［編集］：thread/queue/delete で消せたら取り消しの印にし、もう始まっていた（deleted が false）なら取り消せないと返す")
    func cancelDeletes() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        world.server.setResults("thread/queue/delete", [#"{"deleted":true}"#])
        #expect(try await cancel(world, second))
        #expect(await params(world.host, "thread/queue/delete")?["queuedSubmissionId"] as? String == "q-1")
        #expect(await eventually { world.events.accepted(second) == ["queued", "cancelled"] })
        #expect(!(await world.conversation.received(second)))
        // 取り消した後の［今すぐ送信］は空振り
        #expect(try await sendNow(world, second) == .nothingWaiting)

        let third = UUID().uuidString.lowercased()
        world.server.setResults("thread/queue/add", [Self.added("q-2", third)])
        _ = try await world.conversation.send(ConversationSendRequest(text: "三つ目", clientMessageID: third))
        world.server.setResults("thread/queue/delete", [#"{"deleted":false}"#])
        #expect(!(try await cancel(world, third)))
        #expect(await eventually { world.events.accepted(third) == ["queued"] })
    }

    @Test("圧縮中の［今すぐ送信］：steer を断られたら待ち行列に残し、圧縮が終わってから送ると知らせる")
    func compactionKeepsQueued() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        world.server.setResults("turn/steer", [Self.compactRefusal])
        #expect(try await sendNow(world, second) == .delivering)
        #expect(await eventually { world.events.notices == [ConversationScreenText.steerAfterCompaction] })
        #expect(await sent(world.host, "thread/queue/delete").isEmpty)
        #expect(await sent(world.host, "thread/queue/start").isEmpty)
        #expect(await eventually { world.events.accepted(second) == ["queued"] })
    }

    @Test("［今すぐ送信］の steer で turn が替わっていた・無かったら、thread/queue/start で始めさせる。ほかの turn が動いていれば待ち行列に残す")
    func turnGoneStartsQueued() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        world.server.setResults("turn/steer", [Self.refusal("expected active turn id `turn-1` but found `turn-9`")])
        world.server.setResults("thread/queue/start", [Self.refusal("thread already has an active or pending turn")])
        #expect(try await sendNow(world, second) == .delivering)
        #expect(await sent(world.host, "thread/queue/start").count == 1)
        #expect(await eventually { world.events.accepted(second) == ["queued"] })

        world.server.setResults("turn/steer", [Self.refusal("no active turn to steer")])
        world.server.setResults("thread/queue/start", [#"{"turn":{"id":"turn-2","status":"inProgress","error":null,"durationMs":null}}"#])
        #expect(try await sendNow(world, second) == .delivering)
        #expect(await sent(world.host, "thread/queue/start").count == 2)
        #expect(await eventually { world.events.accepted(second) == ["queued", "started"] })
    }

    @Test("［今すぐ送信］の steer のほかの断りは握りつぶさず失敗にし、待ち行列に残す")
    func otherSteerFailureFails() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        world.server.setResults("turn/steer", [Self.refusal("input must not be empty")])
        await #expect(throws: ConversationError.self) { _ = try await sendNow(world, second) }
        #expect(await sent(world.host, "thread/queue/start").isEmpty)
        #expect(await sent(world.host, "thread/queue/delete").isEmpty)
        #expect(await eventually { world.events.accepted(second) == ["queued"] })
    }

    @Test("待ち行列の無い codex（状態の DB が無い）では、生成中の発言を steer で今の turn に足す。turn が無ければ turn/start、ほかの断りは送れなかったことにする")
    func noQueueFallsBackToSteer() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "一つ目", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await eventually { await world.conversation.snapshot().phase == .running })
        world.server.setResults("thread/queue/add", [Self.refusal(CodexConversation.queueUnavailable)])

        let steered = UUID().uuidString.lowercased()
        world.server.setResults("turn/steer", [#"{"turnId":"turn-1"}"#])
        #expect(try await world.conversation.send(ConversationSendRequest(text: "二つ目", clientMessageID: steered)) == .accepted)
        #expect(await params(world.host, "turn/steer")?["clientUserMessageId"] as? String == steered)
        #expect(await eventually { world.events.accepted(steered) == ["started"] })
        #expect(await sent(world.host, "turn/start").count == 1)

        let restarted = UUID().uuidString.lowercased()
        world.server.setResults("turn/steer", [Self.refusal("no active turn to steer")])
        _ = try await world.conversation.send(ConversationSendRequest(text: "三つ目", clientMessageID: restarted))
        #expect(await params(world.host, "turn/start")?["clientUserMessageId"] as? String == restarted)

        world.server.setResults("turn/steer", [Self.compactRefusal])
        await #expect(throws: ConversationError.self) {
            _ = try await world.conversation.send(ConversationSendRequest(text: "四つ目", clientMessageID: UUID().uuidString.lowercased()))
        }
        world.server.setResults("turn/steer", [Self.refusal("input must not be empty")])
        await #expect(throws: ConversationError.self) {
            _ = try await world.conversation.send(ConversationSendRequest(text: "五つ目", clientMessageID: UUID().uuidString.lowercased()))
        }
        #expect(await sent(world.host, "turn/start").count == 2)
    }

    @Test("新しい daemon が引き取ったら、待ち行列を一覧で読み直して待機中に戻す")
    func attachRestoresQueue() async throws {
        let world = try await make()
        let second = try await queueSecond(world)
        world.server.setResults("thread/queue/list", [Self.page([Self.submission("q-1", second)])])
        let (restarted, events) = try await restart(world)
        #expect(await eventually { events.accepted(second).last == "queued" })
        #expect(try await restarted.send(ConversationSendRequest(text: "二つ目", clientMessageID: second)) == .duplicate)
        world.server.setResults("thread/queue/delete", [#"{"deleted":true}"#])
        let response = try await restarted.control(ConversationControlRequest(kind: .cancelQueued, value: second))
        #expect(try JSONDecoder().decode(ConversationQueuedCancel.self, from: Data(try #require(response.payloadJSON).utf8)).cancelled)
    }

    @Test("止まっていた会話の thread を戻したら、待ち行列を一覧で読み直す（ほかの端末が入れた発言も待機中にする）")
    func resumeRestoresQueue() async throws {
        let world = try await make(thread: "th-1")
        let queued = UUID().uuidString.lowercased()
        world.server.setResults("thread/queue/list", [Self.page([Self.submission("q-7", queued, "前に入れた")])])
        try await world.conversation.start(resume: true)
        #expect(await eventually { world.events.accepted(queued) == ["queued"] })
        #expect(await params(world.host, "thread/queue/list")?["threadId"] as? String == "th-1")
    }
}
