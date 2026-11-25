import Foundation
import TaskboardKit

extension AppModel {
    /// タスクを消す。作業項目・文書も daemon が一緒に消し、state からは daemon の `task.removed` で消える。紐づくセッションは止めない
    func deleteTask(_ task: BoardTask) {
        guard let source = source(for: task.machine) else { return }
        let window = beginAction()
        Task {
            do {
                try await source.deleteTask(number: task.number)
                if selectedTask == task.id { closeTask() }
            } catch {
                fail("タスクを削除できませんでした", error, in: window)
            }
        }
    }
}

extension AppModel {
    func create(task request: TaskCreateRequest, on machine: MachineID) async throws -> BoardTask {
        guard let source = source(for: machine) else { throw ActionError.notWritable(fleet.writeAccess(machine)) }
        return try await source.createTask(request)
    }

    func move(task: BoardTask, to columnID: String) {
        guard let source = source(for: task.machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.updateTask(number: task.number, TaskUpdateRequest(columnID: columnID))
            } catch {
                fail("タスクを移動できませんでした", error, in: window)
            }
        }
    }

    /// 別の案件へ移す。列を指定しなければ daemon が決める（同じ id の列か、行き先の常設とレビュー依頼を除く最初の進行中の列）
    func move(task: BoardTask, toBoard board: Board, column columnID: String? = nil) {
        guard board.id != task.boardID, let source = source(for: task.machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.updateTask(number: task.number, TaskUpdateRequest(columnID: columnID, boardID: board.id))
            } catch {
                fail("タスクを別の案件に移動できませんでした", error, in: window)
            }
        }
    }

    /// 隣の列へ（⌥⌘← / ⌥⌘→）。端なら動かさない
    func moveSelectedTask(by offset: Int) {
        guard let key = keyboardTarget, let task = fleet.task(for: key), let board = fleet.board(id: task.boardID, on: task.machine),
            let column = board.column(nextTo: task.columnID, by: offset)
        else { return }
        move(task: task, to: column.id)
    }

    /// カードの待ち理由とチップに使う材料
    func cardSignals(for task: BoardTask) -> CardSignals {
        let state = fleet.machineState(for: task.machine)
        let urls = Set(task.links.map(\.url))
        let column = fleet.board(id: task.boardID, on: task.machine)?.columns.first { $0.id == task.columnID }
        let linked = state?.prs?.pullRequests.filter { urls.contains($0.url) } ?? []
        return CardSignals(
            workItems: fleet.workItems(for: task.id),
            links: task.links.compactMap { state?.links[$0.url] },
            reviewRequested: linked.contains { $0.category == .reviewRequested },
            reviewed: linked.contains { $0.category == .reviewed },
            reviewerPullRequests: Set(linked.filter { [.reviewRequested, .reviewed].contains($0.category) }.map(\.url)),
            terminal: column?.kind == .terminal, conversations: state?.conversations(of: task).filter { !$0.isClosed } ?? [])
    }

    func update(task: BoardTask, _ request: TaskUpdateRequest) {
        guard let source = source(for: task.machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.updateTask(number: task.number, request)
            } catch {
                fail("タスクを保存できませんでした", error, in: window)
            }
        }
    }

    func addWorkItem(to task: BoardTask, title: String) {
        guard let source = source(for: task.machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.createWorkItem(task: task.number, WorkItemCreateRequest(title: title, source: "manual"))
            } catch {
                fail("作業項目を追加できませんでした", error, in: window)
            }
        }
    }

    func updateWorkItem(_ item: WorkItem, _ request: WorkItemUpdateRequest) {
        guard let source = source(for: item.machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.updateWorkItem(id: item.itemID, request)
            } catch {
                fail("作業項目を保存できませんでした", error, in: window)
            }
        }
    }

    /// 頼まれた手作業を済ませる。項目は作業中に戻り、済んだことは daemon が会話へ届ける
    func finishManualWork(_ item: WorkItem) {
        guard let source = source(for: item.machine) else { return }
        let window = beginAction()
        Task {
            do {
                try await source.finishManualWork(id: item.itemID)
            } catch {
                fail("手作業を対応済みにできませんでした", error, in: window)
            }
        }
    }

    /// 会話のタスクで頼まれている手作業（受信箱の手作業の依頼と同じもの）。委譲先の会話には出さない（頼んだのはタスクの lead）
    func manualWork(forConversation key: ConversationKey) -> [WorkItem] {
        guard let state = fleet.machineState(for: key.machine), let conversation = state.conversations[key], let number = conversation.taskNumber,
            !state.isDelegate(conversation)
        else { return [] }
        let task = TaskKey(machine: key.machine, number: number)
        return inboxItems.compactMap { item in
            guard item.taskKey == task, case .manualWork(let work) = item.kind else { return nil }
            return work
        }
    }

    func deleteWorkItem(_ item: WorkItem) {
        guard let source = source(for: item.machine) else { return }
        let window = beginAction()
        Task {
            do {
                try await source.deleteWorkItem(id: item.itemID)
            } catch {
                fail("作業項目を削除できませんでした", error, in: window)
            }
        }
    }
}
