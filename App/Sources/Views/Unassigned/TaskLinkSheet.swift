import SwiftUI
import TaskboardKit

/// タスクなしの会話・セッション・PR を紐づけるタスクを選ぶ。同じマシンのタスクを検索でき（番号かタイトル）、押すとその場で紐づけて閉じる。
/// 会話とセッションはそのタスクの画面に移って開き、PR はタスクのリンクに足して一覧に残る（行が消える）
struct TaskLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: TaskLinkTarget
    @State private var query = ""
    @State private var linking: TaskKey?
    @State private var error: String?

    var body: some View {
        let candidates = model.linkTargets(on: target.machine)
        let shown = candidates.filter { AppModel.task($0, matches: query) }
        SheetScaffold(
            title: String(localized: "タスクへの紐づけ"), subtitle: model.name(of: target), error: error, width: 520, onCancel: { dismiss() }
        ) {
            Section {
                FormSearchField(query: $query)
            }
            Section {
                if candidates.isEmpty {
                    Text("紐づけられるタスクはありません").textRole(.secondary)
                } else if shown.isEmpty {
                    Text("条件に合うタスクはありません").textRole(.secondary)
                }
                ForEach(shown) { task in
                    Button {
                        link(task)
                    } label: {
                        TaskLinkRow(task: task, board: model.fleet.board(id: task.boardID, on: task.machine))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(linking != nil)
                }
            }
        } actions: {
            if linking != nil { ProgressView().controlSize(.small) }
        }
    }

    private func link(_ task: BoardTask) {
        guard linking == nil else { return }
        linking = task.id
        error = nil
        Task {
            do {
                try await model.attach(target, to: task)
                dismiss()
                if case .conversation(let item) = target { model.navigate(to: .task(task.id, focus: item), from: .app) }
            } catch {
                self.error = UserFacingError("タスクに紐づけられませんでした", error: error)?.text
                linking = nil
            }
        }
    }
}

/// 候補の 1 行。「#番号 タイトル」と、案件と列
private struct TaskLinkRow: View {
    let task: BoardTask
    let board: Board?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "#\(task.number) \(task.title)").lineLimit(2)
            if let board {
                let column = board.columns.first { $0.id == task.columnID }?.label
                Text(verbatim: [board.name, column].compactMap(\.self).joined(separator: " › ")).textRole(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
