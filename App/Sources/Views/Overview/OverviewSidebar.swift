import SwiftUI
import TaskboardKit

/// Mac / iPad のサイドバー。上に「すべての案件」、その下にマシン → 案件 → 列 → タスクの 1 本の木と、マシンごとのタスクなし。
/// マシンと案件はドラッグで並べ替え、マシン・案件・列は畳める（並びと畳みはこの端末に保存）。
/// Mac の設定は ⌘, の設定ウィンドウにあるので、ここには置かない
struct OverviewSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<SidebarItem?>(
            get: { model.sidebar },
            set: { item in
                guard let item else { return }
                switch item {
                case .board(let machine, let id): model.navigate(to: .board(machine: machine, id: id), from: .sidebar)
                case .orchestrator(let machine): model.navigate(to: .orchestrator(machine), from: .sidebar)
                case .unassigned(let machine): model.navigate(to: .unassigned(machine), from: .sidebar)
                case .overview, .settings:
                    model.logNavigation(item == .overview ? .overview : .settings(model.settingsSection), from: .sidebar)
                    model.sidebar = item
                    model.closeTask()
                }
            })
        List(selection: selection) {
            // 案件の行を選ぶとその案件だけを出す。ここで全部に戻す
            Label("すべての案件", systemImage: "square.grid.2x2")
                // 対応待ちの数（Dock のバッジと同じ数）
                .badge(model.inboxWaitingCount > 0 ? Text(verbatim: "\(model.inboxWaitingCount)").foregroundStyle(.orange) : nil)
                .tag(SidebarItem.overview)
            SidebarTree(selectable: true)
            #if os(iOS)
            Section {
                Label("設定", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
            #endif
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .toolbar {
            ToolbarItem { SidebarArrangementMenu() }
        }
    }
}

/// サイドバーの右上の「並べ方」。分け方と並び順を選ぶ（この端末に保存）
struct SidebarArrangementMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("分け方", selection: $model.sidebarArrangement.grouping) {
                ForEach(SidebarArrangement.Grouping.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("並び順", selection: $model.sidebarArrangement.order) {
                ForEach(SidebarArrangement.Order.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("並べ方", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("並べ方")
    }
}

/// 先頭にピン留めの組、続けてマシンごとの木（Mac・iPad のサイドバー）。iPhone の「タスク」タブは `PhoneTaskList` で、同じタスクを節に分けて出す
struct SidebarTree: View {
    @Environment(AppModel.self) private var model
    let selectable: Bool

    var body: some View {
        let waiting = model.waitingItemsByTask
        let pinned = model.pinnedSidebarTasks()
        if !pinned.isEmpty {
            TaskGroupTreeRow(
                id: "pinned", label: String(localized: "ピン留め"),
                rows: pinned.map { (task: $0, status: model.rowStatus(of: $0, waiting: waiting[$0.id] ?? [])) },
                move: { model.movePinned(from: $0, to: $1) })
        }
        ForEach(model.orderedMachines, id: \.id) { machine in
            MachineTreeRow(fleetID: machine.id, state: machine.state, selectable: selectable, waiting: waiting)
        }
        .onMove { model.moveMachines(from: $0, to: $1) }
        if model.orderedMachines.isEmpty {
            NoMachineRow()
        }
    }
}

/// 接続先が 1 つも無いときの行。サイドバーの木と iPhone の一覧に出す
struct NoMachineRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            Text("接続先はありません").foregroundStyle(.secondary)
            if let noMachineMessage {
                Text(noMachineMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("接続先を追加") {
                model.navigate(to: .settings(.connections), from: .sidebar)
                model.addingConnection = .menu
            }
        }
    }

    private var noMachineMessage: String? {
        #if os(macOS)
        model.connectionNote == nil ? nil : String(localized: "このMacのTaskboardに接続できません。Taskboardが起動しているかを確認してください。")
        #else
        nil
        #endif
    }
}

/// 押すと選ぶ行。Mac・iPad はサイドバーの選択（tag）、iPhone は「タスク」タブに積む
struct SidebarItemRow<Content: View>: View {
    let item: SidebarItem
    let selectable: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if selectable {
            content.tag(item)
        } else {
            NavigationLink(value: PhoneRoute.item(item)) { content }
        }
    }
}

/// マシン 1 台。見出しの行の右にオーケストレーターの印（押すとその画面）と今の利用枠。中に案件とタスクなし
private struct MachineTreeRow: View {
    @Environment(AppModel.self) private var model
    let fleetID: String
    let state: MachineState
    let selectable: Bool
    let waiting: [TaskKey: [InboxItem]]

    var body: some View {
        let name = model.machineName(fleetID: fleetID, state: state)
        let isExpanded = !model.collapsedMachines.contains(fleetID)
        let expanded = Binding(
            get: { isExpanded },
            set: { if $0 == model.collapsedMachines.contains(fleetID) { model.toggleCollapsed(fleetID) } })
        DisclosureGroup(isExpanded: expanded) {
            let boards = model.orderedBoards(state, fleetID: fleetID)
            switch model.sidebarArrangement.grouping {
            case .boards:
                ForEach(boards) { board in
                    BoardTreeRow(board: board, state: state, selectable: selectable, waiting: waiting)
                }
                .onMove { model.moveBoards(state, fleetID: fleetID, from: $0, to: $1) }
            case .state:
                let active = model.sidebarActiveTasks(state)
                ForEach(model.sidebarStateGroups(on: state, fleetID: fleetID, waiting: waiting, active: active), id: \.group) { group, rows in
                    TaskGroupTreeRow(id: "state/\(fleetID)/\(group)", label: group.label, rows: rows)
                }
            case .none:
                let active = model.sidebarActiveTasks(state)
                ForEach(model.sidebarTasks(on: state, fleetID: fleetID, waiting: waiting, active: active)) { task in
                    TaskTreeRow(task: task, status: model.rowStatus(of: task, waiting: waiting[task.id] ?? []))
                }
            }
            if boards.isEmpty {
                Text(state.connected ? "案件はありません" : "未接続").foregroundStyle(.secondary)
            }
            if let machine = state.machine?.id {
                UnassignedTreeRow(machine: machine, selectable: selectable)
            }
        } label: {
            HStack(spacing: Space.inline) {
                Text(name).fontWeight(.semibold).lineLimit(1)
                if !state.connected {
                    Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary).help("未接続").accessibilityLabel("未接続")
                }
                Spacer(minLength: Space.row)
                if let machine = state.machine?.id, let row = model.orchestratorRow(on: machine) {
                    OrchestratorMark(row: row)
                }
                MachineUsageBars(state: state, name: name)
            }
            // 見出しの行だけに付ける。DisclosureGroup に付けると、中の案件・列・タスクの行の右クリックにもこのメニューが出る
            .contextMenu { MachineMenuItems(fleetID: fleetID, state: state) }
        }
        .id("machine/\(fleetID)/\(isExpanded)")
    }
}

/// マシンの見出しの右の、オーケストレーターの状態の印。押すとオーケストレーターの画面を開く
private struct OrchestratorMark: View {
    @Environment(AppModel.self) private var model
    let row: OrchestratorRow

    var body: some View {
        let title = String(localized: "オーケストレーター")
        Button {
            model.navigate(to: .orchestrator(row.machine), from: .sidebar)
        } label: {
            OrchestratorGlyph(row: row)
                .frame(minWidth: HitTarget.size, minHeight: HitTarget.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([title, row.statusLabel].joined(separator: "\n"))
        .accessibilityLabel([title, row.statusLabel].joined(separator: "、"))
        .accessibilityHint("押すとオーケストレーターを開きます")
    }
}

/// マシンの見出しの右クリック（長押し）のメニュー。並べ替え、オーケストレーターの操作（`OrchestratorActions`）と Mac だけ指示のシート、定期起動の追加
struct MachineMenuItems: View {
    @Environment(AppModel.self) private var model
    let fleetID: String
    let state: MachineState

    var body: some View {
        let machines = model.orderedMachines.map(\.id)
        if let index = machines.firstIndex(of: fleetID) {
            Button("上へ移動") { model.moveMachines(from: [index], to: index - 1) }.disabled(index == 0)
            Button("下へ移動") { model.moveMachines(from: [index], to: index + 2) }.disabled(index == machines.count - 1)
        }
        if let machine = state.machine?.id {
            Divider()
            Button("オーケストレーターを開く", systemImage: "text.bubble") { model.navigate(to: .orchestrator(machine), from: .sidebar) }
            if let row = model.orchestratorRow(on: machine) {
                OrchestratorActions(row: row, style: .menu)
            }
            if AppModel.showsOrchestratorSheet {
                Button("メッセージを送信…", systemImage: "text.bubble") { model.orchestratorSheet = AppModel.OrchestratorTarget(machine: machine) }
            }
            if AppModel.canEditSchedules {
                Divider()
                Button("定期起動を追加…", systemImage: "clock.arrow.circlepath") { model.scheduleSheet = ScheduleDraft(machine: machine) }
                    .disabled(!model.canWrite(machine))
            }
            Divider()
            Button("使っていないworktreeを削除…", systemImage: "trash") { model.worktreeCleanup = WorktreeCleanupTarget(machine: machine) }
                .disabled(!model.canWrite(machine))
        }
    }
}

/// 状態の印。動いていれば会話の印、無ければ未起動の印
struct OrchestratorGlyph: View {
    let row: OrchestratorRow

    var body: some View {
        if let conversation = row.conversation {
            StatusGlyph(conversation: conversation)
        } else {
            StatusGlyph(appearance: StatusAppearance(label: row.statusLabel, color: .secondary, symbol: "stop.circle"))
        }
    }
}

/// 案件 1 つ。行を選ぶとその案件のボード。中にタスクのある列
private struct BoardTreeRow: View {
    @Environment(AppModel.self) private var model
    let board: Board
    let state: MachineState
    let selectable: Bool
    let waiting: [TaskKey: [InboxItem]]

    var body: some View {
        let id = "board/\(board.machine.rawValue)/\(board.id)"
        let isExpanded = model.isSidebarNodeExpanded(id)
        let expanded = Binding(get: { isExpanded }, set: { model.setSidebarNode(id, expanded: $0) })
        let active = model.sidebarActiveTasks(state)
        let columns = board.orderedColumns.map { ($0, model.sidebarTasks(in: board, column: $0, state: state, waiting: waiting, active: active)) }.filter { !$0.1.isEmpty }
        DisclosureGroup(isExpanded: expanded) {
            ForEach(columns, id: \.0.id) { column, tasks in
                ColumnTreeRow(board: board, column: column, tasks: tasks, waiting: waiting)
            }
        } label: {
            SidebarItemRow(item: .board(machine: board.machine, id: board.id), selectable: selectable) {
                // 数は進行中のタスク
                Label(board.name, systemImage: "rectangle.grid.2x2")
                    .badge(board.openTaskCount(state.tasks.values))
            }
        }
        .id("\(id)/\(isExpanded)")
    }
}

/// 列 1 つと、その列のタスク。完了と見送り（案件の設定で畳む列）は初めは畳む
private struct ColumnTreeRow: View {
    @Environment(AppModel.self) private var model
    let board: Board
    let column: BoardColumn
    let tasks: [BoardTask]
    let waiting: [TaskKey: [InboxItem]]

    var body: some View {
        let id = "column/\(board.machine.rawValue)/\(board.id)/\(column.id)"
        // 開閉が変わったら行を作り直す（`.id`）。木が描き直され続けている間は、Binding が変わっても画面の行（NSOutlineView）の開閉が追いつかず、
        // 押しても開閉せず、親を開き直すと開いていた。マシン・案件の節も同じ
        let isExpanded = model.isSidebarNodeExpanded(id, collapsedByDefault: column.collapsed)
        let expanded = Binding(
            get: { isExpanded },
            set: { model.setSidebarNode(id, expanded: $0, collapsedByDefault: column.collapsed) })
        DisclosureGroup(isExpanded: expanded) {
            ForEach(tasks) { task in
                TaskTreeRow(task: task, status: model.rowStatus(of: task, waiting: waiting[task.id] ?? []))
            }
        } label: {
            Text(column.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .badge(tasks.count)
                .accessibilityAddTraits(.isHeader)
        }
        .id("\(id)/\(isExpanded)")
    }
}

/// タスクの組 1 つ（ピン留めと、状態で分けたときの対応待ち・実行中・未読・待機）と、その組のタスク。畳みはこの端末に覚える
private struct TaskGroupTreeRow: View {
    @Environment(AppModel.self) private var model
    /// 開閉を覚える節の id
    let id: String
    let label: String
    let rows: [(task: BoardTask, status: TaskRowStatus?)]
    /// ドラッグで並べ替える組（ピン留め）だけ渡す
    var move: ((IndexSet, Int) -> Void)?

    var body: some View {
        let isExpanded = model.isSidebarNodeExpanded(id)
        let expanded = Binding(get: { isExpanded }, set: { model.setSidebarNode(id, expanded: $0) })
        DisclosureGroup(isExpanded: expanded) {
            ForEach(rows, id: \.task.id) { row in
                TaskTreeRow(task: row.task, status: row.status)
            }
            .onMove(perform: move)
        } label: {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .badge(rows.count)
                .accessibilityAddTraits(.isHeader)
        }
        // 列の節と同じく、開閉が変わったら行を作り直す（`ColumnTreeRow`）
        .id("\(id)/\(isExpanded)")
    }
}

/// タスクの行。1 行目に番号と題、2 行目に札（応答待ち・回答待ち・CI失敗・未読・実行中など。呼び手が `AppModel.rowStatus` で引いて渡す）と委譲先の進み。押すとタスク画面を開く
struct TaskTreeRow: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    let status: TaskRowStatus?
    @State private var hovering: Bool

    /// `hovering` はマウスを載せた形を snapshot test で描くときだけ渡す
    init(task: BoardTask, status: TaskRowStatus?, hovering: Bool = false) {
        self.task = task
        self.status = status
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        let progress = model.delegateProgress(of: task)
        let selected = model.selectedTask == task.id
        let note = model.statusNote(of: task)
        let badge = [[status?.label, note].compactMap { $0 }.joined(separator: " · "), progress?.label ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let progressText = progress.map { String(localized: "委譲先\($0.total)件中\($0.done)件済み") }
        let background = model.runningBackgroundTasks(of: task)
        let backgroundText = background > 0 ? StatusAppearance.backgroundTasks(background).label : nil
        Button {
            model.navigate(to: .task(task.id, revealBoard: false), from: .sidebar)
        } label: {
            Label {
                // タイトル行と状態の行。状態（札と委譲先の進み）は幅によらず題の下に置く
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Space.inline) {
                        Text(verbatim: "#\(task.number) \(task.title)")
                            .lineLimit(1)
                            .fontWeight(selected ? .semibold : nil)
                        BackgroundTasksGlyph(count: background)
                        #if os(macOS)
                        Spacer(minLength: 0)
                        // マウスを載せたときの操作の置き場。載せている間だけ幅を取り、ほかのときは題に全幅を使わせる（高さは常に取り、行の高さは動かさない）
                        TaskRowHoverActions.placeholder
                            .frame(width: hovering ? nil : 0)
                            .anchorPreference(key: TaskRowActionSlot.self, value: .bounds) { $0 }
                        #endif
                    }
                    if !badge.isEmpty {
                        Text(verbatim: badge)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                TaskRowGlyph(status: status)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        // ほかの操作はホバーで出す（右クリックと同じ中身。会話が 1 つなら［終了］も）
        .overlayPreferenceValue(TaskRowActionSlot.self) { slot in
            if hovering, let slot {
                GeometryReader { proxy in
                    // 縦は題の行に合わせ、横は行の右端に置く
                    let rect = proxy[slot]
                    TaskRowHoverActions(task: task, status: status)
                        .frame(width: proxy.size.width, height: rect.height, alignment: .trailing)
                        .offset(y: rect.minY)
                }
            }
        }
        .onHover { hovering = $0 }
        #endif
        .contextMenu { TaskRowMenuItems(task: task, status: status) }
        .help((["#\(task.number) \(task.title)", status?.label, note, progressText, backgroundText]).compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel((["#\(task.number) \(task.title)", status?.label, note, progressText, backgroundText]).compactMap { $0 }.joined(separator: "、"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(macOS)
/// タスクの行にマウスを載せたときの操作。［ピン留め］、会話が 1 つなら［終了］、残りは［⋯］（右クリックと同じメニュー）
struct TaskRowHoverActions: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    let status: TaskRowStatus?

    var body: some View {
        let targets = model.endTargets(of: task).conversations
        let pinned = model.pinnedTasks.contains(task.id)
        HStack(spacing: 0) {
            Button { model.setPinned(task, !pinned) } label: {
                Self.target(Self.icon(pinned ? "pin.slash" : "pin"))
            }
            .buttonStyle(.plain)
            .help(pinned ? "ピン留めを外す" : "ピン留め")
            .accessibilityLabel(pinned ? "ピン留めを外す" : "ピン留め")
            if targets.count == 1, let conversation = targets.first, model.canWrite(task.machine) {
                Button { model.close(conversation: conversation.key) } label: {
                    Self.target(Self.icon("xmark.circle"))
                }
                .buttonStyle(.plain)
                .help("会話を終了")
                .accessibilityLabel("会話を終了")
            } else {
                Self.slot
            }
            Menu { TaskRowMenuItems(task: task, status: status) } label: {
                Self.target(Self.icon("ellipsis.circle"))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("タスクの操作")
            .accessibilityLabel("タスクの操作")
        }
        .foregroundStyle(.secondary)
    }

    private static func icon(_ name: String) -> some View {
        Image(systemName: name).imageScale(.medium)
    }

    /// 押せる範囲。横は置き場（`placeholder`）と同じ幅、縦は題の行からはみ出して押せる範囲の最小の高さまで広げる
    private static func target(_ icon: some View) -> some View {
        icon.frame(width: HitTarget.size).frame(minHeight: HitTarget.size).contentShape(Rectangle())
    }

    /// 1 つ分の置き場の幅。操作の数が行ごとに違っても、題の右端の位置を揃える
    private static var slot: some View {
        Color.clear.frame(width: HitTarget.size, height: 0)
    }

    /// 操作と同じ大きさの見えない置き場（題の行の右に取っておく）。高さは印の高さで、題の行を高くしない
    static var placeholder: some View {
        HStack(spacing: 0) {
            ForEach(["pin", "xmark.circle", "ellipsis.circle"], id: \.self) { icon($0).frame(width: HitTarget.size) }
        }
        .hidden()
    }
}

/// 行の中の、操作の置き場の位置
private struct TaskRowActionSlot: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}
#endif

/// タスクの行の右クリック（長押し）のメニュー。開く・既読にする・対応待ちを非表示・ピン留めと、動いている会話ごとの停止（タスク画面の札と同じ項目）と［すべて終了］。
/// 会話が 2 つ以上あれば、名前ごとのサブメニューにする
struct TaskRowMenuItems: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    /// 行の札。自分の番の札のときだけ［対応待ちを非表示］を出す（受信箱を引くのは押したときだけ）
    let status: TaskRowStatus?

    var body: some View {
        Button("開く") { model.navigate(to: .task(task.id, revealBoard: false), from: .sidebar) }
        if model.hasUnread(task) {
            Button("既読にする") { model.markRead(task) }
        }
        if status?.isMine == true {
            Button("対応待ちを非表示", systemImage: "eye.slash") { model.dismiss(model.waitingItems(for: task.id)) }
        }
        if model.pinnedTasks.contains(task.id) {
            Button("ピン留めを外す") { model.setPinned(task, false) }
            let pinned = model.pinnedSidebarTasks().map(\.id)
            if pinned.count > 1, let index = pinned.firstIndex(of: task.id) {
                Button("上へ移動", systemImage: "arrow.up") { model.movePinned(task, by: -1) }.disabled(index == 0)
                Button("下へ移動", systemImage: "arrow.down") { model.movePinned(task, by: 1) }.disabled(index == pinned.count - 1)
            }
        } else {
            Button("ピン留め") { model.setPinned(task, true) }
        }
        let rows = model.taskSessions(for: task).rows
        if !rows.isEmpty { Divider() }
        ForEach(rows, id: \.conversation.id) { row in
            if rows.count == 1 {
                ConversationMenuItems(conversation: row.conversation)
            } else {
                Menu { ConversationMenuItems(conversation: row.conversation) } label: { Text(row.conversation.displayTitle) }
            }
        }
        // 1 つだけなら、その行の［終了］と同じになる
        if model.canWrite(task.machine), model.endTargets(of: task).count > 1 {
            Button("すべて終了") { model.requestEndAll(task) }
        }
    }
}

/// タスクの行頭の印。自分の番は橙、未読は青、実行中は緑、どれでもなければ空の丸
struct TaskRowGlyph: View {
    let status: TaskRowStatus?

    var body: some View {
        switch status {
        case nil: StatusGlyph(appearance: StatusAppearance(label: String(localized: "待機"), color: .secondary, symbol: "circle"))
        case .unread: StatusGlyph(appearance: .of(.unread))
        case .running: StatusGlyph(appearance: .of(.running))
        case let status?: StatusGlyph(appearance: StatusAppearance(label: status.label, color: .orange, symbol: "exclamationmark.circle.fill"))
        }
    }
}

/// マシンのタスクなし。中身（タスクに結ばれていない会話・定期起動・PR）があるときだけ出す
struct UnassignedTreeRow: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID
    let selectable: Bool

    var body: some View {
        let contents = model.unassigned(on: machine)
        if !contents.isEmpty {
            let count = contents.sessions.rows.count + contents.schedules.count
            SidebarItemRow(item: .unassigned(machine: machine), selectable: selectable) {
                Label {
                    Text("タスクなし")
                } icon: {
                    Image(systemName: "tray").foregroundStyle(.secondary)
                }
                .badge(count)
            }
        }
    }
}
