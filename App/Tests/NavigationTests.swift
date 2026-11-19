import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 行き先（`AppModel.navigate(to:)`）。fixtures `sidebar-groups`: #201 に lead の w1:p1、#202 に応答待ちの w1:p2 と会話 c-today、
/// タスクに結ばれていない会話 c-yesterday（タスクなしの画面）
@MainActor
@Suite struct NavigationTests {
    private let machine = MachineID(rawValue: "fixture-studio")

    private func model() async throws -> AppModel {
        AppDefaults.useScratch("test-navigation")
        let model = AppModel(options: LaunchOptions(scenario: "sidebar-groups"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.task(for: task(202)) == nil || model.fleet.conversation(for: conversation("c-today")) == nil {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func task(_ number: Int) -> TaskKey { TaskKey(machine: machine, number: number) }
    private func conversation(_ id: String) -> ConversationKey { ConversationKey(machine: machine, id: id) }

    private func scheduleRunItem(task: Int?, conversation: String? = nil) -> InboxItem {
        let t0 = Date(timeIntervalSince1970: 0)
        let schedule = Schedule(
            scheduleID: 9, machine: machine, name: "朝", enabled: true, rule: .interval(minutes: 60), cwd: "/tmp", kind: .claude, agentArgs: [],
            prompt: "", taskNumber: task, overlap: .skip, createdAt: t0, updatedAt: t0)
        let run = ScheduleRun(
            id: 1, scheduleID: 9, scheduledAt: t0, trigger: .schedule, conversationID: conversation, createdAt: t0)
        return InboxItem(id: "run/1", kind: .scheduleRun(schedule, run), group: .notice, machine: machine, taskNumber: task, title: "朝", details: [], at: t0)
    }

    @Test("定期起動の実行の通知を押すと、今ある会話を先に開く（会話のタスクの画面で札を選ぶ）")
    func scheduleRunOpensConversation() async throws {
        let model = try await model()
        model.open(inbox: scheduleRunItem(task: 202, conversation: "c-today"), from: .debug)
        #expect(model.selectedTask == task(202))
        #expect(model.sessionFocus == SessionFocus(scope: .task(task(202)), item: conversation("c-today")))
    }

    @Test("定期起動の実行の会話が無くなっていればタスクを開く。タスクも無ければタスクなしの画面で、開いていたタスクは閉じる")
    func scheduleRunFallbacks() async throws {
        let model = try await model()
        model.open(inbox: scheduleRunItem(task: 202, conversation: "gone"), from: .debug)
        #expect(model.selectedTask == task(202))
        model.open(inbox: scheduleRunItem(task: nil), from: .debug)
        #expect(model.sidebar == .unassigned(machine: machine))
        #expect(model.selectedTask == nil)
    }

    @Test("開くたびに nav.open を 1 行残す。行き先が中で別の画面に替わっても（PR・会話）、記録は押した経路と元の行き先の 1 行")
    func navigationLog() async throws {
        let model = try await model()
        let before = model.eventLog.recent.count
        model.open(inbox: scheduleRunItem(task: 202, conversation: "c-today"), from: .notification)
        model.navigate(to: .pullRequest(url: "https://github.com/o/r/pull/1"), from: .link)
        model.open(URL(string: "taskboard://orchestrator/fixture-studio")!, from: .url)
        let opened = model.eventLog.recent.dropFirst(before).filter { $0.type == "nav.open" }
        #expect(opened.map(\.mode) == ["notification", "link", "url"])
        #expect(opened.map(\.stage) == ["conversation", "pull_request", "orchestrator"])
        #expect(opened.map(\.machine) == ["fixture-studio", nil, "fixture-studio"])
    }

    @Test("どのタスクにも結ばれていない PR は、URL から開いても通知から開いても、開いていたタスクを閉じてタスクなしの画面でその PR を選ぶ")
    func unlinkedPullRequest() async throws {
        let model = try await model()
        let url = "https://github.com/o/r/pull/1"
        for open in [{ model.open(TaskboardLink.pullRequest(url: url).url, from: .debug) }, { model.open(URL(string: "taskboard://prs?url=\(url)")!, from: .debug) }, { model.navigate(to: .pullRequest(url: url), from: .debug) }] {
            model.navigate(to: .task(task(201)), from: .debug)
            model.selectedPR = nil
            open()
            #expect(model.sidebar == .unassigned(machine: machine))
            #expect(model.selectedTask == nil)
            #expect(model.selectedPR == url)
        }
    }

    @Test("タスクにリンクした PR は、そのタスクを開いて右の欄の PR に出す")
    func linkedPullRequest() async throws {
        AppDefaults.useScratch("test-navigation-pr")
        let model = AppModel(options: LaunchOptions(scenario: "stress"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        let linked = try #require(model.fleet.allBoards.first.flatMap { model.fleet.machineState(for: $0.machine) }?.tasks.values.sorted { $0.number < $1.number }.first { !$0.pullRequestLinks.isEmpty })
        let url = try #require(linked.pullRequestLinks.first?.url)
        let before = model.prFocusRequest
        model.navigate(to: .pullRequest(url: url), from: .debug)
        #expect(model.selectedTask == model.tasks(linkedTo: url).first?.id)
        #expect(model.selectedPR == url)
        #expect(model.prFocusRequest == before + 1)
    }

    @Test("タスクに結ばれていない会話はタスクなしの画面で開き、その会話を札で選ぶ。タスクを開くとタスクなしの画面を離れる")
    func unassignedConversation() async throws {
        let model = try await model()
        model.navigate(to: .conversation(conversation("c-yesterday")), from: .debug)
        #expect(model.sidebar == .unassigned(machine: machine))
        #expect(model.sessionFocus == SessionFocus(scope: .unassigned(machine), item: conversation("c-yesterday")))
        #expect(model.unassigned(on: machine).sessions.conversations.map(\.id).contains("c-yesterday"))
        model.navigate(to: .task(task(201)), from: .debug)
        #expect(model.selectedTask == task(201))
    }

    @Test("パレットの行は行き先を持つ。タスクの行は別ウィンドウで開く相手を返し、案件の行を選ぶとその案件だけを出す")
    func paletteDestinations() async throws {
        let model = try await model()
        let entries = model.paletteEntries
        let taskEntry = try #require(entries.first { $0.id == "task:fixture-studio/201" })
        #expect(taskEntry.taskKey == task(201))
        model.runPalette(taskEntry)
        #expect(model.selectedTask == task(201))
        let boardEntry = try #require(entries.first { $0.kind == .board })
        model.runPalette(boardEntry)
        #expect(model.selectedTask == nil)
        guard case .board(let machine, _) = model.sidebar else {
            Issue.record("案件を選んでいない: \(model.sidebar)")
            return
        }
        #expect(machine == self.machine)
    }
}
