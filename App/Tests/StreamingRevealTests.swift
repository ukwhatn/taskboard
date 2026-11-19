import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

@MainActor
@Suite struct StreamingRevealTests {
    /// 1 つの block を始めて `text` を届けた（`stopped` なら止めた）ときの生成中の並び
    private func block(_ text: String, stopped: Bool = false, kind: ConversationEvent.DeltaBlock = .text) -> ConversationTimeline.StreamingBlock {
        var timeline = ConversationTimeline()
        var kinds: [ConversationEvent.Kind] = [.blockStart(messageID: "m1", index: 0, block: kind, toolName: nil)]
        if !text.isEmpty { kinds.append(.delta(messageID: "m1", index: 0, block: kind, text: text)) }
        if stopped { kinds.append(.blockStop(messageID: "m1", index: 0)) }
        _ = timeline.apply(kinds.enumerated().map { ConversationEvent(seq: $0.offset + 1, conversationID: "c1", at: Date(), kind: $0.element) })
        return timeline.streaming[0]
    }

    @Test("初めて見えた block は届いている文を全部見せ、続きは届いてもすぐには見せずに歩ずつ見せ、止まったら全部見せ、消えたら空にする")
    func paces() async throws {
        let reveal = StreamingReveal()
        let id = block("").id
        reveal.update([block("開いたときに届いていた文。")])
        #expect(reveal.text(for: id) == "開いたときに届いていた文。")

        let long = "開いたときに届いていた文。" + String(repeating: "続きの文を少しずつ足していく。", count: 20)
        reveal.update([block(long)])
        #expect(reveal.text(for: id) == "開いたときに届いていた文。", "届いた時点では進めない")
        try await Task.sleep(for: .milliseconds(80))
        let partial = reveal.text(for: id)
        #expect(partial.count > "開いたときに届いていた文。".count && partial.count < long.count && long.hasPrefix(partial))

        reveal.update([block(long, stopped: true)])
        #expect(reveal.text(for: id) == long)
        reveal.update([])
        #expect(reveal.text(for: id) == "")
    }

    @Test("見せている文を、書き終えた塊と書きかけに分けて持つ（Mac の一覧は塊ごとの行と書きかけの 1 行に並べる）。消えたら両方とも捨てる")
    func splitsChunks() {
        let reveal = StreamingReveal()
        let id = block("").id
        reveal.update([block("一つ目の段落。\n\n```\na\n\nb\n```\n\n書きかけの文")])
        #expect(reveal.settled[id] == ["一つ目の段落。\n\n", "```\na\n\nb\n```\n\n"])
        #expect(reveal.tails[id] == "書きかけの文")
        reveal.update([])
        #expect(reveal.settled[id] == nil && reveal.tails[id] == nil)
    }

    @Test("本文でない block（思考・ツールの入力）は持たない")
    func textOnly() {
        let reveal = StreamingReveal()
        reveal.update([block("考えている文", kind: .thinking)])
        #expect(reveal.shown.isEmpty)
    }
}
