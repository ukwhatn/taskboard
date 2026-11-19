import Foundation
import Testing

@testable import TaskboardKit

@Suite("委任範囲: JSON")
struct DelegationKitTests {
    let machine = MachineID(rawValue: "m")
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    @Test("範囲の JSON は id と段階の名前で、知らない項目と段階は読み捨てる。前の版の task と board は空の範囲で読む")
    func json() throws {
        let scope = try JSONDecoder().decode(DelegationScope.self, from: Data(#"{"review_merge":"delegate","tracker":"report","later":"ask","cost":"maybe"}"#.utf8))
        #expect(scope == DelegationScope([.reviewMerge: .delegate, .tracker: .report]))
        let encoded = String(decoding: try WireJSON.encoder().encode(scope), as: UTF8.self)
        #expect(encoded == #"{"review_merge":"delegate","tracker":"report"}"#)

        let task = BoardTask(machine: machine, number: 1, boardID: "b", columnID: "todo", title: "t", createdAt: t0, updatedAt: t0)
        var object = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(task)) as! [String: Any]
        object.removeValue(forKey: "delegation")
        let old = try WireJSON.decoder().decode(BoardTask.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old == task)
    }
}
