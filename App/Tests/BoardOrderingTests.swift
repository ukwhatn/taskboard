import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 案件の並び。サイドバーで並べ替えた順を、起票のシート・定期起動のフォーム・移動のメニュー・iPhone の一覧も使う
@MainActor
@Suite struct BoardOrderingTests {
    private let studio = MachineID(rawValue: "fixture-studio")
    private let secondMac = MachineID(rawValue: "fixture-second")

    private func model() async throws -> AppModel {
        AppDefaults.useScratch("test-board-ordering")
        let model = AppModel(options: LaunchOptions(scenario: "settings+settings-second"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.orderedMachines.count < 2 || model.orderedMachines.contains(where: { $0.state.boards.isEmpty }) {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    @Test("並べ替える前は案件の position の順。しまった案件は出さない")
    func positionOrder() async throws {
        let model = try await model()
        #expect(model.orderedBoards(on: studio).map(\.id) == ["fixture-board", "fixture-long", "fixture-empty"])
        #expect(model.orderedBoards(on: MachineID(rawValue: "none")).isEmpty)
    }

    @Test("サイドバーで並べ替えた順を、1 マシンの案件と全マシンの案件の選択肢が使う。マシンはサイドバーの順")
    func sidebarOrder() async throws {
        let model = try await model()
        let (fleetID, state) = try #require(model.orderedMachines.first { $0.state.machine?.id == studio }.map { ($0.id, $0.state) })
        model.moveBoards(state, fleetID: fleetID, from: [2], to: 0)
        #expect(model.orderedBoards(on: studio).map(\.id) == ["fixture-empty", "fixture-board", "fixture-long"])
        let machines = model.orderedMachines.compactMap { $0.state.machine?.id }
        let expected = machines.flatMap { $0 == studio ? ["fixture-empty", "fixture-board", "fixture-long"] : ["fixture-second-board"] }
        #expect(model.orderedBoardsAcrossMachines.map(\.id) == expected)
    }
}
