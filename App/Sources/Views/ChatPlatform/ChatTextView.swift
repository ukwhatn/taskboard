import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Mac の会話の一覧の AppKit の行が使う字。`ChatFonts` と同じ大きさと太さ
extension ChatFonts {
    var platformBody: PlatformFont { .systemFont(ofSize: size) }
    var platformSubheadline: PlatformFont { .systemFont(ofSize: size * 0.92) }
    var platformSubheadlineMedium: PlatformFont { .systemFont(ofSize: size * 0.92, weight: .medium) }
    var platformCaption: PlatformFont { .systemFont(ofSize: size * 0.85) }
    var platformCaption2: PlatformFont { .systemFont(ofSize: size * 0.77) }
    var platformCode: PlatformFont { .monospacedSystemFont(ofSize: size - 2, weight: .regular) }
    var platformSubheadlineCode: PlatformFont { .monospacedSystemFont(ofSize: size * 0.92, weight: .regular) }

    /// 見出しは本文の 1.143・1.071・1 倍の semibold、4 段目からは本文の medium（`MarkdownStyle.sized`）
    func platformHeading(_ level: Int) -> PlatformFont {
        switch level {
        case 1: .systemFont(ofSize: size * 1.143, weight: .semibold)
        case 2: .systemFont(ofSize: size * 1.071, weight: .semibold)
        case 3: .systemFont(ofSize: size, weight: .semibold)
        default: .systemFont(ofSize: size, weight: .medium)
        }
    }
}

/// 編集しない文の並べ方（TextKit 1）。view を持たず、描く view が `draw(_:at:)` で描く（`ChatTextView`、表の升目の `ChatTableGridView`）。
/// 座標は並べ方の左上が原点
@MainActor
final class ChatTextLayout {
    let storage = NSTextStorage()
    let layout = ChatLayoutManager()
    let container: NSTextContainer

    /// リンクの見た目（SwiftUI の Text のリンクと同じく、下線を引かずにシステムの強調の色）。NSTextView の無い並べ方は、Mac では下線を引くので描くときに替える
    private static let linkDrawing: [NSAttributedString.Key: Any] = [.foregroundColor: ChatPalette.Platform.controlAccent, .underlineStyle: 0]
    /// 最後に入れた文（iPhone・iPad はリンクの色を storage に入れるので、storage と比べられない）
    private var source = NSAttributedString()
    /// 折り返さないときに使う幅
    static let unlimitedWidth: CGFloat = 1_000_000

    init() {
        container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
    }

    var string: String { storage.string }
    /// 読み上げる文（文の中の印を `ChatAttributed.spoken` の語に替える）
    var spokenString: String { ChatAttributed.spokenString(source) }

    /// 文を入れる。同じ文なら何もせず false
    @discardableResult
    func set(_ text: NSAttributedString) -> Bool {
        guard !source.isEqual(to: text) else { return false }
        source = text.copy() as! NSAttributedString
        // 入れ物の高さを 0 にしてから入れる。入れると今の幅（作ったときは仮の 100）ですぐ並べ始め、その並べは幅の決まる `fit(width:)` で捨てていた
        container.size = CGSize(width: container.size.width, height: 0)
        let whole = NSRange(location: 0, length: text.length)
        #if os(macOS)
        storage.setAttributedString(text)
        layout.setTemporaryAttributes([:], forCharacterRange: whole)
        storage.enumerateAttribute(.link, in: whole) { value, range, _ in
            if value != nil { layout.setTemporaryAttributes(Self.linkDrawing, forCharacterRange: range) }
        }
        #else
        // UIKit には一時の属性が無いので、文に入れてから storage へ 1 回で渡す（storage に 1 か所ずつ入れると、そのたびに編集の処理が走る）
        let drawn = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.link, in: whole) { value, range, _ in
            if value != nil { drawn.addAttributes(Self.linkDrawing, range: range) }
        }
        storage.setAttributedString(drawn)
        #endif
        return true
    }

    /// `width` で折り返して並べた枠（幅は 1 から `unlimitedWidth` に収める）
    func fit(width: CGFloat) -> CGSize {
        let width = min(max(width, 1), Self.unlimitedWidth)
        let size = CGSize(width: width, height: .greatestFiniteMagnitude)
        if container.size != size { container.size = size }
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    /// 折り返さずに並べた幅と高さ。並べ方は折り返さないまま残る（左寄せの文はそのまま描ける）
    func fitUnwrapped() -> CGSize {
        let height = fit(width: Self.unlimitedWidth).height
        // 入れ物の幅を変えた後の usedRect(for:) は、入れ物の幅いっぱいを返す。行ごとの使った幅で測る（右寄せ・中寄せの行は右の端でなく幅）
        var widest: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, used, _, _, _ in
            widest = max(widest, used.width)
        }
        return CGSize(width: ceil(widest), height: height)
    }

    /// `rect`（並べ方の座標）にかかる字と地を、view の `origin` に描く。`selection` は地と字の間に塗る（行内のコードの地に隠れない）
    func draw(_ rect: CGRect, at origin: CGPoint, selection: (range: NSRange, color: PlatformColor)? = nil) {
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        layout.drawBackground(forGlyphRange: glyphs, at: origin)
        if let selection { drawSelection(selection.range, color: selection.color, at: origin) }
        layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    /// `point` に近い字の間の位置（上より上は先頭、下より下は末尾）
    func characterIndex(at point: CGPoint) -> Int {
        if point.y < 0 { return 0 }
        if point.y >= layout.usedRect(for: container).maxY { return storage.length }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph) + (fraction > 0.5 ? 1 : 0)
        return min(index, storage.length)
    }

    #if os(macOS)
    /// `index` の字を含む語（二度押し）
    func wordRange(at index: Int) -> NSRange {
        guard storage.length > 0 else { return NSRange(location: 0, length: 0) }
        return storage.doubleClick(at: min(index, storage.length - 1))
    }
    #endif

    /// 選んだ範囲の地
    private func drawSelection(_ range: NSRange, color: PlatformColor, at origin: CGPoint) {
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        color.setFill()
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in
            rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

    func link(at point: CGPoint) -> URL? {
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        guard glyph < layout.numberOfGlyphs, layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        let value = storage.attribute(.link, at: layout.characterIndexForGlyph(at: glyph), effectiveRange: nil)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    /// リンクの字の枠（カーソルを指にする所）
    func linkRects() -> [CGRect] {
        var rects: [CGRect] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                rects.append(rect)
            }
        }
        return rects
    }

    #if os(macOS)
    /// 選ぶための NSTextView を、同じ並べ方に付けて作る。付けた後はそちらが描き、選択・コピー・リンク・カーソルを受け持つ
    func selectionView(frame: CGRect, open: @escaping (URL) -> Void) -> ChatSelectionTextView {
        let view = ChatSelectionTextView(frame: frame, textContainer: container)
        view.open = open
        return view
    }
    #endif
}

/// 行内のコード（`ChatAttributed.inlineCode` の範囲）の後ろに、字から少しはみ出す角丸の地を描く（`InlineCode`）。
/// `.backgroundColor` の地は行の高さいっぱいの角の無い四角になる。選ぶための NSTextView も同じ並べ方で描くので、選んでいる間も地が残る
final class ChatLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        if let storage = textStorage, let container = textContainers.first {
            storage.enumerateAttribute(ChatAttributed.diffLine, in: characters) { value, range, _ in
                guard let color = value as? PlatformColor else { return }
                color.setFill()
                self.enumerateLineFragments(forGlyphRange: self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { fragment, _, _, _, _ in
                    fragment.offsetBy(dx: origin.x, dy: origin.y).fill()
                }
            }
            storage.enumerateAttribute(ChatAttributed.inlineCode, in: characters) { value, range, _ in
                guard value != nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont else { return }
                drawCodeFill(characters: range, font: font, container: container, origin: origin)
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// 字の高さ（ascender から descender）の枠を行ごとに取り、`MarkdownMetrics.inlineCodeInset` だけ広げて塗る
    private func drawCodeFill(characters: NSRange, font: PlatformFont, container: NSTextContainer, origin: CGPoint) {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        let inset = MarkdownMetrics.inlineCodeInset
        let shift = (textStorage?.attribute(.baselineOffset, at: characters.location, effectiveRange: nil) as? CGFloat) ?? 0
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            guard part.length > 0 else { return }
            let run = self.boundingRect(forGlyphRange: part, in: container)
            let baseline = fragment.minY + self.location(forGlyphAt: part.location).y - shift
            let rect = CGRect(x: run.minX, y: baseline - font.ascender, width: run.width, height: font.ascender - font.descender)
                .insetBy(dx: -inset.width, dy: -inset.height)
                .offsetBy(dx: origin.x, dy: origin.y)
            ChatPalette.Platform.fill.setFill()
            #if os(macOS)
            NSBezierPath(roundedRect: rect, xRadius: Radius.chip, yRadius: Radius.chip).fill()
            #else
            UIBezierPath(roundedRect: rect, cornerRadius: Radius.chip).fill()
            #endif
        }
    }
}

#if os(macOS)
/// 選んでコピーできる、編集しない文。TextKit 1 で並べて自分で描き、幅を渡すと折り返した高さを返す（`fit(width:)`）。リンクは `openLink` に渡す。
/// 会話の一覧（`ChatListView`）の中では、選択は一覧が持ち、文と行をまたいで選べる。この文にかかる範囲（`selectedRange`）の地を自分で描く。
/// 右クリックは近い親のメニュー（`ChatMenuProviding`）を出し、無ければ文のメニュー（コピー・調べる）。
/// NSTextView は、押して選び始めたときと文のメニューを出すときだけ、同じ並べ方に付ける（`ChatSelectionTextView`）。NSTextView は作って編集しない形にするときと
/// 文を入れるときに、フォーカスのある入力欄の入力メソッドと同期を取る。行を組むたびに作っていたら、日本語入力の IMK の答えを待つ入れ子のループの中で
/// SwiftUI の更新が回り、表の升目ごとに作る行で主スレッドが止まった
final class ChatTextView: PlatformView {
    var openLink: ((URL) -> Void)?
    private let text = ChatTextLayout()
    private var selection: ChatSelectionTextView?
    /// 押したリンク（離したときに同じリンクの上なら開く）
    private var pressedLink: URL?
    /// 一覧が選んでいる、この文にかかる範囲
    var selectedRange: NSRange? {
        didSet { if selectedRange != oldValue { needsDisplay = true } }
    }
    /// 選択の地を強い色で描く（一覧がキーの窓の first responder のとき）
    var selectionEmphasized = true {
        didSet { if selectionEmphasized != oldValue, selectedRange != nil { needsDisplay = true } }
    }

    /// SwiftUI の Text のリンクと同じく、下線を引かずにシステムの強調の色にする
    static let linkAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: ChatPalette.Platform.controlAccent, .cursor: NSCursor.pointingHand]

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var string: String { text.string }

    func set(_ string: NSAttributedString) {
        guard text.set(string) else { return }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// `width` で折り返して並べ、枠をその幅と高さにする
    @discardableResult
    func fit(width: CGFloat) -> CGFloat {
        setFrameSize(text.fit(width: width))
        selection?.frame = bounds
        return bounds.height
    }

    /// 折り返さないときの幅（横に送るコード・吹き出しの幅を中身に合わせる）
    func idealWidth() -> CGFloat { text.fitUnwrapped().width }

    override func draw(_ dirtyRect: CGRect) {
        guard selection == nil else { return }
        let color: PlatformColor = selectionEmphasized ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
        text.draw(dirtyRect, at: .zero, selection: selectedRange.map { ($0, color) })
    }

    /// view の座標の `point` に近い字の間の位置
    func characterIndex(at point: CGPoint) -> Int { text.characterIndex(at: point) }

    override func resetCursorRects() {
        guard selection == nil else { return }
        addCursorRect(bounds, cursor: .iBeam)
        for rect in text.linkRects() { addCursorRect(rect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if let link = link(at: event) {
            pressedLink = link
            return
        }
        if let list = enclosingChatList {
            list.beginSelection(with: event)
            return
        }
        let view = selectionView()
        window?.makeFirstResponder(view)
        view.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedLink = nil }
        guard let pressedLink, link(at: event) == pressedLink else { return }
        open(pressedLink)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // 一覧の中では選ぶための NSTextView を付けない（付けると、この文が一覧の選択から外れる）
        if let list = enclosingChatList { return list.menu(adding: ChatMenu.nearest(from: self)) }
        return ChatMenu.nearest(from: self) ?? selectionView().menu(for: event)
    }


    func open(_ url: URL) {
        if let openLink { openLink(url) } else { NSWorkspace.shared.open(url) }
    }

    private func link(at event: NSEvent) -> URL? {
        text.link(at: convert(event.locationInWindow, from: nil))
    }

    private func selectionView() -> ChatSelectionTextView {
        if let selection { return selection }
        let view = text.selectionView(frame: bounds) { [weak self] in self?.open($0) }
        addSubview(view)
        selection = view
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        return view
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text.spokenString }
}

extension ChatTextView: ChatSelectableText {
    var selectionPieces: [ChatSelectionPiece] { [ChatSelectionPiece(frame: bounds, string: text.string, sameLine: false)] }
    func characterIndex(piece: Int, at point: CGPoint) -> Int { text.characterIndex(at: point) }
    func wordRange(piece: Int, at index: Int) -> NSRange { text.wordRange(at: index) }

    func showSelection(_ ranges: [NSRange?], emphasized: Bool) {
        selectedRange = ranges.first ?? nil
        selectionEmphasized = emphasized
    }
}

/// 会話の一覧（`ChatListView`）の選択が扱う文を持つ部品。文は片（`ChatSelectionPiece`）に分けて読む順に並べる（`ChatTextView` は 1 片、表の格子は升目ごとに 1 片）
@MainActor
protocol ChatSelectableText: PlatformView {
    var selectionPieces: [ChatSelectionPiece] { get }
    /// 片 `piece` の、view の座標の `point` に近い字の間の位置
    func characterIndex(piece: Int, at point: CGPoint) -> Int
    /// 片 `piece` の `index` の字を含む語（二度押し）
    func wordRange(piece: Int, at index: Int) -> NSRange
    /// 片ごとにかかる範囲（`selectionPieces` と同じ並び）と、地を強い色で描くか
    func showSelection(_ ranges: [NSRange?], emphasized: Bool)
}

struct ChatSelectionPiece {
    /// view の座標の枠
    let frame: CGRect
    let string: String
    /// 前の片と同じ行にある（表の同じ行の升目）。写すときはタブでつなぐ
    let sameLine: Bool
}

extension PlatformView {
    /// この部品を置いている会話の一覧
    var enclosingChatList: ChatListView? {
        var current = superview
        while let view = current {
            if let list = view as? ChatListView { return list }
            current = view.superview
        }
        return nil
    }
}

/// 押して選び始めたときだけ文に付ける、編集しない NSTextView（`ChatTextLayout.selectionView`）
final class ChatSelectionTextView: NSTextView {
    /// リンクを開く（付けた先の開き方）
    var open: ((URL) -> Void)?

    override init(frame frameRect: CGRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = ChatTextView.linkAttributes
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, let open { open(url) } else { super.clicked(onLink: link, at: charIndex) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ChatMenu.nearest(from: self) ?? super.menu(for: event)
    }
}

#else
/// 編集しない文。TextKit 1 で並べて自分で描き、幅を渡すと折り返した高さを返す（`fit(width:)`）。リンクは押して離すと `openLink` に渡す。
/// 範囲を選ぶ機能は無く、長押しは一覧のメニュー（近い親のメニュー、無ければ文の［コピー］）を出す（`ChatCollectionCell`）
final class ChatTextView: ChatFlippedView {
    var openLink: ((URL) -> Void)?
    private let text = ChatTextLayout()
    /// 押したリンク（離したときに同じリンクの上なら開く）
    private var pressedLink: URL?

    init() {
        super.init(frame: .zero)
        setChatAccessibility(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var string: String { text.string }

    func set(_ string: NSAttributedString) {
        guard text.set(string) else { return }
        needsDisplay = true
    }

    // 読み上げの文は求められたときに作る（文を入れるたびに作ると、送りの間に組む行ごとに印を探す）
    override var accessibilityLabel: String? {
        get { text.spokenString }
        set {}
    }

    /// `width` で折り返して並べ、枠をその幅と高さにする
    @discardableResult
    func fit(width: CGFloat) -> CGFloat {
        setFrameSize(text.fit(width: width))
        return bounds.height
    }

    /// 折り返さないときの幅（横に送るコード・吹き出しの幅を中身に合わせる）
    func idealWidth() -> CGFloat { text.fitUnwrapped().width }

    override func draw(_ dirtyRect: CGRect) {
        text.draw(dirtyRect, at: .zero)
    }

    func open(_ url: URL) {
        if let openLink { openLink(url) } else { ChatSystem.open(url) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressedLink = touches.first.flatMap { text.link(at: $0.location(in: self)) }
        if pressedLink == nil { super.touchesBegan(touches, with: event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { pressedLink = nil }
        guard let pressedLink else { return super.touchesEnded(touches, with: event) }
        if touches.first.flatMap({ text.link(at: $0.location(in: self)) }) == pressedLink { open(pressedLink) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pressed = pressedLink
        pressedLink = nil
        if pressed == nil { super.touchesCancelled(touches, with: event) }
    }
}
#endif

/// 会話の文を NSAttributedString に組む。行の高さは段落の形で固定し（`ChatFonts.line`）、リンクの有無で変えない
@MainActor
enum ChatAttributed {
    static let highlight = PlatformColor.systemYellow.withAlphaComponent(0.45)
    /// 行内のコードの印。`ChatLayoutManager` が角丸の地を描く
    nonisolated static let inlineCode = NSAttributedString.Key("taskboard.inlineCode")
    /// 文の中の印（チェックの印）を読み上げるときの語
    nonisolated static let spoken = NSAttributedString.Key("taskboard.spoken")

    static func spokenString(_ text: NSAttributedString) -> String {
        let result = NSMutableString(string: text.string)
        text.enumerateAttribute(spoken, in: NSRange(location: 0, length: text.length), options: .reverse) { value, range, _ in
            if let value = value as? String { result.replaceCharacters(in: range, with: value) }
        }
        return result as String
    }

    /// 段落の形。`line` が nil なら字の高さのまま
    static func paragraph(
        line: CGFloat?, before: CGFloat = 0, indent: CGFloat = 0, headIndent: CGFloat? = nil, tabs: [NSTextTab] = [],
        alignment: NSTextAlignment = .natural, lineBreak: NSLineBreakMode = .byWordWrapping
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if let line {
            style.minimumLineHeight = line
            style.maximumLineHeight = line
        }
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = indent
        style.headIndent = headIndent ?? indent
        style.tabStops = tabs
        style.alignment = alignment
        style.lineBreakMode = lineBreak
        return style
    }

    /// 字の高さを行の高さの真ん中に置く上げ幅（段落の形で行を高くすると、字は行の下に寄る）
    static func baselineOffset(font: PlatformFont, line: CGFloat?) -> CGFloat {
        guard let line else { return 0 }
        let natural = font.ascender - font.descender + font.leading
        return max(0, (line - natural) / 2)
    }

    /// 素の文
    static func plain(_ text: String, font: PlatformFont, color: PlatformColor, line: CGFloat?, query: String?, paragraph: NSParagraphStyle? = nil) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph ?? Self.paragraph(line: line),
            .baselineOffset: baselineOffset(font: font, line: line),
        ])
        mark(result, query)
        return result
    }

    /// 1 行の札の文。段落の形を付けない（札の切り詰めに任せる）。色は札が当てる
    static func label(_ text: String, font: PlatformFont, query: String?) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font])
        mark(result, query)
        return result
    }

    /// Markdown の行内（`MarkdownBlocks` の AttributedString）。強調・斜体・行内のコード・取り消し線・リンク。チャットの行内のコードは墨 5% の角丸の地とコードの色
    static func inline(_ text: AttributedString, font: PlatformFont, color: PlatformColor, line: CGFloat?, query: String?) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let offset = baselineOffset(font: font, line: line)
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .baselineOffset: offset]
            var runFont = font
            if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
            var traits = runFont.fontDescriptor.symbolicTraits
            #if os(macOS)
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if traits != runFont.fontDescriptor.symbolicTraits {
                runFont = PlatformFont(descriptor: runFont.fontDescriptor.withSymbolicTraits(traits), size: runFont.pointSize) ?? runFont
            }
            #else
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if traits != runFont.fontDescriptor.symbolicTraits, let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits) {
                runFont = PlatformFont(descriptor: descriptor, size: runFont.pointSize)
            }
            #endif
            attributes[.font] = runFont
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
            } else if intent.contains(.code) {
                attributes[Self.inlineCode] = true
                attributes[.foregroundColor] = ChatPalette.Platform.inlineCode
            }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        mark(result, query)
        return result
    }

    /// diff の塊の足した行・消した行の地の色。`ChatLayoutManager` が行の幅いっぱいに描く
    nonisolated static let diffLine = NSAttributedString.Key("taskboard.diffLine")

    /// diff の塊の行に色を付ける（`DiffCode`）。足した行と消した行に地と行の頭の + − の色、hunk と見出しの行に薄い色
    static func markDiff(_ text: NSMutableAttributedString) {
        var location = 0
        let string = text.string as NSString
        for (line, kind) in zip(text.string.split(separator: "\n", omittingEmptySubsequences: false), DiffCode.kinds(text.string)) {
            let length = (String(line) as NSString).length
            let range = NSRange(location: location, length: length)
            switch kind {
            case .added, .removed:
                let added = kind == .added
                let full = NSRange(location: location, length: min(length + 1, string.length - location))
                text.addAttribute(diffLine, value: PlatformColor(added ? DiffPalette.addedBackground : DiffPalette.removedBackground), range: full)
                text.addAttribute(.foregroundColor, value: PlatformColor(added ? DiffPalette.added : DiffPalette.removed), range: NSRange(location: location, length: 1))
            case .hunk, .header:
                text.addAttribute(.foregroundColor, value: ChatPalette.Platform.secondaryLabel, range: range)
            case .context: break
            }
            location += length + 1
        }
    }

    /// 検索の一致箇所に地の色を付ける（大文字小文字は区別しない）
    static func mark(_ text: NSMutableAttributedString, _ query: String?) {
        guard let query, !query.isEmpty else { return }
        let string = text.string as NSString
        var range = NSRange(location: 0, length: string.length)
        while range.length > 0 {
            let found = string.range(of: query, options: [.caseInsensitive], range: range)
            guard found.location != NSNotFound else { return }
            text.addAttribute(.backgroundColor, value: highlight, range: found)
            range = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        }
    }

    /// 段落の形を範囲の全部に当てる
    static func setParagraph(_ text: NSMutableAttributedString, _ style: NSParagraphStyle, range: NSRange? = nil) {
        text.addAttribute(.paragraphStyle, value: style, range: range ?? NSRange(location: 0, length: text.length))
    }

    /// 文の中に置く SF Symbols の画像（リストのチェックの印）。色は描くときの外観で解く
    static func symbol(_ name: String, spoken: String, font: PlatformFont, color: PlatformColor, line: CGFloat?) -> NSAttributedString {
        #if os(macOS)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = ChatSymbolAttachmentCell(name: name, font: font, color: color)
        #else
        // 画像の下の端を字の下がり（descender）に合わせる。色は画像に付け、外観が変わると UIKit が解き直す
        let image = ChatSymbol.image(name, size: font.pointSize)?.withTintColor(color, renderingMode: .alwaysOriginal)
        let attachment = NSTextAttachment(image: image ?? UIImage())
        let size = image.map { CGSize(width: ceil($0.size.width), height: ceil($0.size.height)) } ?? .zero
        attachment.bounds = CGRect(origin: CGPoint(x: 0, y: font.descender), size: size)
        #endif
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes([.font: font, .baselineOffset: baselineOffset(font: font, line: line), Self.spoken: spoken], range: NSRange(location: 0, length: result.length))
        return result
    }
}

#if os(macOS)
/// 文の中の SF Symbols の画像。字の基準線に揃えて置く
final class ChatSymbolAttachmentCell: NSTextAttachmentCell {
    private let symbol: PlatformImage?
    private let color: PlatformColor
    private let symbolFont: PlatformFont

    init(name: String, font: PlatformFont, color: PlatformColor) {
        symbol = ChatSymbol.image(name, size: font.pointSize)
        self.color = color
        symbolFont = font
        super.init()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override nonisolated func cellSize() -> CGSize {
        MainActor.assumeIsolated { symbol.map { CGSize(width: ceil($0.size.width), height: ceil($0.size.height)) } ?? .zero }
    }

    override nonisolated func cellBaselineOffset() -> CGPoint {
        // 画像の下の端を字の下がり（descender）に合わせる
        MainActor.assumeIsolated { CGPoint(x: 0, y: symbolFont.descender) }
    }

    override nonisolated func draw(withFrame cellFrame: CGRect, in controlView: PlatformView?) {
        MainActor.assumeIsolated {
            guard let symbol else { return }
            ChatDrawing.symbol(symbol, in: cellFrame, tint: color)
        }
    }
}
#endif
