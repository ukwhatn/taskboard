import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 取り消された待機中の発言を入力欄に戻す（`ConversationFeed.restoredDrafts`）
@MainActor
@Suite struct ConversationFeedRestoreTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

    @Test("［編集］と生成の停止で取り消された発言は、文と画像とファイルをそろえて戻す")
    func restoresAttachments() async throws {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply([ConversationEvent(seq: 1, conversationID: "c1", at: Date(), kind: .blockStart(messageID: "m1", index: 0, block: .text, toolName: nil))])
        let feed = ConversationFeed(key: ConversationKey(machine: MachineID(rawValue: "studio"), id: "c1"), fixture: timeline)
        feed.send("直す", images: [ChatDraftImage(data: Self.png, type: .png)], files: [ChatDraftFile(name: "a.csv", content: .path("/tmp/a.csv"))])
        let id = try #require(feed.outgoing.first?.clientMessageID)

        feed.streamEvent(ConversationEvent(seq: 2, conversationID: "c1", at: Date(), kind: .accepted(clientMessageID: id, state: "cancelled")))
        let deadline = ContinuousClock.now + .seconds(2)
        while feed.restoredDrafts.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        let restored = try #require(feed.restoredDrafts.first)
        #expect(restored.text == "直す")
        #expect(restored.images.map(\.data) == [Self.png])
        #expect(restored.files.map(\.content) == [.path("/tmp/a.csv")])
        #expect(feed.outgoing.isEmpty)
    }
}
