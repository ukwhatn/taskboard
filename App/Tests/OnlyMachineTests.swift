import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

@MainActor
@Suite struct OnlyMachineTests {
    /// 同じ fixtures を 2 つの接続として足し、届くまで待つ
    private func twoMachines() async throws -> Fleet {
        let fleet = Fleet()
        fleet.add(id: "local", source: try FixtureSource.named("sessions-basic"))
        fleet.add(id: "conn:other", source: try FixtureSource.named("sessions-basic"))
        for _ in 0..<100 where fleet.allMachines.values.contains(where: { $0.machine == nil }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        return fleet
    }

    @Test func showsOnlyTheChosenMachine() async throws {
        let fleet = try await twoMachines()
        let all = fleet.inbox.items.count
        fleet.onlyMachine = "local"
        #expect(Array(fleet.machines.keys) == ["local"])
        #expect(fleet.allMachines.count == 2)
        // 同じ PR の「自分の番」は URL で 1 つにまとまるので、2 台分の半分にはならない。残したマシンの受信箱と同じになる
        #expect(fleet.inbox.items.count == fleet.allMachines["local"]?.inboxItems().count)
        #expect(fleet.inboxIncludingHidden.count == all)
    }

    @Test func missingMachineShowsNothing() async throws {
        let fleet = try await twoMachines()
        fleet.onlyMachine = "conn:removed"
        #expect(fleet.machines.isEmpty)
        #expect(fleet.allBoards.isEmpty)
    }

    @Test func releasingShowsEverythingAgain() async throws {
        let fleet = try await twoMachines()
        fleet.onlyMachine = "local"
        fleet.onlyMachine = nil
        #expect(fleet.machines.count == 2)
    }

    @Test("画面に出すかの決まりは 1 つ（machines と通知の登録が同じ isVisible）")
    func visibility() async throws {
        let fleet = try await twoMachines()
        fleet.hiddenMachines = ["conn:other"]
        #expect(fleet.isVisible(fleetID: "local") && !fleet.isVisible(fleetID: "conn:other"))
        #expect(Set(fleet.machines.keys) == ["local"])
        fleet.onlyMachine = "conn:other"
        #expect(!fleet.isVisible(fleetID: "local") && fleet.isVisible(fleetID: "conn:other"))
    }

    /// fixtures の扱い（1 台だけ表示を当てない）を外したモデルに、別のマシンの fixtures を 2 つ足す。daemon には繋がない
    private func modelWithTwoMachines() async throws -> AppModel {
        AppDefaults.useScratch("test-only-machine")
        let token = FileManager.default.temporaryDirectory.appending(path: "taskboard-test-token-\(UUID().uuidString)")
        try "x".write(to: token, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: token) }
        let model = AppModel(options: LaunchOptions(daemonURL: URL(string: "http://127.0.0.1:9")!, tokenFile: token.path, localOnly: true))
        model.fleet.add(id: "local", source: try FixtureSource.named("sidebar-groups"))
        model.fleet.add(id: "conn:second", source: try FixtureSource.named("machine-second"))
        for _ in 0..<250 where model.fleet.allMachines["local"]?.machine == nil || model.fleet.allMachines["conn:second"]?.machine == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    @Test("書き込めるかの理由: 表示用のデータ、隠したマシン、届いていないマシン")
    func writeAccess() async throws {
        let model = try await modelWithTwoMachines()
        let studio = MachineID(rawValue: "fixture-studio")
        #expect(model.fleet.writeAccess(studio) == .readOnly)
        #expect(!model.canWrite(studio))
        #expect(model.writeBlock(studio, "送信できません")?.text == "送信できません。この接続先は表示用のデータです。")
        model.hiddenMachines = ["local"]
        #expect(model.fleet.writeAccess(studio) == .hidden)
        #expect(model.writeBlock(studio, "送信できません")?.text == "送信できません。1台だけ表示で隠しているMacです。")
        let nowhere = MachineID(rawValue: "nowhere")
        #expect(model.fleet.writeAccess(nowhere) == .unknown)
        // 原因が分からなければ事象と対処だけ
        #expect(model.writeBlock(nowhere, "送信できません")?.text == "送信できません。ネットワークと、接続先のMacが起動しているかを確認してください。")
        #expect(UserFacingError("変更できませんでした", error: AppModel.ActionError.notWritable(.readOnly))?.text == "変更できませんでした。この接続先は表示用のデータです。")
        model.hiddenMachines = []
    }

    @Test("1 台だけ表示で隠したマシンの選択・iPhone に積んだ画面・パネルで選ぶものを外す。残すマシンのものは残す")
    func hidingDropsSelections() async throws {
        let model = try await modelWithTwoMachines()
        let studio = MachineID(rawValue: "fixture-studio")
        let conversation = ConversationKey(machine: studio, id: "c-yesterday")
        model.phoneTaskItem = conversation
        model.sessionFocus = SessionFocus(scope: .task(TaskKey(machine: studio, number: 202)), item: conversation)
        model.sidebar = .unassigned(machine: studio)
        model.chosenOnlyMachineID = "conn:second"
        model.onlyMachineEnabled = true
        #expect(model.phoneTaskItem == nil)
        #expect(model.sessionFocus == nil)
        #expect(model.sidebar == .overview)
        model.onlyMachineEnabled = false
    }
}
