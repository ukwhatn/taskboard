import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 作業項目の段と依存の線の組み立て
@Suite struct WorkItemGraphTests {
    private static let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    private func item(_ id: Int64, _ state: WorkItem.State = .todo, deps: [Int64] = []) -> WorkItem {
        WorkItem(
            machine: MachineID(rawValue: "m1"), itemID: id, taskNumber: 1, title: "項目\(id)", state: state, blockerKind: nil, blockerText: "",
            blockerTone: nil, dependsOn: deps, position: Int(id), source: "session", createdAt: Self.t0, updatedAt: Self.t0)
    }

    /// 1 → 2・3 → 4（2 と 3 の両方の後）、5 は依存なし
    private var diamond: [WorkItem] {
        [item(1, .done), item(2, .doing, deps: [1]), item(3, deps: [1]), item(4, deps: [2, 3]), item(5)]
    }

    @Test("終わっていない項目を依存から段に分ける。完了した項目への依存は段を下げない。段の中は作業中・待ちが先で、ほかは計画順")
    func levels() {
        let graph = WorkItemGraph(items: diamond + [item(6, .wait)])
        #expect(graph.rows.map(\.id) == [2, 6, 3, 5, 4])
        #expect(graph.rows.map(\.level) == [0, 0, 0, 0, 1])
        #expect(graph.rows.map(\.header) == [.init(number: 1, count: 4), nil, nil, nil, .init(number: 2, count: 1)])
        #expect(graph.rows.map(\.state) == [.doing, .wait, .ready, .ready, .todo])
    }

    @Test("完了と見送りは段に入れず、計画順で closed に持つ")
    func closed() {
        let items = [item(1, .done), item(2), item(3, .drop), item(4, .done, deps: [1])]
        let graph = WorkItemGraph(items: items)
        #expect(graph.rows.map(\.id) == [2])
        #expect(graph.closed.map(\.id) == [1, 3, 4])
        #expect(graph.closed.map(\.state) == [.done, .drop, .done])
    }

    /// 1 → 2・3 → 4（2 と 3 の両方の後）、5 は依存なし。全部終わっていない
    private var openDiamond: [WorkItem] {
        [item(1, .doing), item(2, deps: [1]), item(3, deps: [1]), item(4, deps: [2, 3]), item(5)]
    }

    @Test("線は出元ごとに 1 本。重なる線は別の筋に置く")
    func lanes() {
        let graph = WorkItemGraph(items: openDiamond)
        #expect(graph.lanes == [.init(source: 1, targets: [2, 3], slot: 0), .init(source: 2, targets: [4], slot: 1), .init(source: 3, targets: [4], slot: 2)])
        #expect(graph.slotCount == 3)
    }

    @Test("前の線が終わった行より後から始まる線は、同じ筋を使い直す")
    func reusesSlot() {
        // 1 → 2、3 → 4。行は 1・3・2・4（段 0 と段 1）なので重なる。5 → 6 を足すと 6 は段 1
        let chain = [item(1), item(2, deps: [1]), item(3), item(4, deps: [3]), item(5, deps: [2]), item(6, deps: [5])]
        let graph = WorkItemGraph(items: chain)
        #expect(graph.rows.map(\.id) == [1, 3, 2, 4, 5, 6])
        // 1: 行 0→2、3: 行 1→3、2: 行 2→4、5: 行 4→5。5 の線は 1 の線（行 2 で終わる）の筋 0 を使える
        #expect(graph.lanes == [
            .init(source: 1, targets: [2], slot: 0), .init(source: 3, targets: [4], slot: 1),
            .init(source: 2, targets: [5], slot: 2), .init(source: 5, targets: [6], slot: 0),
        ])
    }

    @Test("行ごとに受け持つ線: 出元の行は印から下へ、間の行は通るだけ、途中の線の先は枝、最後の線の先は上から印へ")
    func marks() {
        let graph = WorkItemGraph(items: openDiamond)
        let marks = Dictionary(uniqueKeysWithValues: graph.rows.map { ($0.id, $0.marks) })
        // 行は 1・5・2・3・4。筋 0 は 1 → 2・3、筋 1 は 2 → 4、筋 2 は 3 → 4
        #expect(graph.rows.map(\.id) == [1, 5, 2, 3, 4])
        #expect(marks[1] == [.init(slot: 0, kind: .source)])
        #expect(marks[5] == [.init(slot: 0, kind: .through)])
        #expect(marks[2] == [.init(slot: 0, kind: .branch), .init(slot: 1, kind: .source)])
        #expect(marks[3] == [.init(slot: 0, kind: .target), .init(slot: 1, kind: .through), .init(slot: 2, kind: .source)])
        #expect(marks[4] == [.init(slot: 1, kind: .target), .init(slot: 2, kind: .target)])
    }

    @Test("依存の無い項目だけなら段は 1 つで、見出しも線も無い（計画順の一覧と同じ）")
    func flat() {
        let items = (1...60).map { item(Int64($0)) }
        let graph = WorkItemGraph(items: items)
        #expect(graph.rows.map(\.id) == items.map(\.itemID))
        #expect(graph.rows.allSatisfy { $0.header == nil })
        #expect(graph.lanes.isEmpty)
        #expect(graph.slotCount == 0)
    }

    @Test("循環・自分への依存・一覧に無い項目への依存があっても止まらず、全部を 1 回ずつ並べる")
    func cycles() {
        let items = [item(1, deps: [2]), item(2, deps: [1]), item(3, deps: [3]), item(4, deps: [99])]
        let graph = WorkItemGraph(items: items)
        #expect(Set(graph.rows.map(\.id)) == [1, 2, 3, 4])
        #expect(graph.rows.count == 4)
    }

    @Test("行は、出している文書の題が変わったら描き直す（項目が同じでも）")
    @MainActor
    func rowComparesDocumentTitle() {
        let doc = WorkItem(
            machine: MachineID(rawValue: "m1"), itemID: 1, taskNumber: 1, title: "計画を書く", state: .done, blockerKind: nil, blockerText: "",
            blockerTone: nil, dependsOn: [], deliverableKind: .doc, deliverableRef: "3", position: 0, source: "session", createdAt: Self.t0, updatedAt: Self.t0)
        let task = BoardTask(machine: MachineID(rawValue: "m1"), number: 1, boardID: "b", columnID: "working", title: "t", createdAt: Self.t0, updatedAt: Self.t0)
        func row(_ title: String?) -> WorkItemRow {
            WorkItemRow(item: doc, state: .done, waitsFor: [], deliverableTitle: title, task: task, update: { _ in }, delete: {})
        }
        #expect(row("フェーズ 3 計画") == row("フェーズ 3 計画"))
        #expect(row("フェーズ 3 計画") != row("フェーズ 3 計画（改）"))
    }
}
