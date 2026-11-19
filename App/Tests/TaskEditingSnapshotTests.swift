import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// タスクの編集のシート（セッションの紐づけ）と、メモが空のときの節。題・メモ・リンクはシートでなくその場で直す。fixtures `stress` の #137（メモあり、PR 1 件、
/// w1:p1 が紐づく）と #125（メモ・リンク・セッションが無い）。シートは Mac の幅で描く。fixtures は書き込めないので、
/// メモの空状態（「メモはありません」）は `editable` で描く（パネルは書き込める接続先でだけ渡す）
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct TaskEditingSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    private func key(_ model: AppModel, _ number: Int) throws -> TaskKey {
        let key = TaskKey(machine: LaunchSnapshotTests.machine(model), number: number)
        try #require(model.fleet.task(for: key) != nil, "fixtures のタスク番号が変わった")
        return key
    }

    @Test("セッションの紐づけのシート（#137 の候補はタスクなしの会話。終了したものとオーケストレーターは出さない）", arguments: Matrix.cases([520]))
    func sessionLinkSheet(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await LaunchSnapshotTests.loadedModel("conversations")
        let view = TaskSessionLinkSheet(key: try key(model, 137)).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 360), variant: appearance), named: name)
    }

    @Test("タスクへの紐づけのシート（タスクなしの会話 c-stop を紐づける先。進行中の列のタスクが先）", arguments: Matrix.cases([520]))
    func taskLinkSheet(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await LaunchSnapshotTests.loadedModel("conversations")
        let target = TaskLinkTarget.conversation(ConversationKey(machine: LaunchSnapshotTests.machine(model), id: "c-stop"))
        let view = TaskLinkSheet(target: target).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 520), variant: appearance), named: name)
    }

    @Test("タスクなしの会話から開いた起票のシート（起動の欄を出さず、確定は［追加］。見出しの下に紐づける名前）", arguments: Matrix.cases([560]))
    func attachingNewTaskSheet(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await LaunchSnapshotTests.loadedModel("conversations")
        let target = TaskLinkTarget.conversation(ConversationKey(machine: LaunchSnapshotTests.machine(model), id: "c-stop"))
        let draft = try #require(model.newTaskDraft(for: target))
        let view = NewTaskSheet(draft: draft).environment(model).environment(\.today, BoardSnapshotTests.today).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 700), variant: appearance), named: name)
    }

    @Test("メモが空のときの右側の状態の欄（「メモはありません」。押すと欄になる）", arguments: Matrix.cases([420]))
    func emptyNote(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await LaunchSnapshotTests.loadedModel()
        let task = try #require(model.fleet.task(for: try key(model, 125)))
        try #require(task.note.isEmpty, "fixtures の #125 にメモが入った")
        AppDefaults.store.set(SidePanelSet(open: [.status]).json, forKey: AppPreferences.taskSidePanelsKey)
        let view = TaskSideArea(task: task, editable: true).environment(model).environment(\.taskScope, task.id).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 480), variant: appearance), named: name)
    }
}
