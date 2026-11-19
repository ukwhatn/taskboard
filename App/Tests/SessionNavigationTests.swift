import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 会話の行き来（サイドバー・通知・URL からタスクの画面へ）と、タスクの削除の確認。
/// fixtures `conversations`: c-gen（#137、生成中）、c-plan（#125、応答待ち）、c-stop（タスクなし、止まっている）
@MainActor
@Suite struct SessionNavigationTests {
    private let machine = MachineID(rawValue: "fixture-studio")

    private func model() async throws -> AppModel {
        AppDefaults.useScratch("test-session-navigation")
        let model = AppModel(options: LaunchOptions(scenario: "conversations"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty || model.fleet.conversation(for: conversation("c-gen")) == nil {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func task(_ number: Int) -> TaskKey { TaskKey(machine: machine, number: number) }
    private func conversation(_ id: String) -> ConversationKey { ConversationKey(machine: machine, id: id) }

    @Test("タスクの会話を開くと、そのタスクの画面を開き、札でその会話を選ぶ")
    func linkedConversationOpensTask() async throws {
        let model = try await model()
        model.navigate(to: .conversation(conversation("c-gen")), from: .debug)
        #expect(model.selectedTask == task(137))
        #expect(model.sessionFocus?.scope == .task(task(137)))
        #expect(model.sessionFocus?.item == conversation("c-gen"))
    }

    @Test("タスクの無い会話は、マシンのタスクなしの画面で開いて札で選ぶ")
    func unlinkedConversationOpensUnassigned() async throws {
        let model = try await model()
        model.navigate(to: .conversation(conversation("c-stop")), from: .debug)
        #expect(model.sidebar == .unassigned(machine: machine))
        #expect(model.sessionFocus?.item == conversation("c-stop"))
        #expect(model.selectedTask == nil)
    }

    @Test("通知の項目が消えた後でも、通知の URL の会話がタスクにあればタスクで開く")
    func notificationFallbackOpensTask() async throws {
        let model = try await model()
        model.openNotification(itemID: "gone", fallback: URL(string: "taskboard://conversation/fixture-studio/c-plan")!)
        #expect(model.selectedTask == task(125))
        #expect(model.sessionFocus?.item == conversation("c-plan"))
    }

    @Test("サイドバーの木には、動いている会話か対応待ちのあるタスクだけを出す。どちらも無いタスク（終わったものなど）は出さない")
    func sidebarShowsOnlyActiveTasks() async throws {
        let model = try await model()
        let shown = Set(model.fleet.allBoards.filter { $0.machine == machine }.flatMap { board in
            board.orderedColumns.flatMap { column in
                model.sidebarTasks(in: board, column: column, state: model.fleet.machineState(for: machine)!, waiting: model.waitingItemsByTask, active: model.sidebarActiveTasks(model.fleet.machineState(for: machine)!))
            }
        }.map(\.number))
        #expect(shown.contains(137), "生成中の会話がある")
        #expect(shown.contains(125), "応答待ちの会話がある")
        #expect(!shown.contains(109), "会話も対応待ちも無い完了")
    }

    @Test("タスクのパネルを開いたまま案件を選ぶと、パネルを閉じてその案件に移る（⌘1〜⌘9・サイドバー・URL のどれも reveal を通る）")
    func revealBoardClosesTask() async throws {
        let model = try await model()
        model.navigate(to: .task(task(137)), from: .debug)
        #expect(model.selectedTask == task(137))
        let board = try #require(model.fleet.allBoards.first { $0.machine == machine })
        model.navigate(to: .board(machine: board.machine, id: board.id), from: .debug)
        #expect(model.selectedTask == nil)
        #expect(model.sidebar == .board(machine: board.machine, id: board.id))
    }

    // MARK: 5. タスクの削除

    @Test("削除の確認の本文: 番号と題、一緒に消えるもの。紐づくセッションが動いていれば止まらないことを添える")
    func deleteMessage() async throws {
        let model = try await model()
        let task137 = try #require(model.fleet.task(for: task(137)))
        #expect(
            TaskDeletion.message(task137, hasRunningSessions: false)
                == "「#137 \(task137.title)」を削除しますか？　作業項目と文書も削除されます。この操作は元に戻せません。")
        #expect(
            TaskDeletion.message(task137, hasRunningSessions: true)
                == "「#137 \(task137.title)」を削除しますか？　作業項目と文書も削除されます。動いているセッションは止まりません。この操作は元に戻せません。")
    }

    @Test("表示用のデータ（fixtures）のタスクには削除の項目を出さない")
    func deleteHiddenForFixtures() async throws {
        let model = try await model()
        let task137 = try #require(model.fleet.task(for: task(137)))
        #expect(!model.canWrite(task137.machine))
    }
}
