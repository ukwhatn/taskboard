import Foundation
import Testing

@testable import TaskboardKit

@Suite("案件の列の並び・隣の列・進行中のタスクの数")
struct BoardOrderTests {
    private let machine = MachineID(rawValue: "m")

    /// 配列の順と position の順をわざと違えた案件（daemon が position の順で返さなくても、並びは position で決まる）
    private var board: Board {
        let columns = [
            BoardColumn(id: "done", label: "完了", kind: .terminal, position: 3, collapsed: false),
            BoardColumn(id: "todo", label: "未着手", kind: .open, position: 0),
            BoardColumn(id: "review", label: "レビュー中", kind: .open, position: 2, collapsed: true),
            BoardColumn(id: "working", label: "作業中", kind: .open, position: 1),
        ]
        return Board(id: "b", machine: machine, name: "b", position: 0, columns: columns, createdAt: Date())
    }

    private func task(_ number: Int, board: String = "b", column: String) -> BoardTask {
        BoardTask(machine: machine, number: number, boardID: board, columnID: column, title: "t", createdAt: Date(), updatedAt: Date())
    }

    @Test("列は position の順。進行中・終端・畳まない列も同じ順")
    func ordered() {
        #expect(board.orderedColumns.map(\.id) == ["todo", "working", "review", "done"])
        #expect(board.openColumns.map(\.id) == ["todo", "working", "review"])
        #expect(board.terminalColumns.map(\.id) == ["done"])
        #expect(board.unfoldedColumns.map(\.id) == ["todo", "working", "done"])
    }

    @Test("隣の列は並びの順で引き、端を越えるか列が無ければ nil")
    func neighbors() {
        #expect(board.column(nextTo: "working", by: 1)?.id == "review")
        #expect(board.column(nextTo: "working", by: -1)?.id == "todo")
        #expect(board.column(nextTo: "todo", by: -1) == nil)
        #expect(board.column(nextTo: "done", by: 1) == nil)
        #expect(board.column(nextTo: "gone", by: 1) == nil)
    }

    @Test("進行中の数は、この案件の進行中の列にあるタスクだけ。終端の列・列の無いタスク・ほかの案件は数えない")
    func openCount() {
        let tasks = [task(1, column: "todo"), task(2, column: "review"), task(3, column: "done"), task(4, column: "gone"), task(5, board: "other", column: "todo")]
        #expect(board.openTaskCount(tasks) == 2)
        #expect(board.openTaskCount([BoardTask]()) == 0)
    }

    @Test("既定の起票先はアーカイブした案件を飛ばした position の先頭。同じ position なら並びの先、全部アーカイブか空なら nil")
    func defaultBoard() {
        func board(_ id: String, position: Int, archived: Bool = false) -> Board {
            Board(id: id, machine: machine, name: id, position: position, columns: BoardColumn.standard, createdAt: Date(), archived: archived)
        }
        #expect([board("b", position: 1), board("a", position: 0, archived: true)].defaultBoard?.id == "b")
        #expect([board("c", position: 2), board("b", position: 1)].defaultBoard?.id == "b")
        #expect([board("x", position: 1), board("y", position: 1)].defaultBoard?.id == "x")
        #expect([board("a", position: 0, archived: true)].defaultBoard == nil)
        #expect([Board]().defaultBoard == nil)
    }
}
