import SwiftUI
import TaskboardKit

/// タスクの「委任範囲」の節の中身。タスクで上書きした項目の段階（押すとタスクの上書きを保存）。
/// 案件の設定のままの項目は「ほか N 項目は案件の設定のまま」の 1 行に折りたたみ、全部が案件の設定なら段階ごとの数の 1 行にする。
/// ［編集］で 7 項目を全部並べる。Mac のよく開く欄なので segmented にせず `ChipButton` で選ぶ
struct TaskDelegationScope: View {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window
    let task: BoardTask
    let board: Board?

    /// 保存を送った上書き。daemon から新しい上書きが届くまで、これを出す
    @TaskState private var pending = PendingValue<DelegationScope>()
    @TaskState private var editing = false

    var body: some View {
        let shown = pending.shown(task.delegation)
        var display = task
        let _ = display.delegation = shown
        let entries = display.delegation(board: board)
        let overridden = entries.filter { !$0.followsBoard }
        VStack(alignment: .leading, spacing: Space.block) {
            ForEach(editing ? entries : overridden, id: \.area) { entry in
                row(entry, scope: shown)
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                if !editing {
                    if overridden.isEmpty {
                        Text(Self.summary(entries)).textRole(.secondary)
                    } else if overridden.count < entries.count {
                        Text("ほか\(entries.count - overridden.count)項目は案件の設定のまま").textRole(.secondary)
                    }
                }
                Button(editing ? "閉じる" : "編集") { editing.toggle() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(!editing && !model.canWrite(task.machine))
            }
        }
        .onChange(of: task.delegation) { _, _ in pending.settle() }
    }

    /// 全部が案件の設定のときの 1 行（段階ごとの数）
    static func summary(_ entries: [DelegationEntry]) -> String {
        let counts = DelegationLevel.allCases.map { level in "\(level.label)\(entries.filter { $0.level == level }.count)" }
        return String(localized: "\(counts.joined(separator: "・"))（すべて案件の設定のまま）")
    }

    private func row(_ entry: DelegationEntry, scope: DelegationScope) -> some View {
        VStack(alignment: .leading, spacing: Space.row) {
            Text(entry.area.label).textRole(.body)
            FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
                ForEach(DelegationLevel.allCases) { level in
                    ChipButton(text: level.label, selected: entry.level == level) {
                        var next = scope
                        next[entry.area] = level
                        save(next)
                    }
                }
                Group {
                    if entry.followsBoard {
                        Text("案件の設定").textRole(.secondary)
                    } else {
                        Button("案件の設定に戻す") {
                            var next = scope
                            next[entry.area] = nil
                            save(next)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                .padding(.leading, Space.row)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.area.label)
    }

    private func save(_ scope: DelegationScope) {
        guard scope != pending.shown(task.delegation) else { return }
        pending.send(scope)
        Task {
            do {
                try await model.saveDelegation(scope, of: task)
            } catch {
                pending.failed(scope)
                model.fail("委任範囲を保存できませんでした", error, in: window)
            }
        }
    }
}
