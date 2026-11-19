import Foundation
import Testing

@testable import TaskboardKit

@Suite("1 本の接続の通信の型")
struct StreamWireTests {
    let machine = MachineID(rawValue: "m")
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    func conversation(_ id: String = "c1", phase: Conversation.Phase = .idle, pending: [ConversationRequest] = []) -> Conversation {
        Conversation(
            id: id, machine: machine, taskNumber: 7, agentSessionID: "a1", cwd: "/tmp", title: "会話", runner: .host, phase: phase, pending: pending,
            createdAt: t0, updatedAt: t0)
    }

    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try WireJSON.decoder().decode(T.self, from: WireJSON.encoder().encode(value))
    }

    @Test("アプリが送る 3 種類を読み書きできる")
    func clientMessages() throws {
        for message in [
            StreamClientMessage.hello(epoch: nil, rev: nil), .hello(epoch: "e", rev: 12), .subscribe(conversation: "c1", epoch: "e", after: 3),
            .subscribe(conversation: "c1", epoch: nil, after: 0), .unsubscribe(conversation: "c1"),
        ] {
            #expect(try roundTrip(message) == message)
        }
        let text = String(decoding: try WireJSON.encoder().encode(StreamClientMessage.subscribe(conversation: "c1", epoch: "e", after: 3)), as: UTF8.self)
        #expect(text == #"{"after":3,"conversation":"c1","epoch":"e","type":"subscribe"}"#, "求めないときは subagents を書かない（前の版の daemon と同じ形）")
        let asking = StreamClientMessage.subscribe(conversation: "c1", epoch: nil, after: 0, subagents: true)
        #expect(try roundTrip(asking) == asking)
        #expect(String(decoding: try WireJSON.encoder().encode(asking), as: UTF8.self).contains(#""subagents":true"#))
    }

    @Test("daemon が送る 6 種類を読み書きできる")
    func serverFrames() throws {
        let snapshot = StateSnapshot(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"), generatedAt: t0)
        let event = ConversationEvent(seq: 4, conversationID: "c1", at: t0, kind: .delta(messageID: "msg", index: 0, block: .text, text: "あ"))
        for frame in [
            StreamServerFrame.state(epoch: "e", rev: 3, snapshot: snapshot), .resume(epoch: "e", rev: 3),
            .event(rev: 4, event: .conversationUpdated(conversation())), .event(rev: 5, event: .conversationRemoved(ConversationKey(machine: machine, id: "c1"))),
            .subscribed(conversation: "c1", epoch: "e", through: 9), .conversation(event), .unsubscribed(conversation: "c1", reason: StreamServerFrame.behind),
        ] {
            #expect(try roundTrip(frame) == frame)
        }
    }

    @Test("知らない種類の出来事は番号だけ進め、知らない種類の 1 通は読み飛ばす")
    func unknownKinds() throws {
        let decoder = WireJSON.decoder()
        let event = Data(#"{"type":"event","rev":8,"data":{"event":"future.thing","data":{}}}"#.utf8)
        #expect(try StreamServerFrame.decodeIfKnown(event, decoder: decoder) == .event(rev: 8, event: nil))
        let frame = Data(#"{"type":"future","x":1}"#.utf8)
        #expect(try StreamServerFrame.decodeIfKnown(frame, decoder: decoder) == nil)
        // 知っている種類の中身が壊れていたら投げる
        let broken = Data(#"{"type":"event","rev":8,"data":{"event":"task.removed","data":{}}}"#.utf8)
        #expect(throws: DecodingError.self) { try StreamServerFrame.decodeIfKnown(broken, decoder: decoder) }
    }

    @Test("新しい daemon が足した engine・問いの種類・役目を読んでも、会話を捨てずに読める")
    func futureConversationValues() throws {
        let waiting = RequestWaiting(id: "r1", since: t0, questions: [AskQuestion(id: "q1", question: "どちらにしますか", options: [])])
        let request = ConversationRequest(id: "r1", kind: .question, toolName: "AskUserQuestion", toolUseID: "tu1", waiting: waiting)
        var object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(conversation(pending: [request]))) as? [String: Any])
        object["engine"] = "gemini"
        object["purpose"] = "nightly"
        var pending = try #require(object["pending"] as? [[String: Any]])
        pending[0]["kind"] = "user_dialog"
        object["pending"] = pending
        let decoded = try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.engine == .unknown)
        #expect(decoded.purpose == nil)
        #expect(decoded.pending.map(\.kind) == [.unknown])
        #expect(decoded.pending.first?.waiting.questions?.first?.question == "どちらにしますか")
        // ログインの段階：無ければ nil、知らない段階は unknown
        #expect(decoded.login == nil)
        object["login"] = "expired"
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).login == .unknown)
        object["login"] = "waiting"
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).login == .waiting)
        object["engine"] = "codex"
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).engine == .codex)
    }

    @Test("圧縮中の様子と止まりの時刻は書いて読み戻せ、無い（前の版の daemon）か読めなければ nil で、会話は読める")
    func conversationCompaction() throws {
        var made = conversation()
        made.compaction = ConversationCompaction(startedAt: t0, outputChars: 1_830)
        let data = try WireJSON.encoder().encode(made)
        #expect(try WireJSON.decoder().decode(Conversation.self, from: data).compaction == ConversationCompaction(startedAt: t0, outputChars: 1_830))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["compaction"] = nil
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).compaction == nil)
        object["compaction"] = ["outputChars": "多い"]
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).compaction == nil)
        // 止まりの時刻も同じ
        made.stalledSince = t0
        #expect(try WireJSON.decoder().decode(Conversation.self, from: WireJSON.encoder().encode(made)).stalledSince == t0)
        object["stalledSince"] = "きのう"
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).stalledSince == nil)
    }

    @Test("API の送り直しの様子は書いて読み戻せ、無い（前の版の daemon）か読めなければ nil で、会話は読める")
    func conversationAPIRetry() throws {
        var made = conversation()
        let retry = ConversationAPIRetry(attempt: 3, maxRetries: 10, retryAt: t0.addingTimeInterval(12), status: nil, kind: "unknown")
        made.apiRetry = retry
        let data = try WireJSON.encoder().encode(made)
        #expect(try WireJSON.decoder().decode(Conversation.self, from: data).apiRetry == retry)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["apiRetry"] = nil
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).apiRetry == nil)
        object["apiRetry"] = ["attempt": "三回目"]
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).apiRetry == nil)
        made.apiRetry = ConversationAPIRetry(attempt: 1, maxRetries: 10, retryAt: t0, status: 529, kind: "overloaded")
        #expect(try roundTrip(made).apiRetry?.status == 529)
    }

    @Test("待ち行列の止まりは書いて読み戻せ、止まっていなければ欄を書かず、無い（前の版の daemon）か読めなければ nil で、会話は読める")
    func conversationQueuePaused() throws {
        var made = conversation()
        let plain = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(made)) as? [String: Any])
        #expect(plain["queuePaused"] == nil)
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: plain)).queuePaused == nil)
        made.queuePaused = true
        #expect(try roundTrip(made).queuePaused == true)
        var object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(made)) as? [String: Any])
        object["queuePaused"] = "止まっている"
        let decoded = try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.queuePaused == nil)
        #expect(decoded.id == "c1")
    }

    @Test("ネットワークの続きの印は書いて読み戻せ、無ければ欄を書かず、無い（前の版の daemon）か読めなければ nil で、会話は読める")
    func conversationNetworkResume() throws {
        var made = conversation()
        let plain = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(made)) as? [String: Any])
        #expect(plain["networkResume"] == nil)
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: plain)).networkResume == nil)
        made.networkResume = true
        #expect(try roundTrip(made).networkResume == true)
        var object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(made)) as? [String: Any])
        object["networkResume"] = "待っている"
        let decoded = try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.networkResume == nil)
        #expect(decoded.id == "c1")
    }

    @Test("人の付けた名前は書いて読み戻せ、無い（前の版の daemon）なら nil で、会話は読める")
    func conversationCustomTitle() throws {
        var made = conversation()
        made.customTitle = "差分の画面"
        #expect(try roundTrip(made).customTitle == "差分の画面")
        var object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(made)) as? [String: Any])
        object["customTitle"] = nil
        let decoded = try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.customTitle == nil)
        #expect(decoded.id == "c1")
    }

    @Test("会話の値は今の engine の会話のものだけを出し、知らない欄は読み捨て、読めない値でも会話は読める")
    func conversationStats() throws {
        var made = conversation()
        made.stats = ConversationStats(
            agentSessionID: "a1", model: "claude-haiku-5-5", engineVersion: "2.1.303", costUSD: 0.0094,
            tokens: .init(input: 4, output: 7, cacheRead: 46604, cacheWrite: 44718), contextTokens: 51058, contextWindow: 600_000, at: t0)
        #expect(try roundTrip(made).currentStats == made.stats)
        var cleared = made
        cleared.agentSessionID = "a2"
        #expect(cleared.currentStats == nil, "/clear の後は前の会話の値を出さない")
        var object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(made)) as? [String: Any])
        var stats = try #require(object["stats"] as? [String: Any])
        stats["reasoningTokens"] = 12
        object["stats"] = stats
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).currentStats?.costUSD == 0.0094)
        object["stats"] = ["agentSessionID": 3]
        let broken = try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(broken.stats == nil && broken.id == made.id)
    }

    @Test("知らない種類の会話の出来事と塊は、番号を残して読み捨てる。知っている種類の中身が壊れていたら投げる")
    func futureConversationEvents() throws {
        func decode(_ kind: Any) throws -> ConversationEvent {
            let base = ConversationEvent(seq: 5, conversationID: "c1", at: t0, kind: .gap)
            var object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(base)) as? [String: Any])
            object["kind"] = kind
            return try WireJSON.decoder().decode(ConversationEvent.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let future = try decode(["commandOutput": ["itemID": "i1", "text": "ok"]])
        #expect(future.seq == 5)
        #expect(future.kind == .unsupported)
        let block = try decode(["blockStart": ["messageID": "m1", "index": 0, "block": "commandOutput"]])
        #expect(block.kind == .unsupported)
        #expect(try decode(["delta": ["messageID": "m1", "index": 0, "block": "text", "text": "あ"]]).kind
            == .delta(messageID: "m1", index: 0, block: .text, text: "あ"))
        #expect(throws: DecodingError.self) { try decode(["notice": [String: Any]()]) }
        #expect(throws: DecodingError.self) { try decode(["delta": ["messageID": "m1", "block": "text", "text": "あ"]]) }
    }

    @Test("E1 の daemon が返す会話（裏のタスクの数が無い）は、数が 0 で分かっている")
    func conversationWithoutBackgroundTasks() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(conversation())) as? [String: Any])
        object.removeValue(forKey: "backgroundTasks")
        object.removeValue(forKey: "backgroundTasksKnown")
        let decoded = try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.backgroundTasks == 0)
        #expect(decoded.backgroundTasksKnown)
        #expect(try roundTrip(Conversation(
            id: "c2", machine: machine, taskNumber: nil, agentSessionID: "a2", cwd: "/", runner: .none, phase: .stopped, backgroundTasks: 2,
            backgroundTasksKnown: false, createdAt: t0, updatedAt: t0)).backgroundTasksKnown == false)
    }

    @Test("裏のタスクの様子：前の版の daemon（項目が無い）は nil。知らない終わり方は「終了」と読む")
    func backgroundTaskStates() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(conversation())) as? [String: Any])
        #expect(object["backgroundTaskStates"] == nil)
        #expect(try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).backgroundTaskStates == nil)

        var withStates = object
        withStates["backgroundTaskStates"] = [["id": "b1", "status": "running"], ["id": "b2", "status": "stopped"], ["id": "b3", "status": "paused"]]
        let decoded = try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: withStates))
        #expect(decoded.backgroundTaskStates == [.init(id: "b1", status: .running), .init(id: "b2", status: .stopped), .init(id: "b3", status: .ended)])
        #expect(try roundTrip(decoded).backgroundTaskStates == decoded.backgroundTaskStates)
    }

    @Test("会話の出来事を当て、全体で置き換えると消えた会話も消える")
    func applyConversations() throws {
        var state = MachineState()
        let info = MachineInfo(id: machine, name: "m", daemonVersion: "t")
        var snapshot = StateSnapshot(machine: info, generatedAt: t0)
        snapshot.conversations = [conversation("c1"), conversation("c2")]
        state.apply(.stateSnapshot(snapshot))
        #expect(state.conversations.count == 2)
        state.apply(.conversationUpdated(conversation("c1", phase: .running)))
        #expect(state.conversations[ConversationKey(machine: machine, id: "c1")]?.phase == .running)
        state.apply(.conversationRemoved(ConversationKey(machine: machine, id: "c2")))
        #expect(state.conversations.keys.map(\.id) == ["c1"])
        snapshot.conversations = []
        state.apply(.stateSnapshot(snapshot))
        #expect(state.conversations.isEmpty)
        // E1 までの daemon の全体（conversations が無い）も読める
        var object = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "conversations")
        #expect(try WireJSON.decoder().decode(StateSnapshot.self, from: JSONSerialization.data(withJSONObject: object)).conversations.isEmpty)
    }

    @Test("会話の問いは受信箱の応答待ちに出て、問いの id ごとに別の項目になる")
    func inboxRequests() throws {
        let waiting = RequestWaiting(id: "r1", since: t0, questions: [AskQuestion(id: "q1", question: "どちらにしますか", options: [])])
        let request = ConversationRequest(id: "r1", kind: .question, toolName: "AskUserQuestion", toolUseID: "tu1", waiting: waiting)
        var state = MachineState()
        state.machine = MachineInfo(id: machine, name: "m", daemonVersion: "t")
        var waitingConversation = conversation("c1", phase: .waiting, pending: [request])
        state.conversations[waitingConversation.key] = waitingConversation
        let items = state.inboxItems(now: t0).filter { if case .conversationRequest = $0.kind { true } else { false } }
        #expect(items.map(\.localID) == ["conversation/c1/r1"])
        #expect(items.first?.group == .waiting)
        #expect(items.first?.details.first == "どちらにしますか")
        let first = try #require(items.first)
        let notification = try #require(InboxNotification.make(first, machineName: "Studio"))
        #expect(notification.body == "会話\nどちらにしますか")
        #expect(notification.url.absoluteString == "taskboard://conversation/m/c1")
        #expect(NotifyKind.of(first) == .approval)
        // defer で終えた問いも出る
        waitingConversation.pending = []
        waitingConversation.deferred = request
        waitingConversation.phase = Conversation.Phase.stopped
        state.conversations[waitingConversation.key] = waitingConversation
        #expect(state.inboxItems(now: t0).contains { $0.localID == "conversation/c1/r1" })
    }
}
