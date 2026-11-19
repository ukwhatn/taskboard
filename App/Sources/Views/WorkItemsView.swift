import SwiftUI
import TaskboardKit

/// 作業項目の状態の見せ方と名前。画面に出す状態の名前はここだけにある（Kit の `label` は MCP の出力のためのもの）。色は状態にだけ使う
enum WorkItemGlyph {
    static func symbol(_ state: WorkItem.EffectiveState) -> String {
        switch state {
        case .todo: "circle.dotted"
        case .ready: "circle"
        case .doing: "circle.lefthalf.filled"
        case .wait: "hourglass"
        case .done: "checkmark.circle.fill"
        case .drop: "xmark.circle"
        }
    }

    static func color(_ state: WorkItem.EffectiveState) -> Color {
        switch state {
        case .todo: .secondary
        case .ready: .primary
        case .doing: .green
        case .wait: .orange
        case .done: .blue
        case .drop: .secondary
        }
    }

    static func title(_ state: WorkItem.EffectiveState) -> String {
        switch state {
        case .todo: String(localized: "前の項目待ち")
        case .ready: String(localized: "未着手")
        case .doing: String(localized: "作業中")
        case .wait: String(localized: "待ち")
        case .done: String(localized: "完了")
        case .drop: String(localized: "見送り")
        }
    }

    static func waitColor(_ tone: WaitLine.Tone) -> AnyShapeStyle {
        switch tone {
        case .mine: AnyShapeStyle(Color.orange)
        case .theirs: AnyShapeStyle(.secondary)
        case .quiet: AnyShapeStyle(.tertiary)
        }
    }

    /// カードの 2 行目: 作業中の項目の題（複数なら数）。作業中が無ければ未着手の数
    static func progressLine(_ progress: TaskProgress) -> String? {
        switch progress.current.count {
        case 0: progress.ready > 0 ? String(localized: "未着手\(progress.ready)件") : nil
        case 1: progress.current[0].title
        default: String(localized: "\(progress.current.count)件を作業中")
        }
    }
}

extension WorkItem.State {
    /// 画面に出す状態（保存した状態の名前。依存を見ない）
    var display: WorkItem.EffectiveState {
        switch self {
        case .todo: .ready
        case .doing: .doing
        case .wait: .wait
        case .done: .done
        case .drop: .drop
        }
    }
}

/// 作業項目の絞り込み（文字と件数の付いた横並び）
enum WorkItemFilter: Hashable, CaseIterable {
    case all, open, doing, wait, done, drop

    var title: String {
        switch self {
        case .all: String(localized: "すべて")
        case .open: WorkItemGlyph.title(.ready)
        case .doing: WorkItemGlyph.title(.doing)
        case .wait: WorkItemGlyph.title(.wait)
        case .done: WorkItemGlyph.title(.done)
        case .drop: WorkItemGlyph.title(.drop)
        }
    }

    func matches(_ state: WorkItem.EffectiveState) -> Bool {
        switch self {
        case .all: true
        case .open: state == .todo || state == .ready
        case .doing: state == .doing
        case .wait: state == .wait
        case .done: state == .done
        case .drop: state == .drop
        }
    }
}

/// タスクの作業項目。上に絞り込み（4 件以上のとき）とまとまりごとの進み（まとまりがあるとき）、依存の段（`WorkItemGraphView`。絞り込んだときは計画順の一覧）、末尾に追加の欄。
/// 置かれた欄の余白に揃え、自分では左右の余白を持たない
struct WorkItemList: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    let items: [WorkItem]

    @TaskState private var filter: WorkItemFilter = .all
    @TaskState private var showsClosed = false
    @TaskState private var deleteTarget: WorkItem?

    /// 絞り込みを出す件数
    static let filterThreshold = 4

    var body: some View {
        let states = WorkItem.effectiveStates(of: items)
        let shown = items.filter { filter.matches(states[$0.itemID] ?? .todo) }
        let titles = Dictionary(items.filter { $0.state != .done && $0.state != .drop }.map { ($0.itemID, $0.codedTitle) }, uniquingKeysWith: { a, _ in a })
        let documents = Dictionary(model.fleet.documents(for: task.id).map { (String($0.docID), $0.displayTitle) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: Space.block) {
            if items.count >= Self.filterThreshold {
                FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
                    ForEach(WorkItemFilter.allCases, id: \.self) { option in
                        let count = items.filter { option.matches(states[$0.itemID] ?? .todo) }.count
                        if option == .all || option == filter || count > 0 {
                            ChipButton(text: "\(option.title)\(count)", selected: filter == option) { filter = option }
                                .accessibilityLabel("\(option.title)\(count)件")
                        }
                    }
                }
            }
            WorkGroupProgress(items: items)
            if items.isEmpty {
                Text("作業項目はありません").textRole(.secondary)
            } else if shown.isEmpty {
                Text("条件に合う作業項目はありません").textRole(.secondary)
            } else if filter == .all {
                WorkItemGraphView(graph: WorkItemGraph(items: items), showsClosed: $showsClosed) { row in
                    self.row(row.item, state: row.state, titles: titles, documents: documents)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: Space.row) {
                    ForEach(shown) { item in
                        row(item, state: states[item.itemID] ?? .todo, titles: titles, documents: documents)
                    }
                }
            }
            WorkItemAddField { title in
                model.addWorkItem(to: task, title: title)
                // 足した項目（未着手）が絞り込みで隠れないように
                if !filter.matches(.ready) && !filter.matches(.todo) { filter = .all }
            }
        }
        .confirmationDialog(
            "作業項目の削除", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible, presenting: deleteTarget
        ) { item in
            Button("削除", role: .destructive) { model.deleteWorkItem(item) }
            Button("キャンセル", role: .cancel) {}
        } message: { item in
            Text("「\(item.codedTitle)」を削除しますか？　この操作は元に戻せません。")
        }
    }

    /// `titles` は終わっていない項目の題（行の「〜の後」）、`documents` はタスクの文書の題（文書の id の文字 → 題。成果物のチップ）
    private func row(_ item: WorkItem, state: WorkItem.EffectiveState, titles: [Int64: String], documents: [String: String]) -> some View {
        WorkItemRow(
            item: item, state: state, waitsFor: state == .todo ? item.dependsOn.compactMap { titles[$0] } : [],
            deliverableTitle: item.deliverableKind == .doc ? documents[item.deliverableRef] : nil, task: task
        ) { request in
            model.updateWorkItem(item, request)
        } delete: {
            deleteTarget = item
        }
        // 1 件の状態が変わったときに、ほかの行まで描き直さない（閉じ処理を持つ行は、比べないと毎回変わったとみなされる）
        .equatable()
    }
}

/// 作業項目の追加の欄。打った文字は自分で持つ（一覧と段の線を打鍵のたびに組み直さない）
private struct WorkItemAddField: View {
    let add: (String) -> Void
    @TaskState private var title = ""

    var body: some View {
        HStack(spacing: Space.inline) {
            Image(systemName: "plus.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("作業項目のタイトル", text: $title)
                .textFieldStyle(.plain)
                .onSubmit(submit)
            Button("追加", action: submit)
                .controlSize(.small)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(minHeight: HitTarget.size)
    }

    private func submit() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        add(trimmed)
        title = ""
    }
}

/// 終わっていない作業項目を段ごとに上から並べ、左の溝に依存の線を引く。同じ段の項目は並行できる（段の見出しに数）。
/// 完了と見送りは末尾の 1 行に畳み、開くとその下に計画順で並べる（線は引かない）。段が 1 つ（依存が無い）なら見出しも線も無い。
/// 行は画面に出ているものだけを配置し（`LazyVStack`）、線は行ごとに自分の高さの分を引く（`WorkItemGraph.Row.marks`）
struct WorkItemGraphView<Row: View>: View {
    let graph: WorkItemGraph
    @Binding var showsClosed: Bool
    @ViewBuilder let row: (WorkItemGraph.Row) -> Row

    var body: some View {
        let gutter = WorkItemGraphMetrics.gutter(slots: graph.slotCount)
        let spacing = WorkItemGraphMetrics.spacing(slots: graph.slotCount)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(graph.rows) { item in
                // 行どうしの間も線がつながるよう、間は行の下の余白で取る
                VStack(alignment: .leading, spacing: Space.row) {
                    if let header = item.header {
                        Text(header.count > 1 ? "\(header.number)段目・\(header.count)件を並行" : "\(header.number)段目")
                            .textRole(.caption)
                            .accessibilityAddTraits(.isHeader)
                    }
                    row(item)
                }
                .padding(.bottom, Space.row)
                .padding(.leading, gutter)
                .backgroundPreferenceValue(WorkItemGlyphAnchors.self) { anchors in
                    if !item.marks.isEmpty, let glyph = anchors[item.id] {
                        GeometryReader { proxy in
                            let frame = proxy[glyph]
                            Canvas { context, size in Self.draw(item.marks, glyph: frame, size: size, spacing: spacing, in: &context) }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
            if !graph.closed.isEmpty {
                Button(
                    showsClosed ? "完了・見送りの\(graph.closed.count)件を非表示" : "完了・見送りの\(graph.closed.count)件を表示",
                    systemImage: showsClosed ? "chevron.down" : "chevron.right"
                ) { showsClosed.toggle() }
                .buttonStyle(.borderless)
                .font(.callout)
                .hitTarget()
                .padding(.leading, gutter)
                .padding(.bottom, Space.row)
                if showsClosed {
                    ForEach(graph.closed) { item in
                        row(item)
                            .padding(.bottom, Space.row)
                            .padding(.leading, gutter)
                    }
                }
            }
        }
    }

    /// 1 つの行の線。筋は状態の印の左に並び、出元は印から筋へ出て下へ、線の先は上から来て印の左の矢じりで止まる
    private static func draw(_ marks: [WorkItemGraph.LaneMark], glyph: CGRect, size: CGSize, spacing: CGFloat, in context: inout GraphicsContext) {
        let arrow = WorkItemGraphMetrics.arrow
        let y = glyph.midY
        for mark in marks {
            let x = glyph.minX - WorkItemGraphMetrics.laneInset - CGFloat(mark.slot) * spacing
            let radius = min(WorkItemGraphMetrics.corner, y, size.height - y)
            var path = Path()
            var head: Path?
            switch mark.kind {
            case .through:
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            case .source:
                path.move(to: CGPoint(x: glyph.minX, y: y))
                path.addLine(to: CGPoint(x: x + radius, y: y))
                path.addQuadCurve(to: CGPoint(x: x, y: y + radius), control: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: size.height))
            case .branch:
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: glyph.minX - arrow, y: y))
                head = arrowHead(at: CGPoint(x: glyph.minX, y: y), length: arrow)
            case .target:
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: y - radius))
                path.addQuadCurve(to: CGPoint(x: x + radius, y: y), control: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: glyph.minX - arrow, y: y))
                head = arrowHead(at: CGPoint(x: glyph.minX, y: y), length: arrow)
            }
            let color = Color.secondary.opacity(0.9)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: WorkItemGraphMetrics.line, lineCap: .round, lineJoin: .round))
            if let head { context.fill(head, with: .color(color)) }
        }
    }

    private static func arrowHead(at tip: CGPoint, length: CGFloat) -> Path {
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length, y: tip.y - length * 0.7))
        path.addLine(to: CGPoint(x: tip.x - length, y: tip.y + length * 0.7))
        path.closeSubpath()
        return path
    }
}

/// 行の状態の印の位置（項目の id ごと）。その行の依存の線の端に使う
struct WorkItemGlyphAnchors: PreferenceKey {
    static let defaultValue: [Int64: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int64: Anchor<CGRect>], nextValue: () -> [Int64: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 一覧の 1 行。左の状態を押すと完了と未着手を切り替え、長押しか右クリックで状態を選ぶ。題（全文）、右に担当。
/// 下に待ち理由・成果物・前の項目
struct WorkItemRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let item: WorkItem
    let state: WorkItem.EffectiveState
    /// まだ終わっていない前の項目の題（着手できないときだけ）
    let waitsFor: [String]
    /// 成果物が文書なら、その文書の題（無ければ文書の id を出す）
    let deliverableTitle: String?
    let task: BoardTask
    let update: (WorkItemUpdateRequest) -> Void
    let delete: () -> Void

    @State private var editingBlocker = false

    /// 閉じ処理は比べない（同じ項目には同じ操作）
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.state == b.state && a.waitsFor == b.waitsFor && a.deliverableTitle == b.deliverableTitle && a.task == b.task
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            Menu {
                stateMenu
            } label: {
                Image(systemName: WorkItemGlyph.symbol(state))
                    .foregroundStyle(WorkItemGlyph.color(state))
            } primaryAction: {
                update(WorkItemUpdateRequest(state: item.state == .done ? .todo : .done))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .hitTarget()
            .anchorPreference(key: WorkItemGlyphAnchors.self, value: .bounds) { [item.itemID: $0] }
            .accessibilityLabel("状態")
            .accessibilityValue(WorkItemGlyph.title(state))
            .accessibilityHint(item.state == .done ? "押すと未着手に戻します。長押しで状態を選べます" : "押すと完了にします。長押しで状態を選べます")
            VStack(alignment: .leading, spacing: Space.inline) {
                Text(item.codedTitle)
                    .strikethrough(state == .drop)
                    .foregroundStyle(state == .done || state == .drop ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let wait = item.waitLine {
                    Button { editingBlocker = true } label: { BlockerLine(wait: wait) }
                        .buttonStyle(.plain)
                        .help("待ち理由を編集")
                        .accessibilityHint("押すと待ち理由を編集できます")
                }
                if item.isManualWait {
                    ChipButton(text: String(localized: "対応済みにする")) { model.finishManualWork(item) }
                        .fixedSize()
                        .help("作業中に戻し、済んだことを会話に伝えます")
                }
                if !item.owner.isEmpty {
                    Label(item.owner, systemImage: "person.crop.circle")
                        .textRole(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.owner)
                        .accessibilityLabel("担当：\(item.owner)")
                }
                if let kind = item.deliverableKind {
                    DeliverableChip(item: item, kind: kind, documentTitle: deliverableTitle, task: task)
                }
                if !waitsFor.isEmpty {
                    Label(waitsFor.map { "「\($0)」" }.joined(separator: "・") + "の後", systemImage: "arrow.turn.down.right")
                        .textRole(.caption)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .contextMenu {
            stateMenu
            Divider()
            Button("削除", systemImage: "trash", role: .destructive, action: delete)
        }
        .popover(isPresented: $editingBlocker, arrowEdge: .leading) {
            BlockerEditor(item: item) { kind, text in
                update(WorkItemUpdateRequest(state: .wait, blockerKind: kind, blockerText: text))
                editingBlocker = false
            } cancel: {
                editingBlocker = false
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 状態の選択。「待ち」は理由の入力を開く
    @ViewBuilder
    private var stateMenu: some View {
        ForEach(WorkItem.State.allCases, id: \.self) { next in
            Button {
                if next == .wait { editingBlocker = true } else { update(WorkItemUpdateRequest(state: next)) }
            } label: {
                Label(next == .wait ? String(localized: "待ちにする…") : WorkItemGlyph.title(next.display), systemImage: WorkItemGlyph.symbol(next.display))
            }
            .disabled(next == item.state && next != .wait)
        }
    }
}

/// 待ち理由の入力。種類を横並びで選び、カードにそのまま出る 1 行を書く
struct BlockerEditor: View {
    private static let padding: CGFloat = 18
    let item: WorkItem
    let save: (WorkItem.BlockerKind, String) -> Void
    let cancel: () -> Void

    @State private var kind: WorkItem.BlockerKind
    @State private var text: String

    init(item: WorkItem, save: @escaping (WorkItem.BlockerKind, String) -> Void, cancel: @escaping () -> Void) {
        self.item = item
        self.save = save
        self.cancel = cancel
        _kind = State(initialValue: item.blockerKind ?? .external)
        _text = State(initialValue: item.blockerText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Text("待ち理由").textRole(.sectionTitle)
            VStack(alignment: .leading, spacing: Space.inline) {
                Text("種類").textRole(.caption)
                FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
                    ForEach(WorkItem.BlockerKind.allCases, id: \.self) { option in
                        ChipButton(text: Self.title(option), selected: kind == option) { kind = option }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.inline) {
                Text("カードに表示する文").textRole(.caption)
                MultilineTextField(
                    label: String(localized: "カードに表示する文"), text: $text, lines: 1...3, style: .roundedBorder, newlineOnShiftReturn: false,
                    submit: { save(kind, trimmed) })
                Text("空欄のときは種類の名前を表示します。例：先方の回答待ち")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(item.state == .wait ? "保存" : "待ちにする") { save(kind, trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Self.padding)
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 待ち理由の種類の名前（画面の表はここだけ）
    static func title(_ kind: WorkItem.BlockerKind) -> String {
        switch kind {
        case .approval: String(localized: "承認・回答")
        case .manual: String(localized: "手作業")
        case .review: String(localized: "レビュー")
        case .ci: String(localized: "CI")
        case .deploy: String(localized: "デプロイ")
        case .item: String(localized: "別の項目")
        case .external: String(localized: "外部")
        }
    }
}

struct BlockerLine: View {
    let wait: WaitLine

    var body: some View {
        Label(wait.text, systemImage: wait.tone == .mine ? "hand.raised.fill" : "hourglass")
            .font(.caption)
            .foregroundStyle(WorkItemGlyph.waitColor(wait.tone))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 作業項目の成果物。PR はタスクの PR の節で中身を出し（タスクに無い PR は GitHub）、文書は文書の画面を開く
struct DeliverableChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: WorkItem
    let kind: WorkItem.DeliverableKind
    /// 文書の題（成果物が文書のとき。行が比べる値に入れるので、外から渡す）
    let documentTitle: String?
    let task: BoardTask

    var body: some View {
        let chip = Chip(text: title, symbol: symbol)
        switch kind {
        case .pr:
            Button {
                if task.pullRequestLinks.contains(where: { $0.url == item.deliverableRef }) {
                    model.show(pr: item.deliverableRef)
                } else if let url = URL(string: item.deliverableRef), url.scheme != nil {
                    openURL(url)
                }
            } label: { chip }
            .buttonStyle(.plain)
            .help("PRの中身を見る")
        case .doc:
            if let id = Int64(item.deliverableRef) {
                Button { model.navigate(to: .doc(DocKey(machine: item.machine, id: id)), from: .link) } label: { chip }
                    .buttonStyle(.plain)
                    .help("文書を開く")
            } else {
                chip
            }
        case .commit, .file:
            chip.textSelection(.enabled).help(item.deliverableRef)
        }
    }

    private var title: String {
        switch kind {
        case .pr: TaskLink(id: 0, url: item.deliverableRef, kind: .githubPR, addedAt: .distantPast).shortLabel
        case .commit: String(item.deliverableRef.prefix(7))
        case .file: (item.deliverableRef as NSString).lastPathComponent
        case .doc: documentTitle ?? item.deliverableRef
        }
    }

    private var symbol: String {
        switch kind {
        case .pr: "arrow.triangle.pull"
        case .commit: "number"
        case .file: "doc"
        case .doc: "doc.text"
        }
    }
}

/// まとまり（work_add の group）ごとの「済んだ数 / 全部」を 1 行に並べる。今のまとまりは太字。まとまりの無い計画では出さない
private struct WorkGroupProgress: View {
    let items: [WorkItem]

    var body: some View {
        let groups = WorkPlan.groups(items)
        if groups.contains(where: { !$0.name.isEmpty }) {
            FlowRow(spacing: Space.row, lineSpacing: Space.inline) {
                ForEach(groups) { group in
                    Text(verbatim: "\(group.name.isEmpty ? String(localized: "まとまりなし") : group.name) \(group.fractionLabel)")
                        .textRole(.caption)
                        .monospacedDigit()
                        .fontWeight(group.isCurrent ? .semibold : nil)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
