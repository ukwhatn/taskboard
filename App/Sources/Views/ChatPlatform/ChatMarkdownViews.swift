import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import TaskboardKit

/// コードの塊の［実行］に要るもの（会話の画面の口と、塊のある発言）
struct ChatCodeRun {
    let actions: CodeRunActions
    let messageID: String
}

/// チャットの Markdown の見た目と口（`MarkdownStyle.sized` の chat）
struct ChatMarkdownLook {
    let fonts: ChatFonts
    let query: String?
    /// 本文の色。引用の中は補足の色
    var color: PlatformColor = ChatPalette.Platform.label
    let openLink: (URL) -> Void
    /// シェルの塊に［実行］を出す。nil なら出さない
    var codeRun: ChatCodeRun?
}

/// Markdown のブロックを AppKit の部品で並べる（`MarkdownView` の chat の見た目）。段落・見出し・リストは続く分を 1 つの文の view に流し、
/// コードの塊・表・区切り線・引用は別の部品にする。間は `BlockStack` と同じ（塊どうし `ChatFonts.itemGap`、リストの中 `tightSpacing`、見出し 1・2 の上に tight を足す）
final class ChatMarkdownView: ChatFlippedView, ChatFitting {
    private let pieces: [ChatMarkdownBuilder.Piece]

    init(blocks: [MarkdownBlock], look: ChatMarkdownLook) {
        var builder = ChatMarkdownBuilder(look: look)
        builder.walk(blocks, depth: 0, indent: 0, spacing: look.fonts.itemGap, leadIn: 0)
        builder.flush()
        pieces = builder.pieces
        super.init(frame: .zero)
        pieces.forEach { addSubview($0.view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        var y: CGFloat = 0
        for piece in pieces {
            // 先頭の部品の前の間は、見出しの上の tight だけ（塊どうしの間は 2 つ目から）
            y += piece.before
            let size = piece.view.fit(width: max(width - piece.indent, 1))
            piece.view.frame.origin = CGPoint(x: piece.indent, y: y)
            y += size.height
        }
        let size = CGSize(width: width, height: y)
        setFrameSize(size)
        return size
    }
}

/// `[MarkdownBlock]` を部品の並びにする
@MainActor
struct ChatMarkdownBuilder {
    struct Piece {
        let view: ChatPart
        /// 前の部品との間
        let before: CGFloat
        let indent: CGFloat
    }

    let look: ChatMarkdownLook
    private(set) var pieces: [Piece] = []
    /// 流している文と、その前の部品との間
    private var text = NSMutableAttributedString()
    private var textBefore: CGFloat = 0

    init(look: ChatMarkdownLook) {
        self.look = look
    }

    private var fonts: ChatFonts { look.fonts }

    /// `leadIn` は先頭のブロックの前の間（2 つ目からは `spacing`）
    mutating func walk(_ blocks: [MarkdownBlock], depth: Int, indent: CGFloat, spacing: CGFloat, leadIn: CGFloat) {
        for (index, block) in blocks.enumerated() {
            let gap = index == 0 ? leadIn : spacing
            switch block {
            case .paragraph(let inline):
                appendText(ChatAttributed.inline(inline, font: fonts.platformBody, color: look.color, line: fonts.line, query: look.query), before: gap, indent: indent)
            case .heading(let level, let inline):
                appendText(
                    ChatAttributed.inline(inline, font: fonts.platformHeading(level), color: look.color, line: fonts.line, query: look.query),
                    before: gap + (level <= 2 ? MarkdownMetrics.tightSpacing : 0), indent: indent)
            case .list(let list):
                for (number, item) in list.items.enumerated() {
                    appendItem(item, number: list.start.map { $0 + number }, ordered: list.start != nil, depth: depth, indent: indent,
                        before: number == 0 ? gap : MarkdownMetrics.tightSpacing)
                }
            case .code(let code, let language):
                append(ChatCodeBlockView(code: code, language: language, look: look), before: gap, indent: indent)
            case .quote(let inner):
                var quoted = look
                quoted.color = ChatPalette.Platform.secondaryLabel
                append(ChatQuoteView(blocks: inner, look: quoted), before: gap, indent: indent)
            case .rule:
                // 線の上下に tight を空ける
                append(ChatSpacerView(height: 0.5 + MarkdownMetrics.tightSpacing * 2, color: ChatPalette.Platform.fillStronger, line: 0.5), before: gap, indent: indent)
            case .table(let table):
                append(ChatTableView(table: table, look: look), before: gap, indent: indent)
            }
        }
    }

    /// リストの 1 項目。印は右に寄せて `bulletWidth`・`numberWidth` の幅を取り、項目の頭を揃える。最初の段落は印と同じ行に流す
    private mutating func appendItem(_ item: MarkdownList.Item, number: Int?, ordered: Bool, depth: Int, indent: CGFloat, before: CGFloat) {
        let marker: NSAttributedString
        if let checked = item.checked {
            marker = ChatAttributed.symbol(
                checked ? "checkmark.square.fill" : "square", spoken: checked ? String(localized: "済み") : String(localized: "未完了"), font: fonts.platformBody, color: checked ? ChatPalette.Platform.controlAccent : ChatPalette.Platform.secondaryLabel, line: fonts.line)
        } else if let number {
            marker = ChatAttributed.plain(
                "\(number).", font: .monospacedDigitSystemFont(ofSize: fonts.size, weight: .regular), color: ChatPalette.Platform.secondaryLabel, line: fonts.line, query: nil)
        } else {
            marker = ChatAttributed.plain(depth == 0 ? "•" : "◦", font: fonts.platformBody, color: ChatPalette.Platform.secondaryLabel, line: fonts.line, query: nil)
        }
        let markerWidth = max(ceil(marker.size().width), ordered ? MarkdownMetrics.numberWidth : MarkdownMetrics.bulletWidth)
        let textIndent = indent + markerWidth + MarkdownMetrics.tightSpacing
        let tabs = [NSTextTab(textAlignment: .right, location: indent + markerWidth), NSTextTab(textAlignment: .left, location: textIndent)]
        let line = NSMutableAttributedString(string: "\t")
        line.append(marker)
        line.append(NSAttributedString(string: "\t"))
        var rest = item.blocks[...]
        switch rest.first {
        case .paragraph(let inline):
            line.append(ChatAttributed.inline(inline, font: fonts.platformBody, color: look.color, line: fonts.line, query: look.query))
            rest = rest.dropFirst()
        case .heading(let level, let inline):
            line.append(ChatAttributed.inline(inline, font: fonts.platformHeading(level), color: look.color, line: fonts.line, query: look.query))
            rest = rest.dropFirst()
        default:
            break
        }
        appendText(line, before: before, indent: textIndent, firstIndent: indent, tabs: tabs)
        walk(Array(rest), depth: depth + 1, indent: textIndent, spacing: MarkdownMetrics.tightSpacing, leadIn: MarkdownMetrics.tightSpacing)
    }

    /// 流している文に段落を足す。段落の中の改行（"\n"）は段落を分けるので、前の間は頭の行にだけ付ける
    private mutating func appendText(_ paragraph: NSAttributedString, before: CGFloat, indent: CGFloat, firstIndent: CGFloat? = nil, tabs: [NSTextTab] = []) {
        let first = text.length == 0
        if first { textBefore = before } else { text.append(NSAttributedString(string: "\n")) }
        let start = text.length
        text.append(paragraph)
        let string = text.string as NSString
        var lineStart = start
        var isHead = true
        while lineStart <= text.length {
            let found = string.range(of: "\n", range: NSRange(location: lineStart, length: text.length - lineStart))
            let end = found.location == NSNotFound ? text.length : found.location
            let style = ChatAttributed.paragraph(
                line: fonts.line, before: isHead && !first ? before : 0, indent: isHead ? (firstIndent ?? indent) : indent, headIndent: indent, tabs: isHead ? tabs : [])
            ChatAttributed.setParagraph(text, style, range: NSRange(location: lineStart, length: end - lineStart + (found.location == NSNotFound ? 0 : 1)))
            guard found.location != NSNotFound else { break }
            lineStart = end + 1
            isHead = false
        }
    }

    private mutating func append(_ view: ChatPart, before: CGFloat, indent: CGFloat) {
        flush()
        pieces.append(Piece(view: view, before: before, indent: indent))
    }

    /// 流している文を部品にする
    mutating func flush() {
        guard text.length > 0 else { return }
        let block = ChatTextBlock(text)
        block.text.openLink = look.openLink
        pieces.append(Piece(view: block, before: textBefore, indent: 0))
        text = NSMutableAttributedString()
    }
}

/// 引用。左に 2pt の線を引き、中を補足の色で並べる
final class ChatQuoteView: ChatFlippedView, ChatFitting {
    private let content: ChatMarkdownView

    init(blocks: [MarkdownBlock], look: ChatMarkdownLook) {
        content = ChatMarkdownView(blocks: blocks, look: look)
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let offset = 2 + MarkdownMetrics.quoteSpacing
        let inner = content.fit(width: max(width - offset, 1))
        content.frame.origin = CGPoint(x: offset, y: 0)
        let size = CGSize(width: width, height: inner.height)
        setFrameSize(size)
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        ChatPalette.Platform.fillStrong.setFill()
        CGRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}

#if os(macOS)
/// 横に送る入れ物（表）。縦のホイールは親（会話の一覧）へ渡す
final class ChatHorizontalScrollView: NSScrollView, ChatFitting {
    private let content: ChatPart
    private let document = ChatFlippedView()

    init(content: ChatPart) {
        self.content = content
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        // 古い形のスクロールバーは文に重なって高さを取るので、重ねる形に揃える
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        document.addSubview(content)
        documentView = document
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let inner = content.fit(width: .greatestFiniteMagnitude)
        content.frame.origin = .zero
        document.setFrameSize(inner)
        horizontalScrollElasticity = inner.width > width ? .automatic : .none
        let size = CGSize(width: width, height: inner.height)
        setFrameSize(size)
        return size
    }

    /// 中身を折り返さないときの幅
    var naturalWidth: CGFloat { content.fit(width: .greatestFiniteMagnitude).width }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

#else
/// 横に送る入れ物（表）。縦に送る指は一覧が受ける
final class ChatHorizontalScrollView: UIScrollView, ChatFitting {
    private let content: ChatPart

    init(content: ChatPart) {
        self.content = content
        super.init(frame: .zero)
        backgroundColor = nil
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        scrollsToTop = false
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let inner = content.fit(width: .greatestFiniteMagnitude)
        content.frame.origin = .zero
        contentSize = inner
        alwaysBounceHorizontal = inner.width > width
        let size = CGSize(width: width, height: inner.height)
        setFrameSize(size)
        return size
    }
}
#endif

/// 中の部品の周りに余白を取る
final class ChatPaddingView: ChatFlippedView, ChatFitting {
    private let content: ChatPart
    private let horizontal: CGFloat
    private let vertical: CGFloat

    init(_ content: ChatPart, horizontal: CGFloat, vertical: CGFloat) {
        self.content = content
        self.horizontal = horizontal
        self.vertical = vertical
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let inner = content.fit(width: width == .greatestFiniteMagnitude ? width : max(width - horizontal * 2, 1))
        content.frame.origin = CGPoint(x: horizontal, y: vertical)
        let size = CGSize(width: inner.width + horizontal * 2, height: inner.height + vertical * 2)
        setFrameSize(size)
        return size
    }
}
