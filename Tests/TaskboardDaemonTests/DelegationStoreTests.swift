import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("Store: 委任範囲")
struct DelegationStoreTests {
    private let machine = MachineID(rawValue: "m-test")

    private func makeStore() throws -> (Store, Board, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "planning", title: "設計"))
        return (store, board, task)
    }

    @Test("段階はタスクの上書き → 案件の初期値 → 組み込みの初期値の順に決まり、空の指定で戻せる")
    func levels() throws {
        let (store, board, task) = try makeStore()
        #expect(task.delegation(board: board).map(\.level) == [.delegate, .delegate, .report, .ask, .ask, .ask, .ask])
        #expect(task.delegation(board: board).allSatisfy { $0.source == .builtin })

        let edited = try store.editBoard(id: board.id, BoardUpdateRequest(delegation: DelegationScope([.reviewMerge: .delegate, .tracker: .report]))).board
        #expect(edited.delegation == DelegationScope([.reviewMerge: .delegate, .tracker: .report]))
        let updated = try store.updateTask(number: task.number, TaskUpdateRequest(delegation: DelegationScope([.reviewMerge: .ask, .cost: .report])))
        let entries = Dictionary(uniqueKeysWithValues: updated.delegation(board: edited).map { ($0.area, $0) })
        #expect(entries[.reviewMerge] == DelegationEntry(area: .reviewMerge, level: .ask, source: .task))
        #expect(entries[.tracker] == DelegationEntry(area: .tracker, level: .report, source: .board))
        #expect(entries[.cost] == DelegationEntry(area: .cost, level: .report, source: .task))
        #expect(entries[.destructive] == DelegationEntry(area: .destructive, level: .ask, source: .builtin))

        #expect(try store.task(number: task.number)?.delegation == updated.delegation, "読み直しても同じ")
        let cleared = try store.updateTask(number: task.number, TaskUpdateRequest(delegation: DelegationScope()))
        #expect(cleared.delegation.isEmpty)
        let other = try store.updateTask(number: task.number, TaskUpdateRequest(title: "題だけ"))
        #expect(other.delegation.isEmpty, "delegation を送らない更新は上書きに触らない")
    }
}
