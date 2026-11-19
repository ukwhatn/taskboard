import AppKit
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

@MainActor
@Suite struct ChatTextViewTests {
    private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private static func click(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private static func grid(_ markdown: String, opened: @escaping (URL) -> Void = { _ in }) throws -> ChatTableGridView {
        guard case .table(let table) = try #require(MarkdownBlocks.parse(markdown).first) else { throw CancellationError() }
        let grid = ChatTableGridView(table: table, look: ChatMarkdownLook(fonts: ChatFonts(size: 14), query: nil, openLink: opened))
        _ = grid.fit(width: 560)
        return grid
    }

    private static func cells(_ grid: ChatTableGridView) -> [NSAccessibilityElement] {
        (grid.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    @Test("表を含む発言の行を組んでも NSTextView を作らない（作るたびに入力欄の入力メソッドと同期を取り、日本語入力で止まった）。升目は view にしない")
    func buildsRowsWithoutTextViews() throws {
        let rows = (1...20).map { "| 行 \($0) | 値 \($0) | 説明 \($0) |" }.joined(separator: "\n")
        let table = ChatMessage(id: "a1", role: .assistant, kind: .text, text: "比べた結果です。\n\n| 手順 | 値 | 説明 |\n|---|---|---|\n" + rows + "\n")
        let host = BoardSnapshotTests.host(ChatTranscript(messages: [table]), size: CGSize(width: 560, height: 800), variant: BoardSnapshotTests.variants[0])
        let grid = try #require(Self.views(ChatTableGridView.self, in: host).first)
        #expect(grid.subviews.isEmpty)
        #expect(Self.views(NSTextView.self, in: host).isEmpty)
    }

    @Test("チェックリストの印は、読み上げでは「済み」「未完了」になる（印は文の中の画像で、そのままでは読まれない）")
    func speaksChecklistMarks() throws {
        let view = ChatMarkdownView(
            blocks: MarkdownBlocks.parse("- [x] ビルド\n- [ ] テスト\n"), look: ChatMarkdownLook(fonts: ChatFonts(size: 14), query: nil, openLink: { _ in }))
        _ = view.fit(width: 560)
        let text = try #require(Self.views(ChatTextView.self, in: view).first)
        #expect(text.accessibilityValue() as? String == "\t済み\tビルド\n\t未完了\tテスト")
    }

    @Test("表の升目は 1 つずつ読み上げの文になり、値は升目の文、枠は行と列の順に並ぶ")
    func exposesCellsToAccessibility() throws {
        let grid = try Self.grid("| 手順 | 値 |\n|---|---:|\n| ビルド | 12 |\n| テスト | 345 |\n")
        let cells = Self.cells(grid)
        #expect(cells.map { $0.accessibilityValue() as? String } == ["手順", "値", "ビルド", "12", "テスト", "345"])
        #expect(cells.allSatisfy { $0.accessibilityRole() == .staticText })
        let frames = cells.map { $0.accessibilityFrameInParentSpace() }
        // 見出しの行の下に本体の行、左の列の右に右の列。右寄せの列は列の右の端にそろう
        #expect(frames[2].minY >= frames[0].maxY && frames[4].minY >= frames[2].maxY)
        #expect(frames[1].minX >= frames[0].maxX)
        #expect(abs(frames[3].maxX - frames[5].maxX) < 0.5 && frames[3].width < frames[5].width)
    }

    @Test("表の升目のリンクは押して離すと openLink に渡し、ほかの升目を押すとその升目にだけ選ぶための NSTextView を付ける")
    func tableCellsOpenLinksAndSelect() throws {
        var opened: [URL] = []
        let grid = try Self.grid("| 名前 | 場所 |\n|---|---|\n| 説明 | [docs](https://example.com/docs) |\n", opened: { opened.append($0) })
        let frames = Self.cells(grid).map { $0.accessibilityFrameInParentSpace() }
        let link = grid.convert(NSPoint(x: frames[3].minX + 4, y: frames[3].midY), to: nil)
        grid.mouseDown(with: try Self.click(.leftMouseDown, at: link))
        grid.mouseUp(with: try Self.click(.leftMouseUp, at: link))
        #expect(opened == [try #require(URL(string: "https://example.com/docs"))])
        #expect(grid.subviews.isEmpty)

        let plain = grid.convert(NSPoint(x: frames[2].minX + 4, y: frames[2].midY), to: nil)
        #expect(grid.menu(for: try Self.click(.rightMouseDown, at: plain)) != nil)
        let selection = try #require(Self.views(ChatSelectionTextView.self, in: grid).first)
        #expect(Self.views(ChatSelectionTextView.self, in: grid).count == 1)
        #expect(selection.string == "説明" && !selection.isEditable && selection.isSelectable)
        #expect(selection.frame == frames[2])
    }

    @Test("選ぶための NSTextView は、文のメニューを出すときに初めて付け、編集できない")
    func attachesSelectionOnDemand() throws {
        let text = ChatTextView()
        text.set(NSAttributedString(string: "選んでコピーする文"))
        text.fit(width: 300)
        #expect(Self.views(NSTextView.self, in: text).isEmpty)
        let menu = text.menu(for: try Self.click(.rightMouseDown, at: NSPoint(x: 4, y: 4)))
        #expect(menu != nil)
        let selection = try #require(Self.views(ChatSelectionTextView.self, in: text).first)
        #expect(!selection.isEditable)
        #expect(selection.isSelectable)
        #expect(selection.string == "選んでコピーする文")
        #expect(!selection.shouldChangeText(in: NSRange(location: 0, length: 1), replacementString: "x"))
    }

    @Test("リンクの上で押して離すと openLink に渡し、選ぶための NSTextView は付けない")
    func opensLinks() throws {
        let url = try #require(URL(string: "https://example.com/docs"))
        let text = ChatTextView()
        var opened: [URL] = []
        text.openLink = { opened.append($0) }
        text.set(NSAttributedString(string: "https://example.com/docs", attributes: [.link: url, .font: NSFont.systemFont(ofSize: 13)]))
        text.fit(width: 300)
        let inside = text.convert(NSPoint(x: 6, y: 6), to: nil)
        text.mouseDown(with: try Self.click(.leftMouseDown, at: inside))
        text.mouseUp(with: try Self.click(.leftMouseUp, at: inside))
        #expect(opened == [url])
        #expect(Self.views(NSTextView.self, in: text).isEmpty)
    }
}
