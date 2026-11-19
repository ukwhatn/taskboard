import SwiftUI
import TaskboardKit

extension View {
    /// タスクのパネルと iPhone のタスクの画面のセッションの欄が出すシート（起動と、編集のシート）と、止まったセッションの題の読み直し。
    /// 編集のシートで残っているのはセッションの紐づけ（題・メモ・リンクはその場で直す）
    func taskSessionSheets(task: BoardTask, launch: Binding<LaunchDraft?>, editing: Binding<TaskEditSheet?>) -> some View {
        modifier(TaskSessionSheets(task: task, launch: launch, editing: editing))
    }
}

private struct TaskSessionSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    @Binding var launch: LaunchDraft?
    @Binding var editing: TaskEditSheet?

    func body(content: Content) -> some View {
        content
            .task(id: task.sessions.map(\.sessionID)) { await model.loadSessionHistory(for: task) }
            .sheet(item: $launch) { draft in
                LaunchSheet(task: task, draft: draft)
            }
            .sheet(item: $editing) { kind in
                switch kind {
                case .sessions: TaskSessionLinkSheet(key: task.id)
                }
            }
    }
}

/// セッションの紐づけ。同じマシンのタスクなしの会話を並べ、押すとその場で紐づけて閉じる
struct TaskSessionLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: TaskKey
    @State private var linking: ConversationKey?
    @State private var error: String?

    var body: some View {
        let task = model.fleet.task(for: key)
        let candidates = task.map { model.linkCandidates(for: $0) } ?? []
        SheetScaffold(
            title: String(localized: "セッションの紐づけ"), subtitle: task.map { "#\($0.number) \($0.title)" }, error: error, width: 520,
            onCancel: { dismiss() }
        ) {
            Section {
                if candidates.isEmpty {
                    Text("紐づけられるセッションはありません").textRole(.secondary)
                } else {
                    ForEach(candidates) { conversation in
                        Button {
                            link(conversation)
                        } label: {
                            ConversationLinkRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        .disabled(linking != nil)
                    }
                }
            }
        } actions: {
            EmptyView()
        }
    }

    private func link(_ conversation: Conversation) {
        guard let task = model.fleet.task(for: key), linking == nil else { return }
        linking = conversation.key
        error = nil
        Task {
            do {
                try await model.link(conversation, to: task)
                dismiss()
            } catch {
                self.error = UserFacingError("セッションを紐づけられませんでした", error: error)?.text
                linking = nil
            }
        }
    }
}
