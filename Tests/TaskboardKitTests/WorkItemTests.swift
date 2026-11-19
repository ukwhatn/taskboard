import Foundation
import Testing

@testable import TaskboardKit

@Suite("作業項目")
struct WorkItemTests {
    private let machine = MachineID(rawValue: "m1")
    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    private func item(_ id: Int64, _ title: String, _ state: WorkItem.State, deps: [Int64] = [], position: Int? = nil, blocker: WorkItem.BlockerKind? = nil, blockerText: String = "", tone: WorkItem.BlockerTone? = nil) -> WorkItem {
        WorkItem(
            machine: machine, itemID: id, taskNumber: 1, title: title, state: state, blockerKind: blocker, blockerText: blockerText,
            blockerTone: tone, dependsOn: deps, position: position ?? Int(id), source: "session", createdAt: t0, updatedAt: t0)
    }

    @Test("todo は依存が全部 done / drop になると着手できる。一覧に無い id への依存は塞がない")
    func readiness() {
        let a = item(1, "設計", .done)
        let b = item(2, "実装", .todo, deps: [1])
        let c = item(3, "テスト", .todo, deps: [2])
        let d = item(4, "消えた項目に依存", .todo, deps: [99])
        let e = item(5, "見送りに依存", .todo, deps: [6])
        let f = item(6, "見送り", .drop)
        let states = WorkItem.effectiveStates(of: [a, b, c, d, e, f])
        #expect(states[2] == .ready)
        #expect(states[3] == .todo)
        #expect(states[4] == .ready)
        #expect(states[5] == .ready)
        #expect(states[6] == .drop)
    }

    @Test("互いに依存する項目があっても止まらず、どちらも着手不可になる")
    func cycleDoesNotHang() {
        let a = item(1, "A", .todo, deps: [2])
        let b = item(2, "B", .todo, deps: [1])
        let c = item(3, "自分に依存", .todo, deps: [3])
        let states = WorkItem.effectiveStates(of: [a, b, c])
        #expect(states[1] == .todo)
        #expect(states[2] == .todo)
        #expect(states[3] == .todo)
    }

    @Test("待ちの 1 行は blocker の文を優先し、無ければ種別の文。色は tone → 種別の既定の順")
    func waitLine() {
        let plain = item(1, "x", .wait, blocker: .review)
        #expect(plain.waitLine == WaitLine(text: "レビュー待ち", tone: .quiet), "承認以外の待ちは「待つだけ」の灰")
        let text = item(2, "x", .wait, blocker: .approval, blockerText: "ユーザーの承認待ち（計画 #3）")
        #expect(text.waitLine?.text == "ユーザーの承認待ち（計画 #3）")
        #expect(text.waitLine?.tone == .mine)
        let overridden = item(3, "x", .wait, blocker: .approval, tone: .dim)
        #expect(overridden.waitLine?.tone == .quiet)
        let bare = item(4, "x", .wait)
        #expect(bare.waitLine == WaitLine(text: "待ち", tone: .quiet))
        #expect(item(5, "x", .doing, blocker: .review).waitLine == nil, "待ち以外は blocker が残っていても 1 行を出さない")
    }

    @Test("進捗は見送りを母数から外し、作業中・待ち・着手可を計画順に数える")
    func progress() throws {
        #expect(TaskProgress.derive([]) == nil)
        let items = [
            item(1, "設計", .done, position: 0),
            item(2, "実装 A", .doing, position: 1),
            item(3, "実装 B", .wait, position: 2, blocker: .ci),
            item(4, "テスト", .todo, deps: [2, 3], position: 3),
            item(5, "文書", .todo, position: 4),
            item(6, "やめた", .drop, position: 5),
        ]
        let progress = try #require(TaskProgress.derive(items.shuffled()))
        #expect(progress.total == 5)
        #expect(progress.done == 1)
        #expect(progress.current.map(\.itemID) == [2])
        #expect(progress.waiting.map(\.itemID) == [3])
        #expect(progress.ready == 1)
        #expect(progress.currentLabel == "実装 A")
        #expect(progress.fractionLabel == "1 / 5")

        var two = items
        two[2].state = .doing
        #expect(TaskProgress.derive(two)?.currentLabel == "2件を作業中")
        #expect(TaskProgress.derive([items[0]])?.currentLabel == nil)
    }

    @Test("タスクの待ち理由は作業項目の待ちを最優先にする")
    func taskWaitLinePrefersWorkItems() {
        let task = BoardTask(machine: machine, number: 1, boardID: "b", columnID: "working", title: "t", createdAt: t0, updatedAt: t0)
        let waiting = item(1, "CI", .wait, blocker: .ci, blockerText: "CI 待ち（3 分）")
        #expect(task.waitLine(CardSignals(workItems: [waiting]), today: t0)?.text == "CI 待ち（3 分）")
        // 自分の番（承認）は、計画順で後ろにあっても CI 待ちより先に出す
        let approval = item(2, "承認", .wait, blocker: .approval, blockerText: "計画の承認を待っている")
        #expect(task.waitLine(CardSignals(workItems: [waiting, approval]), today: t0) == WaitLine(text: "計画の承認を待っている", tone: .mine))
        #expect(TaskProgress.derive([waiting, approval])?.primaryWait?.tone == .mine)
        #expect(task.waitLine(CardSignals(workItems: [item(2, "x", .doing)]), today: t0) == nil)
    }
}
