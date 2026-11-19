import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 会話の画面の行の表（`ChatTranscriptIndex`）
@MainActor
@Suite struct ChatTranscriptIndexTests {
    private func texts(_ range: Range<Int>) -> [ChatMessage] {
        range.map { ChatMessage(id: "m\($0)", role: $0 % 2 == 0 ? .user : .assistant, kind: .text, text: "発言 \($0)") }
    }

    @Test("行の位置は、行の id か行に出る発言の id で引き、ツールの組の中の発言は組の行で引く")
    func rowContaining() throws {
        let tools = (0..<3).map { ChatMessage(id: "t\($0)", role: .assistant, kind: .toolUse, text: "", toolName: "Read", toolID: "toolu_\($0)") }
        let index = ChatTranscriptIndex().update(texts(0..<2) + tools + texts(2..<4), groupsTools: true)
        let group = try #require(index.rows.firstIndex { $0.id.hasPrefix("tools/") })
        #expect(group == 2)
        #expect(index.row(containing: "t0") == 2 && index.row(containing: "t2") == 2)
        #expect(index.row(containing: index.rows[2].id) == 2)
        #expect(index.row(containing: "m2") == 3)
        #expect(index.row(containing: "nothing") == nil)
    }

    @Test("古いページが前に足されたら、前に一番上だった行の位置は足した分だけ後ろになる")
    func olderPageShiftsRows() {
        let index = ChatTranscriptIndex().update(texts(50..<100), groupsTools: true)
        #expect(index.row(containing: "m50") == 0)
        #expect(index.update(texts(0..<100), groupsTools: true).row(containing: "m50") == 50)
    }

    @Test("ツールを組にしない設定では、ツールの発言はそれぞれの行で引く")
    func ungrouped() {
        let tools = (0..<2).map { ChatMessage(id: "t\($0)", role: .assistant, kind: .toolUse, text: "", toolName: "Read", toolID: "toolu_\($0)") }
        let index = ChatTranscriptIndex().update(texts(0..<1) + tools, groupsTools: false)
        #expect(index.row(containing: "t0") == 1 && index.row(containing: "t1") == 2)
    }
}
