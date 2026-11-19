import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 起票・起動・定期起動の画面（docs/ui-system.md「確かめ方」）。fixtures `stress` の定期起動（長い名前、スキップ、起動失敗、起動中、未起動、
/// カスタムの引数、58 分の cron、日曜を含む毎週）と作業ディレクトリの候補を、外観を変えて描く。シートは Mac の幅（560）で描く
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct LaunchSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    static func loadedModel(_ scenario: String = "stress") async throws -> AppModel {
        AppDefaults.useScratch("snapshot-launch")
        let model = AppModel(options: LaunchOptions(scenario: scenario))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty {
            try #require(ContinuousClock.now < deadline, "fixtures \(scenario) を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(50))
        }
        return model
    }

    static func machine(_ model: AppModel) -> MachineID { model.fleet.allBoards[0].machine }

    @Test("タスク画面の右の欄の定期起動（このタスクに結んだもの・行を閉じた状態）", arguments: Matrix.cases([420]))
    func taskSchedules(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let task = try #require(model.fleet.task(for: TaskKey(machine: Self.machine(model), number: 200)))
        let view = TaskScheduleList(task: task).padding(Space.card).frame(maxHeight: .infinity, alignment: .top).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 400), variant: appearance), named: name)
    }

    @Test("タスクなしの画面の定期起動（タスクに結んでいないもの・行を閉じた状態）", arguments: Matrix.cases([640]))
    func unassignedSchedules(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let schedules = model.unassigned(on: Self.machine(model)).schedules
        try #require(schedules.map(\.scheduleID) == [2, 4, 5, 6])
        let view = VStack(spacing: Space.block) { ScheduleRows(schedules: schedules, expanded: .constant([])) }
            .padding(Space.card).frame(maxHeight: .infinity, alignment: .top).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test("定期起動の行を開いた状態（スキップ・起動失敗とカスタムの引数・起動中）", arguments: Matrix.cases([420, 760]))
    func scheduleRowsExpanded(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let schedules = model.fleet.machineState(for: Self.machine(model))!.schedules.values.filter { [3, 4, 5].contains($0.scheduleID) }.sorted { $0.scheduleID < $1.scheduleID }
        try #require(schedules.count == 3)
        let view = VStack(spacing: Space.block) {
            ForEach(schedules) { schedule in
                ScheduleRowView(schedule: schedule, expanded: true, canEdit: true, toggle: {}, edit: {})
            }
        }
        .padding(Space.card)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(model)
        .pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1300), variant: appearance), named: name)
    }

    @Test("起票のシート（既定のまま。期日・リンク・備考と起動プロンプトは畳む）", arguments: Matrix.cases([560]))
    func newTaskSheet(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let draft = NewTaskDraft(board: model.fleet.allBoards[0])
        let view = NewTaskSheet(draft: draft).environment(model).environment(\.today, BoardSnapshotTests.today).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test("起票のシート（期日・リンク・備考を書いた下書き）", arguments: Matrix.cases([560]))
    func newTaskSheetWithDetails(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        var draft = NewTaskDraft(board: model.fleet.allBoards[0])
        draft.title = "実機の iPhone で QR コードを読んで接続できることを確かめる"
        draft.links = NewTaskDraft.normalizedLinks(["https://github.com/ukwhatn/taskboard/pull/41\nhttps://example.atlassian.net/browse/PROJ-1297"])
        draft.note = "Studio と Mac mini の両方で確かめる。"
        // 今日・明日でない日は「日付を指定」と日付の欄で出る
        draft.due = Calendar.current.date(byAdding: .day, value: 5, to: BoardSnapshotTests.today)
        let view = NewTaskSheet(draft: draft).environment(model).environment(\.today, BoardSnapshotTests.today).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1100), variant: appearance), named: name)
    }

    @Test("起動のシート", arguments: Matrix.cases([520]))
    func launchSheet(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let task = try #require(model.fleet.task(for: TaskKey(machine: Self.machine(model), number: 200)))
        let view = LaunchSheet(task: task, draft: model.launchDraft(for: task)).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 640), variant: appearance), named: name)
    }

    @Test("会話の名前の変更のシート", arguments: Matrix.cases([440]))
    func conversationRenameSheet(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel("conversations")
        // 名前を付けてある会話（欄に今の名前が入る）
        let conversation = try #require(model.fleet.allMachines.values.flatMap(\.conversations.values).first { $0.id == "c-tools" })
        let view = SessionRenameSheet(target: conversation.key).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 300), variant: appearance), named: name)
    }

    @Test("定期起動のシート（追加・毎週・カスタムの引数・間隔・cron式）", arguments: ["new", "weekly", "custom", "interval"].flatMap { kind in
        Matrix.appearances.map { "\(kind)-\($0.name)" }
    })
    func scheduleForm(name: String) async throws {
        let parts = name.split(separator: "-")
        let appearance = try #require(Matrix.appearances.first { $0.name == parts[1] })
        let model = try await Self.loadedModel()
        let byID = Dictionary(uniqueKeysWithValues: model.fleet.machineState(for: Self.machine(model))!.schedules.values.map { ($0.scheduleID, $0) })
        var draft: ScheduleDraft
        switch parts[0] {
        case "weekly": draft = ScheduleDraft(try #require(byID[3]))
        case "custom": draft = ScheduleDraft(try #require(byID[4]))
        case "interval": draft = ScheduleDraft(try #require(byID[5]))
        default: draft = ScheduleDraft(machine: Self.machine(model))
        }
        let view = ScheduleForm(draft: draft).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 1100), variant: appearance), named: name)
    }
}
