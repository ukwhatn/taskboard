import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 裏で続けているツールの行（［今すぐ送信］で裏に回した Bash と、裏で起こした Agent）と、ふつうに終わった Bash を PNG で固定する。
/// ライト / ダークの 2 組。記録し直すときは suite の `record` を一時的に `.all` にして流す
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ChatBackgroundSnapshotTests {
    private static func messages() -> [ChatMessage] {
        let at = Date(timeIntervalSince1970: 1_792_540_800)
        func said(_ id: String, _ text: String) -> ChatMessage { ChatMessage(id: id, role: .assistant, kind: .text, text: text, at: at) }
        func call(_ id: String, _ name: String, _ text: String) -> ChatMessage {
            ChatMessage(id: "c-\(id)", role: .assistant, kind: .toolUse, text: text, toolName: name, toolID: id, at: at)
        }
        func result(_ id: String, _ text: String, background: String? = nil) -> ChatMessage {
            ChatMessage(id: "r-\(id)", role: .user, kind: .toolResult, text: text, toolID: id, at: at, backgroundTaskID: background)
        }
        // 続いたツールは組に畳まれるので、間に発言を挟んで 1 件ずつの行にする
        return [
            said("a1", "テストを回します。"),
            call("t1", "Bash", "swift test"),
            result("t1", "Command was manually backgrounded by user with ID: bttty78ys.", background: "bttty78ys"),
            said("a2", "調べ物はサブエージェントに任せます。"),
            call("t2", "Agent", "Run ping and report last line"),
            result("t2", "Async agent launched successfully.", background: "a43ac519cd242c5a9"),
            said("a3", "差分を確かめます。"),
            call("t3", "Bash", "git diff --stat"),
            result("t3", " a.txt | 2 +-"),
        ]
    }

    @Test(arguments: ChatFilesSnapshotTests.variants.map(\.name))
    func rows(variantName: String) async throws {
        AppDefaults.useScratch("snapshot")
        let variant = try #require(ChatFilesSnapshotTests.variants.first { $0.name == variantName })
        let view = ChatTranscript(messages: Self.messages(), expandedTools: ["t1"])
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 520), variant: variant), named: variant.name)
    }

    /// 続いたツールを畳んだ組の見出し。中に裏で続けているものがあれば、同じ印を出す（下の組は全部ふつうに終わったので印を出さない）
    @Test(arguments: ChatFilesSnapshotTests.variants.map(\.name))
    func group(variantName: String) async throws {
        AppDefaults.useScratch("snapshot")
        let variant = try #require(ChatFilesSnapshotTests.variants.first { $0.name == variantName })
        let all = Self.messages()
        let calls = all.filter { $0.kind != .text }
        let finished = [
            ChatMessage(id: "c-t4", role: .assistant, kind: .toolUse, text: "ls", toolName: "Bash", toolID: "t4", at: all[0].at),
            ChatMessage(id: "r-t4", role: .user, kind: .toolResult, text: "a.txt", toolID: "t4", at: all[0].at),
            ChatMessage(id: "c-t5", role: .assistant, kind: .toolUse, text: "pwd", toolName: "Bash", toolID: "t5", at: all[0].at),
            ChatMessage(id: "r-t5", role: .user, kind: .toolResult, text: "/w", toolID: "t5", at: all[0].at),
        ]
        let view = ChatTranscript(messages: [all[0]] + calls + [all[6]] + finished)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 260), variant: variant), named: variant.name)
    }

    /// fixtures `chat-background` の会話。会話の裏のタスクの様子で、動いている間は回る印と「バックグラウンドで実行中」、
    /// 終わったら完了・失敗・停止・終了（daemon が覚えていない）。続いたツールの組の見出しにも回る印
    @Test(arguments: ChatFilesSnapshotTests.variants.map(\.name))
    func states(variantName: String) async throws {
        AppDefaults.useScratch("snapshot")
        let variant = try #require(ChatFilesSnapshotTests.variants.first { $0.name == variantName })
        let (conversation, messages) = try Self.fixture("c-bg")
        let view = ChatTranscript(messages: messages, backgroundTasks: ChatBackgroundTasks(conversation: conversation))
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 560), variant: variant), named: variant.name)
    }

    /// 止まった会話の裏のタスクは動いていないので、daemon の記録が無くても終了と出す
    @Test(arguments: ChatFilesSnapshotTests.variants.map(\.name))
    func stopped(variantName: String) async throws {
        AppDefaults.useScratch("snapshot")
        let variant = try #require(ChatFilesSnapshotTests.variants.first { $0.name == variantName })
        let (conversation, messages) = try Self.fixture("c-bg-done")
        let view = ChatTranscript(messages: messages, backgroundTasks: ChatBackgroundTasks(conversation: conversation))
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 160), variant: variant), named: variant.name)
    }

    /// 動いている裏のタスクがある会話の画面。下の帯の末尾に回る印と「バックグラウンド2件」
    @Test(arguments: LayoutMatrixSnapshotTests.cases([560]))
    func screen(name: String) async throws {
        let (width, appearance) = try LayoutMatrixSnapshotTests.parse(name)
        let model = try await Self.loadedModel()
        let key = ConversationKey(machine: try #require(model.fleet.allBoards.first?.machine), id: "c-bg")
        let feed = model.conversationFeed(for: key)
        try #require(!feed.isEmpty, "fixtures の会話 c-bg に発言が無い")
        let view = ConversationView(key: key, feed: feed).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 820), variant: appearance), named: name)
    }

    /// ボードのカード。札に出しきれない会話も含め、タスクの会話の裏のタスクがあれば止まった印を添える
    @Test(arguments: BoardSnapshotTests.variants.prefix(2).map(\.name))
    func card(variantName: String) async throws {
        let variant = try #require(BoardSnapshotTests.variants.first { $0.name == variantName })
        let model = try await Self.loadedModel()
        let machine = try #require(model.fleet.allBoards.first?.machine)
        let task = try #require(model.fleet.task(for: TaskKey(machine: machine, number: 137)), "fixtures に #137 が無い")
        let view = TaskCard(task: task, signals: model.cardSignals(for: task), scheduleName: nil)
            .padding(BoardSnapshotTests.margin)
            .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 300, height: 220), variant: variant), named: variant.name)
    }

    private static func loadedModel() async throws -> AppModel {
        AppDefaults.useScratch("snapshot-background")
        let model = AppModel(options: LaunchOptions(scenario: "chat-background"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty || model.fleet.allMachines.values.allSatisfy({ $0.conversations.isEmpty }) {
            try #require(ContinuousClock.now < deadline, "fixtures chat-background を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(50))
        }
        return model
    }

    private struct Fixture: Decodable {
        struct Chat: Decodable { var messages: [ChatMessage] }
        var conversations: [Conversation]
        var conversationChats: [String: Chat]
    }

    private static func fixture(_ id: String) throws -> (Conversation, [ChatMessage]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/chat-background.json")
        let fixture = try WireJSON.decoder().decode(Fixture.self, from: Data(contentsOf: url))
        return (try #require(fixture.conversations.first { $0.id == id }), try #require(fixture.conversationChats[id]).messages)
    }
}
