import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// タスクなしの画面の［タスクを追加…］［タスクに紐づける…］。紐づける先の並びは fixtures `stress`（Mac Studio）のタスクで、
/// 会話は `conversations`（c-stop はタスクなしの会話、c-orch はオーケストレーター）で回す
@MainActor
@Suite(.serialized) struct UnassignedActionsTests {
    private let machine = MachineID(rawValue: "fixture-studio")
    private func key(_ id: String) -> ConversationKey { ConversationKey(machine: machine, id: id) }

    private func model(_ scenario: String = "conversations", writable: Bool) async throws -> AppModel {
        AppDefaults.useScratch("test-unassigned-actions")
        let model = AppModel(options: LaunchOptions(scenario: scenario))
        if writable {
            model.fleet.add(id: "fixture:\(scenario)", source: ConversationRecorder(base: try FixtureSource.named(scenario)))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.task(for: TaskKey(machine: machine, number: 137)) == nil || (writable && model.fleet.conversationSource(for: machine) == nil) {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func conversation(purpose: Conversation.Purpose? = nil, engine: Conversation.Engine = .claude, sessionID: String = "s-1") -> Conversation {
        Conversation(
            id: "c-1", machine: machine, taskNumber: nil, engine: engine, agentSessionID: sessionID, cwd: "/work", runner: .host, phase: .idle,
            purpose: purpose, createdAt: .distantPast, updatedAt: .distantPast)
    }

    @Test("紐づけの要求：会話は engine と会話 ID（pane なし）。オーケストレーターと会話 ID の無い会話は紐づけない")
    func linkRequests() {
        #expect(
            AppModel.linkRequest(conversation(engine: .codex, sessionID: "th-9"), task: 12)
                == SessionLinkRequest(paneID: nil, agent: "codex", agentSessionID: "th-9", cwd: "/work", taskNumber: 12))
        #expect(AppModel.linkRequest(conversation(purpose: .orchestrator), task: 12) == nil)
        #expect(AppModel.linkRequest(conversation(sessionID: ""), task: 12) == nil)
    }

    @Test("操作を出すのは、書き込める接続先の紐づけられる会話と PR だけ（表示用のデータとオーケストレーターには出さない）")
    func attachable() async throws {
        let readOnly = try await model(writable: false)
        #expect(!readOnly.canAttach(.conversation(key("c-stop"))))
        #expect(!readOnly.canAttach(.pullRequest(url: "https://github.com/o/r/pull/1", title: "t", machine: machine)))

        let model = try await model(writable: true)
        #expect(model.canAttach(.conversation(key("c-stop"))))
        #expect(!model.canAttach(.conversation(key("c-orch"))))
        #expect(!model.canAttach(.conversation(key("c-missing"))))
        #expect(model.canAttach(.pullRequest(url: "https://github.com/o/r/pull/1", title: "t", machine: machine)))
    }

    @Test("紐づける先の候補は、進行中の列のタスクを先に最近動いた順（同じ時刻は番号の大きい順）、完了と見送りは最後")
    func linkTargetOrder() async throws {
        let model = try await model("stress", writable: false)
        let numbers = model.linkTargets(on: machine).map(\.number)
        #expect(Array(numbers.prefix(7)) == [200, 137, 131, 128, 125, 118, 355])
        #expect(Array(numbers.suffix(3)) == [110, 109, 90])
        #expect(numbers.count == 72)
        #expect(model.linkTargets(on: MachineID(rawValue: "missing")).isEmpty)
    }

    @Test("候補の絞り込みは番号（# は付けても付けなくても）かタイトルの一部。空白だけなら全部")
    func matching() {
        let task = BoardTask(machine: machine, number: 137, boardID: "b", columnID: "c", title: "会員の権限 API", createdAt: .distantPast, updatedAt: .distantPast)
        for query in ["", "  ", "137", "#137", " #137 ", "権限", "api"] {
            #expect(AppModel.task(task, matches: query), "\(query)")
        }
        for query in ["13", "#1370", "決済", "#"] {
            #expect(!AppModel.task(task, matches: query), "\(query)")
        }
    }

    @Test("起票の下書き：PR はタイトルとリンクを入れ、会話は追加した後に紐づける。案件はそのマシンのサイドバーの先頭")
    func drafts() async throws {
        let model = try await model("stress", writable: false)
        let pr = try #require(model.newTaskDraft(for: .pullRequest(url: "https://github.com/o/r/pull/1", title: "決済の API の移行", machine: machine)))
        #expect(pr.title == "決済の API の移行")
        #expect(pr.links == ["https://github.com/o/r/pull/1", ""])
        #expect(pr.attach == nil)
        #expect(pr.board.id == "fixture-board")

        let conversations = try await self.model(writable: false)
        let stopped = try #require(conversations.newTaskDraft(for: .conversation(key("c-stop"))))
        #expect(stopped.attach == key("c-stop"))
        #expect(stopped.links == [""])
        #expect(!stopped.title.isEmpty)
        #expect(conversations.newTaskDraft(for: .conversation(ConversationKey(machine: MachineID(rawValue: "missing"), id: "c-stop"))) == nil)
    }
}
