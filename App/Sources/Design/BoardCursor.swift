import Foundation
import TaskboardKit

/// 全体のボードでキーで動かすカードの並び。案件ごとに、画面の左から列、列の中は上から。
/// 上下は列の中を動き、端から先は隣の案件の同じ列へ。左右は空の列を飛ばして同じ段へ（無ければ列の末尾）
struct BoardCursorGrid: Equatable {
    enum Direction: CaseIterable { case up, down, left, right }

    /// boards[案件][列][段]
    var boards: [[[TaskKey]]]

    func move(from current: TaskKey?, _ direction: Direction) -> TaskKey? {
        guard let current, let at = position(of: current) else { return first }
        switch direction {
        case .up:
            if at.row > 0 { return boards[at.board][at.column][at.row - 1] }
            return neighbourBoard(from: at, step: -1).map { board, column in boards[board][column].last! } ?? current
        case .down:
            if at.row + 1 < boards[at.board][at.column].count { return boards[at.board][at.column][at.row + 1] }
            return neighbourBoard(from: at, step: 1).map { board, column in boards[board][column].first! } ?? current
        case .left, .right:
            let step = direction == .left ? -1 : 1
            let columns = boards[at.board]
            var column = at.column + step
            while columns.indices.contains(column) {
                if !columns[column].isEmpty { return columns[column][min(at.row, columns[column].count - 1)] }
                column += step
            }
            return current
        }
    }

    private var first: TaskKey? {
        boards.lazy.flatMap { $0 }.first { !$0.isEmpty }?.first
    }

    private func position(of key: TaskKey) -> (board: Int, column: Int, row: Int)? {
        for (b, columns) in boards.enumerated() {
            for (c, cards) in columns.enumerated() {
                if let r = cards.firstIndex(of: key) { return (b, c, r) }
            }
        }
        return nil
    }

    /// カードのある隣の案件と、その中で今の列に一番近い列（同じ距離なら左）。無ければ動かない
    private func neighbourBoard(from at: (board: Int, column: Int, row: Int), step: Int) -> (Int, Int)? {
        var board = at.board + step
        while boards.indices.contains(board) {
            let columns = boards[board]
            let filled = columns.indices.filter { !columns[$0].isEmpty }
            if let column = filled.min(by: { (abs($0 - at.column), $0) < (abs($1 - at.column), $1) }) {
                return (board, column)
            }
            board += step
        }
        return nil
    }
}
