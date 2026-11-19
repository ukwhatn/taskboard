import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// サイドバーのタスクの行の［ピン留め］と［すべて終了］
@MainActor
@Suite struct SidebarTaskActionsTests {
    private func store() -> UserDefaults {
        let name = "tb-sidebar-task-actions-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func loaded(_ scratch: String) async throws -> AppModel {
        AppDefaults.useScratch(scratch)
        let model = AppModel(options: LaunchOptions(scenario: "sessions-basic"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.inboxItems.isEmpty {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    @Test("ピン留めは並べた順のままこの端末に保存して読み戻せる。読めない値と重なりは捨てる")
    func pinPersistence() {
        let defaults = store()
        let prefs = DevicePrefs(defaults: defaults)
        #expect(prefs.pinnedTasks.isEmpty)
        let pinned = [TaskKey(machine: MachineID(rawValue: "studio"), number: 12), TaskKey(machine: MachineID(rawValue: "laptop"), number: 3)]
        prefs.pinnedTasks = pinned
        #expect(DevicePrefs(defaults: defaults).pinnedTasks == pinned)
        prefs.pinnedTasks = pinned.reversed()
        #expect(DevicePrefs(defaults: defaults).pinnedTasks == pinned.reversed(), "名前の順に並べ直さない")
        defaults.set(["studio\n12", "壊れた値", "laptop\nx", "studio\n12"], forKey: AppPreferences.pinnedTasksKey)
        #expect(prefs.pinnedTasks == [TaskKey(machine: MachineID(rawValue: "studio"), number: 12)])
    }

    @Test("ピン留めしたタスクは、全部のマシンのものをサイドバーの先頭の組にまとめて動いていなくても出し、元の組にも残す。並べ替えられ、外すと先頭の組から消える")
    func pinnedGroup() async throws {
        let model = try await loaded("test-sidebar-pin")
        let machine = try #require(model.orderedMachines.first)
        let waiting = model.waitingItemsByTask
        let active = model.sidebarActiveTasks(machine.state)
        let shown = Set(model.sidebarTasks(on: machine.state, fleetID: machine.id, waiting: waiting, active: active).map(\.number))
        let quiet = try #require(machine.state.tasks.values.sorted { $0.number < $1.number }.first { !shown.contains($0.number) }, "木に出ていないタスクが要る")
        let busy = try #require(model.sidebarTasks(on: machine.state, fleetID: machine.id, waiting: waiting, active: active).first)
        model.setPinned(quiet, true)
        model.setPinned(busy, true)
        #expect(model.pinnedSidebarTasks().map(\.number) == [quiet.number, busy.number], "ピン留めした順")
        model.movePinned(from: [1], to: 0)
        #expect(model.pinnedSidebarTasks().map(\.number) == [busy.number, quiet.number], "ドラッグで並べ替える")
        model.movePinned(busy, by: 1)
        #expect(model.pinnedSidebarTasks().map(\.number) == [quiet.number, busy.number], "メニューの［下へ移動］")
        model.movePinned(busy, by: 1)
        #expect(model.pinnedSidebarTasks().map(\.number) == [quiet.number, busy.number], "末尾から下へは動かない")
        let rest = model.sidebarTasks(on: machine.state, fleetID: machine.id, waiting: waiting, active: active).map(\.number)
        #expect(rest.contains(busy.number), "動いているタスクは元の組にも出す")
        #expect(!rest.contains(quiet.number), "元の組に出す条件は変えない")
        let columns = model.orderedBoards(machine.state, fleetID: machine.id).flatMap { board in
            board.orderedColumns.flatMap { model.sidebarTasks(in: board, column: $0, state: machine.state, waiting: waiting, active: active) }
        }
        #expect(columns.map(\.number).contains(busy.number))
        model.setPinned(busy, false)
        model.setPinned(quiet, false)
        #expect(model.pinnedSidebarTasks().isEmpty)
    }

    @Test("すべて終了の対象は札に並ぶ会話（オーケストレーターを除く）。作業の途中のものがあれば名前を出して確かめ、無ければ確かめない")
    func endAll() async throws {
        let model = try await loaded("test-sidebar-end-all")
        let tasks = model.fleet.allMachines.values.flatMap(\.tasks.values).sorted { $0.number < $1.number }
        for task in tasks {
            let targets = model.endTargets(of: task)
            let rows = model.taskSessions(for: task).rows
            #expect(targets.count <= rows.count)
            #expect(targets.conversations.allSatisfy { $0.purpose != .orchestrator })
        }
        let busy = try #require(tasks.first { !model.endTargets(of: $0).busy.isEmpty }, "作業の途中のセッションのあるタスクが要る")
        model.requestEndAll(busy)
        #expect(model.confirmation(in: model.activeWindow) == .endTaskSessions(busy.id))
        let message = model.endTargets(of: busy).message(task: busy)
        #expect(message.hasPrefix("「#\(busy.number) \(busy.title)」のセッションをすべて終了しますか？\u{3000}「"))
        #expect(message.contains("は作業の途中で終了します。"))
        model.dismissConfirmation(in: model.activeWindow)
    }

    @Test("確認の本文：作業の途中のものの名前を並べる")
    func endAllMessage() {
        let task = BoardTask(machine: MachineID(rawValue: "studio"), number: 12, boardID: "b", columnID: "c", title: "検索を直す", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        var targets = TaskEndTargets()
        targets.busy = ["Claude Code", "#12 調べる"]
        #expect(targets.message(task: task) == "「#12 検索を直す」のセッションをすべて終了しますか？\u{3000}「Claude Code」、「#12 調べる」は作業の途中で終了します。")
    }
}
