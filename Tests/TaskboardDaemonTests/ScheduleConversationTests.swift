import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("定期起動の会話の回（偽物の host）", .serialized)
struct ScheduleConversationTests {
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func scheduler(_ world: ServiceWorld) -> Scheduler {
        Scheduler(store: world.store, state: world.state, conversations: world.service, accounts: nil, isFullWake: { true }, isOnline: { true })
    }

    private func schedule(_ world: ServiceWorld, _ name: String, agentArgs: [String] = [], now: Date = Date()) throws -> Schedule {
        try world.store.createSchedule(
            ScheduleCreateRequest(name: name, rule: .interval(minutes: 60), cwd: world.directory.path, kind: .claude, agentArgs: agentArgs, prompt: "棚卸し"),
            now: now
        ).0
    }

    private func users(_ world: ServiceWorld) async -> [(uuid: String, text: String)] {
        await world.host.written().filter { $0["type"] as? String == "user" }.compactMap { line in
            guard let uuid = line["uuid"] as? String, let text = (line["message"] as? [String: Any])?["content"] as? String else { return nil }
            return (uuid, text)
        }
    }

    @Test("会話で動かせる回は、回の id から決めた会話で起こし、回の uuid で最初の発言を送る。同じ回の会話は 2 つ作れない")
    func runsInConversation() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let created = try schedule(world, "PR 棚卸し")
        let run = try await scheduler(world).runNow(id: created.scheduleID)
        let id = try #require(run.conversationID)
        #expect(id == Scheduler.conversationID(runID: run.id) && run.requestID == nil)
        let record = try #require(try world.store.conversation(id: id))
        #expect(record.purposeValue == .schedule && record.title == "PR 棚卸し")
        #expect(await world.service.isLive(id))
        #expect(await users(world).map(\.uuid) == [Scheduler.firstMessageID(runID: run.id)])
        #expect(await users(world).map(\.text) == ["棚卸し"])
        #expect(try world.store.scheduleRuns(id: created.scheduleID).first?.outcome == .launched)

        await #expect(throws: (any Error).self) { try await world.service.start(world.request(bound: false), purpose: .schedule, id: id) }
        #expect(try world.store.conversations().count == 1)
    }

    @Test("会話に読み替えられない引数の回は、会話を作らずに失敗にし、読めなかった引数を理由に入れる")
    func refusesUnconvertibleArguments() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let created = try schedule(world, "remote", agentArgs: ["--remote-control"])
        let run = try await scheduler(world).runNow(id: created.scheduleID)
        #expect(run.outcome == .failed && run.error?.contains("--remote-control") == true)
        #expect(try world.store.conversations().isEmpty)
    }

    @Test("会話を起こせなければ回を失敗にする")
    func failureIsNotRetriedInTerminal() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        await world.host.setFailing([.spawn])
        let created = try schedule(world, "fail")
        let run = try await scheduler(world).runNow(id: created.scheduleID)
        #expect(run.outcome == .failed && run.requestID == nil)
    }

    @Test("前の回の会話が動いていれば、次の回はスキップとして記録する")
    func skipsWhileConversationRuns() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let t0 = Date(timeIntervalSince1970: ((Date().timeIntervalSince1970 - 3 * 3600) / 60).rounded(.down) * 60)
        let created = try schedule(world, "overlap", now: t0)
        let scheduler = scheduler(world)
        await scheduler.tick(now: t0.addingTimeInterval(3600 + 30))
        let first = try #require(try world.store.scheduleRuns(id: created.scheduleID).first)
        #expect(await world.service.isLive(try #require(first.conversationID)))
        await scheduler.tick(now: t0.addingTimeInterval(7200 + 30))
        let runs = try world.store.scheduleRuns(id: created.scheduleID)
        #expect(runs.count == 2 && runs.first?.skipped == Scheduler.skippedBusyReason && runs.first?.conversationID == nil)
    }

    @Test("回のターンが error で終わったら回を失敗にする")
    func errorTurnFailsRun() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let created = try schedule(world, "error")
        let run = try await scheduler(world).runNow(id: created.scheduleID)
        await world.host.emit(#"{"type":"result","subtype":"error_during_execution","is_error":true,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { (try? world.store.scheduleRuns(id: created.scheduleID).first?.outcome) == .failed })
        #expect(try world.store.scheduleRuns(id: created.scheduleID).first?.error == "実行がエラーで終わりました（end_turn）")
        #expect(run.conversationID != nil)
    }

    @Test("回のターンが利用枠の上限で断られたら、戻るのを待たずに回を失敗にし、閉じる側が会話を止める")
    func limitedRunIsClosed() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let closer = ScheduledRunCloser(store: world.store, state: world.state, conversations: world.service)
        let created = try schedule(world, "limited")
        let run = try await scheduler(world).runNow(id: created.scheduleID)
        let id = try #require(run.conversationID)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(Scheduler.firstMessageID(runID: run.id))","state":"started"}"#)
        let resets = Int(Date().timeIntervalSince1970) + 3600
        await world.host.emit(
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":\#(resets),"rateLimitType":"five_hour"},"session_id":"s1"}"#)
        await world.host.emit(#"{"type":"result","subtype":"success","is_error":true,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { (try? world.store.scheduleRuns(id: created.scheduleID).first?.error) == ClaudeConversation.scheduleRunLimitedReason })
        #expect(try world.store.conversation(id: id)?.limitResumeAt == nil, "回の会話は上限の後の続きを待たない")
        #expect(await eventually { await closer.stopIfFinished(id) })
        #expect(await !world.service.isLive(id))
    }

    @Test("回の会話は、利用枠が区切る閾値を越えてターンを終えても区切らず、閉じる側が止める")
    func pausedThresholdDoesNotKeepRun() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let closer = ScheduledRunCloser(store: world.store, state: world.state, conversations: world.service)
        let run = try await scheduler(world).runNow(id: try schedule(world, "pause").scheduleID)
        let id = try #require(run.conversationID)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(Scheduler.firstMessageID(runID: run.id))","state":"started"}"#)
        let resets = Int(Date().timeIntervalSince1970) + 7200
        await world.host.emit(
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.97,"resetsAt":\#(resets)}}},"session_id":"s1"}"#)
        await world.host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { await closer.stopIfFinished(id) })
        #expect(try world.store.conversation(id: id)?.limitResumeAt == nil)
        #expect(try world.store.scheduleRuns(id: run.scheduleID).first?.outcome == .launched)
    }

    @Test("最初の発言を受けてターンを終えた回の会話は止め、受けていない会話は止めない")
    func closerStopsFinishedRun() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let closer = ScheduledRunCloser(store: world.store, state: world.state, conversations: world.service)
        let run = try await scheduler(world).runNow(id: try schedule(world, "close").scheduleID)
        let id = try #require(run.conversationID)
        #expect(await closer.stopIfFinished(id) == false)
        #expect(await world.service.isLive(id))

        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(Scheduler.firstMessageID(runID: run.id))","state":"started"}"#)
        await world.host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { await closer.stopIfFinished(id) })
        #expect(await !world.service.isLive(id))
        #expect(try world.store.scheduleRuns(id: run.scheduleID).first?.outcome == .launched)
    }

    @Test("タスクの無い定期起動の回の会話は、人が止めても記録を残す（回の行から開き直す）")
    func keepsStoppedRunConversation() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let run = try await scheduler(world).runNow(id: try schedule(world, "stop").scheduleID)
        let id = try #require(run.conversationID)
        try await world.service.stop(id, cause: .person)
        #expect(await !world.service.isLive(id))
        #expect(try world.store.conversation(id: id) != nil)
        #expect(try world.store.scheduleRuns(id: run.scheduleID).first?.outcome == .launched)
    }

    @Test("起き直した daemon は、直前に記録した会話の回のうち、最初の発言を受けていない回と会話の記録が無い回を失敗にして会話を止める。受けた回（待ち行列に入っただけの回も）と古い回は触らない")
    func recoversInterruptedRuns() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        await world.state.setAgentHost(AgentHostInfo(connected: true))
        let before = scheduler(world)

        let delivered = try await before.runNow(id: try schedule(world, "delivered").scheduleID)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(Scheduler.firstMessageID(runID: delivered.id))","state":"started"}"#)
        #expect(await eventually { await world.service.deliveryState(delivered.conversationID!, uuid: Scheduler.firstMessageID(runID: delivered.id)) == .delivered })
        let queued = try await before.runNow(id: try schedule(world, "queued").scheduleID)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(Scheduler.firstMessageID(runID: queued.id))","state":"queued"}"#)
        let unsent = try await before.runNow(id: try schedule(world, "unsent").scheduleID)
        let removed = try await before.runNow(id: try schedule(world, "removed").scheduleID)
        try await world.service.stop(try #require(removed.conversationID), cause: .person)
        try await world.service.delete(try #require(removed.conversationID))
        let old = try await before.runNow(id: try schedule(world, "old").scheduleID, now: Date().addingTimeInterval(-2 * 3600))

        try await Task.sleep(for: .milliseconds(10))
        let after = scheduler(world)
        await after.recoverInterruptedRuns(hostGrace: .zero)
        func run(_ given: ScheduleRun) throws -> ScheduleRun? { try world.store.scheduleRuns(id: given.scheduleID).first }
        #expect(try run(delivered)?.outcome == .launched)
        #expect(await world.service.isLive(delivered.conversationID!))
        #expect(try run(queued)?.outcome == .launched)
        #expect(await world.service.isLive(queued.conversationID!))
        #expect(try run(unsent)?.outcome == .failed && run(unsent)?.error == Scheduler.interruptedReason)
        #expect(await !world.service.isLive(unsent.conversationID!))
        #expect(try run(removed)?.outcome == .failed && run(removed)?.error == Scheduler.interruptedReason)
        #expect(try run(old)?.outcome == .launched, "1 時間より前の回は見ない")
    }
}
