import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// タスクなしの画面とサイドバーの木の崩れの確認。多数（3 台）・長い題・長いマシン名・取得の失敗を、幅と外観を変えて描く。
/// サイドバーは `List` なのでウィンドウの外で描かれない。木の中身を並べ直して描き、本物の行は実ウィンドウの撮影（scripts/ui/capture.sh）で見る
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ListSnapshotTests {
    static let many = "stress+lists-second+lists-long"

    static func model(_ scenario: String) -> AppModel {
        // 未読はこの端末で終わりを見たターンの印。fixtures は動いていた記録を持たないので、c-pr41（#131）の印を先に置く
        AppDefaults.useScratch("snapshot", seed: [AppPreferences.unreadConversationsKey: ["fixture-studio\nc-pr41"]])
        return AppModel(options: LaunchOptions(scenario: scenario))
    }

    static func loaded(_ model: AppModel, machines: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.machines.values.filter({ $0.machine != nil }).count < machines {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// アカウントが 2 つ（どちらも Mac mini と MacBook Air の 2 台が取っている。review-bot は Mac mini で取得に失敗している）
    static let accounts = "lists-second+prs-second"
    nonisolated static let screenCases = LayoutMatrixSnapshotTests.cases([760, 1280])

    /// Mac mini を書き込める接続先にした形（タスクなしの画面の［ほかの操作］と［タスクを追加…］［タスクに紐づける…］が出る）
    static func writableModel() async throws -> AppModel {
        let model = Self.model(Self.many)
        model.fleet.add(id: "fixture:lists-second", source: ConversationRecorder(base: try FixtureSource.named("lists-second")))
        try await Self.loaded(model, machines: 3)
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.canWrite(Self.secondMac) {
            try #require(ContinuousClock.now < deadline, "Mac mini を書き込める接続先にできない")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    static let secondMac = MachineID(rawValue: "fixture-second")

    static func unassignedScreen(_ model: AppModel, machine: MachineID = secondMac) -> some View {
        NavigationStack { UnassignedScreen(machine: machine) }.environment(model).pageInsets()
    }

    @Test("タスクなしの画面（Mac Studio の fixtures conversations を書き込める接続先にした形: 会話の節と、行の右の［ほかの操作］。PR は並べない）", arguments: screenCases)
    func unassigned(name: String) async throws {
        let (width, appearance) = try LayoutMatrixSnapshotTests.parse(name)
        let studio = MachineID(rawValue: "fixture-studio")
        AppDefaults.useScratch("snapshot")
        let model = AppModel(options: LaunchOptions(scenario: "conversations"))
        model.fleet.add(id: "fixture:conversations", source: ConversationRecorder(base: try FixtureSource.named("conversations")))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.unassigned(on: studio).sessions.rows.isEmpty || !model.canWrite(studio) {
            try #require(ContinuousClock.now < deadline, "fixtures conversations を書き込める接続先にできない")
            try await Task.sleep(for: .milliseconds(20))
        }
        assertImageSnapshot(
            of: BoardSnapshotTests.host(Self.unassignedScreen(model, machine: studio), size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test("タスクなしの画面で PR を開いた形（上の帯に［一覧に戻る］と［タスクを追加…］［タスクに紐づける…］、下に PR の詳細）", arguments: LayoutMatrixSnapshotTests.cases([1280]))
    func unassignedPRSelected(name: String) async throws {
        let (width, appearance) = try LayoutMatrixSnapshotTests.parse(name)
        let model = try await Self.writableModel()
        model.selectedPR = "https://github.com/example-org/api/pull/310"
        assertImageSnapshot(
            of: BoardSnapshotTests.host(Self.unassignedScreen(model), size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test("タスクなしの画面で何も無いとき（空状態）", arguments: LayoutMatrixSnapshotTests.cases([760]))
    func unassignedEmpty(name: String) async throws {
        let (width, appearance) = try LayoutMatrixSnapshotTests.parse(name)
        let model = Self.model(Self.many)
        try await Self.loaded(model, machines: 3)
        let view = Self.unassignedScreen(model, machine: MachineID(rawValue: "fixture-missing"))
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 500), variant: appearance), named: name)
    }

    @Test("サイドバーの木（3 台、長いマシン名、案件 → 列 → タスクの札、タスクなし）", arguments: LayoutMatrixSnapshotTests.cases([320]))
    func sidebarTree(name: String) async throws {
        let (width, appearance) = try LayoutMatrixSnapshotTests.parse(name)
        let model = Self.model(Self.many)
        try await Self.loaded(model, machines: 3)
        // List はウィンドウの外で描かれないので、木の行を ScrollView に並べて描く
        let view = ScrollView { VStack(alignment: .leading, spacing: Space.inline) { SidebarTreeSnapshot() } .padding(Space.block) }
            .environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1100), variant: appearance), named: name)
    }
}

/// サイドバーの木の中身を、List を使わずに並べたもの（snapshot 用。行の組み立ては `AppModel` の札と進みをそのまま使う）
private struct SidebarTreeSnapshot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.waitingItemsByTask
        ForEach(model.orderedMachines, id: \.id) { machine in
            Text(model.machineName(fleetID: machine.id, state: machine.state)).fontWeight(.semibold)
            ForEach(model.orderedBoards(machine.state, fleetID: machine.id)) { board in
                Label(board.name, systemImage: "rectangle.grid.2x2").padding(.leading, 12)
                ForEach(board.orderedColumns.filter { !model.sidebarTasks(in: board, column: $0, state: machine.state, waiting: waiting, active: model.sidebarActiveTasks(machine.state)).isEmpty }) { column in
                    Text(column.label).foregroundStyle(.secondary).padding(.leading, 24)
                    if model.isSidebarNodeExpanded("column/\(board.machine.rawValue)/\(board.id)/\(column.id)", collapsedByDefault: column.collapsed) {
                        ForEach(model.sidebarTasks(in: board, column: column, state: machine.state, waiting: waiting, active: model.sidebarActiveTasks(machine.state))) { task in
                            let status = model.rowStatus(of: task, waiting: waiting[task.id] ?? [])
                            let badge = [status?.label, model.delegateProgress(of: task)?.label].compactMap { $0 }.joined(separator: " ")
                            HStack {
                                Text(verbatim: "#\(task.number) \(task.title)").lineLimit(1)
                                Spacer()
                                Text(verbatim: badge).foregroundStyle(status?.isMine == true ? Color.orange : .secondary)
                            }
                            .padding(.leading, 36)
                        }
                    }
                }
            }
            if let id = machine.state.machine?.id, !model.unassigned(on: id).isEmpty {
                Label("タスクなし", systemImage: "tray").padding(.leading, 12)
            }
        }
    }
}
