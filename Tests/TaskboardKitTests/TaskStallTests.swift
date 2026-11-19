import Foundation
import Testing

@testable import TaskboardKit

@Suite("動いていないタスク")
struct TaskStallTests {
    private let machine = MachineID(rawValue: "m-test")
    private let calendar = Calendar(identifier: .gregorian)
    private var now: Date { BoardTask.dateFormatter.date(from: "2026-10-12")!.addingTimeInterval(10 * 3600) }

    private func daysAgo(_ days: Int, hours: Double = 0) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!.addingTimeInterval(hours * 3600)
    }

    private func task(_ number: Int = 1, column: String = "working", updated: Date, linked: Bool = false, board: String = "b") -> BoardTask {
        BoardTask(
            machine: machine, number: number, boardID: board, columnID: column, title: "題\(number)",
            sessions: linked ? [TaskSessionRef(id: 1, agent: "claude", sessionID: "s\(number)", cwd: "", linkedAt: updated)] : [],
            createdAt: updated, updatedAt: updated)
    }

    private func work(_ id: Int64, task number: Int = 1, state: WorkItem.State = .doing, updated: Date) -> WorkItem {
        WorkItem(
            machine: machine, itemID: id, taskNumber: number, title: "項目", state: state, position: 0, source: "session",
            createdAt: updated, updatedAt: updated)
    }

    private func stall(_ task: BoardTask, _ items: [WorkItem] = [], terminal: Bool = false) -> TaskStall? {
        task.stall(workItems: items, terminal: terminal, now: now, calendar: calendar)
    }

    @Test("日付の差で 3 日からを停滞にする（時刻の細かさは見ない）")
    func threshold() {
        let started = [work(1, updated: .distantPast)]
        #expect(stall(task(updated: daysAgo(3)), started) == TaskStall(since: daysAgo(3), days: 3))
        // 72 時間に満たなくても、日付が 3 日違えば 3 日
        #expect(stall(task(updated: daysAgo(3, hours: 13)), started)?.days == 3)
        #expect(stall(task(updated: daysAgo(2)), started) == nil)
        #expect(stall(task(updated: daysAgo(0)), started) == nil)
        #expect(stall(task(updated: daysAgo(40)), started)?.days == 40)
    }

    @Test("着手済み（セッションが結ばれているか、作業項目がある）のタスクだけを見る")
    func onlyStarted() {
        #expect(stall(task(updated: daysAgo(10))) == nil)
        #expect(stall(task(updated: daysAgo(10), linked: true))?.days == 10)
        #expect(stall(task(updated: daysAgo(10)), [work(1, updated: daysAgo(10))])?.days == 10)
    }

    @Test("常設と終端の列は数えない。ほかの列は id によらず数える")
    func columns() {
        #expect(stall(task(column: BoardColumn.standingID, updated: daysAgo(10), linked: true)) == nil)
        #expect(stall(task(column: "done", updated: daysAgo(10), linked: true), terminal: true) == nil)
        for column in ["review_req", "todo", "planning", "working", "review", "deploying", "custom"] {
            #expect(stall(task(column: column, updated: daysAgo(5), linked: true))?.days == 5, "\(column)")
        }
    }

    @Test("作業項目だけが新しければ、作業項目の時刻から数える")
    func newestWorkItem() {
        let old = task(updated: daysAgo(10))
        #expect(stall(old, [work(1, updated: daysAgo(10)), work(2, updated: daysAgo(1))]) == nil)
        #expect(stall(old, [work(1, updated: daysAgo(10)), work(2, updated: daysAgo(4))]) == TaskStall(since: daysAgo(4), days: 4))
    }

    @Test("残りの作業項目が全部待ちのタスクは停滞にならない（終わった項目は数えない）")
    func onlyWaitsLeft() {
        let old = task(updated: daysAgo(10))
        let at = daysAgo(10)
        #expect(stall(old, [work(1, state: .wait, updated: at), work(2, state: .done, updated: at), work(3, state: .drop, updated: at)]) == nil)
        #expect(stall(old, [work(1, state: .wait, updated: at), work(2, state: .wait, updated: at)]) == nil)
    }

    @Test("待ちと未着手が混じっていれば停滞になる。作業項目が全部終わっていても、作業項目が無くセッションだけでも停滞になる")
    func waitsMixed() {
        let old = task(updated: daysAgo(10))
        let at = daysAgo(10)
        #expect(stall(old, [work(1, state: .wait, updated: at), work(2, state: .todo, updated: at)])?.days == 10)
        #expect(stall(old, [work(1, state: .done, updated: at)])?.days == 10)
        #expect(stall(task(updated: at, linked: true))?.days == 10)
    }

    @Test("札の文は日数だけ")
    func label() {
        #expect(TaskStall(since: now, days: 3).label == "3日更新なし")
    }

    private func state(tasks: [BoardTask], workItems: [WorkItem] = []) -> MachineState {
        var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        state.boards["b"] = Board(id: "b", machine: machine, name: "案件", position: 0, columns: BoardColumn.standard, createdAt: .distantPast)
        state.tasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        state.workItems = Dictionary(uniqueKeysWithValues: workItems.map { (WorkItemKey(machine: machine, id: $0.itemID), $0) })
        return state
    }

    @Test("受信箱には着手済みの停滞タスクだけがお知らせで出て、まとめて起票しただけのタスクは出ない")
    func inbox() {
        let tasks = [
            task(1, column: "deploying", updated: daysAgo(5)),
            task(2, column: "planning", updated: daysAgo(5), linked: true),
            task(3, column: "todo", updated: daysAgo(5)),
            task(4, column: "planning", updated: daysAgo(5)),
            task(5, column: "done", updated: daysAgo(5), linked: true),
            task(6, column: "working", updated: daysAgo(1), linked: true),
        ]
        let items = state(tasks: tasks, workItems: [work(1, task: 1, updated: daysAgo(5))]).inboxItems(now: now)
        let stalled = items.filter { if case .stalled = $0.kind { true } else { false } }
        #expect(stalled.map(\.localID).sorted() == ["stall/1", "stall/2"])
        let first = stalled.first { $0.localID == "stall/1" }!
        #expect(first.group == .notice)
        #expect(first.title == "#1 題1")
        #expect(first.details == ["デプロイ中", "5日更新なし"])
        #expect(first.at == daysAgo(5))
        #expect(first.kind.label == "更新のないタスク")
    }

    @Test("revision は停滞の起点。動けば消え、また止まれば別の revision で出直す")
    func revisionFollowsSince() {
        let linked = task(column: "working", updated: daysAgo(5), linked: true)
        let item = state(tasks: [linked]).inboxItems(now: now).first { $0.localID == "stall/1" }!
        var dismissed = state(tasks: [linked])
        dismissed.inboxDismissals = ["stall/1": InboxDismissal(itemID: "stall/1", revision: item.revision, dismissedAt: now)]
        #expect(dismissed.inbox(now: now).items.contains { $0.localID == "stall/1" } == false)

        var moved = linked
        moved.updatedAt = daysAgo(1)
        dismissed.tasks[moved.id] = moved
        #expect(dismissed.inbox(now: now).items.contains { $0.localID == "stall/1" } == false)
        moved.updatedAt = daysAgo(1)
        let later = calendar.date(byAdding: .day, value: 3, to: now)!
        let back = dismissed.inbox(now: later).items.first { $0.localID == "stall/1" }
        #expect(back != nil)
        #expect(back?.revision != item.revision)
    }

    @Test("通知は出さない（通知の種類に当たらない）")
    func noNotification() {
        let item = state(tasks: [task(updated: daysAgo(5), linked: true)]).inboxItems(now: now).first { $0.localID == "stall/1" }!
        #expect(NotifyKind.of(item) == nil)
        #expect(InboxNotification.make(item, machineName: "m") == nil)
    }
}
