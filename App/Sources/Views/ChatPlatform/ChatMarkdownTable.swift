import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import TaskboardKit

/// Markdown の表（`TableBlock` の chat の見た目）。列の幅は中身に合わせ、長いセルは `MarkdownMetrics.tableCellMaxWidth` で折り返す。列は表の中で横に送る。
/// 線と外の枠は引かず、セルごとに地を敷く（`ChatTableGridView`）
final class ChatTableView: ChatFlippedView, ChatFitting {
    private let scroll: ChatHorizontalScrollView

    init(table: MarkdownTable, look: ChatMarkdownLook) {
        scroll = ChatHorizontalScrollView(content: ChatTableGridView(table: table, look: look))
        super.init(frame: .zero)
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let inner = scroll.fit(width: width)
        scroll.frame.origin = .zero
        let size = CGSize(width: width, height: inner.height)
        setFrameSize(size)
        return size
    }
}

/// 表の格子。升目ごとに角丸の地（見出しは濃く）を敷き、升目の間を空ける。地は列の幅と行の一番高い升目に揃える。升目の文は view にせず並べ方（`ChatTextLayout`）だけを持ち、1 枚に描く
/// （升目ごとに view を作ると、300 升目の表を組むたびに、作る・layer・制約の見張り・外すのが view の数だけ掛かった）。
/// 会話の一覧の中では、升目の文も一覧の選択に入る（`ChatSelectableText`）。一覧の外では、選ぶための NSTextView を押した升目にだけ付ける。読み上げは升目ごとの要素で出す
final class ChatTableGridView: ChatFlippedView, ChatFitting {
    @MainActor
    private final class Cell {
        let text = ChatTextLayout()
        let alignment: NSTextAlignment
        var frame = CGRect.zero
        /// 地を敷く所（列の幅と行の高さ）
        var fill = CGRect.zero
        #if os(macOS)
        var selection: ChatSelectionTextView?
        /// 会話の一覧が選んでいる、この升目にかかる範囲
        var selected: NSRange?
        var element: NSAccessibilityElement?
        #else
        var element: UIAccessibilityElement?
        #endif

        init(_ string: NSAttributedString, alignment: NSTextAlignment) {
            self.alignment = alignment
            text.set(string)
        }
    }

    private let alignments: [MarkdownTable.Alignment]
    /// 見出しの行と本体の行
    private let rows: [[Cell]]
    /// 見出しの升目の数（`rows` の頭の行）
    private let header: Int
    private let openLink: (URL) -> Void
    /// 中身は作ったときに決まり、幅は置ける幅を見ないので、1 回並べたら覚えておく
    private var fitted: CGSize?
    /// 押したリンク（離したときに同じリンクの上なら開く）
    private var pressedLink: URL?
    /// 選択の地を強い色で描く
    private var selectionEmphasized = true

    init(table: MarkdownTable, look: ChatMarkdownLook) {
        alignments = table.alignments
        header = table.header.count
        openLink = look.openLink
        let fonts = look.fonts
        func cell(_ text: AttributedString, column: Int, header: Bool) -> Cell {
            let font: PlatformFont = header ? .systemFont(ofSize: fonts.size, weight: .semibold) : fonts.platformBody
            let alignment = Self.textAlignment(table.alignments, column)
            let string = ChatAttributed.inline(text, font: font, color: look.color, line: fonts.line, query: look.query)
            ChatAttributed.setParagraph(string, ChatAttributed.paragraph(line: fonts.line, alignment: alignment))
            return Cell(string, alignment: alignment)
        }
        rows = [table.header.enumerated().map { cell($1, column: $0, header: true) }]
            + table.rows.map { row in row.enumerated().map { cell($1, column: $0, header: false) } }
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func textAlignment(_ alignments: [MarkdownTable.Alignment], _ column: Int) -> NSTextAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    /// 升目を並べた大きさ。列の上限に収まる左寄せの升目は、折り返さずに並べたまま使う（並べ直すと升目ごとに 2 回並べることになる）
    private static func measure(_ cell: Cell) -> CGSize {
        let natural = cell.text.fitUnwrapped()
        if natural.width <= MarkdownMetrics.tableCellMaxWidth && cell.alignment == .left { return natural }
        return cell.text.fit(width: min(natural.width, MarkdownMetrics.tableCellMaxWidth))
    }

    /// 幅は中身で決まる（置ける幅は見ない。はみ出した分は横に送る）
    func fit(width: CGFloat) -> CGSize {
        if let fitted { return fitted }
        let padding = MarkdownMetrics.tableCellPadding
        let spacing = MarkdownMetrics.tableCellSpacing
        let columns = rows.map(\.count).max() ?? 0
        let sizes = rows.map { $0.map(Self.measure) }
        var widths = Array(repeating: CGFloat(0), count: columns)
        for row in sizes {
            for (column, size) in row.enumerated() { widths[column] = max(widths[column], size.width) }
        }
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            if index > 0 { y += spacing }
            var x: CGFloat = 0
            let height = (sizes[index].map(\.height).max() ?? 0) + padding * 2
            for (column, cell) in row.enumerated() {
                let size = sizes[index][column]
                let offset: CGFloat = switch alignments.indices.contains(column) ? alignments[column] : .leading {
                case .leading: 0
                case .center: ((widths[column] - size.width) / 2).rounded()
                case .trailing: widths[column] - size.width
                }
                cell.frame = CGRect(origin: CGPoint(x: x + padding + offset, y: y + padding), size: size)
                cell.fill = CGRect(x: x, y: y, width: widths[column] + padding * 2, height: height)
                #if os(macOS)
                cell.element?.setAccessibilityFrameInParentSpace(cell.frame)
                #else
                cell.element?.accessibilityFrameInContainerSpace = cell.frame
                #endif
                x += widths[column] + padding * 2 + spacing
            }
            y += height
        }
        let gridWidth = widths.reduce(0, +) + padding * 2 * CGFloat(columns) + spacing * CGFloat(max(columns - 1, 0))
        let size = CGSize(width: gridWidth, height: y)
        setFrameSize(size)
        fitted = size
        needsDisplay = true
        #if os(macOS)
        window?.invalidateCursorRects(for: self)
        #endif
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        for (index, cell) in rows.joined().enumerated() where cell.fill.intersects(dirtyRect) {
            let fill = index < header ? ChatPalette.Platform.fillStrong : ChatPalette.Platform.fill
            ChatDrawing.box(cell.fill, radius: MarkdownMetrics.tableCellRadius, fill: fill)
        }
        #if os(macOS)
        let color: PlatformColor = selectionEmphasized ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
        for cell in rows.joined() where cell.selection == nil && cell.frame.intersects(dirtyRect) {
            cell.text.draw(
                dirtyRect.offsetBy(dx: -cell.frame.minX, dy: -cell.frame.minY), at: cell.frame.origin, selection: cell.selected.map { ($0, color) })
        }
        #else
        for cell in rows.joined() where cell.frame.intersects(dirtyRect) {
            cell.text.draw(dirtyRect.offsetBy(dx: -cell.frame.minX, dy: -cell.frame.minY), at: cell.frame.origin)
        }
        #endif
    }

    #if os(macOS)
    override func resetCursorRects() {
        for cell in rows.joined() where cell.selection == nil {
            addCursorRect(cell.frame, cursor: .iBeam)
            for rect in cell.text.linkRects() { addCursorRect(rect.offsetBy(dx: cell.frame.minX, dy: cell.frame.minY), cursor: .pointingHand) }
        }
    }

    private func cell(at event: NSEvent) -> (cell: Cell, point: CGPoint)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = rows.joined().first(where: { $0.frame.contains(point) }) else { return nil }
        return (cell, CGPoint(x: point.x - cell.frame.minX, y: point.y - cell.frame.minY))
    }

    override func mouseDown(with event: NSEvent) {
        guard let hit = cell(at: event) else { return super.mouseDown(with: event) }
        if let link = hit.cell.text.link(at: hit.point) {
            pressedLink = link
            return
        }
        if let list = enclosingChatList { return list.beginSelection(with: event) }
        let view = selectionView(hit.cell)
        window?.makeFirstResponder(view)
        view.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedLink = nil }
        guard let pressedLink, let hit = cell(at: event), hit.cell.text.link(at: hit.point) == pressedLink else { return }
        openLink(pressedLink)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let list = enclosingChatList { return list.menu(adding: ChatMenu.nearest(from: self)) }
        if let menu = ChatMenu.nearest(from: self) { return menu }
        guard let hit = cell(at: event) else { return super.menu(for: event) }
        return selectionView(hit.cell).menu(for: event)
    }

    private func selectionView(_ cell: Cell) -> ChatSelectionTextView {
        if let selection = cell.selection { return selection }
        // 折り返さずに並べた升目は入れ物が広いままなので、升目の幅で並べ直してから付ける（左寄せの 1 行は同じ並びになる）
        _ = cell.text.fit(width: cell.frame.width)
        let view = cell.text.selectionView(frame: cell.frame) { [weak self] in self?.openLink($0) }
        addSubview(view)
        cell.selection = view
        setNeedsDisplay(cell.frame)
        window?.invalidateCursorRects(for: self)
        return view
    }

    var selectionPieces: [ChatSelectionPiece] {
        rows.flatMap { row in row.enumerated().map { ChatSelectionPiece(frame: $1.frame, string: $1.text.string, sameLine: $0 > 0) } }
    }

    private func cell(_ piece: Int) -> Cell { Array(rows.joined())[piece] }

    func characterIndex(piece: Int, at point: CGPoint) -> Int {
        let cell = cell(piece)
        return cell.text.characterIndex(at: CGPoint(x: point.x - cell.frame.minX, y: point.y - cell.frame.minY))
    }

    func wordRange(piece: Int, at index: Int) -> NSRange { cell(piece).text.wordRange(at: index) }

    func showSelection(_ ranges: [NSRange?], emphasized: Bool) {
        var changed = emphasized != selectionEmphasized && rows.joined().contains { $0.selected != nil }
        for (cell, range) in zip(rows.joined(), ranges) where cell.selected != range {
            cell.selected = range
            changed = true
        }
        selectionEmphasized = emphasized
        if changed { needsDisplay = true }
    }

    override func accessibilityChildren() -> [Any]? {
        rows.joined().map { cell in
            if let element = cell.element { return element }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityValue(cell.text.string)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(cell.frame)
            cell.element = element
            return element
        }
    }
    #else
    private func cell(at touch: UITouch?) -> (cell: Cell, point: CGPoint)? {
        guard let point = touch?.location(in: self), let cell = rows.joined().first(where: { $0.frame.contains(point) }) else { return nil }
        return (cell, CGPoint(x: point.x - cell.frame.minX, y: point.y - cell.frame.minY))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressedLink = cell(at: touches.first).flatMap { $0.cell.text.link(at: $0.point) }
        if pressedLink == nil { super.touchesBegan(touches, with: event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { pressedLink = nil }
        guard let pressedLink else { return super.touchesEnded(touches, with: event) }
        if let hit = cell(at: touches.first), hit.cell.text.link(at: hit.point) == pressedLink { openLink(pressedLink) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pressed = pressedLink
        pressedLink = nil
        if pressed == nil { super.touchesCancelled(touches, with: event) }
    }

    /// 升目の文（長押しの［コピー］で写す）
    var plainText: String {
        rows.map { $0.map(\.text.string).joined(separator: "\t") }.joined(separator: "\n")
    }

    override var accessibilityElements: [Any]? {
        get {
            rows.joined().map { cell in
                if let element = cell.element { return element }
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityTraits = .staticText
                element.accessibilityLabel = cell.text.string
                element.accessibilityFrameInContainerSpace = cell.frame
                cell.element = element
                return element
            }
        }
        set {}
    }
    #endif
}

#if os(macOS)
extension ChatTableGridView: ChatSelectableText {}
#endif
