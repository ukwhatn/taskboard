import Foundation
import TaskboardKit
import Testing

@testable import taskboard

@Suite("hook session: SessionStart の出力")
struct SessionStartHookTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    func task() -> BoardTask {
        BoardTask(machine: MachineID(rawValue: "m"), number: 148, boardID: "b", columnID: "working", title: "受入条件まで仕上げる", createdAt: t0, updatedAt: t0)
    }

    func decode(_ text: String) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try #require(root["hookSpecificOutput"] as? [String: Any])
    }

    @Test("起動のときは案内と題を返す。案内は Kit の文と同じ")
    func startup() throws {
        let board = Board(id: "b", machine: MachineID(rawValue: "m"), name: "default", position: 0, columns: BoardColumn.standard, createdAt: t0)
        let output = try decode(Hook.sessionStartOutput(task: task(), board: board, source: "startup", currentTitle: nil))
        #expect(output["hookEventName"] as? String == "SessionStart")
        #expect(output["additionalContext"] as? String == SessionGuidance.text(task: task(), board: board, machineName: "この Mac"))
        #expect(output["sessionTitle"] as? String == "#148 受入条件まで仕上げる")
    }

    @Test("/clear と圧縮では案内だけ（題は Claude Code が無視するので付けない）。題が既にあれば上書きしない")
    func clearCompactAndExistingTitle() throws {
        for source in ["clear", "compact"] {
            let output = try decode(Hook.sessionStartOutput(task: task(), board: nil, source: source, currentTitle: nil))
            #expect(output["additionalContext"] != nil)
            #expect(output["sessionTitle"] == nil, "\(source)")
        }
        let renamed = try decode(Hook.sessionStartOutput(task: task(), board: nil, source: "resume", currentTitle: "自分で付けた題"))
        #expect(renamed["sessionTitle"] == nil)
        let resumed = try decode(Hook.sessionStartOutput(task: task(), board: nil, source: "resume", currentTitle: ""))
        #expect(resumed["sessionTitle"] as? String == "#148 受入条件まで仕上げる")
        let stale = try decode(Hook.sessionStartOutput(task: task(), board: nil, source: "resume", currentTitle: "#148 タスクタイトルからつけて"))
        #expect(stale["sessionTitle"] as? String == "#148 受入条件まで仕上げる", "hook が付けた題が古ければ、再開で付け直す")
    }
}
