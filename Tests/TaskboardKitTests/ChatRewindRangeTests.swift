import Foundation
import Testing

@testable import TaskboardKit

@Suite("巻き戻せる範囲：最後に圧縮した後の人の発言だけ")
struct ChatRewindRangeTests {
    private func human(_ id: String) -> ChatMessage { ChatMessage(id: id, role: .user, kind: .text, text: "発言 \(id)") }
    private func reply(_ id: String) -> ChatMessage { ChatMessage(id: id, role: .assistant, kind: .text, text: "answer \(id)") }
    private func compacted(_ id: String, subagent: Bool = false) -> ChatMessage {
        var message = ChatMessage(id: id, role: .user, kind: .notice, text: "会話を圧縮しました", compactSummary: true)
        if subagent { message.parentToolID = "t-agent" }
        return message
    }

    @Test("圧縮していなければ人の発言は全部戻せる。最後に戻せるのは最後の人の発言")
    func uncompacted() {
        let messages = [human("u1"), reply("a1"), human("u2"), reply("a2")]
        let range = ChatRewindRange(messages)
        #expect(!range.compacted && range.readOnly.isEmpty)
        #expect(messages.filter(range.allows).map(\.id) == ["u1", "u2"])
        #expect(ChatRewindRange.last(in: messages)?.id == "u2")
        #expect(ChatRewindRange.last(in: []) == nil && ChatRewindRange([]).readOnly.isEmpty)
    }

    @Test("2 回圧縮した会話は、最後の圧縮より前の人の発言を読むだけにする。アシスタントの文と圧縮の印は元から巻き戻しの対象でない")
    func compactedTwice() {
        let messages = [human("u1"), reply("a1"), compacted("c1"), human("u2"), reply("a2"), compacted("c2"), human("u3"), reply("a3")]
        let range = ChatRewindRange(messages)
        #expect(range.compacted && range.readOnly == ["u1", "u2"])
        #expect(messages.filter(range.allows).map(\.id) == ["u3"])
        #expect(ChatRewindRange.last(in: messages)?.id == "u3")
    }

    @Test("圧縮の後に人の発言が無ければ、/rewind で戻せる発言は無い")
    func nothingAfter() {
        let messages = [human("u1"), reply("a1"), compacted("c1"), reply("a2")]
        #expect(ChatRewindRange.last(in: messages) == nil)
        #expect(messages.filter(ChatRewindRange(messages).allows).isEmpty)
    }

    @Test("サブエージェントの中の圧縮は本筋の範囲を変えない")
    func subagentCompaction() {
        let messages = [human("u1"), compacted("sc", subagent: true), human("u2")]
        let range = ChatRewindRange(messages)
        #expect(!range.compacted && range.readOnly.isEmpty)
        #expect(ChatRewindRange.last(in: messages)?.id == "u2")
    }
}
