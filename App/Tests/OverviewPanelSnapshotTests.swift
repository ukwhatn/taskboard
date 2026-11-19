import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 会話が置く部品の描き手。fixtures の部品の一覧（`panel-catalog.json`）を、種類ごとに分けて #214（`overview-panels`）の値で描く（自由の部品の HTML は WKWebView で、snapshot には写らない）
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct OverviewPanelSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    private func render(_ ids: [String], name: String, height: CGFloat, testName: String = #function) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await LaunchSnapshotTests.loadedModel("overview-panels")
        let key = TaskKey(machine: LaunchSnapshotTests.machine(model), number: 214)
        let task = try #require(model.fleet.task(for: key), "fixtures の #214 が無い")
        let url = try #require(Bundle.main.url(forResource: "panel-catalog", withExtension: "json", subdirectory: "Fixtures"), "fixtures の部品の一覧が無い")
        let catalog = try WireJSON.decoder().decode([PanelPart].self, from: Data(contentsOf: url))
        let parts = ids.compactMap { id in catalog.first { $0.id == id } }
        let panel = OverviewPanel(machine: key.machine, taskNumber: key.number, parts: parts, turn: 5, updatedAt: .distantPast)
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

    private static func placesModel() async throws -> (AppModel, TaskKey) {
        AppDefaults.useScratch("snapshot-places")
        let model = AppModel(options: LaunchOptions(scenario: "overview-panels"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty || model.fleet.allMachines.values.allSatisfy({ $0.panels.isEmpty }) {
            try #require(ContinuousClock.now < deadline, "fixtures overview-panels を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(50))
        }
        return (model, TaskKey(machine: LaunchSnapshotTests.machine(model), number: 214))
    }

    /// 帯に計器 4 個、会話の頭に判断事項の表、入力欄の上に承認を待つ送る文面、右の欄に子のタスクの表（差分と並べて開く）
    @Test("4 か所に置いた部品（右の欄の部品を開く）", arguments: Matrix.cases([1180, 1440, 1728]))
    func places(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, task) = try await Self.placesModel()
        AppDefaults.store.set(SidePanelSet(open: [.changes, .part]).json, forKey: AppPreferences.taskSidePanelsKey)
        model.navigate(to: .conversation(ConversationKey(machine: task.machine, id: "d-checkout")), from: .debug)
        let view = TaskPanel(key: task).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    /// 既定の右の欄（差分だけ。部品の欄は帯のボタンだけ）と、折りたたんだ会話の頭
    @Test("既定の右の欄と、折りたたんだ会話の頭", arguments: Matrix.cases([1440]))
    func placesDefault(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, task) = try await Self.placesModel()
        AppDefaults.store.set(true, forKey: AppPreferences.taskPanelHeadCollapsedKey)
        model.navigate(to: .conversation(ConversationKey(machine: task.machine, id: "d-checkout")), from: .debug)
        let view = TaskPanel(key: task).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }
}
