import SwiftUI
import TaskboardKit

/// 1 列。見出し（列の名前と件数）と、カードを縦に並べる。カードは lazy にしない（lazy にすると、作ったカードの分しか高さを測らず、
/// 列と帯の高さが実際より低く決まる。docs/ui-system.md「使わない書き方」）。数は `limit` で抑える
struct BoardColumnView: View {
    @Environment(AppModel.self) private var model
    let board: Board
    let column: BoardColumn
    let tasks: [BoardTask]
    /// 1 列に出すカードの数。残りは「さらにN件」で開く。nil なら全部
    var limit: Int?

    @State private var showsAll = false
    @State private var dropTargeted = false

    var body: some View {
        let shown = showsAll ? tasks : Array(tasks.prefix(limit ?? tasks.count))
        VStack(alignment: .leading, spacing: Space.row) {
            HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                Text(column.label).textRole(.sectionTitle)
                Text(tasks.count, format: .number).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ForEach(shown) { task in
                TaskCardButton(task: task, signals: model.cardSignals(for: task), scheduleName: model.schedule(forTask: task.id)?.name)
                    .equatable()
                    .id(task.id)
            }
            if tasks.isEmpty {
                // 落とせる場所を示す。数は見出しにある
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(height: HitTarget.size * 2)
                    .accessibilityLabel("タスクはありません")
            }
            if let limit, tasks.count > limit {
                Button(showsAll ? "折りたたむ" : "さらに\(tasks.count - limit)件") {
                    showsAll.toggle()
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .hitTarget()
            }
        }
        .frame(width: BoardMetrics.columnWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            if let limit, tasks.count > limit, !showsAll {
                HiddenCardReveal(hidden: Set(tasks.dropFirst(limit).map(\.id)), showsAll: $showsAll)
            }
        }
        .background(dropTargeted ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .dropDestination(for: String.self) { payloads, _ in
            var moved = false
            for payload in payloads {
                guard let key = TaskDrag.key(from: payload), key.machine == board.machine, let task = model.fleet.task(for: key) else { continue }
                if task.boardID != board.id {
                    model.move(task: task, toBoard: board, column: column.id)
                } else if task.columnID != column.id {
                    model.move(task: task, to: column.id)
                }
                moved = true
            }
            return moved
        } isTargeted: { dropTargeted = $0 }
    }
}

/// キーで選んだカードが「さらにN件」の中なら開く。カーソルを読むのはこのビューだけ（列の body で読むと、カーソルを動かすたびに全列を作り直す）
private struct HiddenCardReveal: View {
    @Environment(AppModel.self) private var model
    let hidden: Set<TaskKey>
    @Binding var showsAll: Bool

    var body: some View {
        Color.clear.onChange(of: model.cursorTask) { _, key in
            if let key, hidden.contains(key) { showsAll = true }
        }
    }
}

/// 1 案件の列を横に並べる。列の高さは揃え（いちばん高い列に合わせる）、どの列も下まで落とせる場所にする。
/// 「初めから畳む」列が続くところは 1 本の帯にまとめ、押すと列ごとに開く
struct BoardColumnsRow: View {
    let board: Board
    let tasks: [BoardTask]
    /// 開いた帯（先頭の列 id）
    @Binding var expanded: Set<String>
    var limit: Int?
    var filter: ([BoardTask]) -> [BoardTask] = { $0 }

    var body: some View {
        HStack(alignment: .top, spacing: Space.block) {
            ForEach(BoardColumnSegment.segments(board.columns)) { segment in
                switch segment {
                case .column(let column):
                    // 列は 1 回に 1 本ずつ組む（本番の量の案件で、列を全部 1 回で組むと主スレッドが 100 ms を超えて止まった）。
                    // first にするのは、全案件の画面で帯 1 本の列を組み終えてから次の帯（later）を組ませるため
                    DeferredMount {
                        BoardColumnView(board: board, column: column, tasks: filter(tasks.filter { $0.columnID == column.id }), limit: limit)
                    }
                case .folded(let columns):
                    FoldedColumnsView(
                        board: board, columns: columns, tasks: tasks,
                        expanded: Binding(
                            get: { expanded.contains(columns[0].id) },
                            set: { if $0 { expanded.insert(columns[0].id) } else { expanded.remove(columns[0].id) } }),
                        limit: limit, filter: filter)
                }
            }
        }
        // 高さを中身で決めたうえで、列に同じ高さを配る
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 列の並びを、そのまま出す列と、畳んで 1 本にする列の続きに分ける
enum BoardColumnSegment: Identifiable, Hashable {
    case column(BoardColumn)
    case folded([BoardColumn])

    var id: String {
        switch self {
        case .column(let column): "column:\(column.id)"
        case .folded(let columns): "folded:\(columns[0].id)"
        }
    }

    static func segments(_ columns: [BoardColumn]) -> [BoardColumnSegment] {
        var result: [BoardColumnSegment] = []
        for column in columns.sorted(by: { $0.position < $1.position }) {
            if column.collapsed {
                if case .folded(let run) = result.last {
                    result[result.count - 1] = .folded(run + [column])
                } else {
                    result.append(.folded([column]))
                }
            } else {
                result.append(.column(column))
            }
        }
        return result
    }

    /// 列の並び（`BoardColumnsRow`）の幅。`expanded` は開いた帯の先頭の列 id。全体のボードは、組む前の帯の幅をこれで知る
    static func rowWidth(_ columns: [BoardColumn], expanded: Set<String>) -> CGFloat {
        let widths = segments(columns).flatMap { segment -> [CGFloat] in
            switch segment {
            case .column: [BoardMetrics.columnWidth]
            case .folded(let run) where expanded.contains(run[0].id): Array(repeating: BoardMetrics.columnWidth, count: run.count) + [HitTarget.size]
            case .folded: [BoardMetrics.foldedWidth]
            }
        }
        return widths.reduce(0, +) + Space.block * CGFloat(max(widths.count - 1, 0))
    }
}

/// 畳んだ列の帯。開くと列ごとに並ぶ
struct FoldedColumnsView: View {
    let board: Board
    let columns: [BoardColumn]
    let tasks: [BoardTask]
    @Binding var expanded: Bool
    var limit: Int?
    var filter: ([BoardTask]) -> [BoardTask] = { $0 }

    var body: some View {
        if expanded {
            ForEach(columns) { column in
                BoardColumnView(board: board, column: column, tasks: filter(tasks.filter { $0.columnID == column.id }), limit: limit)
            }
            Button("折りたたむ", systemImage: "chevron.left") { expanded = false }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: HitTarget.size)
                .hitTarget()
        } else {
            Button {
                expanded = true
            } label: {
                VStack(spacing: Space.row) {
                    ForEach(columns) { column in
                        HStack(spacing: Space.inline) {
                            Text(column.label).lineLimit(1)
                            Text(tasks.filter { $0.columnID == column.id }.count, format: .number).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(Space.row)
                .frame(width: BoardMetrics.foldedWidth)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(columns.map(\.label).joined(separator: "、"))を展開")
        }
    }
}
