import Foundation
import Testing

@testable import TaskboardKit

@Suite("列の既定と、列が消えたときの寄せ先")
struct BoardColumnTests {
    private func board(_ ids: [String], mergeTarget: MergeTarget = .deploying) -> Board {
        let columns = ids.enumerated().map { index, id in
            BoardColumn.standard.first { $0.id == id }.map { var c = $0; c.position = index; return c }
                ?? BoardColumn(id: id, label: id, kind: .open, position: index)
        }
        return Board(id: "b", machine: MachineID(rawValue: "m"), name: "b", position: 0, columns: columns, createdAt: Date(), mergeTarget: mergeTarget)
    }

    @Test("常設は PR の状態で進める順に入らない。ほかの既定の列は表示の順と同じ")
    func progressOrder() {
        #expect(BoardColumn.progressIndex(of: "standing") == nil)
        #expect(BoardColumn.progressOrder == ["review_req", "todo", "planning", "working", "review", "deploying", "done", "wontfix"])
        #expect(BoardColumn.progressIndex(of: "c-1234abcd") == nil)
    }

    @Test("消せないのは完了だけで、既定の列かは id で決まる")
    func removable() {
        #expect(BoardColumn.standard.filter { !$0.isRemovable }.map(\.id) == ["done"])
        #expect(BoardColumn.standard.allSatisfy { $0.isStandard })
        #expect(!BoardColumn(id: "c-1", label: "x", kind: .open, position: 0).isStandard)
    }

    @Test("起票の既定は未着手、無ければ常設とレビュー依頼を除く最初の進行中の列。それも無ければレビュー依頼か常設")
    func defaultColumn() {
        #expect(board(BoardColumn.standard.map(\.id)).defaultColumn?.id == "todo")
        #expect(board(["standing", "review_req", "planning", "done"]).defaultColumn?.id == "planning", "レビュー依頼は他人の PR の受け口なので、自分の仕事を入れない")
        #expect(board(["standing", "review_req", "done"]).defaultColumn?.id == "review_req")
        #expect(board(["done", "c-1", "standing"]).defaultColumn?.id == "c-1", "並びは position の順")
        #expect(board(["standing", "done"]).defaultColumn?.id == "standing")
        #expect(board(["done", "wontfix"]).defaultColumn == nil)
    }

    @Test("「マージしたら」の列が案件に無ければ完了")
    func mergeTarget() {
        #expect(board(BoardColumn.standard.map(\.id)).mergeTargetColumnID == "deploying")
        #expect(board(["todo", "review", "done"]).mergeTargetColumnID == "done")
        #expect(board(["todo", "deploying", "done"], mergeTarget: .done).mergeTargetColumnID == "done")
    }

    @Test("説明の無い古い JSON の列は空の説明で読む")
    func decodesWithoutDescription() throws {
        let json = #"{"id":"todo","label":"未着手","kind":"open","position":0}"#
        let column = try JSONDecoder().decode(BoardColumn.self, from: Data(json.utf8))
        #expect(column.description == "")
        let round = try JSONDecoder().decode(BoardColumn.self, from: JSONEncoder().encode(BoardColumn.standard[0]))
        #expect(round.description == BoardColumn.standard[0].description)
    }
}
