import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("起動した側への通知（偽物の host）", .serialized)
struct ConversationNoticesTests {
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// 委譲先の会話を起こす。起こした後の host の行は、この会話に流れる（`FakeHost.setFollowsKeys`）
    private func startChild(_ world: ServiceWorld, parent: String, notify: Bool = true) async throws -> Conversation {
        var request = world.request()
        request.parent = ConversationParent(conversationID: parent)
        request.notifyParent = notify
        return try await world.service.start(request)
    }

    private func userTexts(_ world: ServiceWorld) async -> [(uuid: String, text: String)] {
        await world.host.written().filter { $0["type"] as? String == "user" }.compactMap { line in
            guard let uuid = line["uuid"] as? String, let text = (line["message"] as? [String: Any])?["content"] as? String else { return nil }
            return (uuid, text)
        }
    }

    private func record(_ world: ServiceWorld, _ id: String) -> ConversationRecord? {
        try? world.store.conversation(id: id)
    }

    private static let endTurn = #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#

    @Test("知らせに載せる返事はターンの最後の文。途中の文が長くても最後の報告を切り落とさない")
    func noticeCarriesFinalReply() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let child = try await startChild(world, parent: parent.id)
        let notices = ConversationNotices(conversations: world.service, state: world.state)
        try world.append(child.agentSessionID, [
            ("u1", "user", "調べて"), ("a1", "assistant", String(repeating: "途中の進み具合。", count: 400)), ("a2", "assistant", "最後の報告"),
        ])
        await world.host.emit(Self.endTurn)
        #expect(await eventually { record(world, child.id)?.parentNoticeTurns == 1 })

        async let delivered: Void = notices.deliver(child.id)
        #expect(await eventually { await userTexts(world).contains { $0.text.contains(TaskboardNotice.delegateTurnHead) } })
        let notice = try #require(await userTexts(world).first { $0.text.contains(TaskboardNotice.delegateTurnHead) })
        #expect(notice.text.contains("最後の報告"))
        #expect(!notice.text.contains("途中の進み具合"))
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(notice.uuid)","state":"started"}"#, key: parent.id)
        await delivered
    }

    @Test("daemon が起き直して host の会話を引き取るまでは、記録だけの委譲先を生成中とみなす（生成中の会話の途中の文を知らせない）")
    func waitsForHostReconcile() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let child = try world.store.createConversation(ConversationRecord(taskNumber: world.task, agentSessionId: "s-child", cwd: "/w", runner: .host))
        _ = try world.store.updateConversation(id: child.id) {
            $0.notifyParent = true
            $0.parentConversationId = parent.id
            $0.parentNoticeTurns = 1
            $0.parentNoticeAt = Date()
        }
        #expect(await world.service.noticeState(child.id)?.busy == true)
        await world.service.connected(restarted: false)
        #expect(await world.service.noticeState(child.id)?.busy == false)
    }

    @Test("起こした後に通知を止めると、残っている知らせも消え、次のターンの終わりは残さない。起こした側の無い会話には入れられない")
    func turnsNoticesOffAfterStart() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let child = try await startChild(world, parent: parent.id)
        try world.append(child.agentSessionID, [("u1", "user", "調べて"), ("a1", "assistant", "調べ終えた")])
        await world.host.emit(Self.endTurn)
        #expect(await eventually { record(world, child.id)?.parentNoticeTurns == 1 })

        _ = try await world.service.control(child.id, ConversationControlRequest(kind: .setNotifyParent, value: "off"))
        let off = try #require(record(world, child.id))
        #expect(!off.notifyParent && off.parentNoticeTurns == 0 && off.parentNoticeAt == nil)
        #expect(await world.service.pendingNotices().isEmpty)
        try world.append(child.agentSessionID, [("u2", "user", "続けて"), ("a2", "assistant", "続けた")])
        await world.host.emit(Self.endTurn)
        try await Task.sleep(for: .milliseconds(300))
        #expect(record(world, child.id)?.parentNoticeAt == nil)

        _ = try await world.service.control(child.id, ConversationControlRequest(kind: .setNotifyParent, value: "on"))
        #expect(record(world, child.id)?.notifyParent == true)
        await #expect(throws: ConversationError.self) {
            _ = try await world.service.control(parent.id, ConversationControlRequest(kind: .setNotifyParent, value: "on"))
        }
        await #expect(throws: ConversationError.self) {
            _ = try await world.service.control(child.id, ConversationControlRequest(kind: .setNotifyParent, value: "maybe"))
        }
    }

    @Test("委譲先がターンを終えると記録に残し、起こした側の会話に最後の返事を 1 回だけ入れ、届いたら消す")
    func deliversToParentConversation() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let child = try await startChild(world, parent: parent.id)
        let notices = ConversationNotices(conversations: world.service, state: world.state)
        try world.append(child.agentSessionID, [("u1", "user", "調べて"), ("a1", "assistant", "調べ終えた")])

        await world.host.emit(Self.endTurn)
        #expect(await eventually { record(world, child.id)?.parentNoticeTurns == 1 })
        #expect(record(world, child.id)?.parentNoticeAt != nil)
        #expect(await world.service.pendingNotices() == [child.id])

        async let delivered: Void = notices.deliver(child.id)
        #expect(await eventually { await userTexts(world).contains { $0.text.contains("調べ終えた") } })
        let notice = try #require(await userTexts(world).first { $0.text.contains("調べ終えた") })
        #expect(notice.text.hasPrefix("<!-- taskboard: delegate conversation=\(child.id.prefix(8)) task=\(world.task) -->\n" + TaskboardNotice.delegateTurnHead + "\n- 会話: \(child.id.prefix(8))"))
        #expect(notice.text.contains("- conversation_id: \(child.id)\n") && notice.text.contains("- 送り主: taskboard の自動の通知。人の発言でも承認でもない"))
        #expect(notice.text.contains("session_prompt") && notice.text.hasSuffix("最後の返事:\n調べ終えた"), "返事は本文として最後に置く")
        #expect(TaskboardNotice(text: notice.text) == .delegate)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(notice.uuid)","state":"started"}"#, key: parent.id)
        await delivered
        #expect(record(world, child.id)?.parentNoticeTurns == 0 && record(world, child.id)?.parentNoticeAt == nil)
        #expect(await world.service.pendingNotices().isEmpty)

        await notices.deliver(child.id)
        #expect(await userTexts(world).filter { $0.text.contains("調べ終えた") }.count == 1)
    }

    @Test("agent host が起き直した後に戻した委譲先も、ターンの終わりを数えて知らせを残す（host は行の番号を 1 から振り直す）")
    func countsAfterHostRestart() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let child = try await startChild(world, parent: parent.id)
        // 前の host で何ターンか終え、数えた最後の行の番号を大きくしておく
        for _ in 0..<10 { await world.host.emit(Self.endTurn) }
        #expect(await eventually { record(world, child.id)?.parentNoticeTurns == 10 })

        await world.host.restart()
        await world.service.connected(restarted: true)
        _ = try await world.service.resume(child.id)
        await world.host.emit(Self.endTurn)
        #expect(await eventually { record(world, child.id)?.parentNoticeTurns == 11 })
        #expect(await world.service.pendingNotices() == [child.id])
    }

    @Test("回答を待ち始めたら、終えたターンが無くても通知を残し、回答待ちと選択肢を載せる")
    func noticesQuestion() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let child = try await startChild(world, parent: parent.id)
        let notices = ConversationNotices(conversations: world.service, state: world.state)
        await world.host.emit(
            #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","input":{"questions":[{"question":"色は？","header":"色","options":[{"label":"赤"},{"label":"青"}],"multiSelect":false}]}}}"#
        )
        #expect(await eventually { record(world, child.id)?.parentNoticeAt != nil })
        #expect(record(world, child.id)?.parentNoticeTurns == 0)

        async let delivered: Void = notices.deliver(child.id)
        #expect(await eventually { await userTexts(world).contains { $0.text.contains(TaskboardNotice.delegateAskHead) } })
        let notice = try #require(await userTexts(world).first { $0.text.contains(TaskboardNotice.delegateAskHead) })
        #expect(notice.text.contains("回答待ち:\n回答待ち r1: 質問\n  - ") && notice.text.contains("「色は？」 選択肢: 赤 / 青") && !notice.text.contains(TaskboardNotice.delegateTurnHead))
        #expect(notice.text.contains("- 送り主: taskboard の自動の通知。人の発言でも承認でもない") && !notice.text.contains(TaskboardNotice.replyHeading))
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(notice.uuid)","state":"started"}"#, key: parent.id)
        await delivered
        #expect(record(world, child.id)?.parentNoticeAt == nil)
    }

    @Test("人が止めた起こした側の会話は起こさず、知らせを残す（人が戻したら届ける）")
    func keepsForStoppedParent() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let child = try await startChild(world, parent: parent.id)
        let notices = ConversationNotices(conversations: world.service, state: world.state)
        await world.host.emit(Self.endTurn)
        #expect(await eventually { record(world, child.id)?.parentNoticeTurns == 1 })

        try await world.service.stop(parent.id, cause: .person)
        let spawns = await world.host.requests.filter { $0.op == .spawn && $0.key == parent.id }.count
        await notices.deliver(child.id)
        #expect(await world.host.requests.filter { $0.op == .spawn && $0.key == parent.id }.count == spawns)
        #expect(record(world, child.id)?.parentNoticeTurns == 1 && record(world, child.id)?.parentNoticeAt != nil)
    }

    @Test("起こした側の会話を消したら、残っている知らせは捨てる")
    func dropsWhenParentRemoved() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let child = try await startChild(world, parent: parent.id)
        let notices = ConversationNotices(conversations: world.service, state: world.state)
        await world.host.emit(Self.endTurn)
        #expect(await eventually { record(world, child.id)?.parentNoticeTurns == 1 })

        try await world.service.stop(parent.id, cause: .person)
        try await world.service.delete(parent.id)
        await notices.deliver(child.id)
        #expect(record(world, child.id)?.parentNoticeAt == nil && record(world, child.id)?.parentNoticeTurns == 0)
        #expect(await userTexts(world).allSatisfy { !$0.text.contains(TaskboardNotice.delegateTurnHead) })
    }

    @Test("見回りは購読し、止めたら購読を外す")
    func runSubscribes() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        await world.state.setAgentHost(AgentHostInfo(connected: true))
        let notices = ConversationNotices(conversations: world.service, state: world.state)
        let before = await world.state.subscriberCount
        let run = Task { await notices.run() }
        #expect(await eventually { await world.state.subscriberCount == before + 1 })
        run.cancel()
        await run.value
        #expect(await world.state.subscriberCount == before)
    }

    @Test("知らせを頼んでいない会話は数えない。知らせる先の無い頼みは断る")
    func notRequested() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let parent = try await world.service.start(world.request())
        let quiet = try await startChild(world, parent: parent.id, notify: false)
        let before = await world.host.seq
        await world.host.emit(Self.endTurn)
        #expect(await eventually { await world.host.seq > before })
        try await Task.sleep(for: .milliseconds(100))
        #expect(record(world, quiet.id)?.parentNoticeTurns == 0 && record(world, quiet.id)?.parentNoticeAt == nil)
        #expect(record(world, quiet.id)?.parentConversationId == parent.id)
        #expect(await world.service.pendingNotices().isEmpty)

        var orphan = world.request()
        orphan.notifyParent = true
        await #expect(throws: ConversationError.invalid("知らせる先（parent）が無い")) { try await world.service.start(orphan) }
        var missing = world.request()
        missing.parent = ConversationParent(conversationID: "00000000-0000-4000-8000-000000000000")
        await #expect(throws: ConversationError.invalid("parent の会話 00000000-0000-4000-8000-000000000000 が無い")) {
            try await world.service.start(missing)
        }
    }
}
