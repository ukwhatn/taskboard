import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// サイドバーのタスクの行の札（`TaskRowStatus`）。札は 1 つだけ出し、強いものを先にする
@Suite struct TaskRowStatusTests {
    private let studio = MachineID(rawValue: "studio")

    private func request(_ kind: ConversationRequest.Kind, tool: String, permission: RequestWaiting.Permission? = nil) -> InboxItem {
        let conversation = Conversation(
            id: "c1", machine: studio, taskNumber: 1, agentSessionID: "s1", cwd: "/w", runner: .host, phase: .waiting,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let request = ConversationRequest(
            id: "r1", kind: kind, toolName: tool, toolUseID: nil, waiting: RequestWaiting(id: "w1", since: Date(timeIntervalSince1970: 0), permission: permission))
        return InboxItem(
            id: "i1", kind: .conversationRequest(conversation, request), group: .waiting, machine: studio, taskNumber: 1, title: "t", details: [],
            at: Date(timeIntervalSince1970: 0))
    }

    @Test("ExitPlanMode の問いは計画の承認待ちにし、AskUserQuestion の回答待ちと分ける")
    func planApproval() {
        #expect(TaskRowStatus(request(.plan, tool: "ExitPlanMode")) == .planApproval)
        #expect(TaskRowStatus(request(.question, tool: "AskUserQuestion")) == .question)
        #expect(TaskRowStatus(request(.permission, tool: "Bash", permission: .init(tool: "Bash", summary: "ls"))) == .blocked)
    }

    @Test("札の強さの順")
    func order() {
        #expect(
            TaskRowStatus.allCases.map(\.label) == [
                "応答待ち", "回答待ち", "計画の承認待ち", "手作業待ち", "レビュー依頼あり", "修正依頼あり", "CI失敗", "未読", "実行中", "CI成功", "マージ済み",
            ])
        #expect(TaskRowStatus.allCases.filter(\.isMine) == [.blocked, .question, .planApproval, .manualWork, .reviewRequested, .changesRequested, .ciFailed])
    }

    @Test("手作業の依頼は手作業待ち（自分の番）")
    func manualWork() {
        let machine = MachineID(rawValue: "m")
        let item = WorkItem(
            machine: machine, itemID: 3, taskNumber: 1, title: "実機の確認", state: .wait, blockerKind: .manual, blockerText: "iPhone をつなぐ", position: 0,
            source: "session", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let inbox = InboxItem(
            id: "manual/3", kind: .manualWork(item), group: .waiting, machine: machine, taskNumber: 1, title: "iPhone をつなぐ", details: [],
            at: Date(timeIntervalSince1970: 0))
        #expect(TaskRowStatus(inbox) == .manualWork && TaskRowStatus.manualWork.isMine)
    }

    @Test("開いている PR が全部 CI 成功なら CI成功。チェックが無い・走っている・落ちた PR が 1 つでもあれば出さない")
    func ciPassed() {
        #expect(TaskRowStatus.pullRequest([.init(state: .open, checks: .success)]) == .ciPassed)
        #expect(TaskRowStatus.pullRequest([.init(state: .open, checks: .success), .init(state: .merged)]) == .ciPassed)
        #expect(TaskRowStatus.pullRequest([.init(state: .open, checks: .success), .init(state: .open, checks: .pending)]) == nil)
        #expect(TaskRowStatus.pullRequest([.init(state: .open, checks: .failure)]) == nil)
        #expect(TaskRowStatus.pullRequest([.init(state: .open)]) == nil)
    }

    @Test("開いている PR が無く、マージ済みがあればマージ済み。クローズだけ・PR 無しは出さない")
    func merged() {
        #expect(TaskRowStatus.pullRequest([.init(state: .merged), .init(state: .closed)]) == .merged)
        #expect(TaskRowStatus.pullRequest([.init(state: .open, checks: .pending), .init(state: .merged)]) == nil)
        #expect(TaskRowStatus.pullRequest([.init(state: .closed)]) == nil)
        #expect(TaskRowStatus.pullRequest([]) == nil)
    }

    @MainActor
    private func unreadTask(scratch: String) async throws -> (AppModel, BoardTask) {
        // 未読はこの端末で終わりを見たターンの印。fixtures は動いていた記録を持たないので、c-pr41（#131）の印を先に置く
        AppDefaults.useScratch(scratch, seed: [AppPreferences.unreadConversationsKey: ["fixture-studio\nc-pr41"]])
        let model = AppModel(options: LaunchOptions(scenario: "sessions-basic"))
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if let task = model.fleet.allMachines.values.flatMap(\.tasks.values).first(where: model.hasUnread) { return (model, task) }
            try #require(ContinuousClock.now < deadline, "未読の会話のあるタスクが無い")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    @Test("未読の会話のあるタスクは未読の札。［既読にする］で消える")
    func markReadFromRow() async throws {
        let (model, task) = try await unreadTask(scratch: "test-row-unread-menu")
        #expect(model.rowStatus(of: task, waiting: []) == .unread)
        model.markRead(task)
        #expect(!model.hasUnread(task))
        #expect(model.rowStatus(of: task, waiting: []) != .unread)
    }

    @MainActor
    @Test("タスクを開くと未読が消える")
    func openingClears() async throws {
        let (model, task) = try await unreadTask(scratch: "test-row-unread-open")
        model.navigate(to: .task(task.id, revealBoard: false), from: .debug)
        #expect(!model.hasUnread(task))
    }
}
