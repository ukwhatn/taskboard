import AppKit
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

@MainActor
@Suite struct ChatListTests {
    private final class Probe {
        weak var list: ChatListView? {
            didSet { if list != nil { listWasFound = true } }
        }
        var listWasFound = false
    }

    private static func messages(_ count: Int) -> [ChatMessage] {
        (0..<count).map { ChatMessage(id: "m\($0)", role: $0.isMultiple(of: 2) ? .user : .assistant, kind: .text, text: "発言 \($0)") }
    }

    private static func lists(in view: NSView) -> [ChatListView] {
        (view as? ChatListView).map { [$0] } ?? view.subviews.flatMap { lists(in: $0) }
    }

    /// 1 つの block を始めて `text` を届けて止めたときの生成中の block
    private static func block(_ text: String) -> ConversationTimeline.StreamingBlock {
        var timeline = ConversationTimeline()
        let kinds: [ConversationEvent.Kind] = [
            .blockStart(messageID: "m1", index: 0, block: .text, toolName: nil), .delta(messageID: "m1", index: 0, block: .text, text: text), .blockStop(messageID: "m1", index: 0),
        ]
        _ = timeline.apply(kinds.enumerated().map { ConversationEvent(seq: $0.offset + 1, conversationID: "c1", at: Date(), kind: $0.element) })
        return timeline.streaming[0]
    }

    private static func list(_ items: [ChatList.Item], context: ChatRowContext, jump: ChatJumpRequest = ChatJumpRequest()) -> ChatList {
        ChatList(
            items: items, context: context, spacing: 0, verticalInset: 0, horizontalInset: 0, columnWidth: 400,
            pinned: .constant(false), bottomRequest: 0, target: nil, jump: jump, reachedTop: nil)
    }

    /// 帯の出し入れは少し待ってから決まり、負荷が高いと数百 ms 遅れる
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "待っても起きない")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    @Test("組むときに読んだ生成中の文が伸びたら、その行だけ組み直して測り直し、下の行をずらして中身の高さを伸ばす")
    func remeasuresGrownRow() throws {
        let reveal = StreamingReveal()
        let first = Self.block("1 行目")
        reveal.update([first])
        var context = ChatRowContext.empty
        context.reveal = reveal
        let notice = ChatMessage(id: "n1", role: .assistant, kind: .notice, text: "知らせ")
        let list = Self.list(
            [ChatList.Item(id: "s", estimate: 100, content: .streamChunk(blockID: first.id, index: 0)), ChatList.Item(id: "n1", estimate: 100, content: .row(.message(notice)))],
            context: context)
        let host = BoardSnapshotTests.host(list, size: CGSize(width: 400, height: 300), variant: BoardSnapshotTests.variants[0])
        let view = try #require(Self.lists(in: host).first)
        let rows = { view.rowFrames.sorted { $0.minY < $1.minY } }
        let line = ChatFonts(size: SessionTextSize.chatDefault).line
        #expect(rows().map(\.height).first == line)
        #expect(rows().last?.minY == line)
        reveal.update([Self.block("1 行目\n2 行目\n3 行目")])
        LayoutMatrixSnapshotTests.settle(host)
        #expect(rows().map(\.height).first == line * 3)
        #expect(rows().last?.minY == line * 3)
    }

    @Test("初めて置く回は見えている範囲の行だけを組み、続く回で表示の上下に足す範囲の行も組む")
    func placesVisibleRowsFirst() async throws {
        let items = Self.messages(200).map { ChatList.Item(id: $0.id, estimate: 20, content: .row(.message($0))) }
        let view = ChatListView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        // 置いた行が縦に覆う長さ（一覧は下端に寄せて始まる）
        let span = { (view.rowFrames.map(\.maxY).max() ?? 0) - (view.rowFrames.map(\.minY).min() ?? 0) }
        view.update(Self.list(items, context: .empty))
        view.layoutSubtreeIfNeeded()
        #expect(span() < 400)
        // 広げる回は主スレッドの次の回に来る（入れ子の run loop では回らないので await で待つ）
        try await Self.waitUntil {
            view.layoutSubtreeIfNeeded()
            return span() >= 300 + ChatListView.overscanAbove
        }
    }

    @Test("幅が変わった回は見えている範囲の行だけを測り直し、表示の上下に足す範囲は続く回で置き直す")
    func remeasuresVisibleRowsOnResize() async throws {
        let items = Self.messages(200).map { ChatList.Item(id: $0.id, estimate: 20, content: .row(.message($0))) }
        let view = ChatListView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let span = { (view.rowFrames.map(\.maxY).max() ?? 0) - (view.rowFrames.map(\.minY).min() ?? 0) }
        view.update(Self.list(items, context: .empty))
        try await Self.waitUntil {
            view.layoutSubtreeIfNeeded()
            return span() >= 300 + ChatListView.overscanAbove
        }
        view.setFrameSize(CGSize(width: 300, height: 300))
        view.layoutSubtreeIfNeeded()
        #expect(span() < 400)
        try await Self.waitUntil {
            view.layoutSubtreeIfNeeded()
            return span() >= 300 + ChatListView.overscanAbove
        }
    }

    @Test("上の画面の環境が変わって会話の列を描き直しても、前からある行は組み直さない（「今日」を環境に入れていない画面でも）")
    func keepsRowsWhenEnvironmentChanges() throws {
        // BoardSnapshotTests.host は today と liveClock を固定するので、ここでは環境を入れずに組む。変えるのは会話の列が読まない環境の値
        func view(_ defers: Bool) -> some View { ChatTranscript(messages: Self.messages(4)).frame(width: 560, height: 400).environment(\.defersMount, defers) }
        let hosting = NSHostingView(rootView: view(true))
        hosting.frame = CGRect(x: 0, y: 0, width: 560, height: 400)
        LayoutMatrixSnapshotTests.settle(hosting)
        let rows = { Set(Self.views(ChatMessageContainerView.self, in: hosting).map(ObjectIdentifier.init)) }
        let before = rows()
        #expect(before.count == 4)
        hosting.rootView = view(false)
        LayoutMatrixSnapshotTests.settle(hosting)
        #expect(before.isSubset(of: rows()))
    }

    @Test("⌥⌘↑ は表示の上端より上の、⌥⌘↓ は下の、いちばん近い人の発言を上端に揃える。次が無ければ下端へ戻す。初めて受けた要求では動かない")
    func jumpsBetweenPrompts() throws {
        let items = Self.messages(40).map { ChatList.Item(id: $0.id, estimate: 40, content: .row(.message($0))) }
        var jump = ChatJumpRequest(forward: false, token: 5)
        let host = BoardSnapshotTests.host(Self.list(items, context: .empty, jump: jump), size: CGSize(width: 400, height: 300), variant: BoardSnapshotTests.variants[0])
        let view = try #require(Self.lists(in: host).first)
        #expect(view.isAtBottom)
        func step(_ forward: Bool) -> String? {
            jump.forward = forward
            jump.token += 1
            view.update(Self.list(items, context: .empty, jump: jump))
            LayoutMatrixSnapshotTests.settle(host)
            return view.topRowID
        }
        func index(_ id: String?) -> Int { Int(id?.dropFirst() ?? "") ?? -1 }
        let first = step(false)
        #expect(index(first).isMultiple(of: 2) && index(first) < 38)
        let second = step(false)
        #expect(index(second) == index(first) - 2)
        #expect(step(true) == first)
        #expect(!view.isAtBottom)
        for _ in 0..<40 where !view.isAtBottom { _ = step(true) }
        #expect(view.isAtBottom)
        // 先頭の人の発言より前には行かない
        for _ in 0..<40 { _ = step(false) }
        #expect(view.topRowID == "m0")
    }

    @Test("見出しを押して開いた行は測り直して下の行をずらし、外して置き直しても開いたまま（開閉は一覧が行ごとに持つ）")
    func keepsToggledRows() throws {
        let call = ChatMessage(id: "c1", role: .assistant, kind: .toolUse, text: "swift test", toolName: "Bash", toolID: "t1")
        let result = ChatMessage(id: "r1", role: .user, kind: .toolResult, text: "passed", toolID: "t1")
        let notice = ChatMessage(id: "n1", role: .assistant, kind: .notice, text: "知らせ")
        var context = ChatRowContext.empty
        context.results = ["t1": result]
        let items = [ChatList.Item(id: "c1", estimate: 20, content: .row(.message(call))), ChatList.Item(id: "n1", estimate: 20, content: .row(.message(notice)))]
        let host = BoardSnapshotTests.host(Self.list(items, context: context), size: CGSize(width: 400, height: 300), variant: BoardSnapshotTests.variants[0])
        let view = try #require(Self.lists(in: host).first)
        let rows = { view.rowFrames.sorted { $0.minY < $1.minY } }
        let closed = try #require(rows().first).height
        let header = try #require(Self.views(ChatDisclosureHeaderView.self, in: view).first)
        #expect(header.accessibilityValue() as? String == "折りたたみ済み")
        #expect(header.accessibilityPerformPress())
        LayoutMatrixSnapshotTests.settle(host)
        let open = try #require(rows().first).height
        #expect(open > closed)
        #expect(rows().last?.minY == open)
        #expect(Self.views(ChatDisclosureHeaderView.self, in: view).first?.accessibilityValue() as? String == "展開済み")

        // 行を外す（一覧から消す）・置き直す
        view.update(Self.list([items[1]], context: context))
        LayoutMatrixSnapshotTests.settle(host)
        view.update(Self.list(items, context: context))
        LayoutMatrixSnapshotTests.settle(host)
        #expect(rows().first?.height == open)

        // 見出しをクリック（押して離す）すると閉じる
        let shown = try #require(Self.views(ChatDisclosureHeaderView.self, in: view).first)
        let point = shown.convert(NSPoint(x: shown.bounds.midX, y: shown.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { shown.mouseDown(with: event) } else { shown.mouseUp(with: event) }
        }
        LayoutMatrixSnapshotTests.settle(host)
        #expect(rows().first?.height == closed)
    }

    @Test("応答が終わって巻き戻せるようになっても行を組み直さず、置いている巻き戻しのボタンとメニューだけが押せるようになる")
    func updatesRewindWithoutRebuilding() throws {
        let prompt = ChatMessage(id: "u1", role: .user, kind: .text, text: "直してください")
        var rewound: [String] = []
        func context(blocked: String?) -> ChatRowContext {
            var context = ChatRowContext.empty
            context.look.hasActions = true
            context.look.rewinds = true
            context.messageActions = ChatMessageActions(fork: { _ in }, rewind: { rewound.append($0.id) }, rewindBlocked: blocked)
            return context
        }
        let items = [ChatList.Item(id: "u1", estimate: 20, content: .row(.message(prompt)))]
        let host = BoardSnapshotTests.host(
            Self.list(items, context: context(blocked: "応答が終わると巻き戻せます")), size: CGSize(width: 400, height: 300), variant: BoardSnapshotTests.variants[0])
        let view = try #require(Self.lists(in: host).first)
        let rewindButton = { Self.views(ChatIconButtonView.self, in: view).first { $0.accessibilityLabel() == "ここまで巻き戻す" } }
        let rewindItem = { Self.views(ChatMessageContainerView.self, in: view).first?.chatMenu().map(ChatMenu.menu)?.items.first { $0.title == "ここまで巻き戻す" } }
        // 帯はポインタが乗ったときに作る
        #expect(rewindButton() == nil)
        try #require(Self.views(ChatMessageContainerView.self, in: view).first).setHovered(true)
        let button = try #require(rewindButton())
        #expect(!button.isAccessibilityEnabled())
        #expect(button.toolTip == "応答が終わると巻き戻せます")
        #expect(rewindItem()?.isEnabled == false)

        view.update(Self.list(items, context: context(blocked: nil)))
        LayoutMatrixSnapshotTests.settle(host)
        #expect(rewindButton() === button)
        #expect(button.isAccessibilityEnabled())
        #expect(button.toolTip == "ここまで巻き戻す")
        #expect(rewindItem()?.isEnabled == true)
        #expect(button.accessibilityPerformPress())
        #expect(rewound == ["u1"])
    }

    @Test("ポインタが発言の上に来ると帯を作って少し待って出し、一覧の外へ出ると隠す。乗る前の行には帯を作らない")
    func showsBarOnHover() async throws {
        let prompt = ChatMessage(id: "u1", role: .user, kind: .text, text: "直してください")
        let notice = ChatMessage(id: "n1", role: .assistant, kind: .notice, text: "知らせ")
        let items = [ChatList.Item(id: "u1", estimate: 20, content: .row(.message(prompt))), ChatList.Item(id: "n1", estimate: 20, content: .row(.message(notice)))]
        let host = BoardSnapshotTests.host(Self.list(items, context: .empty), size: CGSize(width: 400, height: 300), variant: BoardSnapshotTests.variants[0])
        let view = try #require(Self.lists(in: host).first)
        let row = try #require(Self.views(ChatMessageContainerView.self, in: view).first)
        let copyButton = { Self.views(ChatIconButtonView.self, in: row).first { $0.accessibilityLabel() == "コピー" } }
        let inside = row.convert(NSPoint(x: row.bounds.maxX - 8, y: 8), to: nil)
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        #expect(copyButton() == nil)

        view.mouseMoved(with: try event(.mouseMoved, at: inside))
        let copy = try #require(copyButton())
        try await Self.waitUntil { !copy.isHiddenOrHasHiddenAncestor }

        let exited = try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: inside, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseExited(with: exited)
        try await Self.waitUntil { copy.isHiddenOrHasHiddenAncestor }

        // 吹き出しの文の上で右クリックしても、文の既定のメニューでなく発言のメニューを出す
        let text = try #require(Self.views(ChatTextView.self, in: row).first)
        let menu = text.menu(for: try event(.rightMouseDown, at: inside))
        #expect(menu?.items.map(\.title) == ["コピー"])
    }

    @Test("閉じた会話の一覧は残らない（行の host に渡した環境から、親の画面を持ち続けない）")
    func releases() throws {
        let probe = Probe()
        // view は autorelease されるので、pool の中で作って手放す
        autoreleasepool {
            let host = BoardSnapshotTests.host(ChatTranscript(messages: Self.messages(40)), size: CGSize(width: 560, height: 400), variant: BoardSnapshotTests.variants[0])
            probe.list = Self.lists(in: host).first
        }
        #expect(probe.listWasFound)
        for _ in 0..<10 where probe.list != nil {
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        #expect(probe.list == nil)
    }
}
