import SwiftUI
import TaskboardKit

// 会話が置く部品の 4 か所（`PanelPlace`）。どれも、その場所に部品が無ければ何も描かない（空の枠・見出し・余白を出さない）。
// 部品は state の今の値で描き、色・余白はここと `OverviewPanelParts` の描き手が当てる。会話の画面の view の外に置き、部品が変わっても会話の view は描き直さない

extension AppModel {
    /// タスクの、その場所に置いた部品
    func panelParts(_ task: TaskKey, in place: PanelPlace) -> (panel: OverviewPanel, parts: [PanelPart])? {
        guard let panel = fleet.machineState(for: task.machine)?.panels[task] else { return nil }
        let parts = panel.parts(in: place)
        return parts.isEmpty ? nil : (panel, parts)
    }
}

// MARK: - 帯

/// タスクの見出しの下の 1 行。計器を名前・値・基準で横に並べる。計器は切らず、入らない幅（iPhone）では横に送る
struct PanelBand: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask

    var body: some View {
        if let found = model.panelParts(task.id, in: .band) {
            let state = model.fleet.machineState(for: task.machine)
            ScrollView(.horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.section) {
                    ForEach(found.parts) { part in
                        if case .gauge(let gauge) = part.spec.content {
                            PanelBandGauge(gauge: state?.resolve(part.spec, task: task)?.gauge ?? gauge, staleAt: found.panel.isStale(part) ? part.updatedAt : nil)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}

/// 帯の計器 1 つ。補足はポインタを載せたときに出す（1 行に収めるため）
private struct PanelBandGauge: View {
    let gauge: PanelGauge
    let staleAt: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
            if gauge.tone == .attention || gauge.tone == .failed {
                ToneMark(tone: gauge.tone, symbol: nil).font(.caption)
            }
            Text(verbatim: gauge.label).textRole(.caption).lineLimit(1)
            Text(verbatim: gauge.value).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(gauge.tone.valueColor).lineLimit(1)
            if let basis = gauge.basis {
                Text(verbatim: PanelGaugeText.basis(basis)).textRole(.caption).monospacedDigit().lineLimit(1)
            }
            if let staleAt { PanelUpdatedLabel(at: staleAt).lineLimit(1) }
        }
        .fixedSize()
        .help(gauge.note)
        .accessibilityElement(children: .combine)
        .accessibilityHint(gauge.note)
    }
}

// MARK: - 会話の頭

/// 会話の一覧の上に固定する部品 1 つ。見出しの行で折りたため、開閉はこの端末に残す。
/// `maxHeight` があれば中身をその高さまでにし、超えた分は中で送る（Mac と iPad は会話の欄の 3 分の 1）。nil なら中身の高さのまま（iPhone のタスク画面の縦並び）
struct PanelHead: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let task: TaskKey
    var maxHeight: CGFloat?
    /// 下に区切り線を引くか（会話の画面では一覧との境目に引く）
    var divided = true
    @AppStorage(AppPreferences.taskPanelHeadCollapsedKey) private var collapsed = AppModel.isPhone

    var body: some View {
        if let found = model.panelParts(task, in: .head), let part = found.parts.first, let board = model.fleet.task(for: task) {
            let panel = found.panel
            let title = PanelPartSection.title(part.spec.content)
            let resolved = model.fleet.machineState(for: task.machine)?.resolve(part.spec, task: board)
            VStack(alignment: .leading, spacing: 0) {
                header(title: title, staleAt: panel.isStale(part) ? part.updatedAt : nil)
                if !collapsed {
                    if let maxHeight {
                        ScrollView {
                            PanelPartContent(task: board, part: part, resolved: resolved).padding(.bottom, Space.block)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .cappedHeight(max(maxHeight - HitTarget.size, HitTarget.size))
                    } else {
                        PanelPartContent(task: board, part: part, resolved: resolved).padding(.bottom, Space.block)
                    }
                }
            }
            // 会話の列（発言と入力欄）と同じ幅に揃える
            .readableColumn(ReadableWidth.chat)
            .padding(.horizontal, inset)
            if divided { Divider() }
        }
    }

    private func header(title: String, staleAt: Date?) -> some View {
        Button {
            collapsed.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                Text(verbatim: title).textRole(.sectionTitle).lineLimit(1)
                if let staleAt { PanelUpdatedLabel(at: staleAt) }
                Spacer(minLength: 0)
                Image(systemName: collapsed ? "chevron.down" : "chevron.up").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: HitTarget.size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? String(localized: "\(title)を展開") : String(localized: "\(title)を折りたたむ"))
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? String(localized: "折りたたみ済み") : String(localized: "展開済み"))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 入力欄の上

/// 入力欄の上の送る文面（2 件まで）。高さは `maxHeight`（会話の欄の 3 分の 1。会話の頭と合わせても一覧に 3 分の 1 を残す）までにし、超えた分は中で送る
struct PanelComposerDrafts: View {
    @Environment(AppModel.self) private var model
    let task: TaskKey
    let maxHeight: CGFloat

    var body: some View {
        if let parts = model.panelParts(task, in: .composer)?.parts, let board = model.fleet.task(for: task) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.block) {
                    ForEach(parts) { part in
                        PanelPartSection(task: board, part: part, resolved: nil, staleAt: nil)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .cappedHeight(maxHeight)
        }
    }
}

// MARK: - 右の欄

/// 右の欄に置いた部品の見出しと記号（欄の切り替えのボタンと欄の頭）
struct PanelSideItem {
    let part: PanelPart
    let title: String

    @MainActor init?(task: TaskKey, model: AppModel) {
        guard let part = model.panelParts(task, in: .side)?.parts.first else { return nil }
        self.part = part
        let title = PanelPartSection.title(part.spec.content)
        self.title = title.isEmpty ? SidePanel.part.label : title
    }

    var symbol: String {
        switch part.spec.content {
        case .table: "tablecells"
        case .plan: "list.bullet.rectangle"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .chart: "chart.bar"
        case .gauge, .draft, .html: "rectangle.on.rectangle"
        }
    }
}

/// 右の欄の部品の中身
struct PanelSideBody: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask

    var body: some View {
        if let found = model.panelParts(task.id, in: .side), let part = found.parts.first {
            let panel = found.panel
            let resolved = model.fleet.machineState(for: task.machine)?.resolve(part.spec, task: task)
            VStack(alignment: .leading, spacing: Space.block) {
                if panel.isStale(part) { PanelUpdatedLabel(at: part.updatedAt) }
                PanelPartContent(task: task, part: part, resolved: resolved)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 計器の基準の文（帯と計器の札で同じ）
enum PanelGaugeText {
    static func basis(_ basis: PanelBasis) -> String {
        switch basis.kind {
        case .denominator: "/ \(basis.value)"
        case .limit: String(localized: "上限\(basis.value)")
        case .deadline: String(localized: "期限\(basis.value)")
        case .previous: String(localized: "前回\(basis.value)")
        }
    }
}
