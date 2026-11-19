import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// host の会話の代わり。`outcomes` を前から順に返し、尽きたら `delivered`
private actor FakeConversations: FeedbackConversations {
    var owners: [String: String] = [:]
    var idle: [(id: String, task: Int)] = []
    var outcomes: [ConversationDeliveryOutcome?] = []
    private(set) var delivered: [(id: String, text: String, uuid: String)] = []
    private(set) var resumed: [(task: Int, agentSessionID: String)] = []

    func set(owner sessionID: String, conversation: String) { owners[sessionID] = conversation }
    func set(idle: [(id: String, task: Int)]) { self.idle = idle }
    func set(outcomes: [ConversationDeliveryOutcome?]) { self.outcomes = outcomes }

    func conversationID(owning agentSessionID: String) async -> String? { owners[agentSessionID] }
    func idleConversations() async -> [(id: String, task: Int)] { idle }
    func deliver(conversationID: String, text: String, uuid: String, kind: DeliveryKind) async -> ConversationDeliveryOutcome? {
        delivered.append((conversationID, text, uuid))
        return outcomes.isEmpty ? .delivered : outcomes.removeFirst()
    }
    func resumeStoppedLead(task number: Int, agentSessionID: String, for kind: DeliveryKind) async {
        if kind.resumesStoppedTerminal { resumed.append((number, agentSessionID)) }
    }
}

private let machine = MachineID(rawValue: "m-routing")

/// タスク #1 に sess-1 と sess-2（後に結んだ）が結ばれている
private struct RoutingWorld {
    let store: Store
    let state: DaemonState
    let conversations: FakeConversations
    let service: FeedbackService
    let task: BoardTask

    static func make() async throws -> RoutingWorld {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let board = try store.createBoard(name: "default", columns: nil)
        let created = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "planning", title: "設計"))
        _ = try store.linkSession(task: created.number, agent: "claude", sessionID: "sess-1", cwd: "/repo", label: "")
        let task = try store.linkSession(task: created.number, agent: "claude", sessionID: "sess-2", cwd: "/repo", label: "")
        await state.upsert(task)
        let conversations = FakeConversations()
        let service = FeedbackService(store: store, state: state, markers: nil)
        await service.setConversations(conversations)
        return RoutingWorld(store: store, state: state, conversations: conversations, service: service, task: task)
    }

    /// 文書 `name` に質問を出し（頼んだ会話は `requester`）、答える。answer の口と同じく notify はしない
    func askAndAnswer(_ name: String, requester: String?) throws -> Int64 {
        let published = try store.publish(
            task: task.number,
            DocPublishRequest(
                name: name, format: .markdown, content: "?",
                questions: [AskQuestion(id: "q1", question: "\(name) はどっち", options: [AskOption(label: "A"), AskOption(label: "B")])]),
            requester: requester)
        let id = try #require(published.askID)
        _ = try store.answerAsk(id: id, answers: [AskAnswer(questionID: "q1", selected: ["A"])])
        return id
    }

    func delivered(_ id: Int64) throws -> Bool { try store.ask(id: id)?.deliveredAt != nil }
}

@Suite("FeedbackService: 回答・レビューを頼んだ会話に届ける")
struct FeedbackRoutingTests {
    @Test("頼んだ会話が host の会話なら発言として入れ、モデルに渡ったら受領済みにする")
    func toHostConversation() async throws {
        let world = try await RoutingWorld.make()
        await world.conversations.set(owner: "sess-h", conversation: "conv-1")
        let id = try world.askAndAnswer("a.md", requester: "sess-h")
        await world.service.notify(task: world.task.number)
        let delivered = await world.conversations.delivered
        #expect(delivered.map(\.id) == ["conv-1"])
        #expect(delivered.first.map { TaskboardNotice.stripMarker($0.text) } == "taskboard で質問に答えました（#\(world.task.number)）。\n- 「a.md はどっち」→ A")
        #expect(delivered.first.map { TaskboardNotice(text: $0.text) } == .answer)
        #expect(try world.delivered(id))
    }

    @Test("取り消されたら回数を進めて未受領に残し、次に空いたときに別の uuid で届ける。生成中・止まっている会話には入れたことにしない")
    func hostCancelledAndBusy() async throws {
        let world = try await RoutingWorld.make()
        await world.conversations.set(owner: "sess-h", conversation: "conv-1")
        await world.conversations.set(outcomes: [.cancelled, .busy, nil, .delivered])
        let id = try world.askAndAnswer("a.md", requester: "sess-h")
        await world.service.notify(task: world.task.number)
        #expect(try !world.delivered(id))
        await world.conversations.set(idle: [("conv-1", world.task.number)])
        await world.service.conversationIdle("conv-1")
        await world.service.conversationIdle("conv-1")
        #expect(try !world.delivered(id), "busy と止まっている（nil）では受領済みにしない")
        await world.service.conversationIdle("conv-1")
        #expect(try world.delivered(id))
        let uuids = await world.conversations.delivered.map(\.uuid)
        #expect(uuids.count == 4)
        #expect(uuids[0] != uuids[1], "取り消しの後は別の uuid")
        #expect(uuids[1] == uuids[2] && uuids[2] == uuids[3], "取り消し以外では同じ uuid で入れ直す（前に受けていれば会話が受けたことにする）")
    }

    @Test("頼んだ会話の無い回答は、lead が host の会話ならそこに入れる（後に結んだ sess-2 の会話。sess-1 は止まった TUI）")
    func estimateToHostConversation() async throws {
        let world = try await RoutingWorld.make()
        await world.conversations.set(owner: "sess-2", conversation: "conv-2")
        // lead はタスクに結ばれた会話（conversation.taskNumber）から選ぶ
        await world.state.upsert(
            Conversation(
                id: "conv-2", machine: machine, taskNumber: world.task.number, agentSessionID: "sess-2", cwd: "/repo", runner: .host, phase: .idle,
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)))
        let id = try world.askAndAnswer("a.md", requester: nil)
        await world.service.notify(task: world.task.number)
        #expect(await world.conversations.delivered.map(\.id) == ["conv-2"])
        #expect(try world.delivered(id))
    }

    @Test("頼んだ会話の無い回答で、lead が止まった TUI なら、その Claude の会話を会話で戻す（戻した会話が空いたら入れる）")
    func resumesStoppedTerminalLead() async throws {
        let world = try await RoutingWorld.make()
        let id = try world.askAndAnswer("a.md", requester: nil)
        await world.service.notify(task: world.task.number)
        #expect(await world.conversations.resumed.map(\.agentSessionID) == ["sess-2"], "後に結んだ sess-2 が lead")
        #expect(await world.conversations.delivered.isEmpty)
        #expect(try !world.delivered(id))
    }

    @Test("hook の claim は、host の会話に届ける分を除いて取る（頼んだのがタスクに結んだ別のセッションでも）")
    func claimTakesOnlyOwn() async throws {
        let world = try await RoutingWorld.make()
        await world.conversations.set(owner: "sess-h", conversation: "conv-1")
        await world.conversations.set(outcomes: [.busy])
        let own = try world.askAndAnswer("a.md", requester: "sess-1")
        let other = try world.askAndAnswer("b.md", requester: "sess-2")
        _ = try world.askAndAnswer("c.md", requester: "sess-h")
        let loose = try world.askAndAnswer("d.md", requester: nil)
        let response = try await world.service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 0))
        #expect(response.status == .feedback)
        #expect(Set(response.bundle?.answeredAsks.map(\.askID) ?? []) == [own, other, loose])
    }

    @Test("頼まれて送ったレビューは、頼んだ会話に届ける")
    func reviewToRequester() async throws {
        let world = try await RoutingWorld.make()
        await world.conversations.set(owner: "sess-h", conversation: "conv-1")
        _ = try world.store.requestReview(task: world.task.number, note: "見て", requester: "sess-h")
        _ = try world.store.setReviewSummary(task: world.task.number, summary: "よさそう")
        _ = try world.store.submitReview(task: world.task.number)
        await world.service.notify(task: world.task.number)
        #expect(await world.conversations.delivered.map(\.id) == ["conv-1"])
        #expect(try world.store.peekUndeliveredFeedback(task: world.task.number).bundle.isEmpty)
    }

    @Test("頼んだ会話は、host の会話なら今の ID、そうでなければ環境の ID に決める")
    func resolveRequester() async throws {
        let world = try await RoutingWorld.make()
        let record = try world.store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: "sess-conv", cwd: "/repo", runner: .host))
        #expect(await world.service.requesterSessionID(FeedbackRequester(conversationID: record.id, agentSessionID: "sess-env")) == "sess-conv")
        #expect(await world.service.requesterSessionID(FeedbackRequester(agentSessionID: "sess-env")) == "sess-env")
        #expect(await world.service.requesterSessionID(nil) == nil)
    }

    @Test("発言の uuid は、同じ回答と回数なら同じ値で、回数か中身が変われば変わる。version 5 の形")
    func messageID() async throws {
        let world = try await RoutingWorld.make()
        _ = try world.askAndAnswer("a.md", requester: nil)
        let pending = try world.store.peekUndeliveredFeedback(task: world.task.number)
        let first = FeedbackService.messageID(pending)
        #expect(first == FeedbackService.messageID(pending))
        #expect(UUID(uuidString: first) != nil && Array(first)[14] == "5")
        try world.store.markFeedbackAttempted(pending.items)
        #expect(FeedbackService.messageID(try world.store.peekUndeliveredFeedback(task: world.task.number)) != first)
        _ = try world.askAndAnswer("b.md", requester: nil)
        let both = try world.store.peekUndeliveredFeedback(task: world.task.number)
        #expect(FeedbackService.messageID(both) != FeedbackService.messageID(both.only([both.items[0]])))
    }
}
