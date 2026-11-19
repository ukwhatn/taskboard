import SwiftUI
import TaskboardKit

/// Mac と iPad のタスク画面の右側。上の帯のボタンで欄（状態・文書・作業項目・差分）を開け閉めし、開いた欄を格子に並べて同時に出す（`SidePanelArrangement`）。
/// 各欄の頭に題と［広げる］［閉じる］。開いている組と大きさはこの端末に残す（`SidePanelSet`）。会話のシェルは欄にせず、会話と右側の下に出す（`TaskTerminalArea`）。
/// 右側を下に重ねる幅（`single`）では欄を 1 つだけ出し、上の帯のボタンで替える（開いている組は書き換えない）。
/// 会話と入れ替える幅（`swap`。iPad の縦）では帯を下に置き、帯の［会話］と欄のボタンで会話と欄を入れ替える。iPhone は `TaskSidePane`
struct TaskSideArea: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    var editable = false
    /// 画面が出している会話（状態の会話の節・差分）
    var conversation: ConversationKey?
    /// 欄を 1 つだけ出すか（右側を下に重ねる幅）
    var single = false
    /// 会話と入れ替える幅（`TaskPanelMetrics.swapsWhenStacked`）なら、欄を出しているか。帯の先頭に［会話］を置き、会話を出している間は帯だけを出す
    var swap: Binding<Bool>?
    var openConversation: (ConversationKey) -> Void = { _ in }

    @AppStorage(AppPreferences.taskSidePanelsKey) private var stored = ""
    /// 広げている欄（このタスクの間だけ）
    @TaskState private var expanded: SidePanel?
    /// 欄を 1 つだけ出すときに選んだ欄（このタスクの間だけ。無ければ開いている組の最初）
    @TaskState private var singlePick: SidePanel?
    @TaskState private var scrollTarget: String?

    var body: some View {
        let set = SidePanelSet(json: stored)
        let panels = SidePanel.allCases
        let opened = set.shown
        let picked = singlePick
        let single = single || swap != nil
        let detailsShown = swap?.wrappedValue ?? true
        let open = single ? [picked ?? opened.first ?? .status] : opened
        let shown = single ? open : expanded.map { panel in open.contains(panel) ? [panel] : open } ?? open
        VStack(spacing: 0) {
            // 入れ替える幅では、帯を常に下に置く（会話を出している間は帯だけ）
            if swap == nil {
                strip(panels: panels, open: open, set: set, single: single, detailsShown: detailsShown)
                Divider()
                grid(shown: shown, open: open, set: set, single: single)
            } else {
                if detailsShown {
                    grid(shown: shown, open: open, set: set, single: single)
                    Divider()
                }
                strip(panels: panels, open: open, set: set, single: single, detailsShown: detailsShown)
            }
        }
        .onChange(of: model.prFocusRequest) { _, _ in
            guard task.pullRequestLinks.contains(where: { $0.url == model.selectedPR }) else { return }
            reveal(.status)
            scrollTarget = SidePanelBody.prAnchor
        }
        // 会話の上の帯の［状態］［差分］と `/status`・`/diff` など。閉じていれば開き、ほかの欄を広げていれば戻す
        .onChange(of: model.sidePaneRequest) { _, request in
            guard let request, request.conversation == nil || request.conversation == conversation else { return }
            reveal(request.panel)
            if let section = request.section { scrollTarget = section }
        }
    }

    /// 欄を開け閉めするボタンの帯。入れ替える幅では先頭に［会話］
    private func strip(panels: [SidePanel], open: [SidePanel], set: SidePanelSet, single: Bool, detailsShown: Bool) -> some View {
        HStack(spacing: Space.inline) {
            if let swap {
                Button("会話", systemImage: "bubble.left.and.text.bubble.right") { swap.wrappedValue = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .symbolVariant(detailsShown ? .none : .fill)
                    .foregroundStyle(detailsShown ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .hitTarget()
                    .help("会話を表示")
                    .accessibilityAddTraits(detailsShown ? [] : .isSelected)
            }
            ForEach(panels) { panel in
                let isOpen = open.contains(panel)
                let selected = isOpen && detailsShown
                Button(panel.label, systemImage: panel.symbol) {
                    if let swap, !selected {
                        // 入れ替える幅では、押した欄を出す
                        singlePick = panel
                        swap.wrappedValue = true
                    } else if single {
                        singlePick = panel
                    } else {
                        toggle(panel, set: set, open: open)
                    }
                }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .symbolVariant(selected ? .fill : .none)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .hitTarget()
                    .help(help(panel, isOpen: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.block)
        .padding(.vertical, Space.inline)
    }

    @ViewBuilder
    private func grid(shown: [SidePanel], open: [SidePanel], set: SidePanelSet, single: Bool) -> some View {
        if shown.isEmpty {
            EmptyState("開いているパネルはありません", symbol: "rectangle.split.2x2", message: swap == nil ? "上のボタンでパネルを開けます。" : "下のボタンでパネルを開けます。")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SidePanelGrid(panels: shown, set: set, store: { stored = $0.json }) { panel in
                VStack(spacing: 0) {
                    SidePanelHeader(
                        title: panel.label,
                        symbol: panel.symbol, expanded: expanded == panel, showsControls: !single
                    ) {
                        expanded = expanded == panel ? nil : panel
                    } close: {
                        if expanded == panel { expanded = nil }
                        var next = set
                        next.toggle(panel, current: open)
                        stored = next.json
                    }
                    Divider()
                    DeferredMount(lane: .later) {
                        SidePanelBody(
                            panel: panel, task: task, editable: editable, conversation: conversation, scrollTarget: $scrollTarget,
                            openConversation: openConversation)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .background(.background)
            }
        }
    }

    private func help(_ panel: SidePanel, isOpen: Bool) -> String {
        single || !isOpen ? String(localized: "\(panel.label)を開く") : String(localized: "\(panel.label)を閉じる")
    }

    private func toggle(_ panel: SidePanel, set: SidePanelSet, open: [SidePanel]) {
        var next = set
        next.toggle(panel, current: open)
        if expanded == panel || (expanded != nil && !open.contains(panel)) { expanded = nil }
        stored = next.json
    }

    private func reveal(_ panel: SidePanel) {
        if let swap {
            singlePick = panel
            swap.wrappedValue = true
            return
        }
        if single {
            singlePick = panel
            return
        }
        if expanded != panel { expanded = nil }
        var next = SidePanelSet(json: stored)
        next.reveal(panel, current: next.shown)
        stored = next.json
    }
}

/// 欄の頭。題と［広げる］（その欄だけを右側いっぱいに。もう一度押すと戻す）・［閉じる］
private struct SidePanelHeader: View {
    let title: String
    let symbol: String
    let expanded: Bool
    /// ［広げる］［閉じる］を出すか（欄を 1 つだけ出す幅では出さない）
    let showsControls: Bool
    let expand: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: Space.inline) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).textRole(.sectionTitle).lineLimit(1).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.row)
            if showsControls { controls }
        }
        .padding(.horizontal, Space.block)
        .frame(minHeight: HitTarget.size)
    }

    @ViewBuilder
    private var controls: some View {
            Button(expanded ? "元に戻す" : "広げる", systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: expand)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hitTarget()
                .help(expanded ? "元の並びに戻す" : "このパネルだけを広げる")
            Button("閉じる", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hitTarget()
                .help("このパネルを閉じる")
    }
}

/// 開いた欄を `SidePanelArrangement` の枠に置き、欄どうしの境目に大きさを変える取っ手を重ねる。
/// 欄は欄の id で並べるので、1 列と 2 列が替わっても作り直されない（端末の欄の接続が張り直されない）
private struct SidePanelGrid<Panel: View>: View {
    let panels: [SidePanel]
    let set: SidePanelSet
    let store: (SidePanelSet) -> Void
    @ViewBuilder let panel: (SidePanel) -> Panel

    /// 動かしている最中の組（離すまで残さない）
    @State private var dragging: SidePanelSet?
    @State private var dragStart: SidePanelSet?

    var body: some View {
        let current = dragging ?? set
        SidePanelGridLayout(panels: panels, set: current) {
            ForEach(panels) { item in
                panel(item)
            }
        }
        .background(.separator)
        // 大きさは state に持たない（持つと、出た直後に格子ごと描き直す回が 1 回増える）
        .overlay(alignment: .topLeading) { GeometryReader { handles(current, size: $0.size) } }
    }

    @ViewBuilder
    private func handles(_ current: SidePanelSet, size: CGSize) -> some View {
        let frames = Dictionary(uniqueKeysWithValues: zip(panels, SidePanelArrangement.frames(of: panels, in: size, set: current)))
        let columns = SidePanelArrangement.columns(of: panels, width: size.width)
        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
            ForEach(Array(zip(column, column.dropFirst())), id: \.0) { upper, lower in
                if let top = frames[upper] {
                    SplitHandle(axis: .vertical, label: String(localized: "パネルの高さ")) { delta in
                        drag { $0.resize(upper, lower, panels: panels, in: size, by: delta) }
                    } end: {
                        endDrag()
                    }
                    .frame(width: top.width, height: SidePanelMetrics.handle)
                    .offset(x: top.minX, y: top.maxY + SidePanelMetrics.divider / 2 - SidePanelMetrics.handle / 2)
                    #if DEBUG
                    .onReceive(NotificationCenter.default.publisher(for: .debugSplitDrag)) { note in
                        guard note.userInfo?["handle"] as? String == "\(upper.rawValue)|\(lower.rawValue)" else { return }
                        if let delta = note.userInfo?["delta"] as? CGFloat {
                            drag { $0.resize(upper, lower, panels: panels, in: size, by: delta) }
                        } else {
                            endDrag()
                        }
                    }
                    #endif
                }
            }
        }
        if columns.count == 2, let left = columns[0].first.flatMap({ frames[$0] }) {
            SplitHandle(axis: .horizontal, label: String(localized: "列の幅")) { delta in
                drag { $0.resizeColumn(panels: panels, in: size, by: delta) }
            } end: {
                endDrag()
            }
            .frame(width: SidePanelMetrics.handle, height: size.height)
            .offset(x: left.maxX + SidePanelMetrics.divider / 2 - SidePanelMetrics.handle / 2)
        }
    }

    /// 動かし始めの組から、始めからの移動量で組み直す（毎回の差で足すと、止めたところで端に張り付いた分がずれる）
    private func drag(_ change: (inout SidePanelSet) -> Void) {
        let start = dragStart ?? set
        dragStart = start
        var next = start
        change(&next)
        dragging = next
    }

    private func endDrag() {
        if let dragging { store(dragging) }
        dragging = nil
        dragStart = nil
    }
}

private struct SidePanelGridLayout: Layout {
    let panels: [SidePanel]
    let set: SidePanelSet

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = SidePanelArrangement.frames(of: panels, in: bounds.size, set: set)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// 境目の取っ手。ドラッグの始めからの移動量（`axis` が vertical なら下へ、horizontal なら右へ）を渡す
struct SplitHandle: View {
    let axis: Axis
    let label: String
    let change: (CGFloat) -> Void
    let end: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(axis == .vertical ? .rowResize : .columnResize)
            #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { change(axis == .vertical ? $0.translation.height : $0.translation.width) }
                    .onEnded { _ in end() })
            .accessibilityLabel(label)
    }
}

#if DEBUG
extension Notification.Name {
    /// debug の口 `/side-panels/drag` が、境目の取っ手を動かしたのと同じ値を `SidePanelGrid` に渡す（userInfo: handle は「上の欄|下の欄」、delta は動かし始めからの移動量で、無ければ離した）
    static let debugSplitDrag = Notification.Name("taskboard.debugSplitDrag")
}
#endif
