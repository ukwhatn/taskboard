import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 思考の行。履歴の思考は、生成中の「思考」の行と同じ見出しで畳み、開くと補足の色の Markdown を出す。
/// fixtures `chat-thinking` の c-think（短い思考・長い思考・ツールの間の思考・返答の前の思考）。
/// ライト / ダークの 2 組。記録し直すときは suite の `record` を一時的に `.all` にして流す
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ChatThinkingTests {
    typealias Variant = BoardSnapshotTests.Variant
    nonisolated static let variants = ChatFilesSnapshotTests.variants

    private struct Fixture: Decodable {
        struct Chat: Decodable { var messages: [ChatMessage] }
        var conversationChats: [String: Chat]
    }

    private static func messages() throws -> [ChatMessage] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/chat-thinking.json")
        let fixture = try WireJSON.decoder().decode(Fixture.self, from: Data(contentsOf: url))
        return try #require(fixture.conversationChats["c-think"]).messages
    }

    private static func thought(_ text: String = "ログを読んで原因を探す。") -> ChatMessage {
        ChatMessage(id: "m1#0", role: .assistant, kind: .text, text: text, thinking: true)
    }

    /// 思考の block を始めて `text` を届けて止めたときの生成中の block
    private static func block(stopped: Bool) -> ConversationTimeline.StreamingBlock {
        var timeline = ConversationTimeline()
        var kinds: [ConversationEvent.Kind] = [
            .blockStart(messageID: "m1", index: 0, block: .thinking, toolName: nil), .delta(messageID: "m1", index: 0, block: .thinking, text: "ログを読んで"),
        ]
        if stopped { kinds.append(.blockStop(messageID: "m1", index: 0)) }
        _ = timeline.apply(kinds.enumerated().map { ConversationEvent(seq: $0.offset + 1, conversationID: "c1", at: Date(), kind: $0.element) })
        return timeline.streaming[0]
    }

    private static func list(_ items: [ChatList.Item], context: ChatRowContext = .empty) -> ChatList {
        ChatList(
            items: items, context: context, spacing: 0, verticalInset: 0, horizontalInset: 0, columnWidth: 400,
            pinned: .constant(false), bottomRequest: 0, target: nil, reachedTop: nil)
    }

    private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private static func render(_ items: [ChatList.Item], context: ChatRowContext = .empty) throws -> (host: NSView, list: ChatListView) {
        let host = BoardSnapshotTests.host(list(items, context: context), size: CGSize(width: 400, height: 300), variant: BoardSnapshotTests.variants[0])
        let view = try #require(views(ChatListView.self, in: host).first)
        return (host, view)
    }

    private static func item(_ message: ChatMessage) -> ChatList.Item { ChatList.Item(id: message.id, estimate: 20, content: .row(.message(message))) }

    /// 見出しの枠（一覧の座標）
    private static func headerFrame(in list: ChatListView) throws -> CGRect {
        let header = try #require(views(ChatDisclosureHeaderView.self, in: list).first)
        return header.convert(header.bounds, to: list)
    }

    @Test("書き終えた思考が履歴の行に替わっても、行の高さと見出しの位置が変わらない")
    func swapKeepsPlace() throws {
        let generating = try Self.render([ChatList.Item(id: "s", estimate: 20, content: .streamBlock(Self.block(stopped: true)))])
        let history = try Self.render([Self.item(Self.thought())])
        let historyFrame = try Self.headerFrame(in: history.list)
        #expect(try Self.headerFrame(in: generating.list) == historyFrame)
        #expect(generating.list.rowFrames.map(\.height) == history.list.rowFrames.map(\.height))
        // 書いている間の見出し（「思考中…」）も同じ高さ・同じ左端
        let writing = try Self.render([ChatList.Item(id: "s", estimate: 20, content: .streamBlock(Self.block(stopped: false)))])
        let writingFrame = try Self.headerFrame(in: writing.list)
        #expect(writingFrame.minX == historyFrame.minX && writingFrame.height == historyFrame.height)
        #expect(writing.list.rowFrames.map(\.height) == history.list.rowFrames.map(\.height))
    }

    @Test("履歴の思考は初めは畳み、見出しを押すと中身を出し、もう一度押すと畳む")
    func togglesOpen() throws {
        let (host, list) = try Self.render([Self.item(Self.thought("原因は保存の順番。\n\n- 更新が先に走る")), Self.item(ChatMessage(id: "n1", role: .assistant, kind: .notice, text: "知らせ"))])
        let rows = { list.rowFrames.sorted { $0.minY < $1.minY } }
        let closed = try #require(rows().first).height
        let header = try #require(Self.views(ChatDisclosureHeaderView.self, in: list).first)
        #expect(header.accessibilityValue() as? String == "折りたたみ済み")
        #expect(header.accessibilityPerformPress())
        LayoutMatrixSnapshotTests.settle(host)
        let open = try #require(rows().first).height
        #expect(open > closed)
        #expect(rows().last?.minY == open)
        #expect(Self.views(ChatDisclosureHeaderView.self, in: list).first?.accessibilityValue() as? String == "展開済み")
        #expect(Self.views(ChatDisclosureHeaderView.self, in: list).first?.accessibilityPerformPress() == true)
        LayoutMatrixSnapshotTests.settle(host)
        #expect(rows().first?.height == closed)
    }

    @Test("会話の中の検索は思考の中の文も数え、今見ている一致が思考なら開いて見せる")
    func searchRevealsThinking() throws {
        let messages = try Self.messages()
        #expect(ChatSearch.rows(in: messages, query: "保存する前に例外").contains("k3"))
        var context = ChatRowContext.empty
        context.look.query = "保存"
        let closed = try Self.render([Self.item(Self.thought("原因は保存の順番。"))], context: context)
        context.look.current = "m1#0"
        let revealed = try Self.render([Self.item(Self.thought("原因は保存の順番。"))], context: context)
        let closedHeight = try #require(closed.list.rowFrames.first).height
        let revealedHeight = try #require(revealed.list.rowFrames.first).height
        #expect(revealedHeight > closedHeight)
    }

    @Test("Mac の一覧（AppKit）の思考の行。畳んだ形と、開いた形（組の中の思考も）", arguments: variants.map(\.name))
    func mac(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        AppDefaults.useScratch("snapshot")
        let all = try Self.messages()
        let collapsed = ChatTranscript(messages: all)
        assertImageSnapshot(
            of: BoardSnapshotTests.host(collapsed, size: CGSize(width: 560, height: 360), variant: variant), named: variant.name, testName: "mac-collapsed")
        let opened = ChatTranscript(messages: all, expandedTools: ["k1", "t1", "k2"])
        assertImageSnapshot(
            of: BoardSnapshotTests.host(opened, size: CGSize(width: 560, height: 900), variant: variant), named: variant.name, testName: "mac-opened")
    }
}
