import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// iPhone の「タスク」タブのスタック（`AppModel.phoneTaskRoutes`）。スタックは path をそのまま書き戻すので、ここでは path の読み書きで操作を表す
@MainActor
@Suite struct PhoneNavigationTests {
    private let machine = MachineID(rawValue: "fixture-studio")
    private var board: PhoneRoute { .item(.board(machine: machine, id: "fixture-board")) }

    private func model() async throws -> AppModel {
        AppDefaults.useScratch("test-phone-navigation")
        let model = AppModel(options: LaunchOptions(scenario: "stress"))
        for _ in 0..<250 where model.fleet.allBoards.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func task(_ number: Int) -> TaskKey { TaskKey(machine: machine, number: number) }
    private func conversation(_ id: String) -> ConversationKey { ConversationKey(machine: machine, id: id) }

    @Test("タスクを開いた状態で別のタスクを開くと、スタックの上のタスクが替わる")
    func openAnotherTask() async throws {
        let model = try await model()
        model.navigate(to: .task(task(137)), from: .debug)
        #expect(model.phoneTaskRoutes == [board, .task(task(137))])
        model.navigate(to: .task(task(128)), from: .debug)
        #expect(model.phoneTaskRoutes == [board, .task(task(128))])
        #expect(model.selectedTask == task(128))
    }

    @Test("タスクの画面から開いた会話は上に積まれ、戻ると消え、もう一度戻るとタスクが閉じる")
    func pushAndPopConversation() async throws {
        let model = try await model()
        model.navigate(to: .task(task(137)), from: .debug)
        model.phoneTaskRoutes.append(.conversation(conversation("c-1")))
        #expect(model.phoneTaskItem == conversation("c-1"))
        #expect(model.phoneTaskRoutes == [board, .task(task(137)), .conversation(conversation("c-1"))])

        model.phoneTaskRoutes.removeLast()
        #expect(model.phoneTaskItem == nil)
        #expect(model.selectedTask == task(137))

        model.phoneTaskRoutes.removeLast()
        #expect(model.selectedTask == nil)
        #expect(model.phoneTaskRoutes == [board])
    }

    @Test("開いているタスクが替わると、上に積んだ会話は閉じる")
    func changingTaskDropsConversation() async throws {
        let model = try await model()
        model.navigate(to: .task(task(137)), from: .debug)
        model.phoneTaskRoutes.append(.conversation(conversation("c-1")))
        model.navigate(to: .task(task(128)), from: .debug)
        #expect(model.phoneTaskItem == nil)
        #expect(model.phoneTaskRoutes == [board, .task(task(128))])
    }

    @Test("タスクなしとオーケストレーターの画面も「タスク」タブに積み、そこから開いた会話をその上に積む")
    func unassignedStack() async throws {
        let model = try await model()
        model.phoneTaskRoutes = [.item(.unassigned(machine: machine)), .conversation(conversation("c-2"))]
        #expect(model.phoneTaskPath == [.unassigned(machine: machine)])
        #expect(model.phoneTaskItem == conversation("c-2"))
        #expect(model.phoneTaskRoutes == [.item(.unassigned(machine: machine)), .conversation(conversation("c-2"))])
        model.navigate(to: .unassigned(machine), from: .debug)
        #expect(model.phoneTab == .tasks)
        #expect(model.phoneTaskPath == [.unassigned(machine: machine)])
    }
}
