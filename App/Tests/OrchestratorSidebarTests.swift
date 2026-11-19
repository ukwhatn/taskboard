import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// サイドバーのマシンの行のオーケストレーターの印（マシンごと）と、オーケストレーターの会話をタスクなしに入れないこと。
/// fixtures: `stress`（Mac Studio。オーケストレーターは居ない）に、Mac mini の 3 つの状態を足す。`machine-second`（動いている）、
/// `machine-second-resident`（常駐がオンで起動していない）、`machine-second-off`（常駐オフで起動していない）
@MainActor
@Suite struct OrchestratorSidebarTests {
    private let studio = MachineID(rawValue: "fixture-studio")
    private let secondMac = MachineID(rawValue: "fixture-second")

    private func model(_ scenario: String) async throws -> AppModel {
        AppDefaults.useScratch("test-orchestrator-sidebar")
        let model = AppModel(options: LaunchOptions(scenario: scenario))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.orchestratorRows.count < 2 {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func row(_ machine: MachineID, in model: AppModel) throws -> OrchestratorRow {
        try #require(model.orchestratorRows.first { $0.machine == machine })
    }

    @Test("動いているマシンの行はその会話の状態で、止められない（常駐がオン）。居ないマシンは未起動で、起動できる。題が同じなので 1 台ずつマシンの名前を出す")
    func running() async throws {
        let model = try await model("stress+machine-second")
        let running = try row(secondMac, in: model)
        #expect(running.conversation?.id == "c-orch-second")
        #expect(running.statusLabel == "待機")
        #expect(running.badge == "Mac mini")
        #expect(!running.canStart && !running.canStop)
        let missing = try row(studio, in: model)
        #expect(missing.conversation == nil)
        #expect(missing.statusLabel == "未起動")
        #expect(missing.badge == "Mac Studio")
        #expect(missing.canStart)
    }

    @Test("常駐がオンで起きていないマシンは未起動で、「常駐オフ」は出さない")
    func residentNotRunning() async throws {
        let model = try await model("stress+machine-second-resident")
        let row = try row(secondMac, in: model)
        #expect(row.conversation == nil && row.statusLabel == "未起動" && row.badge == "Mac mini" && row.canStart)
    }

    @Test("常駐オフで起きていないマシンは、未起動・常駐オフ")
    func residentOff() async throws {
        let model = try await model("stress+machine-second-off")
        let row = try row(secondMac, in: model)
        #expect(row.conversation == nil)
        #expect(row.statusLabel == "常駐オフ・未起動")
        #expect(row.badge == "Mac mini・常駐オフ")
        #expect(row.canStart && !row.canStop)
        #expect(model.fleet.orchestratorConversation(on: secondMac) == nil)
    }

    @Test("タスクなしに、オーケストレーターの会話を入れない")
    func unassignedExcludesOrchestrator() async throws {
        let model = try await model("stress+machine-second")
        #expect(model.sessionSet(for: .unassigned(secondMac)).conversations.isEmpty)
        #expect(model.sessionSet(for: .orchestrator(secondMac)).conversations.map(\.id) == ["c-orch-second"])
    }

    @Test("選択先の id はマシンごと（`orchestrator/<machine>`）")
    func sidebarItemID() {
        #expect(SidebarItem.orchestrator(machine: secondMac).id == "orchestrator/fixture-second")
        #expect(SidebarItem.orchestrator(machine: secondMac) != SidebarItem.orchestrator(machine: studio))
    }

    @Test("行を押したとき: 動いていても止まっていても、そのマシンのオーケストレーターの画面を開き、iPhone は「タスク」タブに積む")
    func openingShowsScreen() async throws {
        let model = try await model("stress+machine-second")
        for machine in [secondMac, studio] {
            model.phoneTab = .settings
            model.navigate(to: .orchestrator(machine), from: .debug)
            #expect(model.sidebar == .orchestrator(machine: machine))
            #expect(model.phoneTab == .tasks)
            #expect(model.phoneTaskPath == [.orchestrator(machine: machine)])
            #expect(model.orchestratorSheet == nil)
        }
    }

    @Test("動いているオーケストレーターの会話を開くと（通知・指示のシート）、オーケストレーターの画面")
    func conversationOpensScreen() async throws {
        let model = try await model("stress+machine-second")
        let key = ConversationKey(machine: secondMac, id: "c-orch-second")
        #expect(model.conversationScope(for: key) == .orchestrator(secondMac))
        model.navigate(to: .conversation(key), from: .debug)
        #expect(model.sidebar == .orchestrator(machine: secondMac))
        #expect(model.selectedTask == nil)
    }

    @Test("`taskboard://orchestrator/<machine>` はそのマシン、マシンが無ければ指示の送り先のマシンの画面")
    func urlOpensScreen() async throws {
        let model = try await model("stress+machine-second")
        model.open(URL(string: "taskboard://orchestrator/fixture-second")!, from: .debug)
        #expect(model.sidebar == .orchestrator(machine: secondMac))
        model.sidebar = .overview
        model.selectOrchestratorTarget(studio)
        model.open(URL(string: "taskboard://orchestrator")!, from: .debug)
        #expect(model.sidebar == .orchestrator(machine: studio))
        // 画面を開いている間の ⌘K の指示の送り先は、選んだ送り先が無ければその画面のマシン
        model.orchestratorTarget = nil
        model.sidebar = .orchestrator(machine: secondMac)
        #expect(model.orchestratorMachine == secondMac)
    }

    @Test("居ないときの状態の文: 常駐がオンなら未起動、オフなら常駐オフ・未起動。起こせなかったときだけ帯の文がある")
    func stoppedStatus() {
        func row(resident: Bool = true, failed: Bool = false) -> OrchestratorRow {
            OrchestratorRow(machine: studio, machineName: "Mac Studio", conversation: nil, resident: resident, launchFailed: failed)
        }
        #expect(row().statusLabel == "未起動")
        #expect(row(resident: false).statusLabel == "常駐オフ・未起動")
        #expect(row().launchFailure == nil)
        #expect(row(failed: true).launchFailure == "常駐のオーケストレーターを起動できませんでした。［起動］を押してください。")
    }

    @Test("1 台分は、接続しているマシンの一覧の行と同じもの")
    func singleRowMatchesList() async throws {
        let model = try await model("stress+machine-second-off")
        #expect(model.orchestratorRow(on: secondMac) == (try row(secondMac, in: model)))
        #expect(model.orchestratorRow(on: studio) == (try row(studio, in: model)))
        #expect(model.orchestratorRow(on: MachineID(rawValue: "none")) == nil)
    }
}
