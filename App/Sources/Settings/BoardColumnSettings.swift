import SwiftUI
import TaskboardKit

/// 見せる値（`Key`）が同じなら描き直さない。`Redraw` で包むと Form が区分でなく 1 行として扱い、見出しと注記が枠の中に入るので、区分そのものを比べる
struct ColumnSection: View, Equatable {
    @Binding var draft: BoardSettingsDraft
    let counts: [String: Int]
    let compact: Bool
    private let shown: Key

    init(draft: Binding<BoardSettingsDraft>, counts: [String: Int], compact: Bool) {
        _draft = draft
        self.counts = counts
        self.compact = compact
        shown = Key(columns: draft.wrappedValue.columns.map { var shown = $0; shown.template = ""; return shown }, counts: counts, compact: compact)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.shown == b.shown }

    var body: some View {
        if compact {
            // iPhone は 1 列 1 区画にし、名前の欄を幅いっぱいに取る（1 行に並べると名前の欄が潰れた）
            // 1 列を 1 つの Equatable の区画にし、打っている列の区画だけを描き直す（区分ごと描き直すと、名前・説明の 1 字ごとに全部の列の区画が組み直された）。
            // `.equatable()` で包むと Form が区画を 1 行として扱い、見出しが枠の中に入るので、包まずに比べさせる
            ForEach($draft.columns, id: \.key) { $column in
                CompactColumnRow(
                    column: $column, count: count(column), isFirst: isFirst(column), isLast: isLast(column),
                    move: { move(column.key, by: $0) }, remove: { remove(column.key) }
                )
            }
            Section { addButton }
        } else {
            Section {
                Grid(alignment: .leading, horizontalSpacing: Space.block, verticalSpacing: Space.row) {
                    GridRow {
                        Text("名前")
                        Text("タスク数").gridColumnAlignment(.trailing)
                        Text("完了扱い").gridColumnAlignment(.center)
                        Text("折りたたむ").gridColumnAlignment(.center)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    .textRole(.caption)
                    ForEach($draft.columns, id: \.key) { $column in
                        GridRow {
                            TextField("名前", text: $column.label)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("列の名前")
                            Text("\(count(column))").monospacedDigit().foregroundStyle(count(column) == 0 ? .tertiary : .secondary)
                            Toggle("「\(column.label)」を完了扱いにする", isOn: Self.terminal($column))
                                .labelsHidden()
                                .disabled(column.standard)
                            Toggle("「\(column.label)」を折りたたむ", isOn: $column.collapsed)
                                .labelsHidden()
                            ColumnActions(column: column, isFirst: isFirst(column), isLast: isLast(column), move: { move(column.key, by: $0) }, remove: { remove(column.key) })
                                .labelStyle(.iconOnly)
                        }
                        GridRow {
                            MultilineTextField(label: String(localized: "「\(column.label)」の説明"), text: $column.description, lines: 1...4, style: .roundedBorder)
                                .fixedSize(horizontal: false, vertical: true)
                                .gridCellColumns(5)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                addButton
            } header: {
                Text("列")
            } footer: {
                Self.footer
            }
        }
    }

    /// 列の表が見せる値。列ごとの起動プロンプトは表に出さないので入れない（入れると 1 字打つたびに表が組み直される）
    struct Key: Equatable {
        let columns: [ColumnDraft]
        let counts: [String: Int]
        let compact: Bool
    }

    static var footer: some View {
        Text("上から順に、ボードの左から並びます。説明は、タスクに紐づいたセッションへの案内にも載ります。デフォルトの列は完了扱いを変更できず、「完了」は削除できません。")
    }

    /// 削除した既定の列があれば、新しい列と並べて戻す先を選べるメニューにする
    @ViewBuilder
    private var addButton: some View {
        let missing = draft.missingStandardColumns
        if missing.isEmpty {
            Button("列を追加", systemImage: "plus", action: addColumn)
        } else {
            Menu("列を追加", systemImage: "plus") {
                Button("新しい列", action: addColumn)
                Section("削除したデフォルトの列") {
                    ForEach(missing) { column in
                        Button(column.label) { draft.restore(column) }
                    }
                }
            }
            .fixedSize()
        }
    }

    private func addColumn() {
        draft.columns.append(ColumnDraft(id: nil, label: "", kind: .open, collapsed: false, standard: false, template: ""))
    }

    static func terminal(_ column: Binding<ColumnDraft>) -> Binding<Bool> {
        Binding(get: { column.wrappedValue.kind == .terminal }, set: { column.wrappedValue.kind = $0 ? .terminal : .open })
    }

    private func count(_ column: ColumnDraft) -> Int { column.id.flatMap { counts[$0] } ?? 0 }
    private func isFirst(_ column: ColumnDraft) -> Bool { draft.columns.first?.key == column.key }
    private func isLast(_ column: ColumnDraft) -> Bool { draft.columns.last?.key == column.key }

    private func move(_ key: UUID, by offset: Int) {
        guard let index = draft.columns.firstIndex(where: { $0.key == key }), draft.columns.indices.contains(index + offset) else { return }
        draft.columns.swapAt(index, index + offset)
    }

    private func remove(_ key: UUID) {
        draft.columns.removeAll { $0.key == key }
    }
}

/// iPhone の 1 列の区画。名前の欄を幅いっぱいに取る（1 行に並べると名前の欄が潰れた）。見せる値が同じなら描き直さない
private struct CompactColumnRow: View, Equatable {
    @Binding var column: ColumnDraft
    let count: Int
    let isFirst: Bool
    let isLast: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    private let shown: ColumnDraft

    init(column: Binding<ColumnDraft>, count: Int, isFirst: Bool, isLast: Bool, move: @escaping (Int) -> Void, remove: @escaping () -> Void) {
        _column = column
        self.count = count
        self.isFirst = isFirst
        self.isLast = isLast
        self.move = move
        self.remove = remove
        shown = column.wrappedValue
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.shown == b.shown && a.count == b.count && a.isFirst == b.isFirst && a.isLast == b.isLast
    }

    var body: some View {
        Section {
            LabeledTextField(label: String(localized: "名前"), text: $column.label)
            LabeledTextEditor(label: String(localized: "説明"), text: $column.description, lines: 2...6, monospaced: false)
            Toggle("完了扱い", isOn: ColumnSection.terminal($column)).disabled(column.standard)
            Toggle("折りたたむ", isOn: $column.collapsed)
            LabeledContent("タスク数", value: String(localized: "\(count)件"))
            // 3 つのボタンを 1 行に並べると、印と文字がどのボタンのものか読み取れなかった。移動は印だけ、削除は行にする
            LabeledContent("並び順") {
                HStack(spacing: Space.block) {
                    Button("上へ移動", systemImage: "chevron.up") { move(-1) }.disabled(isFirst).hitTarget()
                    Button("下へ移動", systemImage: "chevron.down") { move(1) }.disabled(isLast).hitTarget()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            // 「完了」は削除できない（注記に書いてある）ので、押せない行を出さない
            if column.removable {
                Button("列を削除", role: .destructive, action: remove)
            }
        } header: {
            if isFirst { Text("列") }
        } footer: {
            if isLast { ColumnSection.footer }
        }
    }
}

/// 列の並べ替えと削除。「完了」は削除できない
private struct ColumnActions: View {
    let column: ColumnDraft
    let isFirst: Bool
    let isLast: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Space.inline) {
            Button("上へ移動", systemImage: "chevron.up") { move(-1) }.disabled(isFirst).hitTarget()
            Button("下へ移動", systemImage: "chevron.down") { move(1) }.disabled(isLast).hitTarget()
            Button("列を削除", systemImage: "minus.circle", role: .destructive, action: remove)
                .disabled(!column.removable)
                .hitTarget()
                .help(column.removable ? String(localized: "列を削除") : String(localized: "「完了」の列は削除できません。"))
        }
        .buttonStyle(.borderless)
    }
}
