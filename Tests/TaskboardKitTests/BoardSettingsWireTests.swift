import Foundation
import Testing

@testable import TaskboardKit

@Suite("案件の設定の電文")
struct BoardSettingsWireTests {
    @Test("P5 までの daemon の Board（archived・launchDefaults・collapsed が無い）も読め、終端の列は畳む列になる")
    func decodesOldBoard() throws {
        let json = #"""
            {"id":"b1","machine":"m1","name":"default","position":0,"createdAt":"2026-10-01T00:00:00Z","promptTemplate":"",
             "columns":[{"id":"todo","label":"未着手","kind":"open","position":0},{"id":"done","label":"完了","kind":"terminal","position":1}]}
            """#
        let board = try WireJSON.decoder().decode(Board.self, from: Data(json.utf8))
        #expect(board.archived == false)
        #expect(board.launchDefaults == nil)
        #expect(board.columns.map(\.collapsed) == [false, true])
        #expect(board.mergeTarget == .deploying, "mergeTarget の無い daemon の案件は、今までどおりデプロイ中へ")
    }

    @Test("Board と BoardUpdateRequest は新しい項目ごと往復する")
    func roundTrip() throws {
        let board = Board(
            id: "b1", machine: MachineID(rawValue: "m1"), name: "案件", position: 2,
            columns: [BoardColumn(id: "c-1234abcd", label: "保留", kind: .open, position: 0, promptTemplate: "p", collapsed: true)],
            createdAt: Date(timeIntervalSince1970: 1_791_000_000), archived: true,
            launchDefaults: LaunchDefaults(kind: .codex, agentArgs: ["--model", "x"], worktree: true, cwd: "~/dev"), mergeTarget: .done)
        let decoded = try WireJSON.decoder().decode(Board.self, from: try WireJSON.encoder().encode(board))
        #expect(decoded == board)

        let request = BoardUpdateRequest(
            name: "n", archived: false, clearLaunchDefaults: true,
            columns: [BoardColumnEdit(id: nil, label: "新しい", kind: .terminal, collapsed: true, promptTemplate: "")], reassign: ["c-1": "todo"],
            mergeTarget: .done)
        #expect(try WireJSON.decoder().decode(BoardUpdateRequest.self, from: try WireJSON.encoder().encode(request)) == request)
    }

    @Test("省略した項目は nil で届く（daemon は「変えない」と読む）")
    func omittedFieldsAreNil() throws {
        let request = try WireJSON.decoder().decode(BoardUpdateRequest.self, from: Data(#"{"name":"x"}"#.utf8))
        #expect(request.archived == nil && request.columns == nil && request.reassign == nil && request.launchDefaults == nil)
        #expect(request.clearLaunchDefaults == nil && request.mergeTarget == nil)
    }
}
