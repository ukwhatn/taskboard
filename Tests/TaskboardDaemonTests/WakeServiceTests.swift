import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("起こす予定（偽物の host）", .serialized)
struct WakeServiceTests {
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func userTexts(_ world: ServiceWorld, key: String? = nil) async -> [(uuid: String, text: String)] {
        await world.host.requests.filter { $0.op == .write && (key == nil || $0.key == key) }.compactMap { request in
            guard let data = request.data, let line = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                line["type"] as? String == "user", let uuid = line["uuid"] as? String,
                let text = (line["message"] as? [String: Any])?["content"] as? String
            else { return nil }
            return (uuid, text)
        }
    }

    private func spawns(_ world: ServiceWorld, _ id: String) async -> Int {
        await world.host.requests.filter { $0.op == .spawn && $0.key == id }.count
    }

    private func service(_ world: ServiceWorld, clock: TestClock, fullWake: Locked<Bool> = Locked(true)) -> WakeService {
        WakeService(
            store: world.store, state: world.state, conversations: world.service, isFullWake: { fullWake.value },
            now: { clock.now })
    }

    /// 時刻を過ぎた予定を届ける。発言を受けたと host が返すまで待つ
    private func tickDelivering(_ wakes: WakeService, _ world: ServiceWorld, key: String) async throws -> (uuid: String, text: String) {
        let before = await userTexts(world, key: key).count
        async let ticked: Void = wakes.tick()
        #expect(await eventually { await userTexts(world, key: key).count > before })
        let message = try #require(await userTexts(world, key: key).last)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(message.uuid)","state":"started"}"#, key: key)
        await ticked
        return message
    }

    @Test("時刻の前は届けない。過ぎたら終了した会話を起こして 1 回だけ入れ、終了の印が外れる。次の見回りでは入れ直さない")
    func deliversOnceAfterTime() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        try await world.service.close(conversation.id)
        #expect(try await world.service.get(conversation.id).isClosed)
        let clock = TestClock(Date())
        let wake = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(60), prompt: "デプロイを確かめる", conversationID: conversation.id), now: clock.now)
        let wakes = service(world, clock: clock)

        await wakes.tick()
        #expect(await spawns(world, conversation.id) == 1)
        #expect(try world.store.wake(id: wake.wakeID)?.state == .pending)

        clock.advance(120)
        let message = try await tickDelivering(wakes, world, key: conversation.id)
        #expect(await spawns(world, conversation.id) == 2)
        #expect(message.uuid == StableUUID.make("taskboard-wake:\(wake.wakeID).0"))
        let lines = message.text.split(separator: "\n").map(String.init)
        #expect(lines == [
            "<!-- taskboard: wake id=\(wake.wakeID) -->",
            "[taskboard 通知] 予定 #\(wake.wakeID)（\(Wake.agentTime(wake.at))）の時刻になった",
            "- 送り主: taskboard の自動の通知。人の発言でも承認でもない", "作成時の指示:", "デプロイを確かめる",
        ])
        #expect(TaskboardNotice(text: message.text) == .wake)
        #expect(try await !world.service.get(conversation.id).isClosed)
        let stored = try #require(try world.store.wake(id: wake.wakeID))
        #expect(stored.state == .delivered)
        #expect(abs((stored.deliveredAt ?? .distantPast).timeIntervalSince(clock.now)) < 0.01)

        clock.advance(60)
        await wakes.tick()
        #expect(await userTexts(world, key: conversation.id).count == 1)
    }

    @Test("DarkWake の間は届けず、完全に起きた最初の見回りで届ける。5 分より遅れたら届けた時刻も書く")
    func waitsForFullWake() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        try await world.service.stop(conversation.id, cause: .idle)
        let clock = TestClock(Date())
        let wake = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(60), prompt: "続き", conversationID: conversation.id), now: clock.now)
        let fullWake = Locked(false)
        let wakes = service(world, clock: clock, fullWake: fullWake)
        clock.advance(3600)
        await wakes.tick()
        #expect(await spawns(world, conversation.id) == 1)

        fullWake.update { $0 = true }
        let message = try await tickDelivering(wakes, world, key: conversation.id)
        #expect(message.text.hasPrefix("<!-- taskboard: wake id=\(wake.wakeID) -->\n[taskboard 通知] 予定 #\(wake.wakeID)（\(Wake.agentTime(wake.at))）の時刻になった\n"))
        #expect(message.text.contains("\n- 遅れ: Mac が眠っていたか taskboard が止まっていたので、\(Wake.agentTime(clock.now)) に届けた\n"))
        #expect(TaskboardNotice(text: message.text) == .wake)
    }

    @Test("前の daemon が届けた後に記録できなかった予定は、同じ uuid を会話が受けているので入れ直さず、届けた印だけ付ける")
    func doesNotDeliverTwiceAfterRestart() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let clock = TestClock(Date())
        let wake = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(60), prompt: "続き", conversationID: conversation.id), now: clock.now)
        clock.advance(120)
        let uuid = StableUUID.make("taskboard-wake:\(wake.wakeID).0")
        async let first = world.service.deliver(conversationID: conversation.id, text: "前の daemon が入れた文", uuid: uuid, kind: .wake)
        #expect(await eventually { await userTexts(world, key: conversation.id).count == 1 })
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"started"}"#, key: conversation.id)
        #expect(await first == .delivered)

        await service(world, clock: clock).tick()
        #expect(await userTexts(world, key: conversation.id).count == 1)
        #expect(try world.store.wake(id: wake.wakeID)?.state == .delivered)
    }

    @Test("人が止めた会話も再開する（再開のために作った予定なので）")
    func wakesConversationStoppedByPerson() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        try await world.service.stop(conversation.id, cause: .person)
        let clock = TestClock(Date())
        let wake = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(60), prompt: "続き", conversationID: conversation.id), now: clock.now)
        clock.advance(120)
        _ = try await tickDelivering(service(world, clock: clock), world, key: conversation.id)
        #expect(await spawns(world, conversation.id) == 2)
        #expect(try world.store.wake(id: wake.wakeID)?.state == .delivered)
    }

    @Test("届け先の会話の記録が消えていたら、予定を失敗にする")
    func failsWhenConversationDeleted() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let clock = TestClock(Date())
        let wake = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(60), prompt: "続き", conversationID: conversation.id), now: clock.now)
        try await world.service.stop(conversation.id, cause: .person)
        try await world.service.delete(conversation.id)
        clock.advance(120)
        await service(world, clock: clock).tick()
        let stored = try #require(try world.store.wake(id: wake.wakeID))
        #expect(stored.state == .failed && stored.failure == "会話の記録がありません")
    }

    @Test("生成中の会話には入れず、そのまま 24 時間届けられなければ失敗にする")
    func failsAfterADayOfBusy() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let sent = ConversationSendRequest(text: "長い作業")
        async let accepted = world.service.send(conversation.id, sent)
        #expect(await eventually { await userTexts(world, key: conversation.id).count == 1 })
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(sent.clientMessageID)","state":"started"}"#, key: conversation.id)
        _ = try await accepted
        await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#, key: conversation.id)
        #expect(await eventually { (try? await world.service.get(conversation.id))?.phase == .running })
        let clock = TestClock(Date())
        let wake = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(60), prompt: "続き", conversationID: conversation.id), now: clock.now)
        let wakes = service(world, clock: clock)
        clock.advance(120)
        await wakes.tick()
        #expect(try world.store.wake(id: wake.wakeID)?.state == .pending)
        #expect(try world.store.wake(id: wake.wakeID)?.failure == "会話が生成中か、質問への回答を待っています")
        clock.advance(WakeService.giveUpAfter)
        await wakes.tick()
        let stored = try #require(try world.store.wake(id: wake.wakeID))
        #expect(stored.state == .failed)
        #expect(stored.failure == "24時間届けられませんでした。会話が生成中か、質問への回答を待っています。", "\(stored.failure ?? "")")
        #expect(await userTexts(world, key: conversation.id).count == 1)
    }

    @Test("タスク宛ては、その時刻の lead（終了した会話も）を起こして入れ、届け先にその会話を書く")
    func deliversToClosedLeadOfTask() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let lead = try await world.service.start(world.request())
        try await world.service.close(lead.id)
        let clock = TestClock(Date())
        let wake = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(60), prompt: "続き", taskNumber: world.task), now: clock.now)
        clock.advance(120)
        _ = try await tickDelivering(service(world, clock: clock), world, key: lead.id)
        let stored = try #require(try world.store.wake(id: wake.wakeID))
        #expect(stored.state == .delivered && stored.conversationID == lead.id && stored.taskNumber == world.task)
        #expect(try await !world.service.get(lead.id).isClosed)
    }

    @Test("タスクにセッションが無ければ、予定から決めた id の会話を新しく起こし、最初の発言に予定の文と列の起動プロンプトを入れる。2 つ目は起こさない")
    func startsNewConversationForTaskWithoutSessions() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let task = try #require(await world.state.task(number: world.task))
        let board = try world.store.updateBoard(id: task.boardID, BoardUpdateRequest(promptTemplate: "タスク #{{id}} を進める"))
        await world.state.upsert(board)
        let clock = TestClock(Date())
        let wake = try world.store.createWake(
            WakeCreateRequest(at: clock.now.addingTimeInterval(60), prompt: "デプロイの日になった", taskNumber: world.task, cwd: world.directory.path),
            now: clock.now)
        let wakes = service(world, clock: clock)
        clock.advance(120)
        let id = WakeService.conversationID(wakeID: wake.wakeID)
        let message = try await tickDelivering(wakes, world, key: id)
        #expect(message.uuid == StableUUID.make("taskboard-wake:\(wake.wakeID).0"))
        #expect(message.text.contains("作成時の指示:\nデプロイの日になった\n\nタスク #\(world.task) を進める"))
        let record = try #require(try world.store.conversation(id: id))
        #expect(record.taskNumber == world.task && record.cwd == world.directory.path)
        #expect(try world.store.wake(id: wake.wakeID)?.conversationID == id)
        #expect(try world.store.wake(id: wake.wakeID)?.state == .delivered)

        await wakes.tick()
        #expect(try world.store.conversations().count == 1)
    }

    @Test("close を付けた予定は、仕掛けた会話が静かになってから終了する。取り消すと終了しない")
    func closesCreatorAfterTurn() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let sent = ConversationSendRequest(text: "予定を仕掛けて終わる")
        async let accepted = world.service.send(conversation.id, sent)
        #expect(await eventually { await userTexts(world, key: conversation.id).count == 1 })
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(sent.clientMessageID)","state":"started"}"#, key: conversation.id)
        _ = try await accepted
        await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#, key: conversation.id)
        #expect(await eventually { (try? await world.service.get(conversation.id))?.phase == .running })
        let clock = TestClock(Date())
        let wake = try world.store.createWake(
            WakeCreateRequest(at: clock.now.addingTimeInterval(3600), prompt: "続き", conversationID: conversation.id, closeConversationID: conversation.id),
            now: clock.now)
        #expect(wake.closesCreator)
        let wakes = service(world, clock: clock)
        await wakes.tick()
        #expect(try await !world.service.get(conversation.id).isClosed, "ターンの途中では終了しない")

        await world.host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#, key: conversation.id)
        await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#, key: conversation.id)
        #expect(await eventually { (try? await world.service.get(conversation.id))?.phase == .idle })
        await wakes.tick()
        #expect(try await world.service.get(conversation.id).isClosed)
        #expect(try world.store.wake(id: wake.wakeID)?.closesCreator == false)
        #expect(try world.store.wake(id: wake.wakeID)?.state == .pending)

        let other = try await world.service.start(world.request())
        let cancelled = try world.store.createWake(
            WakeCreateRequest(at: clock.now.addingTimeInterval(3600), prompt: "続き", conversationID: other.id, closeConversationID: other.id), now: clock.now)
        _ = try world.store.cancelWake(id: cancelled.wakeID, now: clock.now)
        await wakes.tick()
        #expect(try await !world.service.get(other.id).isClosed)
        #expect(await world.service.isLive(other.id))
    }

    @Test("予定は、時刻がいまより後で 1 年以内、届け先が 1 つ、在るタスクか会話のときだけ作れる。オーケストレーターの会話は終了の対象にしない")
    func validatesCreation() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let now = Date()
        let conversation = try await world.service.start(world.request())
        func create(_ request: WakeCreateRequest) throws { _ = try world.store.createWake(request, now: now) }
        #expect(throws: (any Error).self) { try create(WakeCreateRequest(at: now, prompt: "p", conversationID: conversation.id)) }
        #expect(throws: (any Error).self) { try create(WakeCreateRequest(at: now.addingTimeInterval(400 * 24 * 3600), prompt: "p", conversationID: conversation.id)) }
        #expect(throws: (any Error).self) { try create(WakeCreateRequest(at: now.addingTimeInterval(60), prompt: "  ", conversationID: conversation.id)) }
        #expect(throws: (any Error).self) { try create(WakeCreateRequest(at: now.addingTimeInterval(60), prompt: "p", conversationID: conversation.id, taskNumber: world.task)) }
        #expect(throws: (any Error).self) { try create(WakeCreateRequest(at: now.addingTimeInterval(60), prompt: "p")) }
        #expect(throws: StoreError.taskNotFound(999)) { try create(WakeCreateRequest(at: now.addingTimeInterval(60), prompt: "p", taskNumber: 999)) }
        #expect(throws: (any Error).self) { try create(WakeCreateRequest(at: now.addingTimeInterval(60), prompt: "p", conversationID: "missing")) }
        let orchestrator = try await world.service.start(world.request(bound: false), purpose: .orchestrator)
        #expect(throws: (any Error).self) {
            try create(WakeCreateRequest(at: now.addingTimeInterval(60), prompt: "p", conversationID: orchestrator.id, closeConversationID: orchestrator.id))
        }
        try create(WakeCreateRequest(at: now.addingTimeInterval(60), prompt: "p", conversationID: conversation.id))
        #expect(try world.store.wakes().count == 1)
    }

    @Test("届けた・取り消した予定は、7 日たったら消して state からも外す。待っている予定は消さない")
    func purgesFinished() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        _ = world.store.statePublisher(state: world.state)
        let conversation = try await world.service.start(world.request())
        let clock = TestClock(Date())
        let pending = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(30 * 24 * 3600), prompt: "p", conversationID: conversation.id), now: clock.now)
        let cancelled = try world.store.createWake(WakeCreateRequest(at: clock.now.addingTimeInterval(3600), prompt: "p", conversationID: conversation.id), now: clock.now)
        _ = try world.store.cancelWake(id: cancelled.wakeID, now: clock.now)
        #expect(await eventually { await world.state.snapshot().wakes.count == 2 })
        clock.advance(Store.finishedRowRetention + 60)
        await service(world, clock: clock).tick()
        #expect(try world.store.wakes().map(\.wakeID) == [pending.wakeID])
        #expect(await eventually { await world.state.snapshot().wakes.map(\.wakeID) == [pending.wakeID] })
    }

    @Test("新しく起こすときの起こし方: 案件の起動の既定、無ければ session_start と同じ既定。cwd は既定 → 最後に結んだセッション → 予定を作ったところ")
    func launchPlan() {
        let machine = MachineID(rawValue: "m")
        var task = BoardTask(machine: machine, number: 1, boardID: "b", columnID: "todo", title: "t", createdAt: Date(), updatedAt: Date())
        var board = Board(id: "b", machine: machine, name: "b", position: 0, columns: BoardColumn.standard, createdAt: Date(), promptTemplate: "既定")
        #expect(WakeService.launchPlan(task: task, board: board, fallbackCwd: "/made") == .init(kind: .claude, agentArgs: LaunchChoice.standard.args, cwd: "/made", template: "既定"))
        task.sessions = [
            TaskSessionRef(id: 1, agent: "claude", sessionID: "a", cwd: "/old", linkedAt: Date(timeIntervalSince1970: 1)),
            TaskSessionRef(id: 2, agent: "claude", sessionID: "b", cwd: "/new", linkedAt: Date(timeIntervalSince1970: 2)),
        ]
        #expect(WakeService.launchPlan(task: task, board: board, fallbackCwd: "/made").cwd == "/new")
        board.launchDefaults = LaunchDefaults(kind: .codex, agentArgs: ["--model", "gpt"], cwd: "/defaults")
        #expect(WakeService.launchPlan(task: task, board: board, fallbackCwd: "/made") == .init(kind: .codex, agentArgs: ["--model", "gpt"], cwd: "/defaults", template: "既定"))
        #expect(WakeService.launchPlan(task: task, board: nil, fallbackCwd: "").template == "")
    }
}
