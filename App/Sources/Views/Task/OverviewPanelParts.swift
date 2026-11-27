import Charts
import SwiftUI
import TaskboardKit

/// 会話が登録した概況の部品。会話の並びのまま置き、続く計器は 1 つの格子にまとめる。会話は意味だけを渡し、
/// 色・書体・余白はここで ChatPalette・Space・Radius から当てる（強い色は attention と failed だけ）。
/// 会話が 2 ターン以上更新していない部品は更新の時刻を補足に出す
struct OverviewPanelParts: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    let panel: OverviewPanel

    private enum Block: Identifiable {
        case gauges([PanelPart])
        case part(PanelPart)

        var id: String {
            switch self {
            case .gauges(let parts): "gauges-" + (parts.first?.id ?? "")
            case .part(let part): part.id
            }
        }
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        for part in panel.parts {
            if case .gauge = part.spec.content {
                if case .gauges(let run) = blocks.last {
                    blocks[blocks.count - 1] = .gauges(run + [part])
                    continue
                }
                blocks.append(.gauges([part]))
            } else {
                blocks.append(.part(part))
            }
        }
        return blocks
    }

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("OverviewPanelParts")
        #endif
        let state = model.fleet.machineState(for: task.machine)
        ForEach(blocks) { block in
            switch block {
            case .gauges(let parts):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: OverviewMetrics.gaugeMinWidth), spacing: Space.row, alignment: .top)], spacing: Space.row) {
                    ForEach(parts) { part in
                        if case .gauge(let gauge) = part.spec.content {
                            PanelGaugeCard(gauge: state?.resolve(part.spec, task: task)?.gauge ?? gauge, staleAt: staleAt(part))
                        }
                    }
                }
            case .part(let part):
                PanelPartSection(task: task, part: part, resolved: state?.resolve(part.spec, task: task), staleAt: staleAt(part))
            }
        }
    }

    private func staleAt(_ part: PanelPart) -> Date? { panel.isStale(part) ? part.updatedAt : nil }
}

/// 計器以外の部品 1 つ。題があれば節の見出しにし、古い部品は見出しの右に更新の時刻を出す
struct PanelPartSection: View {
    let task: BoardTask
    let part: PanelPart
    let resolved: PanelResolved?
    let staleAt: Date?

    var body: some View {
        let title = Self.title(part.spec.content)
        VStack(alignment: .leading, spacing: Space.block) {
            if !title.isEmpty || staleAt != nil {
                HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                    if !title.isEmpty { Text(verbatim: title).textRole(.sectionTitle).accessibilityAddTraits(.isHeader) }
                    if let staleAt { PanelUpdatedLabel(at: staleAt) }
                }
            }
            PanelPartContent(task: task, part: part, resolved: resolved)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func title(_ content: PanelContent) -> String {
        switch content {
        case .gauge(let v): v.label
        case .table(let v): v.title
        case .plan(let v): v.title.isEmpty ? String(localized: "計画") : v.title
        case .diagram(let v): v.title
        case .chart(let v): v.title
        case .draft(let v): v.title.isEmpty ? String(localized: "送る文面") : v.title
        case .html(let v): v.title
        }
    }
}

/// 部品の中身（見出しを除く）。種類ごとの描き手に振り分ける
struct PanelPartContent: View {
    let task: BoardTask
    let part: PanelPart
    let resolved: PanelResolved?

    var body: some View {
        switch part.spec.content {
        case .gauge: EmptyView()
        case .table(let table):
            PanelTableView(machine: task.machine, columns: resolved?.columns ?? table.columns, rows: resolved?.rows ?? table.rows)
        case .plan:
            PanelPlanView(groups: resolved?.plan ?? [])
        case .diagram(let diagram):
            PanelDiagramView(machine: task.machine, diagram: diagram)
        case .chart(let chart):
            PanelChartView(chart: chart)
        case .draft(let draft):
            PanelDraftView(task: task, part: part, draft: draft)
                .id("\(part.id)-\(part.updatedAt.timeIntervalSince1970)")
        case .html(let html):
            PanelHTMLView(html: html.html)
        }
    }
}

/// 古い部品の更新の時刻（補足の色）
struct PanelUpdatedLabel: View {
    let at: Date

    var body: some View {
        Text("\(at.formatted(date: .omitted, time: .shortened))更新").textRole(.caption).monospacedDigit()
    }
}

// MARK: - 状態の種類の見た目

extension PanelTone {
    /// 行と札の印。neutral は印を出さない。強い色は attention と failed だけ
    var mark: (symbol: String, color: Color, label: String)? {
        switch self {
        case .attention: ("exclamationmark.circle.fill", ChatPalette.warning, String(localized: "対応待ち"))
        case .failed: ("xmark.octagon.fill", ChatPalette.danger, String(localized: "失敗"))
        case .waiting: ("clock", ChatPalette.mutedText, String(localized: "相手待ち"))
        case .done: ("checkmark.circle", ChatPalette.mutedText, String(localized: "済み"))
        case .ok: ("checkmark", ChatPalette.secondaryText, String(localized: "順調"))
        case .neutral: nil
        }
    }

    /// 値の文字の色。基準の外（attention・failed）だけ色を付ける
    var valueColor: Color {
        switch self {
        case .attention: ChatPalette.warningText
        case .failed: ChatPalette.dangerText
        case .done, .waiting: ChatPalette.secondaryText
        case .ok, .neutral: ChatPalette.text
        }
    }

    var barColor: Color {
        switch self {
        case .attention: ChatPalette.warning
        case .failed: ChatPalette.danger
        case .ok, .neutral, .waiting, .done: ChatPalette.secondaryText
        }
    }
}

extension PanelSymbol {
    var systemImage: String {
        switch self {
        case .check: "checkmark.circle"
        case .clock: "clock"
        case .person: "person"
        case .people: "person.2"
        case .document: "doc.text"
        case .chart: "chart.bar"
        case .flag: "flag"
        case .warning: "exclamationmark.triangle"
        case .calendar: "calendar"
        case .link: "link"
        case .pullRequest: "arrow.triangle.pull"
        case .bug: "ladybug"
        case .gear: "gearshape"
        case .mail: "envelope"
        case .chat: "bubble.left"
        case .lock: "lock"
        case .money: "yensign.circle"
        case .server: "server.rack"
        case .test: "testtube.2"
        case .deploy: "shippingbox"
        }
    }
}

struct ToneMark: View {
    let tone: PanelTone?
    let symbol: PanelSymbol?

    var body: some View {
        if let mark = tone?.mark {
            Image(systemName: mark.symbol).foregroundStyle(mark.color).accessibilityLabel(mark.label)
        } else if let symbol {
            Image(systemName: symbol.systemImage).foregroundStyle(.secondary).accessibilityHidden(true)
        } else {
            // 表の格子で、印の無い行も印の列を 1 つ取る（取らないと後ろのセルが 1 列ずつ前へずれる）
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// 基準に対する値のバー（色だけに頼らず、値と基準の文字を並べて出す）
private struct PanelBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ChatPalette.fillStrong)
                Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: OverviewMetrics.barHeight)
        .accessibilityHidden(true)
    }
}

// MARK: - 計器

private struct PanelGaugeCard: View {
    let gauge: PanelGauge
    let staleAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inline) {
            HStack(spacing: Space.inline) {
                ToneMark(tone: gauge.tone == .neutral ? nil : gauge.tone, symbol: gauge.symbol)
                Text(verbatim: gauge.label).textRole(.caption)
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                Text(verbatim: gauge.value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(gauge.tone.valueColor)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let basis = gauge.basis { Text(verbatim: PanelGaugeText.basis(basis)).textRole(.caption).monospacedDigit() }
            }
            if let amount = gauge.amount, let total = gauge.basis?.amount, total > 0, [.denominator, .limit].contains(gauge.basis?.kind) {
                PanelBar(fraction: amount / total, color: gauge.tone.barColor)
            }
            if !gauge.note.isEmpty { Text(verbatim: gauge.note).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            if let staleAt { PanelUpdatedLabel(at: staleAt) }
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 表

private struct PanelTableView: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID
    let columns: [String]
    let rows: [PanelRow]
    @State private var expanded = false

    var body: some View {
        let shown = expanded ? rows : Array(rows.prefix(PanelBudget.shownRows))
        let marked = rows.contains { $0.tone != nil || $0.symbol != nil }
        let opens = rows.contains { $0.open != nil }
        VStack(alignment: .leading, spacing: Space.row) {
            if rows.isEmpty {
                Text("該当する行はありません").textRole(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.block, verticalSpacing: Space.row) {
                    GridRow {
                        if marked { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            Text(verbatim: column).textRole(.caption).lineLimit(1).fixedSize(horizontal: Self.keepsWhole(column), vertical: true)
                        }
                        if opens { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            if marked { ToneMark(tone: row.tone, symbol: row.symbol) }
                            ForEach(Array(columns.indices), id: \.self) { index in
                                let cell = index < row.cells.count ? row.cells[index] : ""
                                let token = Self.keepsWhole(cell)
                                Text(verbatim: cell)
                                    .font(.callout).lineLimit(token ? 1 : 3).fixedSize(horizontal: token, vertical: true)
                                    // 長い文のセルは、余った幅まで広げてから折り返す（広げないと右に幅が余ったまま 3 行に折れた）
                                    .frame(maxWidth: token ? nil : .infinity, alignment: .leading)
                            }
                            if opens {
                                if let target = row.open {
                                    Button { model.openPanelTarget(target, machine: machine) } label: { Image(systemName: "arrow.up.right") }
                                        .buttonStyle(.borderless).hitTarget().accessibilityLabel("開く")
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                        .opacity(row.tone == .done ? OverviewMetrics.doneOpacity : 1)
                    }
                }
                if !expanded, rows.count > PanelBudget.shownRows {
                    Button("ほか\(rows.count - PanelBudget.shownRows)件") { expanded = true }
                        .buttonStyle(.borderless).font(.callout).hitTarget()
                }
            }
        }
    }

    /// 6 字以内の語（下書き・実行中）と英数字だけの短いセル（SHOP-128・storefront#412）。iPhone の幅で語の途中で折れないよう、列の幅を詰めずに 1 行で出す
    static func keepsWhole(_ cell: String) -> Bool {
        !cell.isEmpty && (cell.count <= 6 || (cell.count <= PanelBudget.cellChars && cell.unicodeScalars.allSatisfy(\.isASCII)))
    }
}

// MARK: - 計画

/// 作業項目のまとまりごとの計画。今のまとまりだけを開き、ほかは「名前 済み / 全部」の 1 行に折りたたむ（押すと開く）。済んだ項目は薄くする
struct PanelPlanView: View {
    let groups: [WorkPlanGroup]
    @State private var opened: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            if groups.isEmpty { Text("作業項目はありません").textRole(.secondary) }
            ForEach(groups) { group in
                if group.isCurrent || opened.contains(group.id) {
                    VStack(alignment: .leading, spacing: Space.row) {
                        header(group, open: true)
                        PanelBar(fraction: group.total > 0 ? Double(group.done) / Double(group.total) : 0, color: ChatPalette.secondaryText)
                        ForEach(group.items) { item in PlanItemRow(item: item) }
                    }
                } else {
                    header(group, open: false)
                }
            }
        }
    }

    private func header(_ group: WorkPlanGroup, open: Bool) -> some View {
        Button {
            guard !group.isCurrent else { return }
            if opened.contains(group.id) { opened.remove(group.id) } else { opened.insert(group.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                if !group.isCurrent { Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary) }
                Text(verbatim: group.name.isEmpty ? String(localized: "まとまりなし") : group.name).font(.callout.weight(.semibold))
                Text(verbatim: group.fractionLabel).textRole(.caption).monospacedDigit()
                if group.isFinished { Text("済み").textRole(.caption) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(group.isFinished && !open ? OverviewMetrics.doneOpacity : 1)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct PlanItemRow: View {
    let item: WorkItem

    var body: some View {
        let done = item.state == .done || item.state == .drop
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            Text(verbatim: item.code).font(.caption.monospaced()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title).font(.callout).strikethrough(item.state == .drop).fixedSize(horizontal: false, vertical: true)
                if let wait = item.waitLine { Text(verbatim: wait.text).textRole(.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.label(item)).textRole(.caption)
        }
        .opacity(done ? OverviewMetrics.doneOpacity : 1)
        .accessibilityElement(children: .combine)
    }

    static func label(_ item: WorkItem) -> String {
        switch item.state {
        case .todo: String(localized: "未着手")
        case .doing: String(localized: "作業中")
        case .wait: String(localized: "待ち")
        case .done: String(localized: "完了")
        case .drop: String(localized: "見送り")
        }
    }
}

// MARK: - 図

private struct PanelDiagramView: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID
    let diagram: PanelDiagram

    var body: some View {
        switch diagram.style {
        case .flow: flow
        case .timeline: timeline
        case .compare: compare
        case .relation: relation
        }
    }

    /// 段の並び（左から右へ、入らなければ折り返す）
    private var flow: some View {
        FlowRow(spacing: Space.inline, lineSpacing: Space.row) {
            ForEach(Array(diagram.nodes.enumerated()), id: \.offset) { index, node in
                HStack(spacing: Space.inline) {
                    if index > 0 { Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true) }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Space.inline) {
                            ToneMark(tone: node.tone, symbol: nil)
                            Text(verbatim: node.label).font(.callout.weight(node.tone == .attention || node.tone == .failed ? .semibold : .regular))
                        }
                        if !node.note.isEmpty { Text(verbatim: node.note).textRole(.caption) }
                    }
                    .padding(.horizontal, Space.row)
                    .padding(.vertical, Space.inline)
                    .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Radius.box, style: .continuous))
                    .opacity(node.tone == .done ? OverviewMetrics.doneOpacity : 1)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// 時点つきの出来事を上から順に
    private var timeline: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.row, verticalSpacing: Space.row) {
            ForEach(Array(diagram.nodes.enumerated()), id: \.offset) { _, node in
                GridRow {
                    Text(verbatim: node.at).font(.caption.monospaced()).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Image(systemName: node.tone.flatMap(\.mark)?.symbol ?? "circle.fill").font(.caption2)
                        .foregroundStyle(node.tone.flatMap(\.mark)?.color ?? ChatPalette.mutedText)
                        .accessibilityLabel(node.tone.flatMap(\.mark)?.label ?? "")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: node.label).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if !node.note.isEmpty { Text(verbatim: node.note).textRole(.caption) }
                    }
                }
                .opacity(node.tone == .done ? OverviewMetrics.doneOpacity : 1)
            }
        }
    }

    /// 選択肢の比較。推奨の行に［推奨］の札と地の色を付ける（色だけに頼らない）
    private var compare: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.block, verticalSpacing: Space.row) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(Array(diagram.columns.enumerated()), id: \.offset) { _, column in Text(verbatim: column).textRole(.caption) }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(diagram.nodes.enumerated()), id: \.offset) { _, node in
                GridRow {
                    HStack(spacing: Space.inline) {
                        Text(verbatim: node.label).font(.callout.weight(node.recommended ? .semibold : .regular))
                        if node.recommended { Chip(text: String(localized: "推奨")) }
                    }
                    ForEach(Array(node.values.enumerated()), id: \.offset) { _, value in Text(verbatim: value).font(.callout) }
                }
                .padding(.vertical, 2)
                .background(node.recommended ? ChatPalette.fill : Color.clear)
            }
        }
    }

    /// 関係。辺ごとに「始点 → 終点（ラベル）」の行。辺に出ない点は末尾に並べる
    private var relation: some View {
        let labels = Dictionary(diagram.nodes.map { ($0.id.isEmpty ? $0.label : $0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let linked = Set(diagram.edges.flatMap { [$0.from, $0.to] })
        return VStack(alignment: .leading, spacing: Space.row) {
            ForEach(Array(diagram.edges.enumerated()), id: \.offset) { _, edge in
                HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                    node(labels[edge.from])
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary).accessibilityLabel(edge.label.isEmpty ? "から" : edge.label)
                    node(labels[edge.to])
                    if !edge.label.isEmpty { Text(verbatim: edge.label).textRole(.caption) }
                }
            }
            ForEach(diagram.nodes.filter { !linked.contains($0.id.isEmpty ? $0.label : $0.id) }, id: \.label) { self.node($0) }
        }
    }

    @ViewBuilder
    private func node(_ node: PanelNode?) -> some View {
        if let node {
            HStack(spacing: Space.inline) {
                ToneMark(tone: node.tone, symbol: nil)
                Text(verbatim: node.label).font(.callout)
            }
            .padding(.horizontal, Space.row)
            .padding(.vertical, 2)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }
}

// MARK: - グラフ

/// 棒・折れ線。系列の色は利用状況のグラフと同じ決まった順（`UsageChartPalette`）、基準の線は補足の色の破線。
/// 2 系列以上で凡例を出し、押した・載せた点の値を出す
private struct PanelChartView: View {
    let chart: PanelChart
    @State private var selected: String?

    private struct Point: Identifiable {
        var series: String
        var x: String
        var y: Double
        var id: String { "\(series)/\(x)" }
    }

    var body: some View {
        let names = chart.series.enumerated().map { $0.element.name.isEmpty ? String(localized: "系列\($0.offset + 1)") : $0.element.name }
        let points = chart.series.enumerated().flatMap { index, series in series.points.map { Point(series: names[index], x: $0.x, y: $0.y) } }
        let colors = UsageChartPalette.colors(names.count)
        Chart {
            ForEach(points) { point in
                switch chart.style {
                case .bar:
                    BarMark(x: .value("x", point.x), y: .value("y", point.y))
                        .foregroundStyle(by: .value("系列", point.series))
                        .position(by: .value("系列", point.series))
                        .cornerRadius(Radius.chip)
                case .line:
                    LineMark(x: .value("x", point.x), y: .value("y", point.y))
                        .foregroundStyle(by: .value("系列", point.series))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("x", point.x), y: .value("y", point.y))
                        .foregroundStyle(by: .value("系列", point.series))
                        .symbolSize(30)
                }
            }
            if let target = chart.target {
                RuleMark(y: .value("基準", target))
                    .foregroundStyle(ChatPalette.mutedText)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(verbatim: chart.targetLabel.isEmpty ? Self.number(target, unit: chart.unit) : chart.targetLabel).textRole(.caption)
                    }
            }
            if let selected {
                RuleMark(x: .value("x", selected))
                    .foregroundStyle(ChatPalette.fillStronger)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: selected).textRole(.caption)
                            ForEach(points.filter { $0.x == selected }) { point in
                                Text(verbatim: (names.count > 1 ? "\(point.series) " : "") + Self.number(point.y, unit: chart.unit)).font(.caption.weight(.semibold))
                            }
                        }
                        .padding(Space.inline)
                        .background(ChatPalette.raised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartLegend(names.count > 1 ? .visible : .hidden)
        .chartXSelection(value: $selected)
        .chartYAxisLabel(chart.unit)
        .frame(height: OverviewMetrics.chartHeight)
    }

    static func number(_ value: Double, unit: String) -> String {
        let text = value.rounded() == value ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(0...2)))
        return text + unit
    }
}

// MARK: - 送る文面

/// 宛先・本文・検査の結果。人は本文を編集してから［承認］し、承認と本文は会話に届く（送るのは会話）。承認の後は本文を読むだけにする
private struct PanelDraftView: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    let part: PanelPart
    let draft: PanelDraft
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Text("宛先：\(draft.to)").textRole(.secondary)
            if let answer = part.answer {
                Text(verbatim: answer.body).textRole(.body).textSelection(.enabled)
                Label(
                    answer.edited
                        ? String(localized: "編集した本文で承認済み（\(answer.answeredAt.formatted(date: .omitted, time: .shortened))）")
                        : String(localized: "承認済み（\(answer.answeredAt.formatted(date: .omitted, time: .shortened))）"),
                    systemImage: "checkmark.circle"
                )
                .textRole(.caption)
            } else {
                MultilineTextField(label: String(localized: "本文"), text: $text, lines: 4...16, style: .roundedBorder)
                    .disabled(!model.canWrite(task.machine))
                if !draft.checks.isEmpty {
                    FlowRow(spacing: Space.block, lineSpacing: Space.inline) {
                        ForEach(Array(draft.checks.enumerated()), id: \.offset) { _, check in
                            HStack(spacing: Space.inline) {
                                Image(systemName: check.ok ? "checkmark" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(check.ok ? ChatPalette.secondaryText : ChatPalette.warning)
                                Text(verbatim: check.note.isEmpty ? check.label : "\(check.label)：\(check.note)").textRole(.caption)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(check.ok ? "\(check.label)、問題なし" : "\(check.label)、要確認")
                        }
                    }
                }
                HStack(spacing: Space.row) {
                    Button("承認") { model.approvePanelDraft(task: task, part: part.id, body: text) }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canWrite(task.machine))
                    if text != draft.body {
                        Button("元の本文に戻す") { text = draft.body }
                    }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DraftCard(open: part.answer == nil))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = draft.body
        }
    }
}

/// 承認を待つ文面は対応待ちのカード、承認した後は通常の囲み
private struct DraftCard: ViewModifier {
    let open: Bool

    func body(content: Content) -> some View {
        if open {
            content.attentionCard()
        } else {
            content
                .padding(Space.card)
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }
}

// MARK: - 自由の部品（HTML）

/// 文書と同じく外部の読み込みを止めた WKWebView に、アプリの CSS 変数と基本のクラスを付けて載せる。高さは中身に合わせる
private struct PanelHTMLView: View {
    let html: String
    @State private var web = DocumentWebController(tracksCurrent: false)

    var body: some View {
        DocumentWebView(controller: web)
            .frame(height: min(max(web.contentHeight, OverviewMetrics.htmlHeight.lowerBound), OverviewMetrics.htmlHeight.upperBound))
            .clipShape(RoundedRectangle(cornerRadius: Radius.box, style: .continuous))
            .onAppear { web.load(page: PanelHTMLPage.page(html)) }
            .onChange(of: html) { web.load(page: PanelHTMLPage.page(html)) }
    }
}

/// 自由の部品の頁。色は ChatPalette、余白は Space、角丸は Radius と同じ値を CSS 変数にする（会話へ送る説明は Prompts/ja/panel-parts.md）
@MainActor
enum PanelHTMLPage {
    static func page(_ body: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\">\(DocumentWebController.viewport)<meta name=\"color-scheme\" content=\"light dark\"><style>\(style)</style></head><body>\(body)</body></html>"
    }

    private static func css(_ rgb: UInt32, _ opacity: Double = 1) -> String {
        let r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF
        return opacity == 1 ? String(format: "#%06X", rgb) : "rgba(\(r),\(g),\(b),\(opacity))"
    }

    private static func variables(dark: Bool) -> String {
        let tones: [(String, ChatTone)] = [
            ("text", .text), ("secondary", .secondaryText), ("muted", .mutedText), ("surface", .surface), ("raised", .raised), ("fill", .fill),
            ("border", .fillStrong), ("accent", .accent), ("attention", .warning), ("attention-text", .warningText), ("failed", .danger),
            ("failed-text", .dangerText),
        ]
        return tones.map { name, tone in "--tb-\(name):\(css(dark ? tone.dark : tone.light, tone.opacity))" }.joined(separator: ";")
    }

    static let style: String = {
        let spaces = "--tb-space-inline:\(Int(Space.inline))px;--tb-space-row:\(Int(Space.row))px;--tb-space-block:\(Int(Space.block))px;--tb-space-section:\(Int(Space.section))px;"
            + "--tb-radius-box:\(Int(Radius.box))px;--tb-radius-card:\(Int(Radius.card))px"
        return """
            :root{\(variables(dark: false));\(spaces)}
            @media (prefers-color-scheme: dark){:root{\(variables(dark: true))}}
            html,body{margin:0;padding:0;background:transparent;color:var(--tb-text);font:13px/1.6 -apple-system,BlinkMacSystemFont,"Hiragino Sans",sans-serif;overflow-wrap:anywhere}
            .tb-h{font-size:14px;font-weight:600;margin:0 0 var(--tb-space-row)}
            .tb-muted{color:var(--tb-secondary);font-size:12px}
            .tb-row{display:flex;flex-wrap:wrap;gap:var(--tb-space-row);align-items:baseline}
            .tb-table{border-collapse:collapse;width:100%}
            .tb-table th{color:var(--tb-secondary);font-size:12px;font-weight:400;text-align:left;padding:var(--tb-space-inline) var(--tb-space-block) var(--tb-space-inline) 0;border-bottom:1px solid var(--tb-border)}
            .tb-table td{padding:var(--tb-space-inline) var(--tb-space-block) var(--tb-space-inline) 0;vertical-align:baseline}
            .tb-gauges{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:var(--tb-space-row)}
            .tb-gauge{background:var(--tb-fill);border-radius:var(--tb-radius-card);padding:var(--tb-space-block)}
            .tb-gauge-label{color:var(--tb-secondary);font-size:12px}
            .tb-gauge-value{font-size:20px;font-weight:600;font-variant-numeric:tabular-nums}
            .tb-gauge-note{color:var(--tb-secondary);font-size:12px}
            .tb-badge{display:inline-block;font-size:12px;padding:0 7px;border-radius:999px;background:var(--tb-fill);color:var(--tb-secondary)}
            .tb-badge.tb-attention{background:var(--tb-fill);color:var(--tb-attention-text);font-weight:600}
            .tb-badge.tb-failed{color:var(--tb-failed-text);font-weight:600}
            .tb-badge.tb-done,.tb-badge.tb-waiting{color:var(--tb-muted)}
            .tb-badge.tb-ok,.tb-badge.tb-neutral{color:var(--tb-secondary)}
            """
    }()
}
