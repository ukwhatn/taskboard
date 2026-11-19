import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 会話が登録した概況の部品。fixtures `overview-panels` の #214 の部品を、種類ごとに分けて描く（自由の部品の HTML は WKWebView で、snapshot には写らない）
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct OverviewPanelSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    private func render(_ ids: [String], name: String, height: CGFloat, testName: String = #function) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await LaunchSnapshotTests.loadedModel("overview-panels")
        let key = TaskKey(machine: LaunchSnapshotTests.machine(model), number: 214)
        let task = try #require(model.fleet.task(for: key), "fixtures の #214 が無い")
        var panel = try #require(model.fleet.machineState(for: key.machine)?.panels[key], "fixtures の #214 に概況が無い")
        panel.parts = ids.compactMap { id in panel.parts.first { $0.id == id } }
        try #require(panel.parts.count == ids.count, "fixtures の部品の id が変わった")
        let view = VStack(alignment: .leading, spacing: Space.section) { OverviewPanelParts(task: task, panel: panel) }
            .padding(Space.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(model).environment(\.taskScope, task.id).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: height), variant: appearance), named: name, testName: testName)
    }

    @Test("計器（値と基準・紐づけ・古い部品の時刻）、主表、計画（今のまとまりだけを開く）", arguments: Matrix.cases([420, 760]))
    func gaugesTablePlan(name: String) async throws {
        try await render(["merchant", "m2", "mismatch", "launch", "questions", "decisions", "plan"], name: name, height: 1100)
    }

    @Test("図（流れ・時系列・比較・関係）", arguments: Matrix.cases([420, 760]))
    func diagrams(name: String) async throws {
        try await render(["stages", "schedule", "inputs", "services"], name: name, height: 900)
    }

    @Test("グラフ（折れ線と基準の線、2 系列の棒と凡例）と、承認を待つ送る文面", arguments: Matrix.cases([420, 760]))
    func chartsAndDraft(name: String) async throws {
        try await render(["match", "latency", "notice"], name: name, height: 980)
    }

    @Test("紐づけた表（リンクした PR と issue、子のタスク）", arguments: Matrix.cases([420, 760]))
    func boundTables(name: String) async throws {
        try await render(["links", "children"], name: name, height: 640)
    }
}
