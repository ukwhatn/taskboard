import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// タスク画面の 2 つ目（右に並べるもの）と、並べた欄の間の移動のキー
@MainActor
@Suite struct TaskSplitTests {
    @Test("右に出すのは札にあって左と違う会話。左と同じか、札に無いものは出さない")
    func visible() async throws {
        let model = try await ConversationSnapshotTests.loadedModel()
        let machine = try ConversationSnapshotTests.key(model, "c-tools").machine
        let task = try #require(model.fleet.task(for: TaskKey(machine: machine, number: 137)))
        let rows = model.taskSessions(for: task).rows
        let tools = ConversationKey(machine: machine, id: "c-tools")
        let gen = ConversationKey(machine: machine, id: "c-gen")

        #expect(TaskSplit.visible(gen, primary: tools, rows: rows)?.key == gen)
        #expect(TaskSplit.visible(tools, primary: gen, rows: rows)?.key == tools)
        #expect(TaskSplit.visible(tools, primary: tools, rows: rows) == nil)
        #expect(TaskSplit.visible(nil, primary: tools, rows: rows) == nil)
        // 別のタスクの会話（c-perm は #131）
        #expect(TaskSplit.visible(ConversationKey(machine: machine, id: "c-perm"), primary: tools, rows: rows) == nil)
    }

    @Test("［並べる］の相手は札の並びで左でない最初のもの。左が無ければ無し")
    func partner() async throws {
        let model = try await ConversationSnapshotTests.loadedModel()
        let machine = try ConversationSnapshotTests.key(model, "c-tools").machine
        let task = try #require(model.fleet.task(for: TaskKey(machine: machine, number: 137)))
        let rows = model.taskSessions(for: task).rows
        let items = rows.map(\.conversation.key)
        #expect(items.count >= 2)
        #expect(TaskSplit.partner(of: items[0], rows: rows) == items[1])
        #expect(TaskSplit.partner(of: items[1], rows: rows) == items[0])
        #expect(TaskSplit.partner(of: nil, rows: rows) == nil)
        #expect(TaskSplit.partner(of: items[0], rows: Array(rows.prefix(1))) == nil)
    }

    @Test("⌃] で右、⌃[ で左。ほかの修飾キーやキーは使わず、並べていなければ受けない")
    func keys() {
        #expect(SplitFocusKeys.side(for: KeyEquivalent("]"), modifiers: .control) == .trailing)
        #expect(SplitFocusKeys.side(for: KeyEquivalent("["), modifiers: .control) == .leading)
        #expect(SplitFocusKeys.side(for: KeyEquivalent("]"), modifiers: [.control, .shift]) == nil)
        #expect(SplitFocusKeys.side(for: KeyEquivalent("]"), modifiers: .command) == nil)
        #expect(SplitFocusKeys.side(for: KeyEquivalent("a"), modifiers: .control) == nil)
        #expect(!SplitFocusKeys.handle(KeyEquivalent("]"), modifiers: .control, move: nil))
        var moved: [SplitSide] = []
        #expect(SplitFocusKeys.handle(KeyEquivalent("["), modifiers: .control) { moved.append($0) })
        #expect(!SplitFocusKeys.handle(.return, modifiers: []) { moved.append($0) })
        #expect(moved == [.leading])
    }
}
