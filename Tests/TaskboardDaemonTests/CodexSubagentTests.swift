import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// codex のサブエージェント（`subAgentActivity` の子の thread）の発言を、起こした行の下に写す。通知は本物の記録（`CodexWire/subagent.jsonl`：子と孫）
@Suite("codex の会話のサブエージェント（偽の app-server）", .serialized)
struct CodexSubagentTests {
    private let machine = MachineID(rawValue: "m-codex")
    private static let child = "01a16d78-e090-7400-a384-a1c8128b4ae8"
    private static let grandchild = "01a16d78-f9eb-79d0-af89-da932d48dc41"
    private static let nested = "\(child)/\(grandchild)"

    private struct World {
        let conversation: CodexConversation
        let host: FakeHost
        let server: FakeThreadServer
        let log: LogLines
    }

    /// 送った turn で記録の通知の `lines` を流す
    private func make(_ lines: ArraySlice<String>, recording: CodexWireRecording) async throws -> World {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        let id = UUID().uuidString.lowercased()
        let saved = try store.createConversation(ConversationRecord(id: id, taskNumber: task.number, engine: .codex, agentSessionId: id, cwd: "/w", runner: .none))
        let host = FakeHost()
        let server = FakeThreadServer()
        let log = LogLines()
        server.setThread(recording.mainThread)
        await host.setResponder(server.respond)
        var context = CodexConversation.Context(
            shared: ConversationContext(
                machine: machine, store: store, host: host, launch: { EngineLaunch(executable: "/x/codex", environment: ["PATH": "/usr/bin"]) },
                attachments: nil, guide: { _ in "案内" }, becameIdle: { _ in }, logger: log.logger))
        var timing = ConversationTiming()
        timing.control = .seconds(2)
        timing.deltaBatch = .milliseconds(5)
        context.timing = timing
        context.epoch = "e1"
        let conversation = CodexConversation(record: saved, context: context)
        await host.connect(conversation.inbox, key: id)
        server.setTurnLines(Array(lines))
        try await conversation.start(resume: false)
        _ = try await conversation.send(ConversationSendRequest(text: "調べて", clientMessageID: UUID().uuidString.lowercased()))
        return World(conversation: conversation, host: host, server: server, log: log)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// 購読に届いた発言を「id:親の toolID」で、最初に届いた順に 1 つずつ。`subagents` を求めない購読はサブエージェントの発言を受けない
    private func messages(_ world: World, subagents: Bool) async throws -> [String] {
        let outbox = StreamOutbox()
        _ = await world.conversation.subscribe(outbox, key: UUID(), epoch: "e1", after: 0, subagents: subagents)
        outbox.finish()
        var lines: [String] = []
        for await frame in outbox.frames {
            guard case .conversation(let event) = try WireJSON.decoder().decode(StreamServerFrame.self, from: frame.data), case .messages(let messages, _) = event.kind
            else { continue }
            for line in messages.filter({ $0.role == .assistant || $0.kind == .toolResult }).map({ "\($0.id):\($0.parentToolID ?? "-")" }) where !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines
    }

    @Test("子と孫の thread の終わった item を、subAgentActivity の行の下に写す（id は thread で分け、孫の親は子の行）。求めた購読にだけ送り、子の turn の終わりで会話を空きにしない")
    func childAndGrandchild() async throws {
        let recording = try CodexWireRecording("subagent")
        let childEnd = try #require(recording.index(of: "turn/completed", thread: Self.child))
        let world = try await make(recording.notifications[...childEnd], recording: recording)
        let main = [
            "msg_0f81a88f8d66fb87016adc89670ad487d0898d818592325b0f:-", "call_O3KXOjoPe58EGQSezfXFhaeU:-", "call_xzTmKXAMFrcgAnatbUGZf8v1:-",
        ]
        let nested = [
            "\(Self.child)/msg_021fe218c8666b63016adc897496dc87d0b07ed8b3f697641f:\(Self.child)", "\(Self.child)/call_ujGVpdwUsVtfZk8VZtLWPwt8:\(Self.child)",
            "\(Self.grandchild)/exec-7ebc611f-39cf-4c68-b116-557dc1883b5a:\(Self.nested)",
            "\(Self.grandchild)/exec-7ebc611f-39cf-4c68-b116-557dc1883b5a-result:\(Self.nested)",
            "\(Self.grandchild)/msg_019b3807f19f7c0d016adc897d946c87d0903929deaf18066f:\(Self.nested)",
            "\(Self.child)/subagent-completed-01a16d78-fa10-7992-8e1d-4e33f8ac31f7:\(Self.child)",
            "\(Self.child)/call_gaMpA99lR9YQaRfbkkMAYyV6:\(Self.child)", "\(Self.child)/call_gaMpA99lR9YQaRfbkkMAYyV6-result:\(Self.child)",
        ]
        let late = [
            "call_xzTmKXAMFrcgAnatbUGZf8v1-result:-", "call_iMgxyLxGAxXJrN9XcnwmJk3D:-",
            "\(Self.child)/msg_021fe218c8666b63016adc898069f087d0b8f8c89502ef49eb:\(Self.child)",
            "subagent-completed-01a16d78-e0b7-7ab3-92ca-fb0be4c3b898:-",
        ]
        #expect(await eventually { (try? await messages(world, subagents: true).count) == main.count + nested.count + late.count })
        #expect(try await messages(world, subagents: true) == main + nested + late)
        #expect(try await messages(world, subagents: false) == main + ["call_xzTmKXAMFrcgAnatbUGZf8v1-result:-", "call_iMgxyLxGAxXJrN9XcnwmJk3D:-", "subagent-completed-01a16d78-e0b7-7ab3-92ca-fb0be4c3b898:-"])
        #expect(await world.conversation.snapshot().phase == .running)

        for line in recording.notifications[(childEnd + 1)...] { await world.host.emit(line) }
        let ended = ["call_iMgxyLxGAxXJrN9XcnwmJk3D-result:-", "msg_0f81a88f8d66fb87016adc898488fc87d09c46ce03891a8a4a:-"]
        #expect(await eventually { (try? await messages(world, subagents: true)) == main + nested + late + ended })
        #expect(await eventually { await world.conversation.snapshot().phase != .running })
    }

    @Test("subAgentActivity の started を受けていない thread の通知は捨て、thread と method を debug に出す")
    func unknownThread() async throws {
        let recording = try CodexWireRecording("subagent")
        let lines = recording.notifications.filter { !$0.contains(#""type":"subAgentActivity""#) }
        let world = try await make(lines[...], recording: recording)
        #expect(await eventually { await world.conversation.snapshot().phase != .running })
        #expect(try await messages(world, subagents: true).allSatisfy { $0.hasSuffix(":-") })
        let dropped = world.log.all.filter { $0.hasPrefix("codex notification of unknown thread dropped") }
        #expect(dropped.contains { $0.contains(Self.child) && $0.contains("item/completed") })
        #expect(dropped.contains { $0.contains(Self.grandchild) && $0.contains("turn/completed") })
    }

    @Test("子の thread の承認は親の会話の問いに混ぜず、codex に断る")
    func childApprovalRefused() async throws {
        let recording = try CodexWireRecording("subagent")
        let started = try #require(recording.index(of: "turn/started", thread: Self.child))
        let world = try await make(recording.notifications[...started], recording: recording)
        await world.host.emit(
            #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"\#(Self.child)","turnId":"t","itemId":"exec-1","command":"rm a.txt","cwd":"/w"}}"#)
        #expect(await eventually { await world.host.written().contains { ($0["id"] as? Int) == 0 && $0["error"] != nil } })
        #expect(await world.conversation.snapshot().pending.isEmpty)
    }
}
