import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

@Suite struct BoardCursorTests {
    private static let m = MachineID(rawValue: "m")
    private func k(_ n: Int) -> TaskKey { TaskKey(machine: Self.m, number: n) }

    /// 案件 A: 列 [1,2,3] [] [4]、案件 B: 列 [5] [6,7]
    private var grid: BoardCursorGrid {
        BoardCursorGrid(boards: [
            [[k(1), k(2), k(3)], [], [k(4)]],
            [[k(5)], [k(6), k(7)]],
        ])
    }

    @Test("選んでいなければ、どの向きでも最初のカード")
    func startsAtFirst() {
        for direction in BoardCursorGrid.Direction.allCases {
            #expect(grid.move(from: nil, direction) == k(1))
        }
    }

    @Test("選んでいたカードが並びから消えていれば、最初のカードから")
    func missingRestarts() {
        #expect(grid.move(from: k(99), .down) == k(1))
    }

    @Test("上下は列の中で動く")
    func verticalInColumn() {
        #expect(grid.move(from: k(1), .down) == k(2))
        #expect(grid.move(from: k(3), .up) == k(2))
    }

    @Test("列の下端から下へは、次の案件の同じ列の先頭へ")
    func downCrossesBoard() {
        #expect(grid.move(from: k(3), .down) == k(5))
    }

    @Test("列の上端から上へは、前の案件の同じ列の末尾へ")
    func upCrossesBoard() {
        #expect(grid.move(from: k(6), .up) == k(3))  // B の列 1 → A の列 1（[]）は空なので近い列 0 の末尾
        #expect(grid.move(from: k(5), .up) == k(3))
    }

    @Test("最初と最後のカードからは外へ出ない")
    func edgesStay() {
        #expect(grid.move(from: k(1), .up) == k(1))
        #expect(grid.move(from: k(7), .down) == k(7))
    }

    @Test("左右は空の列を飛ばし、同じ段か列の末尾へ")
    func horizontalSkipsEmpty() {
        #expect(grid.move(from: k(2), .right) == k(4))  // 段 1 は無いので末尾
        #expect(grid.move(from: k(4), .left) == k(1))
        #expect(grid.move(from: k(5), .right) == k(6))
        #expect(grid.move(from: k(7), .left) == k(5))
    }

    @Test("案件の端から左右へは動かない")
    func horizontalEdgesStay() {
        #expect(grid.move(from: k(4), .right) == k(4))
        #expect(grid.move(from: k(1), .left) == k(1))
    }

    @Test("カードの無い案件は飛ばす")
    func emptyBoardSkipped() {
        let grid = BoardCursorGrid(boards: [[[k(1)]], [[], []], [[k(2)]]])
        #expect(grid.move(from: k(1), .down) == k(2))
        #expect(grid.move(from: k(2), .up) == k(1))
    }

    @Test("カードが 1 枚も無ければ nil")
    func emptyGrid() {
        #expect(BoardCursorGrid(boards: []).move(from: nil, .down) == nil)
        #expect(BoardCursorGrid(boards: [[[]]]).move(from: k(1), .down) == nil)
    }
}
