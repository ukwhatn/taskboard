import SwiftUI
import TaskboardKit

/// 1 案件のカンバン（iPhone の「タスク」タブから開く）。狭い幅は列をチップで選んで縦に並べ、広い幅は列を横に並べる。
/// Mac と iPad は全体のボード（`OverviewBoard`）で案件を並べる
struct BoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.pageInset) private var inset
    let board: Board

    @State private var expandedColumns: Set<String> = []
    @State private var filter: BoardFilter = .all
    /// 狭い幅で見ている列。nil なら最初の進行中の列
    @State private var compactColumnID: String?

    var body: some View {
        let tasks = model.fleet.tasks(onBoard: board.id, machine: board.machine)
        Group {
            if sizeClass == .compact {
                compact(tasks: tasks)
            } else {
                wide(tasks: tasks)
            }
        }
        .navigationTitle(board.name)
        .toolbar {
            // 横並びの選択は、iPhone の上のバーでは戻ると追加のボタンの間に入り切らない
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("絞り込み", selection: $filter) {
                        ForEach(BoardFilter.allCases) { f in Text(f.label).tag(f) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("絞り込み", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityValue(filter.label)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("タスクを追加", systemImage: "plus") { model.newTaskSheet = NewTaskDraft(board: board) }
                    .help("タスクを追加（⌘N）")
            }
        }
    }

    /// 狭い幅: 列を上のチップで選び、その列のカードを縦に並べる
    private func compact(tasks: [BoardTask]) -> some View {
        let current = board.columns.first { $0.id == compactColumnID } ?? board.openColumns.first ?? board.orderedColumns.first
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.inline) {
                    ForEach(board.orderedColumns) { column in
                        let selected = column.id == current?.id
                        Button {
                            compactColumnID = column.id
                        } label: {
                            HStack(spacing: Space.inline) {
                                Text(column.label)
                                Text(tasks.filter { $0.columnID == column.id }.count, format: .number).monospacedDigit().opacity(0.7)
                            }
                            .chipStyle(tint: selected ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .hitTarget()
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, inset)
            }
            if let current {
                let all = tasks.filter { $0.columnID == current.id }
                let shown = model.tasks(all, matching: filter)
                ScrollView(.vertical) {
                    LazyVStack(spacing: Space.row) {
                        ForEach(shown) { task in
                            TaskCardButton(task: task, signals: model.cardSignals(for: task), scheduleName: model.schedule(forTask: task.id)?.name)
                                .equatable()
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .contentMargins(.vertical, Space.block, for: .scrollContent)
                .overlay {
                    if shown.isEmpty {
                        EmptyState(all.isEmpty ? "タスクはありません" : "条件に合うタスクはありません", symbol: "rectangle.stack")
                    }
                }
            }
        }
    }

    /// 広い幅: 列を横に並べ、縦と横の 1 枚の面で送る
    private func wide(tasks: [BoardTask]) -> some View {
        FillContainer {
            ScrollView([.horizontal, .vertical]) {
                BoardColumnsRow(board: board, tasks: tasks, expanded: $expandedColumns) { model.tasks($0, matching: filter) }
                    .padding(.horizontal, inset)
            }
            .contentMargins(.vertical, Space.block, for: .scrollContent)
            .defaultScrollAnchor(.topLeading)
        }
    }

}
