import Foundation
import TaskboardKit

/// 画面の札に並べるもの（`AppModel.taskSessions(for:)`・`sessionSet(for:)`）。置き場の見分けは `MachineState.home(of:)`・`members(of:)`
struct TaskSessionSet {
    /// 札に並べる会話（lead と委譲先。終了したものを除く）。起こした側の後に委譲先
    var rows: [SessionMemberRow] = []
    /// 札で選んでいないときに出す会話（`MachineState.openingConversation`）
    var opening: Conversation?
    /// 再開の候補の記録（今ある会話に無いもの。新しい順）
    var stopped: [TaskSessionRef] = []
    /// 終了した会話（札に出さず、右の欄の履歴から開く）。新しい順
    var closed: [Conversation] = []

    var conversations: [Conversation] { rows.map(\.conversation) }
}

/// 右の欄の「終了したセッション」の 1 行。再開の候補の記録（［再開］）か、終了した会話（［開く］）
enum FinishedSession: Identifiable {
    case record(TaskSessionRef, SessionHistory?)
    case conversation(Conversation)

    var id: String {
        switch self {
        case .record(let ref, _): "record/\(ref.sessionID)"
        case .conversation(let conversation): "conversation/\(conversation.id)"
        }
    }

    /// 行に出す最後の更新の時刻
    var date: Date {
        switch self {
        case .record(let ref, let history): history?.updatedAt ?? ref.linkedAt
        case .conversation(let conversation): conversation.updatedAt
        }
    }
}

/// タスクに紐づく会話と、終了したセッションの記録
extension AppModel {
    /// タスクのパネル・iPhone のタスクの画面・削除の確認が見る、タスクの会話
    func taskSessions(for task: BoardTask) -> TaskSessionSet {
        guard let state = fleet.machineState(for: task.machine) else { return TaskSessionSet() }
        return TaskSessionSet(
            rows: state.members(of: .task(task.number)).filter { !$0.conversation.isClosed }, opening: state.openingConversation(of: task),
            stopped: state.stoppedSessions(of: task), closed: state.conversations(of: task).filter(\.isClosed).sorted { $0.updatedAt > $1.updatedAt })
    }

    /// 右の欄の「終了したセッション」。記録と会話を新しい順に 1 つの並びにする（同じ時刻なら記録が先）
    func finishedSessions(of task: BoardTask, in sessions: TaskSessionSet) -> [FinishedSession] {
        let records = sessions.stopped.map { FinishedSession.record($0, sessionHistory($0, on: task.machine)) }
        let all = records + sessions.closed.map(FinishedSession.conversation)
        return all.enumerated().sorted { ($0.element.date, $1.offset) > ($1.element.date, $0.offset) }.map(\.element)
    }

    /// オーケストレーターとタスクなしの画面の札（終了したものを除く）
    func sessionSet(for scope: SessionScope) -> TaskSessionSet {
        if case .task(let key) = scope, let task = fleet.task(for: key) { return taskSessions(for: task) }
        guard let state = fleet.machineState(for: scope.machine) else { return TaskSessionSet() }
        let all = state.members(of: scope.home)
        return TaskSessionSet(
            rows: all.filter { !$0.conversation.isClosed }, closed: all.map(\.conversation).filter(\.isClosed).sorted { $0.updatedAt > $1.updatedAt })
    }

    /// タスクの会話の状態（iPhone のボードの［応答待ち］［実行中］の絞り込み）。止まっていても結ばれた会話は待機として数える
    func activity(of task: BoardTask) -> Set<SidebarStatus> {
        Set((fleet.machineState(for: task.machine)?.conversations(of: task) ?? []).filter { !$0.isClosed }.map { SidebarStatus.of($0) })
    }

    /// タスクの行の［すべて終了］で終えるもの。タスク画面の札に並ぶ会話（委譲先を含む）のうち、オーケストレーターでないもの
    func endTargets(of task: BoardTask) -> TaskEndTargets {
        var targets = TaskEndTargets()
        for conversation in taskSessions(for: task).conversations where conversation.purpose != .orchestrator {
            targets.conversations.append(conversation)
            if [.running, .waiting].contains(conversation.phase) { targets.busy.append(conversation.displayTitle) }
        }
        return targets
    }

    /// ［すべて終了］。作業の途中のものがあれば、止まるものを出して確かめる
    func requestEndAll(_ task: BoardTask) {
        if endTargets(of: task).needsConfirmation {
            ask(.endTaskSessions(task.id))
        } else {
            endAll(task)
        }
    }

    func endAll(_ task: BoardTask) {
        for conversation in endTargets(of: task).conversations { close(conversation: conversation.key) }
    }

    /// 紐づいたセッションの会話の題を読み直す（タスクを開いたとき）。読めなければ前の値のまま、題の無い一覧になる
    func loadSessionHistory(for task: BoardTask) async {
        guard fleet.machineState(for: task.machine)?.stoppedSessions(of: task).isEmpty == false, fleet.terminalSource(for: task.machine) != nil,
            let histories = try? await sessionHistory(task: task.id)
        else { return }
        for history in histories { sessionHistories["\(task.machine.rawValue)/\(history.sessionID)"] = history }
    }

    func sessionHistory(_ ref: TaskSessionRef, on machine: MachineID) -> SessionHistory? {
        sessionHistories["\(machine.rawValue)/\(ref.sessionID)"]
    }

    func sessionHistory(task key: TaskKey) async throws -> [SessionHistory] {
        try await requireSource(key.machine).sessionHistory(task: key.number)
    }
}

/// ［すべて終了］で終えるもの（`AppModel.endTargets`）
struct TaskEndTargets {
    var conversations: [Conversation] = []
    /// 作業の途中のもの（生成中と確認待ち）の名前
    var busy: [String] = []

    var count: Int { conversations.count }
    var isEmpty: Bool { conversations.isEmpty }
    var needsConfirmation: Bool { !busy.isEmpty }

    /// ［すべて終了］の確認の本文
    func message(task: BoardTask) -> String {
        let busy = busy.isEmpty ? "" : String(localized: "\(busy.map { "「\($0)」" }.joined(separator: "、"))は作業の途中で終了します。")
        return String(localized: "「#\(task.number) \(task.title)」のセッションをすべて終了しますか？") + "\u{3000}" + busy
    }
}
