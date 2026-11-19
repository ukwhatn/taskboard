#if os(iOS)
import SwiftUI
import TaskboardKit

/// iPhone の「タスク」タブの一覧。先頭に対応待ち、次にピン留め、続けてマシンごとにオーケストレーターとタスクなし、列（並べ方で分けた組）の節を並べる。
/// 字下げの木にせず、列は節の見出しにする（Mac・iPad のサイドバーの `SidebarTree` と出すタスクは同じ）。
/// タブを押し直すとシステムが先頭へ戻すので、対応待ちの節は先頭に置く
struct PhoneTaskList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.waitingItemsByTask
        let attention = model.inboxItems.filter { $0.group == .waiting }
        // 止まりの異常は受信箱の項目を持たないので、札から並べる（タブのバッジ `inboxWaitingCount` と同じ集合にする）
        let problems = model.fleet.conversationTiles.waiting.filter { if case .problem = $0.state { true } else { false } }
        let showsMachine = model.orderedMachines.count > 1
        List {
            if !attention.isEmpty || !problems.isEmpty {
                Section("対応待ち") {
                    ForEach(attention) { item in
                        PhoneAttentionRow(item: item, machine: showsMachine ? model.machineName(item.machine) : nil)
                    }
                    ForEach(problems) { tile in
                        PhoneProblemRow(tile: tile, machine: showsMachine ? model.machineName(tile.id.machine) : nil)
                    }
                }
            }
            let pinned = model.pinnedSidebarTasks()
            if !pinned.isEmpty {
                PhoneTaskSection(label: String(localized: "ピン留め"), rows: pinned.map { ($0, model.rowStatus(of: $0, waiting: waiting[$0.id] ?? [])) })
            }
            ForEach(model.orderedMachines, id: \.id) { machine in
                PhoneMachineSections(fleetID: machine.id, state: machine.state, waiting: waiting)
            }
            if model.orderedMachines.isEmpty {
                NoMachineRow()
            }
        }
        .toolbar {
            ToolbarItem { SidebarArrangementMenu() }
        }
    }
}

/// 対応待ちの 1 行。題は 2 行まで、下に札と補足。押すとその置き場（会話・文書・タスク）
private struct PhoneAttentionRow: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    /// 複数のマシンのときだけ出すマシン名
    let machine: String?

    var body: some View {
        let status = TaskRowStatus(item)
        let detail = [machine, item.detail.isEmpty ? nil : item.detail].compactMap { $0 }.joined(separator: "・")
        let caption = [status?.label, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: "・")
        Button {
            model.open(inbox: item, from: .attention)
        } label: {
            PhoneListRow(title: item.title, glyph: TaskRowGlyph(status: status ?? .blocked)) {
                if let status { Text(status.label).foregroundStyle(.orange) }
                if !detail.isEmpty { Text(verbatim: detail).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel([item.title, caption].joined(separator: "、"))
    }
}

/// 止まりの異常の会話の 1 行。題は会話の題、下に異常の種類とタスク。押すと会話
private struct PhoneProblemRow: View {
    @Environment(AppModel.self) private var model
    let tile: ConversationTile
    let machine: String?

    var body: some View {
        let label: String? = if case .problem(let problem) = tile.state { problem.label } else { nil }
        let task = tile.task.map { "#\($0.number) \($0.title)" }
        let detail = [machine, task].compactMap { $0 }.joined(separator: "・")
        let title = tile.conversation.displayTitle
        Button {
            model.navigate(to: .conversation(tile.id), from: .attention)
        } label: {
            PhoneListRow(title: title, glyph: TaskRowGlyph(status: .blocked)) {
                if let label { Text(verbatim: label).foregroundStyle(.orange) }
                if !detail.isEmpty { Text(verbatim: detail).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title, label, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: "、"))
    }
}

/// マシン 1 台の節。見出しはマシン名と利用枠、最初の節にオーケストレーターとタスクなし、続けてピン留めと列（並べ方の分け方）の節
private struct PhoneMachineSections: View {
    @Environment(AppModel.self) private var model
    let fleetID: String
    let state: MachineState
    let waiting: [TaskKey: [InboxItem]]

    var body: some View {
        let name = model.machineName(fleetID: fleetID, state: state)
        let boards = model.orderedBoards(state, fleetID: fleetID)
        let active = model.sidebarActiveTasks(state)
        Section {
            if let machine = state.machine?.id {
                if let row = model.orchestratorRow(on: machine) {
                    NavigationLink(value: PhoneRoute.item(.orchestrator(machine: machine))) {
                        Label {
                            Text("オーケストレーター")
                                .badge(Text(verbatim: row.statusLabel))
                        } icon: {
                            OrchestratorGlyph(row: row)
                        }
                    }
                }
                UnassignedTreeRow(machine: machine, selectable: false)
            }
            if boards.isEmpty {
                Text(state.connected ? "案件はありません" : "未接続").foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: Space.inline) {
                Text(name).lineLimit(1)
                if !state.connected {
                    Image(systemName: "bolt.horizontal.circle").accessibilityLabel("未接続")
                }
                Spacer(minLength: Space.row)
                MachineUsageBars(state: state, name: name)
            }
            .contextMenu { MachineMenuItems(fleetID: fleetID, state: state) }
        }
        switch model.sidebarArrangement.grouping {
        case .boards:
            ForEach(boards) { board in
                ForEach(board.orderedColumns) { column in
                    let tasks = model.sidebarTasks(in: board, column: column, state: state, waiting: waiting, active: active)
                    if !tasks.isEmpty {
                        PhoneTaskSection(
                            label: boards.count > 1 ? "\(board.name) · \(column.label)" : column.label,
                            rows: tasks.map { ($0, model.rowStatus(of: $0, waiting: waiting[$0.id] ?? [])) })
                    }
                }
            }
        case .state:
            ForEach(model.sidebarStateGroups(on: state, fleetID: fleetID, waiting: waiting, active: active), id: \.group) { group, rows in
                PhoneTaskSection(label: group.label, rows: rows.map { ($0.task, $0.status) })
            }
        case .none:
            let tasks = model.sidebarTasks(on: state, fleetID: fleetID, waiting: waiting, active: active)
            if !tasks.isEmpty {
                PhoneTaskSection(label: String(localized: "タスク"), rows: tasks.map { ($0, model.rowStatus(of: $0, waiting: waiting[$0.id] ?? [])) })
            }
        }
    }
}

/// 列（か並べ方の組）の節。見出しに数
private struct PhoneTaskSection: View {
    let label: String
    let rows: [(task: BoardTask, status: TaskRowStatus?)]

    var body: some View {
        Section {
            ForEach(rows, id: \.task.id) { row in
                PhoneTaskRow(task: row.task, status: row.status)
            }
        } header: {
            HStack {
                Text(verbatim: label).lineLimit(1)
                Spacer()
                Text(verbatim: "\(rows.count)")
            }
        }
    }
}

/// タスクの 1 行。番号と題を 2 行まで、下に札と委譲先の進み。会話が 1 つなら押すとその会話を、2 つ以上か無ければタスクの画面を開く
private struct PhoneTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    let status: TaskRowStatus?

    var body: some View {
        let progress = model.delegateProgress(of: task).map { String(localized: "委譲先\($0.total)件中\($0.done)件済み") }
        let background = model.runningBackgroundTasks(of: task)
        let situation = model.fleet.machineState(for: task.machine)?.situation(of: task)?.headline
        let title = "#\(task.number) \(task.title)"
        Button {
            model.openFromPhoneList(task)
        } label: {
            PhoneListRow(title: title, glyph: TaskRowGlyph(status: status)) {
                if let status {
                    Text(status.label).foregroundStyle(status.isMine ? Color.orange : Color.secondary)
                }
                if let progress {
                    Text(progress).foregroundStyle(.secondary)
                }
                BackgroundTasksGlyph(count: background)
                if let situation, !situation.isEmpty {
                    Text(verbatim: situation).foregroundStyle(.secondary).layoutPriority(-1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { TaskRowMenuItems(task: task, status: status) }
        .accessibilityLabel([title, status?.label, progress, situation].compactMap { $0 }.joined(separator: "、"))
    }
}

/// 一覧の行の形。左に印、右に題（2 行まで）とその下の札の行
private struct PhoneListRow<Glyph: View, Caption: View>: View {
    let title: String
    let glyph: Glyph
    @ViewBuilder let caption: Caption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            glyph
            VStack(alignment: .leading, spacing: Space.inline / 2) {
                Text(verbatim: title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Space.inline) { caption }
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

extension AppModel {
    /// iPhone の一覧の行を押したとき。会話が 1 つだけのタスクはその会話を、ほかはタスクの画面を積む。どちらも戻ると一覧
    func openFromPhoneList(_ task: BoardTask) {
        let rows = taskSessions(for: task).rows
        guard rows.count == 1, let only = rows.first else {
            navigate(to: .task(task.id, revealBoard: false), from: .sidebar)
            // `navigate` は裏に案件のボードを積む（通知から開いたとき用）。一覧から開いたときは戻り先を一覧にする
            phoneTaskPath = []
            return
        }
        markRead(task)
        phoneTaskRoutes = [.conversation(only.conversation.key)]
    }
}
#endif
