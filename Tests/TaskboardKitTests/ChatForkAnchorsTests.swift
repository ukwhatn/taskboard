import Foundation
import Testing

@testable import TaskboardKit

@Suite("発言の行に出すフォークの数：地点の行までで最後の、操作の帯がある発言に数える")
struct ChatForkAnchorsTests {
    private func human(_ id: String) -> ChatMessage { ChatMessage(id: id, role: .user, kind: .text, text: "発言 \(id)") }
    private func reply(_ id: String) -> ChatMessage { ChatMessage(id: id, role: .assistant, kind: .text, text: "answer \(id)") }
    private func tool(_ id: String) -> ChatMessage { ChatMessage(id: id, role: .assistant, kind: .toolUse, text: "", toolID: "t-\(id)") }

    @Test("発言を指したフォークはその発言に、同じ発言の 2 つは 2 と数える。block の発言（uuid#i）は同じ行の最後の block に数える")
    func pointedMessages() {
        let messages = [human("u1"), reply("a1#0"), reply("a1#1"), human("u2"), reply("a2")]
        let anchors = ChatForkAnchors(messages)
        #expect(anchors.counts(["u1", "u1", "a1", "a2"]) == ["u1": 2, "a1#1": 1, "a2": 1])
    }

    @Test("帯の無い行（ツールの呼び出し・思考・差し込み）が地点なら、その前で最後の帯がある発言に数える。前に無ければ数えない")
    func pointsWithoutBar() {
        var thinking = reply("a0")
        thinking.thinking = true
        var injected = human("i1")
        injected.injected = true
        let messages = [thinking, tool("x0"), human("u1"), reply("a1"), tool("x1"), injected]
        let anchors = ChatForkAnchors(messages)
        #expect(anchors.counts(["x1", "i1"]) == ["a1": 2])
        #expect(anchors.counts(["x0", "a0"]).isEmpty)
    }

    @Test("一覧に無い地点と空の地点は数えない。地点が無ければ空")
    func unknownPoints() {
        let anchors = ChatForkAnchors([human("u1"), reply("a1")])
        #expect(anchors.counts(["gone", ""]).isEmpty)
        #expect(anchors.counts([]).isEmpty)
        #expect(ChatForkAnchors([]).counts(["u1"]).isEmpty)
    }
}
