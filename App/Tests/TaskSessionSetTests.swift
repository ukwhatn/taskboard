import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// タスクの会話の集め方（`AppModel.taskSessions(for:)`・`activity(of:)`）。fixtures `sidebar-groups`:
/// #201 は会話なし。#202 は動いている会話 c-today とその委譲先の c-delegate（待機）。#203 は起動中の会話 c-old だけ
@MainActor
@Suite struct TaskSessionSetTests {
    private let machine = MachineID(rawValue: "fixture-studio")

    private func model() async throws -> AppModel {
        AppDefaults.useScratch("test-task-session-set")
        let model = AppModel(options: LaunchOptions(scenario: "sidebar-groups"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.task(for: TaskKey(machine: machine, number: 203)) == nil {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func task(_ number: Int, in model: AppModel) throws -> BoardTask {
        try #require(model.fleet.task(for: TaskKey(machine: machine, number: number)))
    }

    @Test("札に並べるのは lead と委譲先の全部で、委譲先は起こした側のすぐ後に深さ 1 で続く")
    func leadAndDelegates() async throws {
        let model = try await model()
        let delegated = model.taskSessions(for: try task(202, in: model))
        #expect(delegated.rows.map { "\($0.depth):\($0.conversation.id)" } == ["0:c-today", "1:c-delegate"])
        #expect(model.taskSessions(for: try task(201, in: model)).rows.isEmpty)
    }

    @Test("委譲先の進み: 委譲先の全部と、済んだ（終了した会話）数")
    func delegateProgress() async throws {
        let model = try await model()
        #expect(model.delegateProgress(of: try task(202, in: model)) == DelegateProgress(done: 0, total: 1))
        #expect(model.delegateProgress(of: try task(203, in: model)) == nil)
    }

    @Test("開いたときに出す会話: 動いている会話があればその会話。会話の無いタスクは無し")
    func opening() async throws {
        let model = try await model()
        #expect(model.taskSessions(for: try task(202, in: model)).opening?.id == "c-today")
        #expect(model.taskSessions(for: try task(203, in: model)).opening?.id == "c-old")
        #expect(model.taskSessions(for: try task(201, in: model)).opening == nil)
    }

    @Test("iPhone の絞り込みの材料: 結ばれた会話の状態（委譲先も）")
    func activityOfConversations() async throws {
        let model = try await model()
        #expect(model.activity(of: try task(202, in: model)) == [.running, .idle])
        #expect(model.activity(of: try task(203, in: model)) == [.starting])
        #expect(model.activity(of: try task(201, in: model)).isEmpty)
    }

    private func wakesModel() async throws -> AppModel {
        AppDefaults.useScratch("test-task-session-set-wakes")
        let model = AppModel(options: LaunchOptions(scenario: "wakes"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.task(for: TaskKey(machine: machine, number: 128)) == nil {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    /// fixtures `wakes` の #128: 待機の会話 c-live、止まった会話 c-rewind（終了していない）、終了した会話 c-done、記録だけの止まったセッション sess-reviewer-0003
    @Test("止まった会話は待機として数える（札・サイドバーの木・iPhone の絞り込み）。終了した会話は数えない")
    func stoppedConversationCountsAsIdle() async throws {
        let model = try await wakesModel()
        let task = try task(128, in: model)
        #expect(model.activity(of: task) == [.idle])
        #expect(model.taskSessions(for: task).rows.map(\.conversation.id) == ["c-live", "c-rewind"])
        // 止まった会話だけが残っても、タスクはサイドバーの木に出て、札は待機
        var state = try #require(model.fleet.machineState(for: machine))
        let stopped = try #require(state.conversations[ConversationKey(machine: machine, id: "c-rewind")])
        #expect(stopped.phase == .stopped && !stopped.isClosed)
        #expect(SidebarStatus.of(stopped) == .idle)
        state.conversations[ConversationKey(machine: machine, id: "c-live")] = nil
        #expect(state.activeTaskNumbers().contains(128))
    }

    @Test("終了したセッションの節は、止まったセッションの記録と終了した会話を、新しい順に 1 つの並びにする")
    func finishedSessionsMerge() async throws {
        let model = try await wakesModel()
        let task = try task(128, in: model)
        let sessions = model.taskSessions(for: task)
        #expect(sessions.stopped.map(\.sessionID) == ["sess-reviewer-0003"])
        #expect(sessions.closed.map(\.id) == ["c-done"])
        let finished = model.finishedSessions(of: task, in: sessions)
        // 記録の結んだ日は 2026-09-20、c-done の更新は 2026-10-02
        #expect(finished.map(\.id) == ["conversation/c-done", "record/sess-reviewer-0003"])
    }
}
