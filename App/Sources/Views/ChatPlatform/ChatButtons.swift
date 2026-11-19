import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 押せる部品の共通の動き（押して離した所が中なら `action`）
class ChatPressableView: ChatFlippedView {
    var action: (() -> Void)?
    var isEnabled = true {
        didSet {
            needsDisplay = true
            #if os(iOS)
            if isEnabled { accessibilityTraits.remove(.notEnabled) } else { accessibilityTraits.insert(.notEnabled) }
            #endif
        }
    }
    private var pressed = false {
        didSet {
            #if os(iOS)
            // 押している間は薄くする（SwiftUI のボタンと同じ）
            alpha = pressed ? 0.4 : 1
            #endif
        }
    }

    #if os(macOS)
    override func mouseDown(with event: NSEvent) {
        pressed = isEnabled && action != nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        action()
        return true
    }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        setChatAccessibility(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, action != nil else { return super.touchesBegan(touches, with: event) }
        pressed = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed else { return super.touchesMoved(touches, with: event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed else { return super.touchesEnded(touches, with: event) }
        pressed = false
        guard let touch = touches.first, bounds.insetBy(dx: -Space.inline, dy: -Space.inline).contains(touch.location(in: self)) else { return }
        action?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed else { return super.touchesCancelled(touches, with: event) }
        pressed = false
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, let action else { return false }
        action()
        return true
    }
    #endif
}

/// 押せる小さなアイコン（コードの塊・発言の操作の帯）。文字は補足の色で、ホバーで本文の色と墨 5% の地（`ChatIconButton`）
final class ChatIconButtonView: ChatPressableView, ChatHoverable, ChatFitting {
    private var image: PlatformImage?
    private var hovered = false

    init(label: String, symbol: String, help: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.action = action
        set(label: label, symbol: symbol, help: help)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(label: String, symbol: String, help: String? = nil) {
        image = ChatSymbol.image(symbol, size: 12, weight: .medium)
        setChatAccessibility(.button, label: label)
        setHelp(help)
        needsDisplay = true
    }

    /// 説明の札。無ければラベルを出す
    func setHelp(_ help: String?) {
        #if os(macOS)
        toolTip = help ?? accessibilityLabel()
        #else
        // 押せない理由（巻き戻し）は読み上げで添える
        accessibilityHint = help
        #endif
    }

    func fit(width: CGFloat) -> CGSize {
        let size = CGSize(width: HitTarget.size, height: HitTarget.size)
        setFrameSize(size)
        return size
    }

    func setHovered(_ hovered: Bool) {
        guard self.hovered != hovered else { return }
        self.hovered = hovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: CGRect) {
        let lit = hovered && isEnabled
        if lit { ChatDrawing.box(bounds, radius: Radius.control, fill: ChatPalette.Platform.fill) }
        guard let image else { return }
        let tint = (lit ? ChatPalette.Platform.text : ChatPalette.Platform.secondaryText).fading(isEnabled ? 1 : 0.4)
        ChatDrawing.symbol(image, in: bounds, tint: tint)
    }
}

/// 文をコピーするボタン。押すと 1.2 秒だけ印を✓にする（`ChatCopyButton`）
final class ChatCopyButtonView: ChatFlippedView, ChatHoverable, ChatFitting {
    private let text: String
    private lazy var button = ChatIconButtonView(label: String(localized: "コピー"), symbol: "doc.on.doc") { [weak self] in self?.copy() }
    private var resetTask: Task<Void, Never>?

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let size = button.fit(width: width)
        setFrameSize(size)
        return size
    }

    func setHovered(_ hovered: Bool) {}

    private func copy() {
        Pasteboard.copy(text)
        button.set(label: String(localized: "コピーしました"), symbol: "checkmark")
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.button.set(label: String(localized: "コピー"), symbol: "doc.on.doc")
        }
    }
}

/// 畳める行の見出しの先頭の開閉の印。本文の大きさの正方形の真ん中に置き、開くと右向きから下向きへ回す（`ChatRowChevron`）。
/// `turning` は押して開閉したばかりの見出し（組み直した見出しで、前の向きから 0.06 秒で回す。視差効果を減らす設定では回さずに替える）
@MainActor
enum ChatChevron {
    static func view(open: Bool, fonts: ChatFonts, tint: PlatformColor, turning: Bool = false) -> ChatSymbolView {
        let view = ChatSymbolView("chevron.right", size: fonts.chevron, weight: .semibold, tint: tint)
        view.side = fonts.size
        let target: CGFloat = open ? 90 : 0
        if turning, !ChatSystem.reducesMotion {
            view.angle = open ? 0 : 90
            view.turn(to: target, duration: 0.06)
        } else {
            view.angle = target
        }
        return view
    }

    /// 畳める行の中身はこの幅だけ下げる（印の枠と `Space.row`。`chatRowIndented`）
    static func indent(fonts: ChatFonts) -> CGFloat {
        fonts.size + Space.row
    }
}

/// 畳める行の見出しに並べるもの。色は見出しの色（補足の色、ホバーで本文の色）に従うか、薄い色（ホバーで補足の色）か、決まった色
enum ChatHeaderPart {
    enum Tint {
        /// 見出しの色
        case header
        /// 薄い色（ホバーで補足の色）
        case muted
        case fixed(PlatformColor)
    }

    case symbol(String, size: CGFloat, tint: Tint, label: String?)
    /// 回る印（記号と同じ大きさ）
    case spinner(size: CGFloat, label: String)
    /// `flexible` は残りの幅に収まるよう切り詰める文
    case text(NSAttributedString, tint: Tint, flexible: Bool, truncation: NSLineBreakMode)
}

/// 畳める行の見出し。押すと開閉する（`ChatRowHeader`）。`toggle` が nil なら押せず、印を隠して同じ位置に置く。
/// `color` は押せないときと、ホバーしていないときの見出しの色
final class ChatDisclosureHeaderView: ChatPressableView, ChatHoverable, ChatFitting {
    private let chevron: ChatSymbolView
    private var parts: [(view: PlatformView, part: ChatHeaderPart)] = []
    private let open: Bool
    private var hovered = false
    private let color: PlatformColor
    private let accessibilityText: String

    /// 幅を中身に合わせる（吹き出しの中）。false なら置ける幅いっぱい
    var hugs = false
    /// ホバーで色を変える（吹き出しの中の見出しは変えない）
    var hoverable = true
    /// 行の高さ（本文の行に並べるとき）
    var minHeight: CGFloat = 0
    /// 押せないときも印の場所を空けておく
    private let reservesChevron: Bool

    init(
        open: Bool, fonts: ChatFonts, parts: [ChatHeaderPart], color: PlatformColor = ChatPalette.Platform.secondaryText, reservesChevron: Bool = true,
        turning: Bool = false, toggle: (() -> Void)?
    ) {
        self.open = open
        self.color = color
        self.reservesChevron = reservesChevron
        chevron = ChatChevron.view(open: open, fonts: fonts, tint: color, turning: turning)
        accessibilityText = parts.compactMap { part -> String? in
            switch part {
            case .symbol(_, _, _, let label): label
            case .spinner(_, let label): label
            case .text(let text, _, _, _): text.string
            }
        }.joined(separator: "、")
        super.init(frame: .zero)
        action = toggle
        #if os(iOS)
        setChatAccessibility(toggle == nil ? .staticText : .button, label: accessibilityText)
        accessibilityValue = toggle == nil ? nil : (open ? String(localized: "展開済み") : String(localized: "折りたたみ済み"))
        #endif
        chevron.isHidden = toggle == nil
        addSubview(chevron)
        self.parts = parts.map { part in
            let view: PlatformView
            switch part {
            case .symbol(let name, let size, _, _):
                view = ChatSymbolView(name, size: size, tint: color)
            case .spinner(let size, let label):
                view = ChatSpinnerView(side: ceil(size * 1.1), label: label)
            case .text(let text, _, _, let truncation):
                let label = ChatLabelView(text, color: color, truncation: truncation)
                label.readsAloud = false
                view = label
            }
            addSubview(view)
            return (view, part)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let chevronSize = action != nil || reservesChevron ? chevron.imageSize : .zero
        var sizes = parts.map { part -> CGSize in
            switch part.view {
            case let label as ChatLabelView: label.naturalSize
            case let symbol as ChatSymbolView: symbol.imageSize
            case let spinner as ChatSpinnerView: spinner.fit(width: 0)
            default: .zero
            }
        }
        let height = max(sizes.map(\.height).max() ?? 0, chevronSize.height, minHeight)
        // 切り詰める文には、ほかを置いた残りを分ける
        let fixed = sizes.indices.filter { !Self.isFlexible(parts[$0].part) }.reduce(chevronSize.width) { $0 + sizes[$1].width }
            + Space.row * CGFloat(chevronSize.width > 0 ? parts.count : parts.count - 1)
        var room = max(width - fixed, 0)
        for index in sizes.indices where Self.isFlexible(parts[index].part) {
            sizes[index].width = min(sizes[index].width, room)
            room -= sizes[index].width
        }
        chevron.frame = CGRect(x: 0, y: ((height - chevronSize.height) / 2).rounded(), width: chevronSize.width, height: chevronSize.height)
        var x = chevronSize.width > 0 ? chevronSize.width + Space.row : 0
        for (index, part) in parts.enumerated() {
            let size = sizes[index]
            part.view.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Space.row
        }
        let size = CGSize(width: hugs ? min(x - Space.row, width) : width, height: height)
        setFrameSize(size)
        return size
    }

    private static func isFlexible(_ part: ChatHeaderPart) -> Bool {
        if case .text(_, _, true, _) = part { return true }
        return false
    }

    func setHovered(_ hovered: Bool) {
        guard self.hovered != hovered, action != nil, hoverable else { return }
        self.hovered = hovered
        refresh()
    }

    private func refresh() {
        let header = hovered ? ChatPalette.Platform.text : color
        chevron.tint = header
        for (view, part) in parts {
            let tint: ChatHeaderPart.Tint
            switch part {
            case .symbol(_, _, let value, _): tint = value
            case .text(_, let value, _, _): tint = value
            case .spinner: continue
            }
            let resolved: PlatformColor = switch tint {
            case .header: header
            case .muted: hovered ? ChatPalette.Platform.secondaryText : ChatPalette.Platform.mutedText
            case .fixed(let color): color
            }
            if let label = view as? ChatLabelView { label.color = resolved }
            if let symbol = view as? ChatSymbolView { symbol.tint = resolved }
        }
    }

    #if os(macOS)
    override func accessibilityRole() -> NSAccessibility.Role? { action == nil ? .staticText : .button }
    override func accessibilityLabel() -> String? { accessibilityText }
    override func accessibilityValue() -> Any? { action == nil ? nil : (open ? String(localized: "展開済み") : String(localized: "折りたたみ済み")) }
    #endif
}

/// 札（`chipStyle`）：横 7・縦 2 の内側と、色の 12% の地の丸い枠。中は印と文を並べる
class ChatChipView: ChatPressableView, ChatFitting {
    private var pieces: [(view: ChatPart, shrinks: Bool)] = []
    private var tint: PlatformColor = ChatPalette.Platform.secondaryLabel
    /// 中の文の行の高さ（吹き出しの中は本文の行の高さ）
    var lineHeight: CGFloat = 0

    /// `shrinks` の文は、入らないときに切り詰める
    func set(pieces: [(view: ChatPart, shrinks: Bool)], tint: PlatformColor) {
        self.pieces.forEach { $0.view.removeFromSuperview() }
        self.pieces = pieces
        self.tint = tint
        for piece in pieces {
            (piece.view as? ChatLabelView)?.readsAloud = false
            addSubview(piece.view)
        }
        needsDisplay = true
    }

    func fit(width: CGFloat) -> CGSize {
        let padding = CGSize(width: 7, height: 2)
        var sizes = pieces.map { $0.view.fit(width: .greatestFiniteMagnitude) }
        let total = sizes.reduce(0) { $0 + $1.width } + Space.inline * CGFloat(max(pieces.count - 1, 0)) + padding.width * 2
        var over = total - width
        for index in sizes.indices.reversed() where over > 0 && pieces[index].shrinks {
            let cut = min(over, sizes[index].width - 24)
            if cut > 0 {
                sizes[index].width -= cut
                over -= cut
            }
        }
        let height = ceil(max(sizes.map(\.height).max() ?? 0, lineHeight) + padding.height * 2)
        var x = padding.width
        for (index, piece) in pieces.enumerated() {
            let size = sizes[index]
            piece.view.fit(width: size.width)
            piece.view.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Space.inline
        }
        let size = CGSize(width: min(x - Space.inline + padding.width, width), height: height)
        setFrameSize(size)
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        ChatDrawing.box(bounds, radius: bounds.height / 2, fill: tint.fading(0.12))
    }

    #if os(macOS)
    override func accessibilityRole() -> NSAccessibility.Role? { action == nil ? .staticText : .button }
    #endif
}

/// ツールの呼び出しの行に出すファイルの札。パスの末尾（ディレクトリは薄く）と、変えた行の数か「読み取り済み」か画像の大きさ。押すとファイルの欄で開く
final class ChatFileChipView: ChatChipView {
    init(ref: ChatFileRef, fonts: ChatFonts, selected: Bool, open: ((ChatFileRef) -> Void)?) {
        super.init(frame: .zero)
        let font = fonts.platformCaption
        let tint: PlatformColor = selected ? ChatPalette.Platform.controlAccent : ChatPalette.Platform.secondaryLabel
        // SwiftUI の .primary・.secondary・.tertiary は札の色を基準にした濃さになる（選んだ札は強調の色の濃さ違い）
        let primary: PlatformColor = selected ? ChatPalette.Platform.controlAccent : ChatPalette.Platform.label
        let secondary: PlatformColor = selected ? ChatPalette.Platform.controlAccent.fading(0.55) : ChatPalette.Platform.secondaryLabel
        let tertiary: PlatformColor = selected ? ChatPalette.Platform.controlAccent.fading(0.26) : ChatPalette.Platform.tertiaryLabel
        var pieces: [(view: ChatPart, shrinks: Bool)] = [
            (ChatSymbolView(ref.symbol, size: font.pointSize, tint: tint), false),
            (ChatLabelView(ref.name, font: font, color: primary, truncation: .byTruncatingMiddle), true),
        ]
        if let directory = ref.directory {
            pieces.append((ChatLabelView(directory, font: font, color: tertiary, truncation: .byTruncatingHead), true))
        }
        let digits = PlatformFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        switch ref.file.action {
        case .read:
            pieces.append((ChatLabelView(String(localized: "読み取り済み"), font: font, color: secondary), false))
        case .image:
            if let bytes = ref.file.bytes {
                pieces.append((ChatLabelView(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file), font: font, color: secondary), false))
            }
        case .created, .edited:
            pieces.append((ChatLabelView("+\(ref.file.added)", font: digits, color: .systemGreen), false))
            if ref.file.action == .edited {
                pieces.append((ChatLabelView("−\(ref.file.removed)", font: digits, color: .systemRed), false))
            }
        }
        set(pieces: pieces, tint: tint)
        action = open.map { open in { open(ref) } }
        toolTip = [ref.file.path, ref.summaryLabel].compactMap { $0 }.joined(separator: "\n")
        setChatAccessibility(open == nil ? .staticText : .button, label: ref.name + "、" + ref.summaryLabel, help: open == nil ? "" : String(localized: "ファイルパネルで開きます"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 添付したファイルの名前の札（発言の吹き出しの札。`ChatAttachedFileLabel` の `chipStyle`）。行の高さは吹き出しの本文と同じ。
/// `opacity` は送っている発言の薄さ
final class ChatAttachedFileChipView: ChatChipView {
    init(name: String, path: String?, fonts: ChatFonts, opacity: CGFloat = 1) {
        super.init(frame: .zero)
        let font = fonts.platformCaption
        lineHeight = fonts.line
        set(pieces: [
            (ChatSymbolView("doc", size: font.pointSize, tint: ChatPalette.Platform.secondaryLabel.fading(opacity)), false),
            (ChatLabelView(name, font: font, color: ChatPalette.Platform.text.fading(opacity), truncation: .byTruncatingMiddle), true),
        ], tint: ChatPalette.Platform.secondaryLabel.fading(opacity))
        toolTip = path
        setChatAccessibility(.staticText, label: name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// システムのボタン（［生成を停止］［停止］［再送信］）
final class ChatButtonView: ChatFlippedView, ChatFitting {
    #if os(macOS)
    let button: NSButton
    private let handler: ChatMenuAction

    init(title: String, symbol: String? = nil, bordered: Bool, font: PlatformFont? = nil, help: String? = nil, enabled: Bool = true, action: @escaping () -> Void) {
        handler = ChatMenuAction(action)
        button = NSButton(title: title, target: handler, action: #selector(ChatMenuAction.run))
        super.init(frame: .zero)
        button.controlSize = .small
        button.font = font ?? .systemFont(ofSize: PlatformFont.systemFontSize(for: .small))
        if bordered {
            button.bezelStyle = .push
        } else {
            button.isBordered = false
            button.contentTintColor = ChatPalette.Platform.controlAccent
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: button.font as Any, .foregroundColor: ChatPalette.Platform.controlAccent])
        }
        if let symbol {
            button.image = PlatformImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        button.toolTip = help
        button.isEnabled = enabled
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let size = button.fittingSize
        button.frame = CGRect(origin: .zero, size: size)
        setFrameSize(size)
        return size
    }
    #else
    let button: UIButton

    /// `font` が無ければ標準の大きさの本文の字（iPhone・iPad の SwiftUI のボタンは `controlSize(.small)` でも字が小さくならない）。
    /// 行の文は Dynamic Type に連れない（`ChatFonts`）ので、ボタンだけ大きくして行を崩さないよう、Dynamic Type の大きさにはしない
    init(title: String, symbol: String? = nil, bordered: Bool, font: PlatformFont? = nil, help: String? = nil, enabled: Bool = true, action: @escaping () -> Void) {
        var configuration: UIButton.Configuration = bordered ? .bordered() : .plain()
        configuration.buttonSize = .small
        configuration.contentInsets = bordered ? NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10) : .zero
        let font = font ?? .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        var attributes = AttributeContainer()
        attributes.font = font
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))
            configuration.imagePadding = Space.inline
        }
        button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        // 渡した字のままにする（UIButton.Configuration は題の字をボタンの Dynamic Type の大きさに合わせ直す）
        button.maximumContentSizeCategory = .large
        super.init(frame: .zero)
        button.isEnabled = enabled
        button.accessibilityHint = help
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let natural = button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(min(natural.width, width)), height: ceil(natural.height))
        button.frame = CGRect(origin: .zero, size: size)
        setFrameSize(size)
        return size
    }
    #endif
}
