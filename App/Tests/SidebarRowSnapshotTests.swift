import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing

@testable import Taskboard

/// サイドバーのタスクの行。マウスを載せたときの操作が、札の位置に出て題に重ならず、行の高さを変えないこと。
/// サイドバーの List は snapshot に描かれないので、行だけを並べて描く
@MainActor
@Suite("サイドバーの行のホバー", .serialized)
struct SidebarRowSnapshotTests {
    @Test(arguments: BoardSnapshotTests.variants.prefix(2).map(\.name))
    func hoverActions(variantName: String) async throws {
        let variant = try #require(BoardSnapshotTests.variants.first { $0.name == variantName })
        let model = BoardSnapshotTests.model()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty || (model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.tasks.isEmpty ?? true) {
            try #require(ContinuousClock.now < deadline, "fixtures sessions-basic を読み込めない")
            try await Task.sleep(for: .milliseconds(50))
        }
        let machine = model.fleet.allBoards[0].machine
        let state = try #require(model.fleet.machineState(for: machine))
        let short = try #require(state.tasks[TaskKey(machine: machine, number: 128)])
        var long = short
        long.title = "taskboard をソース公開の OSS として README と docs を整え、社内の名前を取り除く"
        let view = VStack(alignment: .leading, spacing: Space.row) {
            ForEach([short, long], id: \.title) { task in
                let status = model.rowStatus(of: task, waiting: model.waitingItems(for: task.id))
                TaskTreeRow(task: task, status: status)
                TaskTreeRow(task: task, status: status, hovering: true)
            }
        }
        .padding(BoardSnapshotTests.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 280, height: 220), variant: variant), named: variant.name)
    }
}
