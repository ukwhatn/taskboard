import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private final class Published: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Conversation] = []
    func add(_ value: Conversation) { lock.withLock { values.append(value) } }
    var all: [Conversation] { lock.withLock { values } }
}

/// E2 の会話：`/v1/stream` の購読・使っていない会話を止める方針・枠・答えの重なり
@Suite("会話の購読と止める方針（偽物の host）", .serialized)
struct ConversationStreamTests {
    private let machine = MachineID(rawValue: "m-stream")

    private struct World {
        let conversation: ClaudeConversation
        let host: FakeHost
        let store: Store
        let published: Published
    }

    private func make(bound: Bool = true, slots: ConversationSlots = ConversationSlots(soft: .max, hard: .max), id: String? = nil) async throws -> World {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        var made = ConversationRecord(taskNumber: bound ? task.number : nil, agentSessionId: "s1", cwd: "/w", model: "haiku", runner: .none)
        if let id { made.id = id }
        let saved = try store.createConversation(made)
        let host = FakeHost()
        var timing = ConversationTiming()
        timing.accept = .milliseconds(300)
        timing.stopResult = .milliseconds(300)
        timing.stopInput = .milliseconds(300)
        timing.stopTerm = .milliseconds(300)
        timing.control = .seconds(2)
        let published = Published()
        var context = ClaudeConversation.Context(
            shared: ConversationContext(
                machine: machine, store: store, host: host, launch: { EngineLaunch(executable: "/x/claude", environment: ["PATH": "/usr/bin"]) },
                attachments: nil, guide: { _ in nil }, becameIdle: { _ in }, logger: Logger(label: "test"), timing: timing))
        context.epoch = "e1"
        context.publish = { published.add($0) }
        context.slots = slots
        let conversation = ClaudeConversation(record: try store.conversation(id: saved.id)!, context: context)
        await host.connect(conversation.inbox, key: saved.id)
        return World(conversation: conversation, host: host, store: store, published: published)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func drain(_ outbox: StreamOutbox) async throws -> [StreamServerFrame] {
        outbox.finish()
        var frames: [StreamServerFrame] = []
        for await frame in outbox.frames { frames.append(try WireJSON.decoder().decode(StreamServerFrame.self, from: frame.data)) }
        return frames
    }

    private func kinds(_ frames: [StreamServerFrame]) -> [String] {
        frames.map { frame in
            switch frame {
            case .subscribed(_, _, let through): "subscribed:\(through)"
            case .conversation(let event): "\(event.seq):\(Self.name(event.kind))"
            case .unsubscribed(_, let reason): "unsubscribed:\(reason)"
            default: "other"
            }
        }
    }

    private static func name(_ kind: ConversationEvent.Kind) -> String {
        switch kind {
        case .conversation: "conversation"
        case .blockStart: "blockStart"
        case .delta(_, _, _, let text): "delta(\(text))"
        case .blockStop: "blockStop"
        case .messages: "messages"
        case .accepted(_, let state): "accepted(\(state))"
        case .turn: "turn"
        case .gap: "gap"
        case .notice: "notice"
        case .commands: "commands"
        case .run: "run"
        case .reset: "reset"
        case .unsupported: "unsupported"
        }
    }

    private static let queued = #"{"type":"command_lifecycle","command_uuid":"5b4e28ba-2fa1-11d2-883f-0016d3cca427","state":"queued"}"#
    private static let started = #"{"type":"command_lifecycle","command_uuid":"5b4e28ba-2fa1-11d2-883f-0016d3cca427","state":"started"}"#
    private static let result = #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#
    private static let running = #"{"type":"system","subtype":"session_state_changed","state":"running"}"#
    private static func delta(_ text: String, index: Int = 0, message: String = "msg_1") -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}},"api_message_id":"\#(message)"}"#
    }

    private static func blockStart(_ index: Int, message: String = "msg_1") -> String {
        #"{"type":"stream_event","event":{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}},"api_message_id":"\#(message)"}"#
    }
    private static func blockStop(_ index: Int, message: String = "msg_1") -> String {
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":\#(index)},"api_message_id":"\#(message)"}"#
    }
    private static func assistant(_ text: String, uuid: String, message: String = "msg_1") -> String {
        #"{"type":"assistant","message":{"id":"\#(message)","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}]},"parent_tool_use_id":null,"session_id":"s1","uuid":"\#(uuid)"}"#
    }

    // MARK: 購読

    @Test("購読：subscribed の後に after より後の控えを seq の順に送り、以後の出来事が続く。会話の様子は購読に入れず publish に回す")
    func subscribeOrder() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        await world.host.emit(Self.queued)
        await world.host.emit(Self.result)
        #expect(await eventually { await world.conversation.lastSeq >= 2 })
        let outbox = StreamOutbox()
        #expect(await world.conversation.subscribe(outbox, key: UUID(), epoch: "e1", after: 1))
        let before = world.published.all.count
        await world.host.emit(Self.running)
        await world.host.emit(Self.started)
        #expect(await eventually { await world.conversation.lastSeq >= 3 })
        #expect(try await kinds(drain(outbox)) == ["subscribed:2", "2:turn", "3:accepted(started)"])
        #expect(world.published.all.count > before && world.published.all.last?.phase == .running)
        #expect(await world.conversation.viewers == 1)
    }

    @Test("サブエージェントの発言は呼び出しの id を付けて控えに積み、求めた購読にだけ送る。ほかの購読と E1 の購読には外して送る")
    func subagentMessages() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let asked = StreamOutbox()
        let plain = StreamOutbox()
        #expect(await world.conversation.subscribe(asked, key: UUID(), epoch: "e1", after: 0, subagents: true))
        #expect(await world.conversation.subscribe(plain, key: UUID(), epoch: "e1", after: 0))
        // 実物（Claude Code 2.1.303 の stream-json）の形。サブエージェントの行は parent_tool_use_id と agent_id を持つ
        await world.host.emit(
            #"{"type":"assistant","message":{"id":"msg_p","role":"assistant","content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"description":"a.txt を読む"}}]},"parent_tool_use_id":null,"uuid":"p1","session_id":"s1"}"#)
        await world.host.emit(
            #"{"type":"assistant","message":{"id":"msg_c","role":"assistant","content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"/w/a.txt"}}]},"parent_tool_use_id":"toolu_agent","agent_id":"a8","uuid":"c1","session_id":"s1"}"#)
        #expect(await eventually { await world.conversation.lastSeq >= 2 })

        func messages(_ frames: [StreamServerFrame]) -> [String] {
            frames.flatMap { frame -> [String] in
                guard case .conversation(let event) = frame, case .messages(let messages, _) = event.kind else { return [] }
                return messages.map { "\($0.id):\($0.parentToolID ?? "-")" }
            }
        }
        #expect(try await messages(drain(asked)) == ["p1#0:-", "c1#0:toolu_agent"])
        #expect(try await messages(drain(plain)) == ["p1#0:-"])
        let replayed = StreamOutbox()
        _ = await world.conversation.subscribe(replayed, key: UUID(), epoch: "e1", after: 0)
        #expect(try await messages(drain(replayed)) == ["p1#0:-"], "控えから送るときも外す")
        var e1: [String] = []
        for await event in await world.conversation.events(after: 0) {
            guard case .messages(let messages, _) = event.kind else { continue }
            e1 += messages.map(\.id)
            if event.seq >= 2 { break }
        }
        #expect(e1 == ["p1#0"])
    }

    @Test("終わると、通知の行には記録に残す内側の理由でなく画面の文を送る")
    func exitNotice() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let outbox = StreamOutbox()
        #expect(await world.conversation.subscribe(outbox, key: UUID(), epoch: "e1", after: 0))
        await world.conversation.stop(.person)
        #expect(await eventually { await !world.conversation.isLive })
        let notices = try await drain(outbox).compactMap { frame -> String? in
            guard case .conversation(let event) = frame, case .notice(let text) = event.kind else { return nil }
            return text
        }
        #expect(notices == ["停止しました"])
        #expect(try world.store.conversation(id: world.conversation.id)?.lastExit == "止めた")
        #expect(ConversationStopCause(lastExit: "使われていないので止めた").notice(engine: .claude) == "しばらく使われていないため停止しました")
        #expect(ConversationStopCause(lastExit: "質問を defer で終えた").notice(engine: .claude) == "質問に答えると再開します")
        #expect(ConversationStopCause(lastExit: "signal 9 で終わった").notice(engine: .claude) == "Claude Codeが終了しました")
        #expect(ConversationStopCause(lastExit: "agent host が起き直した").notice(engine: .codex) == "Codexが終了しました")
    }

    @Test("購読：after が 0 なら gap にせず全部、起動が違う・今より先の番号なら先に gap を送ってから全部")
    func subscribeGap() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        await world.host.emit(Self.queued)
        #expect(await eventually { await world.conversation.lastSeq >= 1 })
        for (epoch, after, expected) in [("e1", 0, ["subscribed:1", "1:accepted(queued)"]), ("e0", 1, ["subscribed:1", "0:gap", "1:accepted(queued)"]),
            ("e1", 5, ["subscribed:1", "0:gap", "1:accepted(queued)"])]
        {
            let outbox = StreamOutbox()
            _ = await world.conversation.subscribe(outbox, key: UUID(), epoch: epoch, after: after)
            #expect(try await kinds(drain(outbox)) == expected, "\(epoch) \(after)")
        }
    }

    @Test("購読：控えの上限で落とした番号より前から求めると gap。終わった発言の差分を控えから外した分は gap にしない")
    func subscribeDropped() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        await world.host.emit(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"api_message_id":"msg_1"}"#)
        await world.host.emit(Self.delta("a"))
        await world.host.emit(#"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"api_message_id":"msg_1"}"#)
        await world.host.emit(
            #"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"a"}]},"parent_tool_use_id":null,"session_id":"s1","uuid":"ca6d846d-c830-4c93-bc77-d3698db3ce08"}"#
        )
        #expect(await eventually { await world.conversation.lastSeq >= 4 })
        let compacted = StreamOutbox()
        _ = await world.conversation.subscribe(compacted, key: UUID(), epoch: "e1", after: 1)
        #expect(try await kinds(drain(compacted)) == ["subscribed:4", "4:messages"])

        for n in 0..<(ConversationEventLog.limit + 5) { await world.host.emit(Self.delta("x", index: n % 2, message: "msg_2")) }
        #expect(await eventually { await world.conversation.lastSeq >= ConversationEventLog.limit + 4 })
        let late = StreamOutbox()
        _ = await world.conversation.subscribe(late, key: UUID(), epoch: "e1", after: 4)
        let frames = try await kinds(drain(late))
        #expect(frames.count == ConversationEventLog.limit + 2)
        #expect(frames.dropFirst().first?.hasSuffix(":gap") == true)
    }

    @Test("終わった発言が block の終わりより先に届いても、block が止まった時点で差分を控えから外す。終わった発言の後に始まった block は、その発言が届くまで残す")
    func compactsEitherOrder() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        func feed() async throws -> [String] {
            let outbox = StreamOutbox()
            _ = await world.conversation.subscribe(outbox, key: UUID(), epoch: "e1", after: 0)
            return try await kinds(drain(outbox))
        }
        // Claude Code 2.1.303 の順：始まり、差分、終わった発言、終わり
        await world.host.emit(Self.blockStart(0))
        await world.host.emit(Self.delta("a"))
        await world.host.emit(Self.assistant("a", uuid: "ca6d846d-c830-4c93-bc77-d3698db3ce08"))
        await world.host.emit(Self.blockStop(0))
        #expect(await eventually { await world.conversation.lastSeq >= 4 })
        #expect(try await feed() == ["subscribed:4", "3:messages"])

        // 終わりが終わった発言より先に来る順の block は、その発言が届くまで差分を残す
        await world.host.emit(Self.blockStart(1))
        await world.host.emit(Self.delta("b", index: 1))
        await world.host.emit(Self.blockStop(1))
        #expect(await eventually { await world.conversation.lastSeq >= 7 })
        #expect(try await feed() == ["subscribed:7", "3:messages", "5:blockStart", "6:delta(b)", "7:blockStop"])
        await world.host.emit(Self.assistant("b", uuid: "da6d846d-c830-4c93-bc77-d3698db3ce08"))
        #expect(await eventually { await world.conversation.lastSeq >= 8 })
        #expect(try await feed() == ["subscribed:8", "3:messages", "8:messages"])
    }

    @Test("daemon が起き直して控えを読み直す間は、生成中の差分を流さない。読み終えた時点で終わっていない block だけを、届いた分を 1 つの差分にまとめて出し、その後の差分は続けて流す")
    func replayCollapsesStream() async throws {
        let world = try await make()
        let outbox = StreamOutbox()
        _ = await world.conversation.subscribe(outbox, key: UUID(), epoch: "e1", after: 0)
        let kept = [
            Self.blockStart(0), Self.delta("こん"), Self.delta("にちは"), Self.assistant("こんにちは", uuid: "ca6d846d-c830-4c93-bc77-d3698db3ce08"),
            Self.blockStop(0), Self.result,
            Self.blockStart(0, message: "msg_2"), Self.delta("途", message: "msg_2"), Self.delta("中", message: "msg_2"),
        ]
        for line in kept { await world.host.keep(line) }
        await world.host.setPending([], state: "running")
        await world.conversation.attach(process: AgentHostProcessInfo(key: world.conversation.id, pid: 42, alive: true, lastSeq: kept.count, firstSeq: 1, keptBytes: 10, startedAt: 0))
        await world.host.emit(Self.delta("の続き", message: "msg_2"))
        #expect(await eventually { await world.conversation.lastSeq >= 5 })
        try await Task.sleep(for: .milliseconds(100))
        let streamed = try await kinds(drain(outbox)).map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) ?? $0 }
            .filter { $0.hasPrefix("blockStart") || $0.hasPrefix("delta") || $0.hasPrefix("blockStop") || $0 == "messages" }
        #expect(streamed == ["messages", "blockStart", "delta(途中)", "delta(の続き)"])
    }

    @Test("同じ block の差分は 50ms の間ためて 1 つの出来事にし、ほかの出来事の前には出し切る")
    func deltaBatch() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let outbox = StreamOutbox()
        _ = await world.conversation.subscribe(outbox, key: UUID(), epoch: "e1", after: 0)
        for text in ["あ", "b", "う"] { await world.host.emit(Self.delta(text)) }
        #expect(await eventually { await world.conversation.lastSeq >= 1 })
        await world.host.emit(Self.delta("c"))
        await world.host.emit(Self.queued)
        #expect(await eventually { await world.conversation.lastSeq >= 3 })
        #expect(try await kinds(drain(outbox)) == ["subscribed:0", "1:delta(あbう)", "2:delta(c)", "3:accepted(queued)"])
    }

    @Test("読まない購読は、書けていない数が上限を超えたら behind で終え、見ている数から外す")
    func slowStream() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let outbox = StreamOutbox(byteLimit: .max)
        _ = await world.conversation.subscribe(outbox, key: UUID(), epoch: "e1", after: 0)
        for n in 0..<(ConversationEventLog.subscriberLimit + 10) { await world.host.emit(Self.delta("a", index: n % 2)) }
        #expect(await eventually { await world.conversation.viewers == 0 })
        let frames = try await kinds(drain(outbox))
        #expect(frames.last == "unsubscribed:behind")
        // subscribed も書けていない数に入るので、出来事は上限より 1 つ少なく積んだところで終わる（subscribed・出来事・unsubscribed）
        #expect(frames.count == ConversationEventLog.subscriberLimit + 2)
    }

    @Test("既定（auto）では、画面に出ている会話の質問は defer せず、誰も見ていない会話の質問は defer で終える")
    func deferByViewers() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let key = UUID()
        _ = await world.conversation.subscribe(StreamOutbox(), key: key, epoch: "e1", after: 0)
        func ask(_ id: String) async -> String? {
            await world.host.emit(
                #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"hook_callback","callback_id":"tb_pre","input":{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_\#(id)","tool_input":{"questions":[{"question":"色は？","options":[{"label":"赤"},{"label":"青"}]}]}}}}"#
            )
            guard await eventually({ await world.host.controlResponses().contains { $0["request_id"] as? String == id } }) else { return "応答なし" }
            let response = await world.host.controlResponses().first { $0["request_id"] as? String == id }?["response"] as? [String: Any]
            return (response?["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String
        }
        #expect(await ask("h1") != "defer")
        await world.conversation.unsubscribe(key: key)
        #expect(await ask("h2") == "defer")
    }

    // MARK: 止める方針

    @Test("止めてよいのは、動いていて空いていて、誰も見ておらず、裏のタスクが無いと分かっていて、cutoff より前から使っておらず、タスクに結ばれている会話だけ")
    func stoppable() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let later = Date().addingTimeInterval(60)
        #expect(await !world.conversation.isStoppable(before: Date().addingTimeInterval(-60)), "最近使った")

        let key = UUID()
        _ = await world.conversation.subscribe(StreamOutbox(), key: key, epoch: "e1", after: 0)
        #expect(await !world.conversation.isStoppable(before: later), "見ている")
        await world.conversation.unsubscribe(key: key)

        await world.host.emit(#"{"type":"system","subtype":"task_started","task_id":"b1","session_id":"s1"}"#)
        #expect(await eventually { await world.conversation.snapshot().backgroundTasks == 1 })
        #expect(await !world.conversation.isStoppable(before: later), "裏のタスクがある")
        await world.host.emit(Self.result)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !world.host.requests.contains { $0.op == .trim }, "裏のタスクがある間は控えを捨てない")
        await world.host.emit(#"{"type":"system","subtype":"task_notification","task_id":"b1","status":"completed","session_id":"s1"}"#)
        #expect(await eventually { await world.conversation.snapshot().backgroundTasks == 0 })
        #expect(await world.conversation.isStoppable(before: later))

        #expect(await world.conversation.stopIfIdle(before: later))
        #expect(await eventually { await !world.conversation.isLive })
        #expect(try world.store.conversation(id: world.conversation.id)?.lastExit == "使われていないので止めた")
    }

    @Test("host の控えから自分で捨てた所より先が落ちたら、裏のタスクの数が分からない会話になり、プロセスが終わるまで止めない")
    func unknownBackground() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        // host の控えから落ちた行（daemon には届いていない）
        for _ in 0..<5 { await world.host.keep(Self.delta("x")) }
        await world.host.gap(through: await world.host.seq)
        #expect(await eventually { await !world.conversation.snapshot().backgroundTasksKnown })
        #expect(await !world.conversation.isStoppable(before: Date().addingTimeInterval(60)))
        await world.conversation.stop(.person)
        #expect(await eventually { await !world.conversation.isLive })
        try await world.conversation.start(resume: true)
        #expect(await world.conversation.snapshot().backgroundTasksKnown, "起こし直せば数え直せる")
    }

    @Test("裏のタスクの数が分からなくなった会話も、CLI の task の一覧（background_tasks_changed）が届けば分かり、また自動で止められる")
    func knownAgainFromTaskList() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        for _ in 0..<5 { await world.host.keep(Self.delta("x")) }
        await world.host.gap(through: await world.host.seq)
        #expect(await eventually { await !world.conversation.snapshot().backgroundTasksKnown })
        let later = Date().addingTimeInterval(60)
        #expect(await !world.conversation.isStoppable(before: later))

        await world.host.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_bash"}],"session_id":"s1"}"#)
        #expect(await eventually { await world.conversation.snapshot().backgroundTasksKnown })
        #expect(await world.conversation.snapshot().backgroundTasks == 1)
        #expect(await !world.conversation.isStoppable(before: later), "裏のタスクがある")
        await world.host.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[],"session_id":"s1"}"#)
        #expect(await eventually { await world.conversation.snapshot().backgroundTasks == 0 })
        #expect(await world.conversation.isStoppable(before: later))
        #expect(await world.conversation.stopIfIdle(before: later))
        #expect(await eventually { await !world.conversation.isLive })
    }

    @Test("タスクに結ばれていない会話は自動では止めない（止めると記録が消える）")
    func unboundNotStoppable() async throws {
        let world = try await make(bound: false)
        try await world.conversation.start(resume: false)
        #expect(await !world.conversation.isStoppable(before: Date().addingTimeInterval(60)))
    }

    @Test("止まった会話へ回答を届けると、起こしてから入れる")
    func deliverWakes() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        await world.conversation.stop(.person)
        #expect(await eventually { await !world.conversation.isLive })
        _ = try await world.conversation.deliver(text: "回答", uuid: "7b4e28ba-2fa1-11d2-883f-0016d3cca427", wake: .always)
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == 2)
        #expect(await world.host.written().last?["type"] as? String == "user")
    }

    // MARK: 枠

    @Test("枠：絶対の上限に達していれば、起こすのも、defer の答えで起こし直すのも 409 で、問いは残る")
    func slotsRefuse() async throws {
        let slots = ConversationSlots(soft: 1, hard: 1)
        let world = try await make(slots: slots)
        _ = try await world.conversation.control(ConversationControlRequest(kind: .deferQuestions, value: "on"))
        try await world.conversation.start(resume: false)
        await world.host.emit(
            #"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback","callback_id":"tb_pre","input":{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","tool_input":{"questions":[{"question":"色は？","options":[{"label":"赤"},{"label":"青"}]}]}}}}"#
        )
        await world.host.emit(
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_deferred","terminal_reason":"tool_deferred","session_id":"s1","deferred_tool_use":{"id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"色は？","options":[{"label":"赤"},{"label":"青"}]}]}}}"#
        )
        #expect(await eventually { await world.conversation.snapshot().phase == .stopped })
        #expect(slots.count == 0)
        slots.setLive("other", true)
        await #expect(throws: ConversationError.limit(1)) {
            try await world.conversation.answer(ConversationAnswerRequest(requestID: "toolu_q", answers: [AskAnswer(questionID: "q0", selected: ["赤"])]))
        }
        #expect(await world.conversation.snapshot().deferred?.id == "toolu_q")
        await #expect(throws: ConversationError.limit(1)) {
            try await world.conversation.send(ConversationSendRequest(text: "x", clientMessageID: "8b4e28ba-2fa1-11d2-883f-0016d3cca427"))
        }
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == 1)
    }

    @Test("枠：同時に起こしても絶対の上限を超えない。目安を超えて起こすと、空きを作る処理を呼ぶ")
    func slotsConcurrent() async throws {
        let slots = ConversationSlots(soft: 1, hard: 2)
        let first = try await make(slots: slots)
        let second = try await make(slots: slots)
        let third = try await make(slots: slots)
        let started = await withTaskGroup(of: Bool.self) { group in
            for world in [first, second, third] {
                group.addTask { (try? await world.conversation.start(resume: false)) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(started == 2)
        #expect(slots.count == 2)
    }

    // MARK: 答え

    @Test("同じ問いに同じ答えが重なれば同じ結果を返し、書くのは 1 回。答えている途中の違う答えは 409。書き終えた後の答えも 409")
    func answerOverlap() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        await world.host.emit(
            #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_b","input":{"command":"ls"}}}"#)
        #expect(await eventually { await world.conversation.snapshot().pending.count == 1 })
        await world.host.setWriteDelay(.milliseconds(200))
        let allow = ConversationAnswerRequest(requestID: "r1", allow: true)
        async let first: Void = world.conversation.answer(allow)
        try await Task.sleep(for: .milliseconds(50))
        async let second: Void = world.conversation.answer(allow)
        await #expect(throws: ConversationError.notWaiting("r1")) { try await world.conversation.answer(ConversationAnswerRequest(requestID: "r1", allow: false)) }
        try await first
        try await second
        await world.host.setWriteDelay(nil)
        let responses = await world.host.controlResponses().filter { $0["request_id"] as? String == "r1" }
        #expect(responses.count == 1)
        await #expect(throws: ConversationError.notWaiting("r1")) { try await world.conversation.answer(allow) }
    }

    @Test("消した会話（retire）は起こさず、答えも受けない")
    func retired() async throws {
        let world = try await make()
        try await world.conversation.retire()
        await #expect(throws: ConversationError.removed(world.conversation.id)) { try await world.conversation.start(resume: false) }
        let outbox = StreamOutbox()
        #expect(await !world.conversation.subscribe(outbox, key: UUID(), epoch: "e1", after: 0))
        #expect(try await kinds(drain(outbox)) == ["unsubscribed:removed"])
    }
}
