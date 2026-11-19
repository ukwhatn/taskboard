import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 失敗と確認の出し先（窓ごと）。fixtures `sidebar-groups` は表示用のデータなので、書き込む操作は始めたところで失敗する
@MainActor
@Suite struct WindowScopeTests {
    private let machine = MachineID(rawValue: "fixture-studio")

    private func model() async throws -> AppModel {
        AppDefaults.useScratch("test-window-scope")
        let model = AppModel(options: LaunchOptions(scenario: "sidebar-groups"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.task(for: TaskKey(machine: machine, number: 201)) == nil {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    @Test("失敗は操作を始めた窓に出し、ほかの窓には出さない。後から届く失敗も始めた窓に出す")
    func failureStaysInItsWindow() async throws {
        let model = try await model()
        let main = WindowID(), task = WindowID()
        let target = try #require(model.fleet.task(for: TaskKey(machine: machine, number: 201)))
        model.activate(task)
        model.deleteTask(target)
        #expect(model.failure(in: task)?.text == "変更できませんでした。この接続先は表示用のデータです。")
        #expect(model.failure(in: main) == nil)

        let started = model.beginAction()
        model.activate(main)
        model.fail("タスクを移動できませんでした", URLError(.timedOut), in: started)
        #expect(model.failure(in: task)?.event == "タスクを移動できませんでした")
        #expect(model.failure(in: main) == nil)
    }

    @Test("確認は出した窓のもので、窓を閉じたら捨てる。前に出ている窓は、その前の窓に戻る")
    func confirmationBelongsToItsWindow() async throws {
        let model = try await model()
        let main = WindowID(), task = WindowID()
        let key = TaskKey(machine: machine, number: 202)
        model.activate(main)
        model.activate(task)
        model.ask(.endTaskSessions(key))
        #expect(model.confirmation(in: task) == .endTaskSessions(key))
        #expect(model.confirmation(in: main) == nil)
        model.closeWindow(task)
        #expect(model.confirmation(in: task) == nil)
        #expect(model.activeWindow == main)
    }

    @Test("出す前と実行する前に対象を照らす。無い対象には出さず、出した後に消えたら閉じて実行しない")
    func confirmationChecksTheTarget() async throws {
        let model = try await model()
        let window = WindowID()
        model.activate(window)
        model.ask(.endTaskSessions(TaskKey(machine: machine, number: 999)))
        #expect(model.confirmation(in: window) == nil)

        model.ask(.endTaskSessions(TaskKey(machine: machine, number: 202)))
        #expect(model.confirmation(in: window) != nil)
        // 1 台だけ表示で隠すと、隠したマシンのタスクは引けなくなる
        model.fleet.onlyMachine = "elsewhere"
        #expect(model.confirmation(in: window) == nil)
        model.confirm(in: window)
        #expect(model.failure(in: window) == nil)
    }
}
