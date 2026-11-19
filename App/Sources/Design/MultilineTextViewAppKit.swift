import SwiftUI
import TaskboardKit

#if os(macOS)
import AppKit

/// `MultilineTextField` の Mac の中身。NSTextView（TextKit 2）を NSScrollView に入れ、枠は下に敷いた NSTextField の角丸の枠で描く
struct MultilineTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    let label: String
    let font: NSFont
    let lines: ClosedRange<Int>
    let bordered: Bool
    let alignment: NSTextAlignment
    let isEnabled: Bool
    let newlineOnShiftReturn: Bool
    let submit: (() -> Void)?
    let commandKey: ((KeyEquivalent, EventModifiers) -> Bool)?
    let passesFileDrops: Bool
    let longPaste: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MultilineScrollView {
        let textView = MultilineNSTextView(usingTextLayoutManager: true)
        textView.passesFileDrops = passesFileDrops
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator

        let scrollView = MultilineScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        scrollView.widthChanged = { [weak coordinator = context.coordinator] in coordinator?.widthChanged($0) }
        textView.controlKey = { [weak coordinator = context.coordinator] in coordinator?.controlKey($0) ?? false }
        textView.commandReturn = { [weak coordinator = context.coordinator] in coordinator?.commandReturn($0) ?? false }
        configure(scrollView, textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: MultilineScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        configure(scrollView, textView, coordinator: coordinator)
        guard !textView.hasMarkedText() else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        if coordinator.textSync.receive(text), textView.string != text {
            let kept = textView.selectedRange().clamped(toLength: (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(kept)
            coordinator.textChanged()
        }
        if coordinator.selectionSync.receive(selection), let range = selection?.range(in: text), range != textView.selectedRange() {
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
    }

    /// 文字・寄せ・枠・使えるか。変わったときだけ入れる（文字を入れ直すと全文の組み直しになる）
    private func configure(_ scrollView: MultilineScrollView, _ textView: MultilineNSTextView, coordinator: Coordinator) {
        textView.longPaste = longPaste
        if textView.font != font {
            textView.font = font
            textView.typingAttributes[.font] = font
            coordinator.fontChanged(font)
        }
        if textView.alignment != alignment { textView.alignment = alignment }
        if textView.isEditable != isEnabled {
            textView.isEditable = isEnabled
            textView.isSelectable = isEnabled
        }
        let color: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
        if textView.textColor != color { textView.textColor = color }
        if scrollView.bordered != bordered {
            scrollView.bordered = bordered
            let insets = Self.textInsets(bordered: bordered)
            scrollView.contentInsets = NSEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
            coordinator.insetsChanged()
        }
        scrollView.isEnabled = isEnabled
        if textView.accessibilityLabel() != label { textView.setAccessibilityLabel(label) }
    }

    /// 高さは置かれた枠の幅で組んだもの。提案の幅ごとには組み直さない（SwiftUI は 1 回の配置で少しずつ違う幅を何度も聞き、そのたびに全文を組み直すことになる）。
    /// 枠の幅が変わったら組み直し、高さが変われば聞き直させる（`MultilineScrollView.widthChanged`）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MultilineScrollView, context: Context) -> CGSize? {
        let coordinator = context.coordinator
        let insets = Self.textInsets(bordered: bordered)
        if let width = proposal.width, width.isFinite, width > 0 { coordinator.setInitialWidth(width - insets.leading - insets.trailing) }
        // 理想の幅（提案の幅が nil か無限）は 0。TextField のように一番長い行の幅を返すと、打鍵のたびに文を測り直すことになる（置き場が幅を決める）
        return CGSize(width: proposal.width.map { $0.isFinite ? $0 : 0 } ?? 0, height: coordinator.height(lines: lines) + insets.top + insets.bottom)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextView?
        weak var textView: MultilineNSTextView?
        weak var scrollView: NSScrollView?
        /// updateNSView で文と選択を入れている間。そこで起きた変化の知らせを Binding に書き戻さない
        var updating = false
        var textSync = MultilineFieldSync<String>()
        var selectionSync = MultilineFieldSync<TextSelection?>()
        /// 文を組んでいる幅（枠の余白を除く）
        private var width: CGFloat = 0
        private var contentHeight: CGFloat?
        private var lineHeight: CGFloat = 0

        func fontChanged(_ font: NSFont) {
            lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            contentHeight = nil
            scrollView?.invalidateIntrinsicContentSize()
        }

        func insetsChanged() {
            guard let scrollView = scrollView as? MultilineScrollView else { return }
            widthChanged(scrollView.contentSize.width - scrollView.contentInsets.left - scrollView.contentInsets.right)
        }

        /// まだ置かれていない間だけ、最初の提案の幅で組む
        func setInitialWidth(_ width: CGFloat) {
            guard self.width == 0, width > 0, let textView else { return }
            self.width = width
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            contentHeight = nil
        }

        func widthChanged(_ width: CGFloat) {
            guard width != self.width, width > 0, let parent else { return }
            let before = height(lines: parent.lines)
            self.width = width
            contentHeight = nil
            if height(lines: parent.lines) != before { scrollView?.invalidateIntrinsicContentSize() }
        }

        /// 文の高さを行の数の範囲に収めたもの。上の行の数より下は組まない（長い文でも組むのは先頭の段落から上限までの所だけ）
        func height(lines: ClosedRange<Int>) -> CGFloat {
            let low = lineHeight * CGFloat(lines.lowerBound), high = lineHeight * CGFloat(lines.upperBound)
            if contentHeight == nil, let layout = textView?.textLayoutManager, width > 0 {
                layout.ensureLayout(for: CGRect(x: 0, y: 0, width: width, height: high + lineHeight))
                contentHeight = layout.usageBoundsForTextContainer.height
            }
            return min(max(contentHeight ?? low, low), high).rounded()
        }

        /// 文が変わったら高さを測り直し、変わっていれば SwiftUI に大きさを聞き直させる
        func textChanged() {
            guard let parent else { return }
            let before = height(lines: parent.lines)
            contentHeight = nil
            if height(lines: parent.lines) != before { scrollView?.invalidateIntrinsicContentSize() }
        }

        func textDidChange(_ notification: Notification) {
            guard !updating, let textView, let parent else { return }
            // NSTextView の string は NSString のままで、== が Swift の文の千倍ほど遅い。SwiftUI は打鍵のたびに Binding の値を View の数だけ比べるので、
            // 長い文では Swift の UTF-8 の置き場に移してから渡す（設定の列の表の 20,000 字で、打鍵 1 回が 276 ms から 32 ms になった）
            var text = textView.string
            text.makeContiguousUTF8()
            let selection = TextSelection(textView.selectedRange(), in: text)
            textSync.wrote(text)
            selectionSync.wrote(selection)
            parent.text = text
            parent.selection = selection
            textChanged()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let textView, let parent else { return }
            let selection = TextSelection(textView.selectedRange(), in: parent.text)
            selectionSync.wrote(selection)
            if selection != parent.selection { parent.selection = selection }
        }

        /// ⌃ と 1 字のキー。変換中は入力メソッドのもの
        func controlKey(_ event: NSEvent) -> Bool {
            guard let textView, !textView.hasMarkedText(), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
                let characters = event.charactersIgnoringModifiers, characters.count == 1, let character = characters.first
            else { return false }
            return parent?.commandKey?(KeyEquivalent(character), .control) == true
        }

        /// ⌘↩・⌥⌘↩。変換中は入力メソッドのもの
        func commandReturn(_ event: NSEvent) -> Bool {
            guard let textView, !textView.hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 else { return false }
            let modifiers = EventModifiers(event.modifierFlags)
            guard modifiers.contains(.command), modifiers.isDisjoint(with: [.shift, .control]) else { return false }
            return parent?.commandKey?(.return, modifiers) == true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let parent else { return false }
            let modifiers = EventModifiers((textView as? MultilineNSTextView)?.keyModifiers ?? NSApp.currentEvent?.modifierFlags ?? [])
            let commandKey = { (key: KeyEquivalent) in parent.commandKey?(key, modifiers) == true }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // 変換中の ↩ は入力メソッドが確定に使うのでふつうは来ない。来たら確定だけして送らない
                if textView.hasMarkedText() {
                    textView.unmarkText()
                } else if modifiers.contains(.option) || (parent.newlineOnShiftReturn && modifiers.contains(.shift)) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if !commandKey(.return), let submit = parent.submit {
                    #if DEBUG
                    DebugCounters.textSubmits += 1
                    #endif
                    submit()
                }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥↩。TextField と同じく、どの欄でも改行
                return false
            case #selector(NSResponder.moveUp(_:)):
                // 変換中の ↑↓ は入力メソッドの候補の選択に使う
                return !textView.hasMarkedText() && commandKey(.upArrow)
            case #selector(NSResponder.moveDown(_:)):
                return !textView.hasMarkedText() && commandKey(.downArrow)
            case #selector(NSResponder.insertTab(_:)):
                if !commandKey(.tab) { textView.window?.selectNextKeyView(nil) }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // NSTextView の Esc は補完の一覧を出す。候補に使わなければ、TextField と同じく外の Esc（シートやタスクを閉じる）に渡す
                if !commandKey(.escape) { textView.nextResponder?.tryToPerform(selector, with: nil) }
                return true
            default:
                return false
            }
        }
    }
}

/// 文の欄の枠。置かれた幅が変わったら知らせる。`bordered` なら TextField（`.roundedBorder`）と同じ角丸の枠を、フォーカスを受けない NSTextField を下に敷いて描き、
/// 中の文にフォーカスがある間はその枠の形でフォーカスリングを出す（NSTextFieldCell を NSTextField の外で描くと、地が塗られず線も薄くなる）
final class MultilineScrollView: NSScrollView {
    var widthChanged: ((CGFloat) -> Void)?
    var bordered = false {
        didSet {
            focusRingType = bordered ? .exterior : .none
            bezel.isHidden = !bordered
        }
    }
    var isEnabled = true {
        didSet { bezel.isEnabled = isEnabled }
    }
    private let bezel: NSTextField = {
        // 編集できない欄（ラベル）は地が薄く描かれるので、編集できる欄にしてフォーカスとクリックを受けさせない（`hitTest`）
        let field = NSTextField(string: "")
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.refusesFirstResponder = true
        field.isHidden = true
        field.setAccessibilityElement(false)
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(bezel, positioned: .below, relativeTo: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        let before = contentSize.width
        super.setFrameSize(newSize)
        if contentSize.width != before { widthChanged?(contentSize.width - contentInsets.left - contentInsets.right) }
    }

    override func tile() {
        super.tile()
        bezel.frame = bounds
    }

    /// 枠と文の間の余白のクリックも文の欄で受ける（TextField と同じく、余白を押してもフォーカスが入る）
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === bezel ? documentView : hit
    }

    override var focusRingMaskBounds: NSRect { bordered ? bounds : .zero }

    override func drawFocusRingMask() {
        guard bordered, let cell = bezel.cell else { return }
        cell.drawFocusRingMask(withFrame: bounds, in: self)
    }
}

/// 長い文の入力欄の NSTextView。修飾キーを `doCommandBy` に渡すため、受けたキーの修飾キーを覚える
final class MultilineNSTextView: NSTextView {
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .tiff, .png, NSPasteboard.PasteboardType("NSFilenamesPboardType")]

    /// ファイルのドロップを受けず、外（チャットと会話の入力欄のまとまり `chatInputColumn`）に回す（受けるとパスの文字が入る）
    var passesFileDrops = false
    /// 長い貼り付けの受け口（`MultilineTextField.longPaste`）
    var longPaste: ((String) -> Void)?
    /// 今受けているキーの修飾キー。↩ などの命令（`doCommandBy`）で、⇧・⌥ が付いていたかを見る
    private(set) var keyModifiers: NSEvent.ModifierFlags?
    /// ⌃ と 1 字のキーを文の欄の命令より先に受ける。使ったら true
    var controlKey: ((NSEvent) -> Bool)?
    /// ⌘↩・⌥⌘↩ を、メニューと画面のボタンの key equivalent より先に受ける。使ったら true
    var commandReturn: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // key equivalent は窓の中の view に順に配られるので、フォーカスのある欄だけが受ける
        if window?.firstResponder === self, commandReturn?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        passesFileDrops ? super.acceptableDragTypes.filter { !Self.fileTypes.contains($0) } : super.acceptableDragTypes
    }

    override func keyDown(with event: NSEvent) {
        if controlKey?(event) == true { return }
        keyModifiers = event.modifierFlags
        defer { keyModifiers = nil }
        super.keyDown(with: event)
    }

    /// 長い文は入力欄に入れない（入れると全文を組み版する）。クリップボードの文字は `takesLongPaste` が見る
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), takesLongPaste(text) { return }
        super.paste(sender)
    }

    /// 貼る文が長く受け口があれば、受け口に渡して true
    func takesLongPaste(_ text: String) -> Bool {
        guard let longPaste, text.utf16.count >= ChatAttachment.pastedTextThreshold else { return false }
        longPaste(text)
        return true
    }

    /// フォーカスが移ったら、枠のフォーカスリングを描き直させる
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { enclosingScrollView?.noteFocusRingMaskChanged() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { enclosingScrollView?.noteFocusRingMaskChanged() }
        return resigned
    }
}

extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.control) { insert(.control) }
    }
}
#endif
