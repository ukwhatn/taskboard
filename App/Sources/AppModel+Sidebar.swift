import Foundation
import TaskboardKit

/// サイドバーのタスクの行の札。対応待ち（無視していない受信箱の項目）が先、次にこの端末で見ていないターンの終わり、
/// 動いているセッション、リンクの PR の順。並びは case の順（強いものが先）
enum TaskRowStatus: CaseIterable, Comparable {
    case blocked, question, planApproval, manualWork, reviewRequested, changesRequested, ciFailed, unread, running, ciPassed, merged

    var label: String {
        switch self {
        case .blocked: String(localized: "応答待ち")
        case .question: String(localized: "回答待ち")
        case .planApproval: String(localized: "計画の承認待ち")
        case .manualWork: String(localized: "手作業待ち")
        case .reviewRequested: String(localized: "レビュー依頼あり")
        case .changesRequested: String(localized: "修正依頼あり")
        case .ciFailed: String(localized: "CI失敗")
        case .unread: String(localized: "未読")
        case .running: String(localized: "実行中")
        case .ciPassed: String(localized: "CI成功")
        case .merged: PullRequestLinkState.State.merged.label
        }
    }

    /// 自分の番か（橙にする）。未読・実行中・PR の札は知らせで、未読と PR はそれぞれの色を持つ
    var isMine: Bool { self < .unread }

    /// 対応待ちの項目の札。お知らせと、タスクの行に出さない種類は nil
    init?(_ item: InboxItem) {
        guard item.group == .waiting else { return nil }
        switch item.kind {
        case .conversationRequest(_, let request) where request.kind == .plan: self = .planApproval
        case .conversationRequest(_, let request): self = request.waiting.permissionPrompt == nil ? .question : .blocked
        case .question, .panelDraft: self = .question
        case .reviewRequest: self = .reviewRequested
        case .manualWork: self = .manualWork
        case .pullRequestTurn(_, .reviewRequested): self = .reviewRequested
        case .pullRequestTurn(_, .changesRequested): self = .changesRequested
        case .pullRequestTurn(_, .ciFailed): self = .ciFailed
        default: return nil
        }
    }

    /// リンクの PR の札。開いている PR が全部 CI 成功なら CI成功、開いている PR が無く、マージ済みがあればマージ済み
    static func pullRequest(_ pullRequests: [PullRequestLinkState]) -> TaskRowStatus? {
        let open = pullRequests.filter { $0.state == .open }
        if !open.isEmpty { return open.allSatisfy { $0.checks == .success } ? .ciPassed : nil }
        return pullRequests.contains { $0.state == .merged } ? .merged : nil
    }
}

/// 委譲先の進み（済んだ数と全部）。済んだのは終了した会話
struct DelegateProgress: Equatable {
    let done: Int
    let total: Int

    var label: String { String(localized: "\(done)/\(total)") }
}

/// マシンのタスクなしの画面の中身（`AppModel.unassigned(on:)`）
struct UnassignedContents {
    /// どのタスクにも結ばれていないセッションと会話（終えたものを除く）
    var sessions: TaskSessionSet
    /// タスクに結ばれていない定期起動
    var schedules: [Schedule]

    var isEmpty: Bool { sessions.rows.isEmpty && schedules.isEmpty }
}

/// サイドバーの木（マシン → 案件 → 列 → タスク、マシンのタスクなし）
extension AppModel {
    /// タスクごとの、無視していない対応待ち（サイドバーの木の根で 1 回だけ作る）
    var waitingItemsByTask: [TaskKey: [InboxItem]] {
        Dictionary(grouping: inboxItems.filter { $0.group == .waiting && $0.taskKey != nil }) { $0.taskKey! }
    }

    /// タスクの行の札。無視していない対応待ち（`waiting`）の強いもの、無ければこの端末で見ていないターンの終わり、
    /// 動いている lead・委譲先、リンクの PR の順
    func rowStatus(of task: BoardTask, waiting: [InboxItem]) -> TaskRowStatus? {
        if let waiting = waiting.compactMap(TaskRowStatus.init).min() { return waiting }
        let conversations = taskSessions(for: task).conversations
        if conversations.contains(where: unreadMarks.isUnread) { return .unread }
        if conversations.contains(where: { [.running, .starting].contains($0.phase) }) { return .running }
        let links = fleet.machineState(for: task.machine)?.links ?? [:]
        return TaskRowStatus.pullRequest(task.links.compactMap { links[$0.url]?.pullRequest })
    }

    /// タスクの行の［既読にする］を出すか
    func hasUnread(_ task: BoardTask) -> Bool {
        taskSessions(for: task).conversations.contains(where: unreadMarks.isUnread)
    }

    /// タスクの会話の未読を消す（タスクを開いたときと、行の［既読にする］）
    func markRead(_ task: BoardTask) {
        let conversations = taskSessions(for: task).conversations
        guard conversations.contains(where: unreadMarks.isUnread) else { return }
        unreadMarks.markRead(conversations)
    }

    /// 見回りで未読の印を付け直す。突き合わせるのは state を受けたマシンだけ。画面に出している会話には印を付けない
    func observeUnread() {
        var listed: [MachineID: MachineState] = [:]
        for state in fleet.allMachines.values where state.connected {
            if let machine = state.machine?.id { listed[machine] = state }
        }
        let shown = Set(conversationFeeds.keys.filter { conversationFeeds.peek($0)?.isOnScreen == true })
        var next = unreadMarks
        if next.observe(listed, shown: shown) { unreadMarks = next }
    }

    /// タスクの会話で動いている裏のタスクの数（タスクの行の印）
    func runningBackgroundTasks(of task: BoardTask) -> Int {
        taskSessions(for: task).conversations.runningBackgroundTasks
    }

    /// 委譲先の進み。委譲先が無ければ nil
    func delegateProgress(of task: BoardTask) -> DelegateProgress? {
        guard let state = fleet.machineState(for: task.machine) else { return nil }
        let delegates = state.members(of: .task(task.number)).filter { $0.depth > 0 }
        guard !delegates.isEmpty else { return nil }
        return DelegateProgress(done: delegates.filter(\.conversation.isClosed).count, total: delegates.count)
    }

    /// サイドバーの列の節に出すタスク（並べ方の並び順）。終了していない会話か、対応待ち（`waiting`）のあるタスクだけで、
    /// どちらも無いタスク（寝かせている未着手など）はボードから開く
    func sidebarTasks(in board: Board, column: BoardColumn, state: MachineState, waiting: [TaskKey: [InboxItem]], active: Set<Int>) -> [BoardTask] {
        sidebarArrangement.sorted(
            state.tasks.values.filter {
                $0.boardID == board.id && $0.columnID == column.id && (active.contains($0.number) || waiting[$0.id] != nil)
            },
            lastActivity: { self.lastActivity(of: $0, in: state) })
    }

    /// 案件で分けないときにマシンの段に出すタスク（並べ方の並び順）。出す条件は `sidebarTasks` と同じで、サイドバーに出す案件のものだけ
    func sidebarTasks(on state: MachineState, fleetID: String, waiting: [TaskKey: [InboxItem]], active: Set<Int>) -> [BoardTask] {
        let boards = Set(orderedBoards(state, fleetID: fleetID).map(\.id))
        return sidebarArrangement.sorted(
            state.tasks.values.filter { boards.contains($0.boardID) && (active.contains($0.number) || waiting[$0.id] != nil) },
            lastActivity: { self.lastActivity(of: $0, in: state) })
    }

    /// サイドバーの先頭の「ピン留め」の組（ピン留めした順か、並べ替えた順）。全部のマシンのものを 1 つにまとめ、動いていなくても、どの案件のものでも出す。元の組にも出す
    func pinnedSidebarTasks() -> [BoardTask] {
        let shown = Set(orderedMachines.compactMap { $0.state.machine?.id })
        return pinnedTasks.filter { shown.contains($0.machine) }.compactMap { fleet.task(for: $0) }
    }

    func setPinned(_ task: BoardTask, _ pinned: Bool) {
        pinnedTasks.removeAll { $0 == task.id }
        if pinned { pinnedTasks.append(task.id) }
    }

    /// ピン留めの組の List の `onMove`。組に出ていないもの（接続していないマシンなど）は後ろに残す
    func movePinned(from source: IndexSet, to destination: Int) {
        var shown = pinnedSidebarTasks().map(\.id)
        shown.move(fromOffsets: source, toOffset: destination)
        let hidden = pinnedTasks.filter { !shown.contains($0) }
        pinnedTasks = shown + hidden
    }

    /// 行のメニューの［上へ移動］［下へ移動］
    func movePinned(_ task: BoardTask, by offset: Int) {
        let shown = pinnedSidebarTasks().map(\.id)
        guard let index = shown.firstIndex(of: task.id), shown.indices.contains(index + offset) else { return }
        movePinned(from: [index], to: offset > 0 ? index + offset + 1 : index + offset)
    }

    /// 状態で分けたときの組（中身のある組だけ、`SidebarStateGroup` の順）。行の札も一緒に返す（行で引き直さない）
    func sidebarStateGroups(on state: MachineState, fleetID: String, waiting: [TaskKey: [InboxItem]], active: Set<Int>)
        -> [(group: SidebarStateGroup, rows: [(task: BoardTask, status: TaskRowStatus?)])]
    {
        let rows = sidebarTasks(on: state, fleetID: fleetID, waiting: waiting, active: active).map { ($0, rowStatus(of: $0, waiting: waiting[$0.id] ?? [])) }
        let grouped = Dictionary(grouping: rows) { SidebarStateGroup($0.1) }
        return SidebarStateGroup.allCases.compactMap { group in grouped[group].map { (group, $0.map { (task: $0.0, status: $0.1) }) } }
    }

    /// 並び順の「最近の動き」。タスクの更新とタスクの会話の最後の動きの新しい方
    func lastActivity(of task: BoardTask, in state: MachineState) -> Date {
        state.conversations(of: task).map(\.updatedAt).reduce(task.updatedAt, max)
    }

    // MARK: 次の入力待ち

    /// ［次の入力待ちへ移動］の行き先。全マシンの無視していない対応待ちのうち、セッション・会話が人の入力を待っているもの
    /// （応答待ち・回答待ち・計画の承認待ち）を、待ちの古い順
    var attentionItems: [InboxItem] {
        let kinds: Set<TaskRowStatus> = [.blocked, .question, .planApproval]
        return inboxItems
            .filter { TaskRowStatus($0).map(kinds.contains) == true }
            .sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    /// 待ちの古い順に 1 つずつ開く。前に開いた項目が残っていればその次（最後なら先頭）、無ければいちばん古いもの。無ければ知らせだけ出す
    func openNextAttention() {
        // ホームの会話の形では、開かずに次の対応待ちの会話を選ぶ（答えは選んだ会話の上で ⌘Y）
        if homeShowsTiles, selectedTask == nil {
            selectNextWaitingTile()
            return
        }
        let items = attentionItems
        guard !items.isEmpty else {
            inform(String(localized: "入力待ちのセッションはありません"))
            return
        }
        let next = lastAttentionItem.flatMap { id in items.firstIndex { $0.id == id } }.map { items[($0 + 1) % items.count] } ?? items[0]
        lastAttentionItem = next.id
        open(inbox: next, from: .attention)
    }

    /// 終了していない会話があるタスクの番号（`sidebarTasks` の `active`）。
    /// サイドバーの描き直しのたびに引くので、タスクごとに `taskSessions(for:)` を引かず、マシンごとに 1 回で数える
    func sidebarActiveTasks(_ state: MachineState) -> Set<Int> {
        state.activeTaskNumbers()
    }

    /// マシンのタスクなしの画面の中身
    func unassigned(on machine: MachineID) -> UnassignedContents {
        let state = fleet.machineState(for: machine)
        return UnassignedContents(
            sessions: sessionSet(for: .unassigned(machine)),
            schedules: (state.map { Array($0.schedules.values) } ?? []).filter { $0.taskNumber == nil }.sorted { $0.scheduleID < $1.scheduleID })
    }

    // MARK: 畳み

    /// 案件と列の節を開いているか。列は案件の設定の畳み（`BoardColumn.collapsed`。完了と見送りは初めから畳む）を初めの値にする
    func isSidebarNodeExpanded(_ id: String, collapsedByDefault: Bool = false) -> Bool {
        toggledSidebarNodes.contains(id) == collapsedByDefault
    }

    func setSidebarNode(_ id: String, expanded: Bool, collapsedByDefault: Bool = false) {
        if expanded == collapsedByDefault { toggledSidebarNodes.insert(id) } else { toggledSidebarNodes.remove(id) }
    }
}
