import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 会話の画面が読む写し（`ConversationFeed` の messages・streaming・reveal・outgoing・historyState・isGenerating・isEmpty）が、
/// 手元の全体（timeline）を替えるたびに同じ値になる
@MainActor
@Suite struct ConversationFeedPublishTests {
    private func expectPublished(_ feed: ConversationFeed, _ note: String) {
        let timeline = feed.debugTimeline
        #expect(feed.messages == timeline.messages, "\(note): messages")
        // 生成中の block は並びと状態だけを写し、文は見せる文の側に置く（開いたときに控えから流れてきた block は全部見せる）
        #expect(feed.streaming.map(\.id) == timeline.streaming.map(\.id), "\(note): streaming")
        #expect(feed.streaming.allSatisfy { $0.text.isEmpty }, "\(note): streaming の文")
        for block in timeline.streaming where block.block == .text {
            #expect(feed.reveal.text(for: block.id) == block.text, "\(note): \(block.id) の見せる文")
        }
        #expect(feed.outgoing == timeline.outgoing, "\(note): outgoing")
        #expect(feed.historyState == timeline.historyState, "\(note): historyState")
        #expect(feed.isGenerating == timeline.isGenerating, "\(note): isGenerating")
        #expect(feed.isEmpty == timeline.isEmpty, "\(note): isEmpty")
    }

    @Test("fixtures の会話を開いたとき、送ったとき、古いページを足したときに、写しが手元の全体と同じ")
    func copiesFollowTimeline() async throws {
        let model = try await ConversationSnapshotTests.loadedModel()
        for id in ["c-gen", "c-ask", "c-stop"] {
            let feed = model.conversationFeed(for: try ConversationSnapshotTests.key(model, id))
            expectPublished(feed, "\(id) 開いた")
            feed.send("写しの確かめ", images: [])
            expectPublished(feed, "\(id) 送った")
            #expect(feed.outgoing.contains { $0.text == "写しの確かめ" })
            let older = (0..<3).map { ChatMessage(id: "older-\(id)-\($0)", role: .user, kind: .text, text: "古いページ \($0)") }
            feed.mergeOlderPage(ConversationHistoryResponse(messages: older, nextCursor: nil, agentSessionID: feed.debugTimeline.agentSessionID ?? "s"))
            expectPublished(feed, "\(id) 古いページ")
        }
    }
}
