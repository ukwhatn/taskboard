import SwiftUI
import TaskboardKit

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// `MultilineTextField` の iPhone・iPad の中身。UITextView（TextKit 2）で、枠（`roundedBorder`）は外の `MultilineTextBorder` が描く
struct MultilineTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    let label: String
    let font: UIFont
    let lines: ClosedRange<Int>
    let bordered: Bool
    let alignment: NSTextAlignment
    let isEnabled: Bool
    let literal: Bool
    let commandKey: ((KeyEquivalent, EventModifiers) -> Bool)?
    let longPaste: ((String) -> Void)?
    let imagePaste: (@MainActor @Sendable ([Data]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MultilineUITextView {
        let textView = MultilineUITextView(usingTextLayoutManager: true)
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = false
        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.widthChanged = { [weak coordinator] in coordinator?.widthChanged($0) }
        textView.keyPressed = { [weak coordinator] in coordinator?.keyPressed($0) ?? false }
        coordinator.textView = textView
        coordinator.parent = self
        configure(textView, coordinator: coordinator)
        return textView
    }

    func updateUIView(_ textView: MultilineUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        configure(textView, coordinator: coordinator)
        guard textView.markedTextRange == nil else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        if coordinator.textSync.receive(text), textView.text != text {
            let kept = textView.selectedRange.clamped(toLength: (text as NSString).length)
            textView.text = text
            textView.selectedRange = kept
            coordinator.textChanged()
        }
        if coordinator.selectionSync.receive(selection), let range = selection?.range(in: text), range != textView.selectedRange {
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
        }
    }

    /// 文字・寄せ・余白・使えるか・自動の大文字と修正。変わったときだけ入れる（文字を入れ直すと全文の組み直しになる）
    private func configure(_ textView: MultilineUITextView, coordinator: Coordinator) {
        textView.longPaste = longPaste
        textView.imagePaste = imagePaste
        if textView.font != font {
            textView.font = font
            coordinator.fontChanged(font)
        }
        if textView.textAlignment != alignment { textView.textAlignment = alignment }
        if textView.isEditable != isEnabled { textView.isEditable = isEnabled }
        let color: UIColor = isEnabled ? .label : .secondaryLabel
        if textView.textColor != color { textView.textColor = color }
        let insets = Self.textInsets(bordered: bordered)
        let containerInset = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
        if textView.textContainerInset != containerInset {
            textView.textContainerInset = containerInset
            coordinator.textChanged()
        }
        let autocapitalization: UITextAutocapitalizationType = literal ? .none : .sentences
        if textView.autocapitalizationType != autocapitalization { textView.autocapitalizationType = autocapitalization }
        let autocorrection: UITextAutocorrectionType = literal ? .no : .default
        if textView.autocorrectionType != autocorrection { textView.autocorrectionType = autocorrection }
        if textView.accessibilityLabel != label { textView.accessibilityLabel = label }
    }

    /// 高さは置かれた幅で組んだもの（Mac の `MultilineTextView.sizeThatFits` と同じ。提案の幅ごとには組み直さない）
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MultilineUITextView, context: Context) -> CGSize? {
        let coordinator = context.coordinator
        let insets = Self.textInsets(bordered: bordered)
        if let width = proposal.width, width.isFinite, width > 0 { coordinator.setInitialWidth(width - insets.leading - insets.trailing) }
        return CGSize(width: proposal.width.map { $0.isFinite ? $0 : 0 } ?? 0, height: coordinator.height(lines: lines) + insets.top + insets.bottom)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MultilineTextView?
        weak var textView: MultilineUITextView?
        /// updateUIView で文と選択を入れている間。そこで起きた変化の知らせを Binding に書き戻さない
        var updating = false
        var textSync = MultilineFieldSync<String>()
        var selectionSync = MultilineFieldSync<TextSelection?>()
        /// 文を組んでいる幅（枠の余白を除く）
        private var width: CGFloat = 0
        /// 先頭から上の行の数までの行を組んだ高さ
        private var contentHeight: CGFloat?
        private var lineHeight: CGFloat = 0

        func fontChanged(_ font: UIFont) {
            lineHeight = font.lineHeight
            contentHeight = nil
            textView?.invalidateIntrinsicContentSize()
        }

        /// まだ置かれていない間だけ、最初の提案の幅で組む
        func setInitialWidth(_ width: CGFloat) {
            guard self.width == 0, width > 0, let textView else { return }
            self.width = width
            textView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            contentHeight = nil
        }

        func widthChanged(_ width: CGFloat) {
            guard width != self.width, width > 0, let parent else { return }
            let before = height(lines: parent.lines)
            self.width = width
            contentHeight = nil
            if height(lines: parent.lines) != before { textView?.invalidateIntrinsicContentSize() }
        }

        /// 文の高さを行の数の範囲に収めたもの。上の行の数より下は組まない。上は組んだ行で数える
        /// （和文は代わりの字で組まれて欄の字の 1 行より高く、字の高さの何倍かで切ると最後の行が欠ける。縦に伸びる TextField も組んだ行で数える）
        func height(lines: ClosedRange<Int>) -> CGFloat {
            if contentHeight == nil, let layout = textView?.textLayoutManager, width > 0 {
                var count = 0
                var bottom: CGFloat = 0
                layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                    for line in fragment.textLineFragments {
                        count += 1
                        bottom = fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY
                        if count >= lines.upperBound { return false }
                    }
                    return true
                }
                contentHeight = bottom
            }
            return max(contentHeight ?? 0, lineHeight * CGFloat(lines.lowerBound)).rounded()
        }

        /// 文が変わったら高さを測り直し、変わっていれば SwiftUI に大きさを聞き直させる
        func textChanged() {
            guard let parent else { return }
            let before = height(lines: parent.lines)
            contentHeight = nil
            if height(lines: parent.lines) != before { textView?.invalidateIntrinsicContentSize() }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !updating, let parent else { return }
            // Mac の textDidChange と同じく、NSString のままの文を Swift の UTF-8 の置き場に移してから渡す
            var text = textView.text ?? ""
            text.makeContiguousUTF8()
            let selection = TextSelection(textView.selectedRange, in: text)
            textSync.wrote(text)
            selectionSync.wrote(selection)
            parent.text = text
            parent.selection = selection
            textChanged()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating, let parent else { return }
            let selection = TextSelection(textView.selectedRange, in: parent.text)
            selectionSync.wrote(selection)
            if selection != parent.selection { parent.selection = selection }
        }

        /// ハードウェアキーボードの ↑↓・↩・Tab・Esc を `/` の候補に渡す（縦に伸びる TextField の `onKeyPress` と同じく、ソフトウェアキーボードの ↩ は渡さない）。使ったら true
        func keyPressed(_ key: UIKey) -> Bool {
            guard let commandKey = parent?.commandKey else { return false }
            let equivalent: KeyEquivalent? = switch key.keyCode {
            case .keyboardUpArrow: .upArrow
            case .keyboardDownArrow: .downArrow
            case .keyboardReturnOrEnter: .return
            case .keyboardTab: .tab
            case .keyboardEscape: .escape
            default: nil
            }
            guard let equivalent else { return false }
            return commandKey(equivalent, EventModifiers(key.modifierFlags))
        }
    }
}

/// 長い文の入力欄の UITextView。置かれた幅が変わったら知らせ、ハードウェアキーボードのキーを `keyPressed` に先に渡す
final class MultilineUITextView: UITextView {
    var widthChanged: ((CGFloat) -> Void)?
    var keyPressed: ((UIKey) -> Bool)?
    /// 長い貼り付けの受け口（`MultilineTextField.longPaste`）
    var longPaste: ((String) -> Void)?
    /// クリップボードの画像の受け口（`MultilineTextField.imagePaste`）。あれば長押しの［ペースト］を画像でも出す
    var imagePaste: (@MainActor @Sendable ([Data]) -> Void)?
    private var laidOutWidth: CGFloat = 0
    /// `keyPressed` が使ったキー。離したときも UITextView に渡さない
    private var handled: Set<UIPress> = []

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width != laidOutWidth else { return }
        laidOutWidth = bounds.width
        widthChanged?(bounds.width - textContainerInset.left - textContainerInset.right)
    }

    /// 長い文は入力欄に入れない（入れると全文を組み版する）
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), imagePaste != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// 画像があれば文より先に画像として受ける（Safari の画像は URL の文も一緒に載る）。編集メニューからの貼り付けはクリップボードの許可を聞かない
    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if let imagePaste, board.hasImages {
            let identifier = UTType.image.identifier
            for provider in board.itemProviders where provider.hasItemConformingToTypeIdentifier(identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in imagePaste([data]) }
                }
            }
            return
        }
        if let longPaste, let text = UIPasteboard.general.string, text.utf16.count >= ChatAttachment.pastedTextThreshold {
            longPaste(text)
            return
        }
        super.paste(sender)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // 変換中のキーは入力メソッドに任せる
        let used = markedTextRange != nil ? [] : presses.filter { $0.key.map { keyPressed?($0) == true } ?? false }
        handled.formUnion(used)
        let rest = presses.subtracting(used)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        finish(presses) { super.pressesEnded($0, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        finish(presses) { super.pressesCancelled($0, with: event) }
    }

    private func finish(_ presses: Set<UIPress>, passOn: (Set<UIPress>) -> Void) {
        let rest = presses.subtracting(handled)
        handled.subtract(presses)
        if !rest.isEmpty { passOn(rest) }
    }
}

/// iPhone・iPad の `roundedBorder` の枠（TextField の `.roundedBorder` と同じ形）
struct MultilineTextBorder: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(uiColor: .systemBackground))
            .strokeBorder(Color(uiColor: .systemGray4), lineWidth: 1 / displayScale)
    }
}

extension EventModifiers {
    init(_ flags: UIKeyModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.alternate) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.control) { insert(.control) }
    }
}

extension UIContentSizeCategory {
    init(_ size: DynamicTypeSize) {
        self = switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
#endif
