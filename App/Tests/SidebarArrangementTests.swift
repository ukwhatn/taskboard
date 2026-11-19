import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// サイドバーの並べ方（`SidebarArrangement`）と状態の組（`SidebarStateGroup`）
@Suite struct SidebarArrangementTests {
    private let studio = MachineID(rawValue: "studio")

    private func store() -> UserDefaults {
        let name = "tb-sidebar-arrangement-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func task(_ number: Int, _ title: String, created: TimeInterval, updated: TimeInterval = 0) -> BoardTask {
        BoardTask(
            machine: studio, number: number, boardID: "b", columnID: "c", title: title,
            createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated))
    }

    private var tasks: [BoardTask] {
        [task(3, "ビルドを直す", created: 30, updated: 100), task(1, "api の整理", created: 10, updated: 300), task(2, "Api の整理", created: 30, updated: 200)]
    }

    private func numbers(_ order: SidebarArrangement.Order, activity: [Int: TimeInterval] = [:]) -> [Int] {
        SidebarArrangement(order: order)
            .sorted(tasks) { task in Date(timeIntervalSince1970: activity[task.number] ?? task.updatedAt.timeIntervalSince1970) }
            .map(\.number)
    }

    @Test("番号は昇順")
    func byNumber() {
        #expect(numbers(.number) == [1, 2, 3])
    }

    @Test("最近の動きは新しい順。会話の動きがタスクの更新より新しければそちらで並ぶ")
    func byRecent() {
        #expect(numbers(.recent) == [1, 2, 3])
        #expect(numbers(.recent, activity: [3: 500]) == [3, 1, 2])
    }

    @Test("追加日は新しい順。同じなら番号の順")
    func byCreated() {
        #expect(numbers(.created) == [2, 3, 1])
    }

    @Test("タイトルは大文字・小文字を区別しない並びで、同じなら番号の順。英字と日本語の両方")
    func byTitle() {
        #expect(numbers(.title) == [1, 2, 3])
    }

    @Test("既定は案件と列・番号。選んだ並べ方は保存して読み戻せる。知らない値は既定に戻す")
    func persistence() {
        let defaults = store()
        let prefs = DevicePrefs(defaults: defaults)
        #expect(prefs.sidebarArrangement == SidebarArrangement(grouping: .boards, order: .number))
        prefs.sidebarArrangement = SidebarArrangement(grouping: .state, order: .recent)
        #expect(DevicePrefs(defaults: defaults).sidebarArrangement == SidebarArrangement(grouping: .state, order: .recent))
        defaults.set("unknown", forKey: AppPreferences.sidebarGroupingKey)
        #expect(prefs.sidebarArrangement.grouping == .boards)
    }

    @Test("状態の組は、自分の番の札が対応待ち、実行中、未読、それ以外（札なし・PR の札）は待機")
    func stateGroups() {
        #expect(SidebarStateGroup(.blocked) == .waiting)
        #expect(SidebarStateGroup(.planApproval) == .waiting)
        #expect(SidebarStateGroup(.ciFailed) == .waiting)
        #expect(SidebarStateGroup(.running) == .running)
        #expect(SidebarStateGroup(.unread) == .unread)
        #expect(SidebarStateGroup(.ciPassed) == .idle)
        #expect(SidebarStateGroup(.merged) == .idle)
        #expect(SidebarStateGroup(nil) == .idle)
        #expect(SidebarStateGroup.allCases.map(\.label) == ["対応待ち", "実行中", "未読", "待機"])
    }

    @MainActor
    @Test("状態で分けると、マシンごとに対応待ち・実行中・未読の組に札のとおり入り、中身の無い組は出さない。分け方を替えても出すタスクは同じ")
    func groupsOnFixtures() async throws {
        // 未読はこの端末で終わりを見たターンの印。fixtures は動いていた記録を持たないので、c-pr41（#131）の印を先に置く
        AppDefaults.useScratch("test-sidebar-arrangement-groups", seed: [AppPreferences.unreadConversationsKey: ["fixture-studio\nc-pr41"]])
        let model = AppModel(options: LaunchOptions(scenario: "sessions-basic"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.inboxItems.isEmpty {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない")
            try await Task.sleep(for: .milliseconds(20))
        }
        let machine = try #require(model.orderedMachines.first)
        let waiting = model.waitingItemsByTask
        let active = model.sidebarActiveTasks(machine.state)
        let groups = model.sidebarStateGroups(on: machine.state, fleetID: machine.id, waiting: waiting, active: active)
        let numbers = Dictionary(uniqueKeysWithValues: groups.map { ($0.group, $0.rows.map(\.task.number)) })
        #expect(numbers[.waiting] == [118, 120, 128])
        #expect(numbers[.running] == [137])
        #expect(numbers[.unread] == [131])
        #expect(numbers[.idle] == nil)
        let tree = model.orderedBoards(machine.state, fleetID: machine.id).flatMap { board in
            board.orderedColumns.flatMap { model.sidebarTasks(in: board, column: $0, state: machine.state, waiting: waiting, active: active) }
        }
        #expect(Set(tree.map(\.number)) == Set(model.sidebarTasks(on: machine.state, fleetID: machine.id, waiting: waiting, active: active).map(\.number)))
    }
}
