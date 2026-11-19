import Foundation
import TaskboardKit

/// タスクなしの画面から、タスクを追加して紐づけるか、既存のタスクに紐づけるもの
enum TaskLinkTarget: Hashable, Identifiable {
    case conversation(ConversationKey)
    case pullRequest(url: String, title: String, machine: MachineID)

    var id: Self { self }

    var machine: MachineID {
        switch self {
        case .conversation(let key): key.machine
        case .pullRequest(_, _, let machine): machine
        }
    }
}

/// タスクなしの画面の［タスクを追加…］［タスクに紐づける…］
extension AppModel {
    /// 操作を出すか。書き込めない接続先と、daemon が紐づけを覚えられないもの（オーケストレーター）には出さない
    func canAttach(_ target: TaskLinkTarget) -> Bool {
        guard canWrite(target.machine) else { return false }
        switch target {
        case .conversation(let key): return fleet.conversation(for: key).flatMap { Self.linkRequest($0, task: 0) } != nil
        case .pullRequest: return true
        }
    }

    /// 起票のタイトルとシートの見出しの下に出す名前
    func name(of target: TaskLinkTarget) -> String {
        switch target {
        case .conversation(let key): fleet.conversation(for: key)?.displayTitle ?? ""
        case .pullRequest(_, let title, _): title
        }
    }

    /// 紐づける先の候補：そのマシンの案件（アーカイブしたものを除く）のタスク。進行中の列のものが先で、それぞれ最近動いた順
    func linkTargets(on machine: MachineID) -> [BoardTask] {
        guard let state = fleet.machineState(for: machine) else { return [] }
        let boards = Dictionary(orderedBoards(on: machine).map { ($0.id, $0) }) { first, _ in first }
        func isOpen(_ task: BoardTask) -> Bool { boards[task.boardID]?.columns.first { $0.id == task.columnID }?.kind != .terminal }
        return state.tasks.values
            .filter { boards[$0.boardID] != nil }
            .sorted { isOpen($0) != isOpen($1) ? isOpen($0) : ($0.updatedAt, $0.number) > ($1.updatedAt, $1.number) }
    }

    /// 候補の絞り込み。番号（「12」「#12」）が一致するか、タイトルに含む
    static func task(_ task: BoardTask, matches query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if let number = Int(query.hasPrefix("#") ? String(query.dropFirst()) : query) { return number == task.number }
        return task.title.localizedStandardContains(query)
    }

    /// 起票の下書き。案件はそのマシンのサイドバーの先頭、タイトルは名前。PR はリンクに入れ、会話は追加した後に紐づける
    func newTaskDraft(for target: TaskLinkTarget) -> NewTaskDraft? {
        guard let board = orderedBoards(on: target.machine).first else { return nil }
        var draft = NewTaskDraft(board: board)
        draft.title = name(of: target)
        switch target {
        case .conversation(let key): draft.attach = key
        case .pullRequest(let url, _, _): draft.links = [url, ""]
        }
        return draft
    }

    /// 会話はタスクに紐づけ、PR はタスクのリンクに足す
    func attach(_ target: TaskLinkTarget, to task: BoardTask) async throws {
        switch target {
        case .conversation(let key):
            guard let conversation = fleet.conversation(for: key) else { return }
            try await link(conversation, to: task)
        case .pullRequest(let url, _, _):
            try await addLinks([url], to: task)
        }
    }
}
