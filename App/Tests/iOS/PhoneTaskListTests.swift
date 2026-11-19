import Foundation
import Testing
import TaskboardKit
@testable import Taskboard

/// iPhone の一覧の行を押したときの行き先（`AppModel.openFromPhoneList`）
@MainActor
@Suite struct PhoneTaskListTests {
    static let machine = MachineID(rawValue: "fixture-studio")

    private func loadedModel() async throws -> AppModel {
        AppDefaults.useScratch("phone-task-list")
        let model = AppModel(options: LaunchOptions(scenario: "conversations"))
        let deadline = ContinuousClock.now + .seconds(5)
        while (model.fleet.machineState(for: Self.machine)?.tasks.count ?? 0) == 0 {
            try #require(ContinuousClock.now < deadline, "fixtures conversations を読み込めない")
            try await Task.sleep(for: .milliseconds(50))
        }
        return model
    }

    private func tasks(_ model: AppModel, where predicate: (Int) -> Bool) throws -> BoardTask {
        let tasks = model.fleet.machineState(for: Self.machine)?.tasks.values.sorted { $0.number < $1.number } ?? []
        return try #require(tasks.first { predicate(model.taskSessions(for: $0).rows.count) })
    }

    @Test func taskWithOneConversationOpensThatConversationOnly() async throws {
        let model = try await loadedModel()
        let task = try tasks(model) { $0 == 1 }
        let conversation = try #require(model.taskSessions(for: task).rows.first?.conversation.key)

        model.openFromPhoneList(task)

        #expect(model.phoneTaskRoutes == [.conversation(conversation)])
        #expect(model.selectedTask == nil)
    }

    @Test func taskWithSeveralConversationsOpensTheTaskScreen() async throws {
        let model = try await loadedModel()
        let task = try tasks(model) { $0 > 1 }

        model.openFromPhoneList(task)

        #expect(model.phoneTaskRoutes == [.task(task.id)])
    }

    @Test func conversationOpenedDirectlyCanMoveToItsTaskScreen() async throws {
        let model = try await loadedModel()
        let task = try tasks(model) { $0 == 1 }
        let conversation = try #require(model.taskSessions(for: task).rows.first?.conversation)
        model.openFromPhoneList(task)

        model.openTaskFromPhoneConversation(conversation)

        // 文書はタスクの画面にしか無いので、会話から入ったときもタスクの画面へ移れる
        #expect(model.phoneTaskRoutes == [.task(task.id)])
    }
}
