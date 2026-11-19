import TaskboardKit
import Testing
@testable import Taskboard

/// 見張り盤のキーの動き。札は行ごとに並び、↑↓は同じ列の札（短い行では行末）、←→は並びの前後へ動く
@MainActor
@Suite struct ConversationBoardTests {
    nonisolated private static let machine = MachineID(rawValue: "m")
    nonisolated private static func key(_ id: String) -> ConversationKey { ConversationKey(machine: machine, id: id) }
    /// 札 3 枚の行・2 枚の行・1 行の形の行
    private static let rows = [["a", "b", "c"], ["d", "e"], ["f"]].map { $0.map(key) }

    private func move(from id: String?, _ direction: BoardCursorGrid.Direction) -> String? {
        AppModel.moveTile(in: Self.rows, from: id.map(Self.key), direction)?.id
    }

    @Test("選んでいなければ、どのキーでも先頭の札を選ぶ")
    func startsAtFirst() {
        for direction in BoardCursorGrid.Direction.allCases {
            #expect(move(from: nil, direction) == "a")
        }
    }

    @Test("↓は同じ列へ、下の行が短ければ行末へ。最後の行ではその場に留まる")
    func down() {
        #expect(move(from: "b", .down) == "e")
        #expect(move(from: "c", .down) == "e")
        #expect(move(from: "e", .down) == "f")
        #expect(move(from: "f", .down) == "f")
    }

    @Test("↑は同じ列へ。先頭の行ではその場に留まる")
    func up() {
        #expect(move(from: "e", .up) == "b")
        #expect(move(from: "f", .up) == "d")
        #expect(move(from: "a", .up) == "a")
    }

    @Test("←→は行をまたいで並びの前後へ動き、両端で留まる")
    func sideways() {
        #expect(move(from: "c", .right) == "d")
        #expect(move(from: "d", .left) == "c")
        #expect(move(from: "a", .left) == "a")
        #expect(move(from: "f", .right) == "f")
    }

    @Test("並びから消えた札を選んでいたら、先頭の札を選び直す")
    func lostCursor() {
        #expect(move(from: "gone", .down) == "a")
    }

    @Test("横の枚数は札の最小幅と間隔で決まり、狭くても 1 枚")
    func columns() {
        let tile = ConversationBoardMetrics.tileMinWidth
        #expect(AppModel.tileColumns(width: 0) == 1)
        #expect(AppModel.tileColumns(width: tile) == 1)
        #expect(AppModel.tileColumns(width: tile * 2 + Space.block) == 2)
        #expect(AppModel.tileColumns(width: tile * 2 + Space.block - 1) == 1)
    }
}
