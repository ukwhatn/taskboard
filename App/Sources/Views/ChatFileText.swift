import SwiftUI
import TaskboardKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// ファイルの欄の本文（diff・読んだ文）。行を 1 つの文に並べ、行をまたいで選んでコピーできる。左の行番号と +・−、行の地の色は
/// 並べ方（`ChatFileLayoutManager`）が描き、選ぶ文に入れない。畳んだ行の帯も文の中の段落で、コピーには入れない
struct ChatFileDocument: Equatable {
    enum Paragraph: Equatable {
        /// `old`・`new` は行番号。読んだ文は `new` だけ
        case line(change: ChatDiffRow.Change, old: Int?, new: Int?, text: String)
        /// 畳んだ行の帯。`expandable` なら押すと `ChatFileText.expand` に `id` を渡す
        case gap(id: Int, label: String, expandable: Bool)
    }

    var paragraphs: [Paragraph]
    /// 左の行番号の列。diff は変える前と後の 2 列と +・−、読んだ文は 1 列
    var diff: Bool
    var digits: Int
    var fontSize: Double
    /// 左端に印を付ける段落（コメントを付けた行）
    var marked: Set<Int> = []

    /// 行の上と下の間
    static let lineSpacing: CGFloat = 1

    /// 読んだ文。行番号は `firstLine` から
    static func text(_ text: String, firstLine: Int, fontSize: Double) -> ChatFileDocument {
        let lines = ChatTextLines.lines(text)
        return ChatFileDocument(
            paragraphs: lines.enumerated().map { .line(change: .context, old: nil, new: firstLine + $0.offset, text: $0.element) },
            diff: false, digits: String(firstLine + max(lines.count - 1, 0)).count, fontSize: fontSize)
    }

    /// コピーする文。帯の段落を外す
    func copied(_ string: NSAttributedString, range: NSRange) -> String {
        var parts: [String] = []
        string.enumerateAttribute(ChatFileLayoutManager.paragraph, in: range) { value, part, _ in
            guard let index = value as? Int, paragraphs.indices.contains(index), case .line = paragraphs[index] else { return }
            parts.append((string.string as NSString).substring(with: part))
        }
        return parts.joined()
    }

    /// `range` にかかる行の段落の番号（帯の段落は外す）
    func lines(_ string: NSAttributedString, range: NSRange) -> [Int] {
        var indices: [Int] = []
        // 行の末尾の改行だけにかかる選択は、次の行に入れない
        let range = NSRange(location: range.location, length: max(range.length, 1))
        string.enumerateAttribute(ChatFileLayoutManager.paragraph, in: NSIntersectionRange(range, NSRange(location: 0, length: string.length))) { value, _, _ in
            guard let index = value as? Int, paragraphs.indices.contains(index), case .line = paragraphs[index], indices.last != index else { return }
            indices.append(index)
        }
        return indices
    }

    /// 段落ごとに `ChatFileLayoutManager.paragraph`（段落の番号）を付けた文
    func attributed(gutter: ChatFileGutter) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let code = gutter.font
        let label = PlatformFont.systemFont(ofSize: fontSize * 0.85)
        let lineStyle = Self.style(indent: gutter.textStart, spacing: Self.lineSpacing)
        let gapStyle = Self.style(indent: Space.block, spacing: Space.inline)
        for (index, paragraph) in paragraphs.enumerated() {
            switch paragraph {
            case .line(_, _, _, let text):
                result.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: code, .foregroundColor: PlatformColor.label, .paragraphStyle: lineStyle, ChatFileLayoutManager.paragraph: index,
                ]))
            case .gap(let id, let text, let expandable):
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: label, .foregroundColor: PlatformColor.secondaryLabel, .paragraphStyle: gapStyle, ChatFileLayoutManager.paragraph: index,
                ]
                if expandable { attributes[.link] = ChatFileText.gapURL(id) }
                result.append(NSAttributedString(string: text + "\n", attributes: attributes))
            }
        }
        return result
    }

    private static func style(indent: CGFloat, spacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.tailIndent = -Space.block
        style.paragraphSpacingBefore = spacing
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byCharWrapping
        return style
    }
}

/// 左の欄の並び。行番号の列（等幅の数字を桁で右に揃える）、+・−、本文の始まり
struct ChatFileGutter {
    fileprivate let font: PlatformFont
    let numberColumns: Int
    let sign: Bool
    let digit: CGFloat
    let numberWidth: CGFloat

    init(_ document: ChatFileDocument) {
        font = .monospacedSystemFont(ofSize: document.fontSize * 0.85, weight: .regular)
        numberColumns = document.diff ? 2 : 1
        sign = document.diff
        digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        numberWidth = digit * CGFloat(document.digits)
    }

    func numberX(_ column: Int) -> CGFloat { Space.block + CGFloat(column) * (numberWidth + Space.row) }
    var signX: CGFloat { numberX(numberColumns) }
    var textStart: CGFloat { sign ? signX + digit + Space.row : numberX(numberColumns) }
}

/// 段落ごとに、行の地の色（足した行・消した行・帯）を幅いっぱいに塗り、最初の行に行番号と +・− を描く
final class ChatFileLayoutManager: NSLayoutManager {
    /// 段落の番号（`ChatFileDocument.paragraphs` の添字）
    nonisolated static let paragraph = NSAttributedString.Key("taskboard.fileParagraph")
    var document = ChatFileDocument(paragraphs: [], diff: false, digits: 1, fontSize: SessionTextSize.chatDefault)
    var gutter: ChatFileGutter?

    /// 行の地の色とコメントの印。選択の地はこの後に塗られる
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        eachLine(glyphsToShow, at: origin) { index, rect, _ in
            if let fill = Self.fill(self.document.paragraphs[index]) { Self.fill(rect, fill) }
            if self.document.marked.contains(index) {
                Self.fill(CGRect(x: rect.minX, y: rect.minY, width: ConversationMetrics.diffCommentMark, height: rect.height), .tintColor)
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// 行番号と +・−。選択の地に隠れないよう、字と一緒に描く
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let gutter else { return }
        eachLine(glyphsToShow, at: origin) { index, rect, first in
            // 段落の最初の行にだけ番号を描く
            guard first, case .line(let change, let old, let new, _) = self.document.paragraphs[index] else { return }
            // 改行だけの段落は字の位置が下にずれるので、段落の上の間から置く（同じ字で並べるので本文と揃う）
            let top = rect.minY + ChatFileDocument.lineSpacing
            let numbers = gutter.numberColumns == 2 ? [old, new] : [new]
            for (column, number) in numbers.enumerated() {
                Self.draw(ChatTextLines.pad(number, self.document.digits), at: CGPoint(x: rect.minX + gutter.numberX(column), y: top), font: gutter.font, color: .tertiaryLabel)
            }
            if gutter.sign, let (sign, color) = Self.sign(change) {
                Self.draw(sign, at: CGPoint(x: rect.minX + gutter.signX, y: top), font: gutter.font, color: color)
            }
        }
    }

    /// 選択の地は本文の幅にだけ塗る（行番号の列にかけない）
    #if os(macOS)
    typealias SelectionColor = NSColor
    #else
    typealias SelectionColor = UIColor
    #endif

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: SelectionColor) {
        guard let gutter else { return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color) }
        let clipped = UnsafeBufferPointer(start: rectArray, count: rectCount).map { rect in
            let left = max(rect.minX, gutter.textStart)
            return CGRect(x: left, y: rect.minY, width: max(rect.maxX - left, 0), height: rect.height)
        }
        clipped.withUnsafeBufferPointer { super.fillBackgroundRectArray($0.baseAddress!, count: rectCount, forCharacterRange: charRange, color: color) }
    }

    /// `glyphs` にかかる行ごとに、段落の番号・行の枠（`origin` に置いた座標）・段落の最初の行か
    private func eachLine(_ glyphs: NSRange, at origin: CGPoint, _ body: @escaping (Int, CGRect, Bool) -> Void) {
        guard let storage = textStorage else { return }
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, line, _ in
            let character = self.characterIndexForGlyph(at: line.location)
            guard let index = storage.attribute(Self.paragraph, at: character, effectiveRange: nil) as? Int,
                self.document.paragraphs.indices.contains(index)
            else { return }
            let first = character == 0 || (storage.string as NSString).character(at: character - 1) == 0x0A
            body(index, fragment.offsetBy(dx: origin.x, dy: origin.y), first)
        }
    }

    private static func fill(_ paragraph: ChatFileDocument.Paragraph) -> PlatformColor? {
        switch paragraph {
        case .line(.added, _, _, _): PlatformColor.systemGreen.withAlphaComponent(0.12)
        case .line(.removed, _, _, _): PlatformColor.systemRed.withAlphaComponent(0.12)
        case .line(.context, _, _, _): nil
        case .gap: PlatformColor.secondaryLabel.withAlphaComponent(0.06)
        }
    }

    private static func sign(_ change: ChatDiffRow.Change) -> (String, PlatformColor)? {
        switch change {
        case .context: nil
        case .removed: ("−", .systemRed)
        case .added: ("+", .systemGreen)
        }
    }

    private static func fill(_ rect: CGRect, _ color: PlatformColor) {
        color.setFill()
        #if os(macOS)
        rect.fill(using: .sourceOver)
        #else
        UIRectFillUsingBlendMode(rect, .normal)
        #endif
    }

    private static func draw(_ text: String, at point: CGPoint, font: PlatformFont, color: PlatformColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

#if os(macOS)
private extension PlatformColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var tintColor: NSColor { .controlAccentColor }
}
#endif

/// 選んだ行へのコメント。`lines` は行の段落の番号、`rect` は選んだ所の枠（view の座標。上が原点）
struct ChatFileSelection: Identifiable {
    let id = UUID()
    let lines: [Int]
    let rect: CGRect
}

/// `ChatFileDocument` を 1 つの選べる文で出す。送りも自分で持つ
struct ChatFileText {
    let document: ChatFileDocument
    /// 帯を押したとき（帯の id）
    var expand: (Int) -> Void = { _ in }
    /// 渡すと、選んだ行に［コメント］を出す（Mac は選択の下に浮かせ、iPhone・iPad は選択のメニューに足す）
    var comment: ((ChatFileSelection) -> Void)?

    static func gapURL(_ id: Int) -> URL { URL(string: "taskboard-file-gap:\(id)")! }

    static func gapID(_ link: Any) -> Int? {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == "taskboard-file-gap" else { return nil }
        return Int(url.absoluteString.dropFirst("taskboard-file-gap:".count))
    }

    /// TextKit 1 の組（入れ物の幅は view に合わせる）
    fileprivate static func stack() -> (NSTextStorage, ChatFileLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = ChatFileLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    /// 文を入れ替える。同じなら何もせず false
    @discardableResult
    fileprivate static func apply(_ document: ChatFileDocument, to layout: ChatFileLayoutManager) -> Bool {
        guard document != layout.document || layout.gutter == nil, let storage = layout.textStorage else { return false }
        let gutter = ChatFileGutter(document)
        layout.document = document
        layout.gutter = gutter
        storage.setAttributedString(document.attributed(gutter: gutter))
        return true
    }

    final class Coordinator: NSObject {
        var expand: (Int) -> Void = { _ in }
        var comment: ((ChatFileSelection) -> Void)?
    }
}

#if os(macOS)
extension ChatFileText: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (storage, _, container) = Self.stack()
        let text = ChatFileNSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), textContainer: container)
        text.storage = storage
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: Space.row)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        text.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.expand = expand
        context.coordinator.comment = comment
        guard let text = scroll.documentView as? ChatFileNSTextView, let layout = text.layoutManager as? ChatFileLayoutManager else { return }
        text.comment = comment.map { comment in { [weak scroll] lines, rect in
            guard let scroll else { return }
            // 選んだ所の枠を、上を原点にした view の座標にする
            let local = scroll.convert(rect, from: scroll.documentView)
            let top = scroll.isFlipped ? local.minY : scroll.bounds.height - local.maxY
            comment(ChatFileSelection(lines: lines, rect: CGRect(x: local.minX, y: top, width: local.width, height: local.height)))
        } }
        if Self.apply(document, to: layout) { text.sizeToFit() }
        text.showCommentButton()
    }
}

extension ChatFileText.Coordinator: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let id = ChatFileText.gapID(link) else { return false }
        expand(id)
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // 押したまま選んでいる間は出さない（離した後に `mouseDown` が出す）
        guard NSEvent.pressedMouseButtons == 0 else { return }
        (notification.object as? ChatFileNSTextView)?.showCommentButton()
    }
}

/// コピーから帯の段落を外す。`comment` があれば、選んだ行の下に［コメント］を浮かせる
final class ChatFileNSTextView: NSTextView {
    /// TextKit 1 の組では、text view は文の入れ物を持たない
    var storage: NSTextStorage?
    /// 選んだ行の段落の番号と、選んだ所の枠（text view の座標）
    var comment: (([Int], NSRect) -> Void)?
    private var commentButton: ChatCommentButtonView?

    override func mouseDown(with event: NSEvent) {
        commentButton?.isHidden = true
        // 離すまでここで追う
        super.mouseDown(with: event)
        showCommentButton()
    }

    /// 選んだ行と枠。行にかからなければ nil
    private var selectedLines: (lines: [Int], rect: NSRect)? {
        guard let storage = textStorage, let layout = layoutManager as? ChatFileLayoutManager, let container = textContainer else { return nil }
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        let lines = layout.document.lines(storage, range: range)
        guard !lines.isEmpty else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (lines, rect)
    }

    func showCommentButton() {
        guard comment != nil, let selected = selectedLines else {
            commentButton?.isHidden = true
            return
        }
        let button = commentButton ?? makeCommentButton()
        button.fit(width: bounds.width)
        let start = (layoutManager as? ChatFileLayoutManager)?.gutter?.textStart ?? 0
        let x = min(max(selected.rect.minX, start), max(bounds.maxX - button.frame.width, 0))
        button.setFrameOrigin(NSPoint(x: x, y: selected.rect.maxY + Space.inline))
        button.isHidden = false
    }

    private func makeCommentButton() -> ChatCommentButtonView {
        let button = ChatCommentButtonView { [weak self] in self?.startComment() }
        addSubview(button)
        commentButton = button
        return button
    }

    @objc func startComment() {
        guard let selected = selectedLines else { return }
        commentButton?.isHidden = true
        comment?(selected.lines, selected.rect)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard comment != nil, selectedLines != nil else { return menu }
        let item = NSMenuItem(title: String(localized: "選んだ行にコメント"), action: #selector(startComment), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "plus.bubble", accessibilityDescription: nil)
        menu?.insertItem(.separator(), at: 0)
        menu?.insertItem(item, at: 0)
        return menu
    }

    override func copy(_ sender: Any?) {
        guard let storage = textStorage, let layout = layoutManager as? ChatFileLayoutManager else { return super.copy(sender) }
        let text = selectedRanges.map { layout.document.copied(storage, range: $0.rangeValue) }.joined()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 選んだ行の下に浮かせる［コメント］。下の行の字に重なるので、窓がキーでなくても透けない強調の色の地で描き、後ろの窓でも 1 回で押せる
final class ChatCommentButtonView: ChatPressableView, ChatFitting {
    private let symbol = ChatSymbolView("plus.bubble", size: NSFont.smallSystemFontSize, tint: .white)
    private let label = ChatLabelView(String(localized: "コメント"), font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), color: .white)

    init(action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.action = action
        addSubview(symbol)
        addSubview(label)
        label.readsAloud = false
        setAccessibilityLabel(String(localized: "コメント"))
        toolTip = String(localized: "選んだ行にコメント")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 窓は押した所の部品に acceptsFirstMouse を聞くので、中の印と文でなく自分が受ける
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    @discardableResult
    func fit(width: CGFloat) -> NSSize {
        let symbolSize = symbol.fit(width: .greatestFiniteMagnitude)
        let labelSize = label.fit(width: .greatestFiniteMagnitude)
        let height = max(HitTarget.size, ceil(max(symbolSize.height, labelSize.height)) + Space.inline)
        var x = Space.row
        symbol.frame = NSRect(x: x, y: ((height - symbolSize.height) / 2).rounded(), width: symbolSize.width, height: symbolSize.height)
        x += symbolSize.width + Space.inline
        label.frame = NSRect(x: x, y: ((height - labelSize.height) / 2).rounded(), width: labelSize.width, height: labelSize.height)
        let size = NSSize(width: min(x + labelSize.width + Space.row, width), height: height)
        setFrameSize(size)
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        ChatDrawing.box(bounds, radius: bounds.height / 2, fill: .controlAccentColor)
    }
}
#else
extension ChatFileText: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ChatFileUITextView {
        let (storage, _, container) = Self.stack()
        let text = ChatFileUITextView(frame: .zero, textContainer: container)
        text.storage = storage
        text.isEditable = false
        text.isSelectable = true
        text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(top: Space.row, left: 0, bottom: Space.row, right: 0)
        text.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        text.delegate = context.coordinator
        return text
    }

    func updateUIView(_ text: ChatFileUITextView, context: Context) {
        context.coordinator.expand = expand
        context.coordinator.comment = comment
        guard let layout = text.layoutManager as? ChatFileLayoutManager else { return }
        Self.apply(document, to: layout)
    }
}

extension ChatFileText.Coordinator: UITextViewDelegate {
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, let id = ChatFileText.gapID(url) else { return defaultAction }
        return UIAction { [weak self] _ in self?.expand(id) }
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let comment, let layout = textView.layoutManager as? ChatFileLayoutManager else { return nil }
        let lines = layout.document.lines(textView.textStorage, range: range)
        guard !lines.isEmpty, let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
            let end = textView.position(from: start, offset: range.length), let textRange = textView.textRange(from: start, to: end)
        else { return nil }
        // 選んだ所の枠を、スクロールした分を引いた view の座標にする
        let rect = textView.selectionRects(for: textRange).map(\.rect).reduce(CGRect.null) { $0.union($1) }
            .offsetBy(dx: -textView.contentOffset.x, dy: -textView.contentOffset.y)
        let action = UIAction(title: String(localized: "コメント"), image: UIImage(systemName: "plus.bubble")) { _ in
            comment(ChatFileSelection(lines: lines, rect: rect))
        }
        return UIMenu(children: [action] + suggestedActions)
    }
}

/// コピーから帯の段落を外す
final class ChatFileUITextView: UITextView {
    /// TextKit 1 の組では、text view は文の入れ物を持たない
    var storage: NSTextStorage?

    override func copy(_ sender: Any?) {
        guard let layout = layoutManager as? ChatFileLayoutManager else { return super.copy(sender) }
        UIPasteboard.general.string = layout.document.copied(textStorage, range: selectedRange)
    }
}
#endif
