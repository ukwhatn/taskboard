import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

@MainActor
@Suite struct SettingsTests {
    private static let machine = MachineID(rawValue: "m1")

    private static func column(_ id: String, _ position: Int, collapsed: Bool = false, kind: BoardColumn.Kind = .open) -> BoardColumn {
        BoardColumn(id: id, label: id, kind: kind, position: position, collapsed: collapsed)
    }

    private static func board(_ id: String, archived: Bool = false, defaults: LaunchDefaults? = nil) -> Board {
        Board(id: id, machine: machine, name: id, position: 0, columns: [column("todo", 0)], createdAt: Date(timeIntervalSince1970: 0),
              promptTemplate: "#{{id}} {{title}}", archived: archived, launchDefaults: defaults)
    }

    // MARK: - test host

    @Test("offline の model は、同じ Mac の daemon にも Keychain の接続先にも繋がない（test host の窓の model）")
    func offlineModelConnectsNowhere() {
        let model = AppModel(options: LaunchOptions(offline: true))
        #expect(model.fleet.allMachines.isEmpty)
        #expect(model.connections.isEmpty)
    }

    // MARK: - 畳んだ列の帯

    @Test func consecutiveCollapsedColumnsShareOneBand() {
        let segments = BoardColumnSegment.segments([
            Self.column("a", 0), Self.column("b", 1, collapsed: true), Self.column("c", 2, collapsed: true),
            Self.column("d", 3), Self.column("e", 4, collapsed: true),
        ])
        #expect(segments.map(\.id) == ["column:a", "folded:b", "column:d", "folded:e"])
        guard case .folded(let run) = segments[1] else { Issue.record("2 つ目が帯でない"); return }
        #expect(run.map(\.id) == ["b", "c"])
    }

    @Test func segmentsFollowPositionNotArrayOrder() {
        let segments = BoardColumnSegment.segments([Self.column("late", 2), Self.column("early", 0), Self.column("mid", 1, collapsed: true)])
        #expect(segments.map(\.id) == ["column:early", "folded:mid", "column:late"])
    }

    @Test func noColumnsMakeNoSegments() {
        #expect(BoardColumnSegment.segments([]).isEmpty)
    }

    @Test("列の並びの幅は、列 260・畳んだ帯 120・開いた帯は列と［折りたたむ］、間は 12")
    func rowWidth() {
        let columns = [Self.column("a", 0), Self.column("b", 1), Self.column("c", 2, collapsed: true), Self.column("d", 3, collapsed: true)]
        #expect(BoardColumnSegment.rowWidth(columns, expanded: []) == 664)
        #expect(BoardColumnSegment.rowWidth(columns, expanded: ["c"]) == 1112)
        #expect(BoardColumnSegment.rowWidth([], expanded: []) == 0)
    }

    // MARK: - 起動の下書き

    @Test func requestCarriesChoiceArgsAndNoWorktree() {
        var draft = LaunchDraft(machine: Self.machine, cwd: " ~/dev/x ")
        draft.choice = LaunchChoice(kind: .claude, model: "claude-sonnet-5", effort: .high)
        let request = draft.request(taskNumber: 152)
        #expect(request.worktree == nil)
        #expect(request.cwd == "~/dev/x")
        #expect(request.agentArgs == ["--dangerously-skip-permissions", "--model", "claude-sonnet-5", "--effort", "high"])
    }

    @Test func boardDefaultsFillTheSheet() {
        let choice = LaunchChoice(kind: .claude, model: "fable", effort: .xhigh)
        let defaults = LaunchDefaults(kind: .claude, agentArgs: choice.args, worktree: true, cwd: "~/dev/x")
        let draft = LaunchDraft.initial(machine: Self.machine, board: Self.board("b1", defaults: defaults), boardID: "b1", columnID: "todo")
        #expect(draft.choice == choice)
        #expect(draft.cwd == "~/dev/x")
        #expect(draft.prompt == "#{{id}} {{title}}")
    }

    @Test func unknownArgsAreKeptAsIs() {
        let defaults = LaunchDefaults(kind: .claude, agentArgs: ["--verbose", "--model", "未知のモデル"], worktree: false, cwd: "")
        var draft = LaunchDraft(machine: Self.machine)
        draft.apply(defaults: defaults, board: "b-unknown-args")
        #expect(draft.choice.isCustom)
        #expect(draft.agentArgs == ["--verbose", "--model", "未知のモデル"])
    }

    @Test func lastChoiceIsRememberedPerBoardWithoutDefaults() {
        AppDefaults.useScratch("settings-tests-remember")
        var draft = LaunchDraft(machine: Self.machine, cwd: "~/dev/remembered")
        draft.choice = LaunchChoice(kind: .claude, model: "claude-sonnet-5", effort: .low)
        draft.remember(board: "b-remember")
        var next = LaunchDraft(machine: Self.machine)
        next.apply(defaults: nil, board: "b-remember")
        #expect(next.choice == draft.choice)
        #expect(next.cwd == "~/dev/remembered")
        var other = LaunchDraft(machine: Self.machine)
        other.apply(defaults: nil, board: "b-other")
        #expect(other.choice == .standard)
    }

    @Test func linksArePerRowAndPastedLinesAreSplit() {
        #expect(NewTaskDraft.normalizedLinks([""]) == [""])
        #expect(NewTaskDraft.normalizedLinks(["https://a"]) == ["https://a", ""])
        #expect(NewTaskDraft.normalizedLinks(["https://a\nhttps://b\n"]) == ["https://a", "https://b", ""])
        #expect(NewTaskDraft.normalizedLinks(["https://a https://b", ""]) == ["https://a", "https://b", ""])
        #expect(NewTaskDraft.normalizedLinks(["https://a", "", "https://c", "", ""]) == ["https://a", "", "https://c", ""])
        #expect(NewTaskDraft.normalizedLinks(["https://日本語/パス\n"]) == ["https://日本語/パス", ""])
    }

    @Test func linkedSessionCwdWinsOverDefaults() {
        let defaults = LaunchDefaults(kind: .claude, agentArgs: [], worktree: false, cwd: "~/dev/x")
        let draft = LaunchDraft.initial(machine: Self.machine, board: Self.board("b1", defaults: defaults), boardID: "b1", columnID: "todo", cwd: "~/dev/linked")
        #expect(draft.cwd == "~/dev/linked")
    }

    // MARK: - 接続先の表示 / 非表示とアーカイブ

    private func twoMachines() async throws -> Fleet {
        let fleet = Fleet()
        fleet.add(id: "local", source: try FixtureSource.named("sessions-basic"))
        fleet.add(id: "conn:other", source: try FixtureSource.named("sessions-basic"))
        for _ in 0..<100 where fleet.allMachines.values.contains(where: { $0.machine == nil }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        return fleet
    }

    @Test func hiddenMachinesLeaveTheScreenButStayConnected() async throws {
        let fleet = try await twoMachines()
        fleet.hiddenMachines = ["conn:other"]
        #expect(Array(fleet.machines.keys) == ["local"])
        #expect(fleet.allMachines.count == 2)
    }

    @Test func onlyMachineWinsOverHidden() async throws {
        let fleet = try await twoMachines()
        fleet.hiddenMachines = ["conn:other"]
        fleet.onlyMachine = "conn:other"
        #expect(Array(fleet.machines.keys) == ["conn:other"])
    }

    @Test func archivedBoardsAreNotActive() {
        var state = MachineState()
        state.boards = ["live": Self.board("live"), "old": Self.board("old", archived: true)]
        #expect(Array(state.activeBoards.keys) == ["live"])
    }
}
