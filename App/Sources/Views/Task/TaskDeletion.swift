import SwiftUI
import TaskboardKit

/// タスクの削除の確認。パネルの上の帯・カードの右クリック・iPhone のタスクの画面で、置いた所の窓に出す
enum TaskDeletion {
    /// 本文。紐づくセッションが動いていれば、止まらないことを添える
    static func message(_ task: BoardTask, hasRunningSessions: Bool) -> String {
        let name = "#\(task.number) \(task.title)"
        return hasRunningSessions
            ? String(localized: "「\(name)」を削除しますか？　作業項目と文書も削除されます。動いているセッションは止まりません。この操作は元に戻せません。")
            : String(localized: "「\(name)」を削除しますか？　作業項目と文書も削除されます。この操作は元に戻せません。")
    }
}

/// 削除の項目（メニューに置く）
struct TaskDeleteButton: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    @Binding var target: BoardTask?

    var body: some View {
        if model.canWrite(task.machine) {
            Button("削除", systemImage: "trash", role: .destructive) { target = task }
        }
    }
}

private struct TaskDeleteDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var target: BoardTask?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "タスクの削除", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible, presenting: target
        ) { task in
            Button("削除", role: .destructive) { model.deleteTask(task) }
            Button("キャンセル", role: .cancel) {}
        } message: { task in
            Text(verbatim: TaskDeletion.message(task, hasRunningSessions: model.taskSessions(for: task).conversations.contains { $0.phase != .stopped }))
        }
    }
}

extension View {
    /// `target` に入れたタスクの削除を確かめる
    func taskDeleteDialog(_ target: Binding<BoardTask?>) -> some View {
        modifier(TaskDeleteDialog(target: target))
    }
}
