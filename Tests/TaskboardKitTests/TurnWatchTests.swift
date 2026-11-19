import Foundation
import Testing

@testable import TaskboardKit

@Suite("ターンの完了")
struct TurnWatchTests {
    private let info = MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t")
    private let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    private func conversation(
        _ id: String, _ phase: Conversation.Phase, task: Int? = 7, purpose: Conversation.Purpose? = nil, parent: String? = nil, title: String? = nil
    ) -> Conversation {
        var conversation = Conversation(
            id: id, machine: info.id, taskNumber: task, agentSessionID: "a-\(id)", cwd: "/tmp", runner: .host, phase: phase, createdAt: t0, updatedAt: t0)
        conversation.purpose = purpose
        conversation.parentConversationID = parent
        conversation.title = title
        return conversation
    }

    private func state(conversations: [Conversation] = []) -> MachineState {
        var state = MachineState(machine: info)
        state.conversations = Dictionary(uniqueKeysWithValues: conversations.map { ($0.key, $0) })
        return state
    }

    @Test("host の会話は running から idle で返し、待ち（waiting）・止めた会話・オーケストレーター・定期起動・委譲先は返さない")
    func conversations() {
        var watch = TurnWatch()
        watch.reset(
            state(conversations: [
                conversation("c1", .running), conversation("c2", .running), conversation("c3", .running), conversation("c4", .running, purpose: .orchestrator),
                conversation("c5", .running, purpose: .schedule), conversation("c6", .running, parent: "c1"),
            ]))
        let finished = watch.update(
            state(conversations: [
                conversation("c1", .idle), conversation("c2", .waiting), conversation("c3", .stopped), conversation("c4", .idle, purpose: .orchestrator),
                conversation("c5", .idle, purpose: .schedule), conversation("c6", .idle, parent: "c1"),
            ]))
        #expect(finished.map(\.key) == ["turn/conversation/c1"])
    }

    @Test("基準を取る前の応答中は数えない（起動して最初の状態で鳴らさない）。同じ状態を当て直しても 2 度は返さない")
    func baseline() {
        var watch = TurnWatch()
        watch.reset(state(conversations: [conversation("c1", .idle)]))
        _ = watch.update(state(conversations: [conversation("c1", .running)]))
        #expect(watch.update(state(conversations: [conversation("c1", .idle)])).map(\.key) == ["turn/conversation/c1"])
        #expect(watch.update(state(conversations: [conversation("c1", .idle)])).isEmpty)
    }

    @Test("通知の中身: 題は「応答の完了」、補足は接続先の名前とタスク、本文は会話の題か「◯◯が応答を終えました」、押すと会話を開く")
    func notification() throws {
        var watch = TurnWatch()
        watch.reset(state(conversations: [conversation("c1", .running, title: "ログの調査"), conversation("c2", .running, task: nil)]))
        let finished = watch.update(state(conversations: [conversation("c1", .idle, title: "ログの調査"), conversation("c2", .idle, task: nil)]))
        let byKey = Dictionary(uniqueKeysWithValues: finished.map { ($0.key, $0) })

        let titled = try #require(byKey["turn/conversation/c1"]).notification(machineName: "Studio")
        #expect(titled.title == "応答の完了")
        #expect(titled.subtitle == "Studio・#7")
        #expect(titled.body == "ログの調査")
        #expect(titled.turn)
        #expect(titled.threadID == TaskKey(machine: info.id, number: 7).description)
        #expect(titled.url == TaskboardLink.conversation(ConversationKey(machine: info.id, id: "c1")).url)

        let untitled = try #require(byKey["turn/conversation/c2"]).notification(machineName: "")
        #expect(untitled.subtitle == "")
        #expect(untitled.body == "Claude Codeが応答を終えました")
        #expect(untitled.threadID == "m")

    }

    @Test("設定の値: 知らない値は「アプリを使っていないときだけ」と読み、登録ごと読めなくしない")
    func decodesUnknown() throws {
        let data = Data(#"{"token":"00","environment":"sandbox","topic":"t","kinds":["question"],"turns":"later","sound":true,"machineName":"m","connection":"c"}"#.utf8)
        let registration = try JSONDecoder().decode(PushRegistration.self, from: data)
        #expect(registration.turns == .background)
        #expect(registration.kinds == [.question])
        // この欄を知らない版のアプリの登録は nil（送らない）
        let old = Data(#"{"token":"00","environment":"sandbox","topic":"t","kinds":[],"sound":true,"machineName":"m","connection":"c"}"#.utf8)
        #expect(try JSONDecoder().decode(PushRegistration.self, from: old).turns == nil)
    }
}
