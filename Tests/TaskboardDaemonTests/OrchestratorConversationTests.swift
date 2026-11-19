import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("オーケストレーターの会話（偽物の host）", .serialized)
struct OrchestratorConversationTests {
    private func keeper(_ world: ServiceWorld) -> OrchestratorKeeper {
        OrchestratorKeeper(store: world.store, state: world.state, conversations: world.service)
    }

    private func userTexts(_ world: ServiceWorld) async -> [String] {
        await world.host.written().filter { $0["type"] as? String == "user" }.compactMap { ($0["message"] as? [String: Any])?["content"] as? String }
    }

    private func spawns(_ world: ServiceWorld) async -> [AgentHostRequest] {
        await world.host.requests.filter { $0.op == .spawn }
    }

    @Test("常駐が入っていれば会話で起こして起動の指示を 1 回送る。止まった記録は同じ会話で戻し、指示は送り直さない")
    func keepsConversation() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let keeper = keeper(world)
        await keeper.tick()
        let record = try #require(await world.service.orchestratorRecord())
        #expect(await world.service.isLive(record.id))
        #expect(record.taskNumber == nil && record.title == OrchestratorKeeper.title)
        #expect(await userTexts(world) == [OrchestratorInfo.startPrompt])
        #expect(try await keeper.info().conversationID == record.id)

        // 常駐の間は人が止められないので、taskboard が止めた記録にする
        try await world.service.stop(record.id, cause: .taskboard)
        #expect(await !world.service.isLive(record.id))
        await keeper.tick()
        #expect(await world.service.isLive(record.id))
        #expect(await world.service.orchestratorRecord()?.id == record.id)
        let again = try #require(await spawns(world).last?.argv)
        #expect(await spawns(world).count == 2 && again.contains(record.agentSessionId))
        #expect(await userTexts(world).count == 1)
    }

    @Test("設定の引数を会話に読み替えられなければ、起こさずに理由を残す")
    func refusesUnconvertibleArguments() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        _ = try world.store.updateSettings(MachineSettingsUpdate(orchestratorAgentArgs: ["--remote-control"]))
        let keeper = keeper(world)
        await keeper.tick()
        #expect(await world.service.orchestratorRecord() == nil)
        #expect(await spawns(world).isEmpty)
        #expect(try await keeper.info().lastError?.contains("--remote-control") == true)
    }

    @Test("破棄して再起動は、古い会話を消して新しい会話を起こし、古い会話が起こした委譲先の親を新しい会話に移す")
    func restartMovesChildren() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let keeper = keeper(world)
        await keeper.tick()
        let old = try #require(await world.service.orchestratorRecord())
        var request = world.request()
        request.parent = ConversationParent(conversationID: old.id)
        request.notifyParent = true
        let child = try await world.service.start(request)

        _ = try await keeper.restart()
        let created = try #require(await world.service.orchestratorRecord())
        #expect(created.id != old.id && created.agentSessionId != old.agentSessionId)
        #expect(try world.store.conversation(id: old.id) == nil)
        #expect(await world.service.isLive(created.id))
        #expect(try world.store.conversation(id: child.id)?.parentConversationId == created.id)
        #expect(await userTexts(world).filter { $0 == OrchestratorInfo.startPrompt }.count == 2)
    }
}
