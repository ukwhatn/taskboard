import SwiftUI
import TaskboardKit

/// 案件のタスクを選んで、別の案件に移動する（default に混ざったタスクの振り分け）
struct TaskMoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: Board
    let scope: SettingsBoardScope
    @State private var selected: Set<TaskKey> = []
    @State private var targetID = ""
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        let tasks = scope.state.tasks.values.filter { $0.boardID == source.id }.sorted { $0.number > $1.number }
        let targets = model.orderedBoards(scope.state, fleetID: scope.fleetID).filter { $0.id != source.id }
        SheetScaffold(title: String(localized: "タスクの移動"), subtitle: String(localized: "「\(source.name)」から移動します"), error: error, onCancel: { dismiss() }) {
            Section {
                Picker("移動先", selection: $targetID) {
                    if targets.isEmpty { Text("未選択").tag("") }
                    ForEach(targets) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text(targets.isEmpty
                     ? String(localized: "移動先にできる案件はありません。先に案件を追加してください。")
                     : String(localized: "移動先に同じ列があればその列に、無ければ最初の進行中の列に入ります。"))
            }
            Section {
                ForEach(tasks) { task in
                    TaskMoveRow(task: task, column: source.columns.first { $0.id == task.columnID }?.label ?? "", selected: Binding(
                        get: { selected.contains(task.id) },
                        set: { if $0 { selected.insert(task.id) } else { selected.remove(task.id) } }))
                }
            } header: {
                HStack {
                    Text("「\(source.name)」のタスク")
                    Spacer()
                    if selected.count == tasks.count {
                        Button("選択を解除") { selected = [] }
                    } else {
                        Button("すべて選択") { selected = Set(tasks.map(\.id)) }
                    }
                }
                .buttonStyle(.borderless)
            }
        } actions: {
            Button(String(localized: "\(selected.count)件を移動")) { submit(tasks: tasks, targets: targets) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || targetID.isEmpty || submitting)
        }
        .onAppear { if targetID.isEmpty { targetID = targets.first?.id ?? "" } }
    }

    private func submit(tasks: [BoardTask], targets: [Board]) {
        guard let target = targets.first(where: { $0.id == targetID }) else { return }
        submitting = true
        error = nil
        Task {
            do {
                try await model.moveTasks(tasks.filter { selected.contains($0.id) }, to: target)
                dismiss()
            } catch {
                self.error = UserFacingError("タスクを移動できませんでした", error: error)?.text
                submitting = false
            }
        }
    }
}

/// 移動するタスクの 1 行。Mac はチェックボックス、iPhone と iPad は押すと印が付く行
private struct TaskMoveRow: View {
    let task: BoardTask
    let column: String
    @Binding var selected: Bool

    var body: some View {
        #if os(macOS)
        Toggle(isOn: $selected) { label }
            .toggleStyle(.checkbox)
        #else
        Button { selected.toggle() } label: {
            HStack(spacing: Space.row) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                label
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        #endif
    }

    private var label: some View {
        HStack(spacing: Space.row) {
            Text(verbatim: "#\(task.number)").monospacedDigit().foregroundStyle(.secondary)
            Text(task.title).lineLimit(1)
            Spacer(minLength: Space.row)
            Text(column).textRole(.caption)
        }
    }
}
