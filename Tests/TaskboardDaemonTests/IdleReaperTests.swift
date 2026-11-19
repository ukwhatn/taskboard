import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

@Suite("IdleReaper: しばらく idle の会話を止める")
struct IdleReaperTests {
    @Test("止めるまでの秒数: 設定の分、0 は止めない、環境変数の秒数が設定より優先。秒数を過ぎた、タスクに結ばれた会話を止める")
    func threshold() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let reaper = IdleReaper(store: world.store, conversations: world.service, environment: [:])
        #expect(await reaper.threshold() == 7200)
        _ = try world.store.updateSettings(MachineSettingsUpdate(idleStopMinutes: 0))
        #expect(await reaper.threshold() == nil)

        let conversation = try await world.service.start(world.request())
        let overridden = IdleReaper(
            store: world.store, conversations: world.service, environment: [IdleReaper.environmentKey: "60"], now: { Date().addingTimeInterval(120) })
        #expect(await overridden.threshold() == 60)
        await overridden.tick()
        #expect(await world.service.isLive(conversation.id) == false)
    }
}

@Suite("オーケストレーターの返事")
struct OrchestratorReplyTests {
    private func user(_ id: String, _ text: String) -> ChatMessage { ChatMessage(id: id, role: .user, kind: .text, text: text) }
    private func assistant(_ id: String, _ text: String) -> ChatMessage { ChatMessage(id: id, role: .assistant, kind: .text, text: text) }

    @Test("最後の user の発話より後の assistant の文。tool の結果・ツール呼び出しは区切りにも返事にもせず、思考も返事にしない")
    func latestReply() {
        let messages = [
            user("u1", "前の指示"), assistant("a1", "前の返事"),
            user("u2", "今の指示"), assistant("a2", "調べる"),
            ChatMessage(id: "k1", role: .assistant, kind: .text, text: "ls で見ればよい", thinking: true),
            ChatMessage(id: "t1", role: .assistant, kind: .toolUse, text: "ls"),
            ChatMessage(id: "r1", role: .user, kind: .toolResult, text: "a.txt"),
            assistant("a3", "a.txt がある"),
        ]
        #expect(OrchestratorReplyReader.latest(in: messages) == .init(id: "a3", text: "調べる\n\na.txt がある", last: "a.txt がある"))
        #expect(OrchestratorReplyReader.latest(in: Array(messages.prefix(3))) == nil, "今の指示の返事がまだ無ければ前の返事を拾わない")
        #expect(OrchestratorReplyReader.latest(in: []) == nil)
    }

    @Test("idle の後に書き込みが遅れても読み直して拾い、古い返事は拾わない。2000 字で切る")
    func keeperCapturesDelayedReply() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let orchestrator = try await world.service.start(world.request(), purpose: .orchestrator)
        let session = orchestrator.agentSessionID
        try world.append(session, [("u1", "user", "前の指示"), ("a1", "assistant", "前の返事"), ("u2", "user", "今の指示")])
        let keeper = OrchestratorKeeper(store: world.store, state: world.state, conversations: world.service, now: { t0 })
        await keeper.setReplyRetry(attempts: 6, interval: .milliseconds(200))

        let writer = Task {
            try await Task.sleep(for: .milliseconds(250))
            try world.append(session, [("a2", "assistant", String(repeating: "返", count: 2100))])
        }
        await keeper.conversationIdle(orchestrator.id)
        try await writer.value
        let reply = try #require(await world.state.orchestratorInfo()?.lastReply)
        #expect(reply.text == String(repeating: "返", count: 2000))
        #expect(reply.at == t0)

        // 次のターンの後に新しい文が無ければ、同じ返事を配り直さない
        let before = await world.state.orchestratorInfo()
        await keeper.setReplyRetry(attempts: 2, interval: .milliseconds(10))
        await keeper.conversationIdle(orchestrator.id)
        #expect(await world.state.orchestratorInfo()?.lastReply == before?.lastReply)
    }
}

