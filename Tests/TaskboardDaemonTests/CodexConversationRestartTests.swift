import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ConversationEvent.Kind] = []
    func add(_ value: ConversationEvent.Kind) { lock.withLock { values.append(value) } }
    var turns: Int { lock.withLock { values.filter { if case .turn = $0 { true } else { false } }.count } }
    /// 生成中の差分と終わった発言の流れ（`blockStart`・`delta(文)`・`blockStop`・`messages`）
    var stream: [String] {
        lock.withLock {
            values.compactMap { kind in
                switch kind {
                case .blockStart: "blockStart"
                case .delta(_, _, _, let text): "delta(\(text))"
                case .blockStop: "blockStop"
                case .messages: "messages"
                default: nil
                }
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("codex の会話の起き直し（偽の app-server）", .serialized)
struct CodexConversationRestartTests {
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

    private func make() async throws -> World {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        let id = UUID().uuidString.lowercased()
        let saved = try store.createConversation(
            ConversationRecord(id: id, taskNumber: task.number, engine: .codex, agentSessionId: id, cwd: "/w", runner: .none))
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
        let conversation = CodexConversation(record: saved, context: context)
        await host.connect(conversation.inbox, key: id)
        let events = Events()
        let stream = await conversation.events(after: 0)
        Task { for await event in stream { events.add(event.kind) } }
        return World(conversation: conversation, host: host, server: server, store: store, events: events, id: id, context: context)
    }

    /// 新しい daemon：記録から会話を作り直し、同じ host の控えを頭から読み直す（前の daemon の会話には、これより後の行が届かない）
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

    private func generation(_ request: [String: Any]?) -> Int? {
        (request?["id"] as? String).flatMap { CodexRequestIDs.generation(of: .string($0)) }
    }

    private func trims(_ host: FakeHost) async -> [Int] {
        await host.requests.filter { $0.op == .trim }.compactMap(\.through)
    }

    private static func userMessageStarted(_ uuid: String) -> String {
        #"{"method":"item/started","params":{"threadId":"th-1","turnId":"turn-1","item":{"type":"userMessage","id":"u-1","clientId":"\#(uuid)","content":[{"type":"text","text":"送った文","text_elements":[]}]}}}"#
    }

    private static let turnStarted = #"{"method":"turn/started","params":{"threadId":"th-1","turn":{"id":"turn-1","status":"inProgress","error":null,"durationMs":null}}}"#

    private static func turnCompleted(_ turn: String) -> String {
        #"{"method":"turn/completed","params":{"threadId":"th-1","turn":{"id":"\#(turn)","status":"completed","error":null,"durationMs":10}}}"#
    }

    private static let turnResult = #"{"turn":{"id":"turn-1","status":"inProgress","error":null,"durationMs":null}}"#

    @Test("送る前に落ちた：新しい daemon が同じ uuid を受けて turn/start を 1 回だけ送り、送り直しは重複にする")
    func crashBeforeWrite() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let opened = await sent(world.host, "thread/start").last
        let (second, _) = try await restart(world)

        let uuid = UUID().uuidString.lowercased()
        #expect(try await second.send(ConversationSendRequest(text: "1", clientMessageID: uuid)) == .accepted)
        let turns = await sent(world.host, "turn/start")
        #expect(turns.count == 1)
        #expect(generation(turns.first) != nil && generation(turns.first) != generation(opened))
        #expect(try await second.send(ConversationSendRequest(text: "1", clientMessageID: uuid)) == .duplicate)
        #expect(await sent(world.host, "turn/start").count == 1)
        #expect(try world.store.conversation(id: world.id)?.recentMessages.contains(uuid) == true)
    }

    @Test("送った後で応答の前に落ちた：codex がその後に出した人の発言の item で受けたと知り、同じ uuid の送り直しで turn/start を送らない")
    func crashAfterWriteBeforeReply() async throws {
        let world = try await make()
        world.server.setResults("turn/start", [FakeThreadServer.noReply])
        try await world.conversation.start(resume: false)
        let uuid = UUID().uuidString.lowercased()
        let first = world.conversation
        Task { _ = try? await first.send(ConversationSendRequest(text: "1", clientMessageID: uuid)) }
        #expect(await eventually { await sent(world.host, "turn/start").count == 1 })
        let rid = try #require(await sent(world.host, "turn/start").first?["id"] as? String)
        #expect(try world.store.conversation(id: world.id)?.recentMessages.contains(uuid) == false)

        let (second, _) = try await restart(world)
        await world.host.emit(#"{"id":"\#(rid)","result":\#(Self.turnResult)}"#)
        await world.host.emit(Self.turnStarted)
        await world.host.emit(Self.userMessageStarted(uuid))
        #expect(await eventually { (try? world.store.conversation(id: world.id)?.recentMessages.contains(uuid)) == true })
        #expect(try await second.send(ConversationSendRequest(text: "1", clientMessageID: uuid)) == .duplicate)
        #expect(await sent(world.host, "turn/start").count == 1)
    }

    @Test("応答の後で記録の前に落ちた：控えの人の発言の item から受けたことを戻し、送り直しを重複にする。読み直した turn の終わりで控えを切る")
    func crashAfterReplyBeforeRecord() async throws {
        let world = try await make()
        world.server.setResults("turn/start", [FakeThreadServer.noReply])
        try await world.conversation.start(resume: false)
        let uuid = UUID().uuidString.lowercased()
        let first = world.conversation
        Task { _ = try? await first.send(ConversationSendRequest(text: "1", clientMessageID: uuid)) }
        #expect(await eventually { await sent(world.host, "turn/start").count == 1 })
        let rid = try #require(await sent(world.host, "turn/start").first?["id"] as? String)
        // 前の daemon は応答を受ける前に止まった：行は控えにだけ残る
        await world.host.keep(#"{"id":"\#(rid)","result":\#(Self.turnResult)}"#)
        await world.host.keep(Self.turnStarted)
        await world.host.keep(Self.userMessageStarted(uuid))
        #expect(try world.store.conversation(id: world.id)?.recentMessages.contains(uuid) == false)

        let (second, events) = try await restart(world)
        #expect(try world.store.conversation(id: world.id)?.recentMessages.contains(uuid) == true)
        #expect(try await second.send(ConversationSendRequest(text: "1", clientMessageID: uuid)) == .duplicate)
        #expect(await sent(world.host, "turn/start").count == 1)
        #expect(await !second.isIdle)

        await world.host.emit(Self.turnCompleted("turn-1"))
        let end = await world.host.seq
        #expect(await eventually { events.turns == 1 })
        #expect(await eventually { await trims(world.host).contains(end) })
        #expect(await eventually { await second.isIdle })
    }

    @Test("控えを読み直す間は、終わった発言の差分を流さない。読み終えた時点で終わっていない発言だけを、届いた分を 1 つの差分にまとめて出し、その後の差分は続けて流す")
    func replayCollapsesStream() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        func item(_ method: String, _ id: String, _ text: String = "") -> String {
            #"{"method":"\#(method)","params":{"threadId":"th-1","turnId":"turn-1","item":{"type":"agentMessage","id":"\#(id)","text":"\#(text)"}}}"#
        }
        func delta(_ id: String, _ text: String) -> String {
            #"{"method":"item/agentMessage/delta","params":{"threadId":"th-1","turnId":"turn-1","itemId":"\#(id)","delta":"\#(text)"}}"#
        }
        for line in [
            Self.turnStarted, item("item/started", "a-1"), delta("a-1", "こん"), delta("a-1", "にちは"), item("item/completed", "a-1", "こんにちは"),
            item("item/started", "a-2"), delta("a-2", "途"), delta("a-2", "中"),
        ] { await world.host.keep(line) }
        let (_, events) = try await restart(world)
        await world.host.emit(delta("a-2", "の続き"))
        #expect(await eventually { events.stream.count >= 4 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.stream == ["messages", "blockStart", "delta(途中)", "delta(の続き)"])
    }

    @Test("前の世代の応答を捨てる：新しい daemon の要求は世代の違う id で送り、前の daemon の同じ番号の応答では解けない")
    func dropsStaleReplies() async throws {
        let world = try await make()
        world.server.setResults("thread/name/set", [FakeThreadServer.noReply])
        try await world.conversation.start(resume: false)
        let old = try #require(generation(await sent(world.host, "thread/start").last))
        let (second, _) = try await restart(world)

        let done = Flag()
        Task {
            _ = try await second.control(ConversationControlRequest(kind: .rename, value: "題"))
            done.set()
        }
        #expect(await eventually { await sent(world.host, "thread/name/set").count == 1 })
        let request = await sent(world.host, "thread/name/set").last
        let rid = try #require(request?["id"] as? String)
        #expect(try #require(generation(request)) != old)
        let counter = try #require(rid.split(separator: "-").last.flatMap { Int($0) })
        for number in 1...(counter + 5) { await world.host.emit(#"{"id":"\#(old)-\#(number)","result":{}}"#) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!done.isSet)

        await world.host.emit(#"{"id":"\#(rid)","result":{}}"#)
        #expect(await eventually { done.isSet })
    }

    @Test("答えていない要求があるうちは、turn の終わりにも /login にも控えを切らない。切らなかった要求は起き直しで問いに戻り、答えた後の turn の終わりで切る")
    func trimKeepsPending() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        world.server.setResults("account/login/start", [
            #"{"type":"chatgptDeviceCode","loginId":"L1","verificationUrl":"https://auth.openai.com/codex/device","userCode":"ABCD-12345"}"#
        ])
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "触る", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(
            #"{"method":"item/fileChange/requestApproval","id":0,"params":{"threadId":"th-1","turnId":"turn-1","itemId":"patch-1","reason":"書き込み"}}"#)
        let asked = await world.host.seq
        #expect(await eventually { await world.conversation.snapshot().pending.map(\.id) == ["codex-0"] })

        await world.host.emit(Self.turnCompleted("turn-1"))
        #expect(await eventually { world.events.turns == 1 })
        _ = try await world.conversation.control(ConversationControlRequest(kind: .login))
        #expect(await trims(world.host).allSatisfy { $0 < asked })

        let (second, events) = try await restart(world)
        #expect(await second.snapshot().pending.map(\.id) == ["codex-0"])
        try await second.answer(ConversationAnswerRequest(requestID: "codex-0", allow: true))
        #expect(await second.snapshot().pending.isEmpty)
        #expect(await trims(world.host).allSatisfy { $0 < asked })

        world.server.setTurnLines(FakeThreadServer.reply("済み"))
        let replayed = events.turns
        _ = try await second.send(ConversationSendRequest(text: "次", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await eventually { events.turns > replayed })
        #expect(await eventually { await trims(world.host).contains { $0 > asked } })
    }
}
