import Foundation
import TaskboardKit

/// 全体のボードに出すマシンと案件。サイドバーで案件を選ぶとその案件だけ、「すべての案件」なら全部
extension AppModel {
    struct OverviewSection {
        var id: String
        var state: MachineState
        var boards: [Board]
        /// マシンを畳んでいる（案件を選んでいるときは畳まずに出す）
        var collapsed: Bool
    }

    /// サイドバーで選んだ案件。選んだ案件が無くなっていれば nil（全部の案件を出す）
    var focusedBoard: Board? {
        guard case .board(let machine, let id) = sidebar else { return nil }
        return fleet.board(id: id, on: machine)
    }

    var overviewSections: [OverviewSection] {
        if let board = focusedBoard,
            let machine = orderedMachines.first(where: { $0.state.machine?.id == board.machine })
        {
            return [OverviewSection(id: machine.id, state: machine.state, boards: [board], collapsed: false)]
        }
        return orderedMachines.map { machine in
            OverviewSection(
                id: machine.id, state: machine.state, boards: orderedBoards(machine.state, fleetID: machine.id),
                collapsed: collapsedMachines.contains(machine.id))
        }
    }
}
