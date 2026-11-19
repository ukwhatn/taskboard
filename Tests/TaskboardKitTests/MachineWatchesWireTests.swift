import Foundation
import Testing

@testable import TaskboardKit

@Suite("マシンの状態の見張りの読み方")
struct MachineWatchesWireTests {
    @Test("知らない種類の見張りはその 1 件だけ飛ばし、状態の残りは読む")
    func skipsUnknownWatch() throws {
        let machine = MachineID(rawValue: "m")
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        var state = StateSnapshot(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"), generatedAt: at)
        state.watches = [
            Watch(watchID: 1, machine: machine, url: "https://github.com/o/r/pull/1", taskNumber: 1, createdAt: at, updatedAt: at),
            Watch(watchID: 2, machine: machine, url: "https://github.com/o/r/pull/2", taskNumber: 1, createdAt: at, updatedAt: at),
        ]
        var json = try #require(try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(state)) as? [String: Any])
        var watches = try #require(json["watches"] as? [[String: Any]])
        watches[1]["kind"] = "someday"
        json["watches"] = watches
        let decoded = try WireJSON.decoder().decode(StateSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.watches.map(\.watchID) == [1])
        #expect(decoded.machine.id == machine)
    }
}
