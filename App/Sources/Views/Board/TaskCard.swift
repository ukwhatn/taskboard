import SwiftUI
import TaskboardKit

/// ボードのカード。押すと開き、⌘ を押しながら押すと別ウィンドウで開く。ドラッグで列を移し、右クリック（長押し）でほかの操作。
/// 見た目は `TaskCard`、押したときの動きはこのビューが持つ
struct TaskCardButton: View, @MainActor Equatable {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    let task: BoardTask
    let signals: CardSignals
    var scheduleName: String?

    @State private var hovering = false
    @State private var deleting: BoardTask?

    /// 比べられないと、親が作り直されるたびに全カードを描き直す
    static func == (lhs: TaskCardButton, rhs: TaskCardButton) -> Bool {
        lhs.task == rhs.task && lhs.signals == rhs.signals && lhs.scheduleName == rhs.scheduleName
    }

    var body: some View {
        Button(action: open) {
            TaskCard(task: task, signals: signals, scheduleName: scheduleName)
        }
        .buttonStyle(CardButtonStyle())
        // 実画面の確認（scripts/ui）がカードを見分ける。ホバーのメニューに付かないよう、重ねる前のボタンに付ける
        .accessibilityIdentifier("task:\(task.machine.rawValue)/\(task.number)")
        // 選択とカーソルは子のビューで読む（ここで読むと、選択が変わるたびに全カードが作り直される）
        .overlay { CardSelectionRing(task: task.id).allowsHitTesting(false) }
        #if os(macOS)
        // ほかの操作はホバーで出す（右クリックと同じ中身）
        .overlay(alignment: .topTrailing) {
            if hovering {
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis.circle.fill").symbolRenderingMode(.hierarchical).font(.body)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(Space.inline)
                .accessibilityLabel("タスクの操作")
            }
        }
        .onHover { hovering = $0 }
        #endif
        .draggable(TaskDrag.payload(task.id)) {
            Text("#\(task.number) \(task.title)").font(.callout).lineLimit(1)
                .padding(Space.row)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .contextMenu { menuItems }
        .taskDeleteDialog($deleting)
        .modifier(CardSelectedTrait(task: task.id))
        .accessibilityActions {
            if supportsMultipleWindows {
                Button("別ウインドウで開く") { openSeparately() }
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("開く") { model.navigate(to: .task(task.id, revealBoard: false), from: .board) }
        if supportsMultipleWindows {
            Button("別ウインドウで開く") { openSeparately() }
        }
        // 受信箱を作り直すのは押したときだけにする（カードごとに描くたびに作ると、ボードが重くなる）。出すかはカードの待ち理由で決める
        if task.waitLine(signals)?.tone == .mine {
            Button("対応待ちを非表示", systemImage: "eye.slash") { model.dismiss(model.waitingItems(for: task.id)) }
        }
        Divider()
        TaskMoveMenu(task: task)
        if model.canWrite(task.machine) {
            Divider()
            TaskDeleteButton(task: task, target: $deleting)
        }
    }

    private func open() {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) { return openSeparately() }
        #endif
        model.navigate(to: .task(task.id, revealBoard: false), from: .board)
    }

    private func openSeparately() {
        guard supportsMultipleWindows else { return model.navigate(to: .task(task.id, revealBoard: false), from: .board) }
        openWindow(value: task.id)
    }
}

/// カードを押したときの見た目。押している間だけ薄くする
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// カードの見た目。題、今の作業項目、セッションの状態とリンク（PR の CI とレビュー、Jira の状態）と期日と動いていない日数、待ち理由。
/// 強い色を使うのは自分の番（待ち理由の `mine`）と動いているセッションだけ
struct TaskCard: View, @MainActor Equatable {
    @Environment(\.today) private var today
    let task: BoardTask
    let signals: CardSignals
    /// このタスクを常設タスクにしている定期起動
    var scheduleName: String?

    static func == (lhs: TaskCard, rhs: TaskCard) -> Bool {
        lhs.task == rhs.task && lhs.signals == rhs.signals && lhs.scheduleName == rhs.scheduleName
    }

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("TaskCard")
        #endif
        let wait = task.waitLine(signals, today: today)
        let progress = TaskProgress.derive(signals.workItems)
        let statuses = Dictionary(signals.links.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let stall = task.stall(workItems: signals.workItems, terminal: signals.terminal, now: today)
        VStack(alignment: .leading, spacing: Space.inline) {
            HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                Text("#\(task.number)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Text(task.title).font(.callout.weight(.medium)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let situation = signals.situation?.headline, !situation.isEmpty {
                Text(verbatim: situation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            // 今の作業項目（作業中が無ければ着手できる数）
            if let progress, let current = WorkItemGlyph.progressLine(progress) {
                Label(current, systemImage: WorkItemGlyph.symbol(progress.current.isEmpty ? .ready : .doing))
                    .font(.caption)
                    .foregroundStyle(progress.current.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(WorkItemGlyph.color(.doing)))
                    .lineLimit(1)
            }
            if !signals.conversations.isEmpty || !task.links.isEmpty || task.due != nil || scheduleName != nil || stall != nil {
                FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
                    if let scheduleName {
                        Label(scheduleName, systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    }
                    ForEach(signals.conversations.prefix(2)) { conversation in
                        let appearance = StatusAppearance.of(conversation)
                        HStack(spacing: 3) {
                            // 隣に状態の文字があるので、記号は読み上げない
                            StatusGlyph(conversation: conversation).accessibilityHidden(true)
                            Text(appearance.label)
                        }
                        .foregroundStyle(appearance.color)
                    }
                    // 札に出しきれない会話の分も数える
                    BackgroundTasksGlyph(count: signals.conversations.runningBackgroundTasks)
                    // 完了したリンク（マージ済みの PR など）より、まだ動いているリンクを先に出す
                    let order = TaskLink.ordered(task.links, statuses: statuses)
                    ForEach((order.active + order.settled).prefix(3)) { link in
                        LinkChip(link: link, status: statuses[link.url])
                    }
                    if let due = task.due {
                        Label(Self.dueLabel(due, today: today), systemImage: "calendar").foregroundStyle(.secondary)
                    }
                    // 待ち理由の行とは分けて控えめに出す（自分の番の印を押しのけない）
                    if let stall {
                        Label(stall.label, systemImage: "clock").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            if wait != nil || progress != nil {
                HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                    if let wait {
                        Image(systemName: wait.tone == .mine ? "hand.raised.fill" : "hourglass")
                        Text(wait.text).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let progress {
                        Text(progress.fractionLabel)
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                            .accessibilityLabel("作業項目\(progress.total)件中\(progress.done)件が完了")
                    }
                }
                .font(.caption)
                .foregroundStyle(wait.map { WorkItemGlyph.waitColor($0.tone) } ?? AnyShapeStyle(.tertiary))
            }
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// `2026-11-16` → `11/16`。年が違えば `2027/1/5`。
    static func dueLabel(_ due: String, today: Date = Date()) -> String {
        guard let date = BoardTask.dateFormatter.date(from: due) else { return due }
        let cal = Calendar.current
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        let thisYear = cal.component(.year, from: today)
        if parts.year == thisYear { return "\(parts.month!)/\(parts.day!)" }
        return "\(parts.year!)/\(parts.month!)/\(parts.day!)"
    }
}

/// リンクのチップ。PR は CI とレビューの印、Jira と Devin のセッションは状態の名前を後ろに付ける（取れていなければ名前だけ）
struct LinkChip: View {
    let link: TaskLink
    var status: LinkStatus?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(symbolColor)
            Text(link.shortLabel).lineLimit(1).truncationMode(.middle)
            if let pr = status?.pullRequest, pr.state == .open {
                if let checks = pr.checks {
                    Image(systemName: checks.symbol).foregroundStyle(checks.color)
                }
                if let review = pr.decision, let symbol = review.symbol {
                    Image(systemName: symbol).foregroundStyle(review.color)
                }
            }
            if let jira = status?.jira {
                Text(jira.statusName).foregroundStyle(Self.jiraColor(jira.category))
            }
            if let devin = status?.devin, let label = devin.phase.label {
                Text(label).foregroundStyle(devin.phase.color)
            }
        }
        .chipStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        switch link.kind {
        case .githubPR:
            if let pr = status?.pullRequest, pr.state != .open {
                pr.state.symbol
            } else {
                status?.pullRequest?.isDraft == true ? "circle.dashed" : PullRequestLinkState.State.open.symbol
            }
        case .githubIssue: "circle.dotted"
        case .jira: "checklist"
        case .other: DevinSession.id(fromURL: link.url) != nil ? "cpu" : "link"
        }
    }

    private var symbolColor: Color {
        status?.pullRequest?.state == .merged ? PullRequestLinkState.State.merged.color : .secondary
    }

    static func jiraColor(_ category: JiraLinkState.Category) -> Color {
        switch category {
        case .new, .unknown: .secondary
        case .indeterminate: .blue
        case .done: .green
        }
    }

    private var accessibilityText: String {
        var parts = [link.shortLabel]
        if let pr = status?.pullRequest {
            switch pr.state {
            case .merged, .closed: parts.append(pr.state.label)
            case .open:
                if pr.isDraft { parts.append(PullRequestLinkState.State.draftLabel) }
                if let checks = pr.checks { parts.append(checks.label) }
                if let review = pr.decision, [.approved, .changesRequested, .reviewRequired].contains(review) { parts.append(review.label) }
            }
        }
        if let jira = status?.jira { parts.append(jira.statusName) }
        if let label = status?.devin?.phase.label { parts.append(label) }
        return parts.joined(separator: "、")
    }
}

extension DevinLinkState.Phase {
    /// 止める・戻すの途中（`other`）は出さない
    var label: String? {
        switch self {
        case .working: String(localized: "実行中")
        case .waiting: String(localized: "応答待ち")
        case .finished: String(localized: "終了")
        case .expired: String(localized: "期限切れ")
        case .other: nil
        }
    }

    var color: Color {
        switch self {
        case .working: .blue
        case .waiting: .orange
        case .finished: .green
        case .expired, .other: .secondary
        }
    }
}

/// 開いているカードの枠と、キーで選んでいるカードの点線
private struct CardSelectionRing: View {
    @Environment(AppModel.self) private var model
    let task: TaskKey

    var body: some View {
        if model.selectedTask == task {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.tint, lineWidth: 2)
                .accessibilityHidden(true)
        } else if model.cursorTask == task {
            // キーで選んでいるだけ（まだ開いていない）
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.tint.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .accessibilityHidden(true)
        }
    }
}

/// 開いているカードに「選択中」を付ける。選択を読むのはこの modifier だけ
private struct CardSelectedTrait: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: TaskKey

    func body(content: Content) -> some View {
        content.accessibilityAddTraits(model.selectedTask == task ? .isSelected : [])
    }
}

/// カードのドラッグで運ぶ文字列。同じマシンの中だけで受ける
enum TaskDrag {
    static let prefix = "taskboard-task:"

    static func payload(_ key: TaskKey) -> String { "\(prefix)\(key.machine.rawValue)/\(key.number)" }

    static func key(from payload: String) -> TaskKey? {
        guard payload.hasPrefix(prefix) else { return nil }
        let body = payload.dropFirst(prefix.count)
        guard let slash = body.lastIndex(of: "/"), let number = Int(body[body.index(after: slash)...]) else { return nil }
        return TaskKey(machine: MachineID(rawValue: String(body[..<slash])), number: number)
    }
}

/// 「移動」のメニュー: 同じ案件の列と、同じマシンのほかの案件
struct TaskMoveMenu: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask

    var body: some View {
        if let board = model.fleet.board(id: task.boardID, on: task.machine) {
            Menu("移動") {
                Section("列") {
                    ForEach(board.orderedColumns) { column in
                        Button(column.label) { model.move(task: task, to: column.id) }
                            .disabled(column.id == task.columnID)
                    }
                }
                let others = model.orderedBoards(on: task.machine).filter { $0.id != board.id }
                if !others.isEmpty {
                    Section("案件") {
                        ForEach(others) { other in
                            Button(other.name) { model.move(task: task, toBoard: other) }
                        }
                    }
                }
            }
        }
    }
}
