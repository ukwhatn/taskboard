import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 会話の一覧の行の部品。置ける幅を受けて中を並べ、自分の大きさを決めて返す（親が位置を決める）。
/// 地・枠・角丸は layer に持たせず `draw(_:)` で描く（snapshot の `cacheDisplay` は layer の地と枠を写さない）
@MainActor
protocol ChatFitting: AnyObject {
    @discardableResult
    func fit(width: CGFloat) -> CGSize
}

/// 行の部品
typealias ChatPart = PlatformView & ChatFitting

/// ポインタが載ったかを受ける部品。一覧が 1 つの tracking area で受けて、ポインタの下の部品と、その親の部品に渡す（部品ごとに tracking area を持たない）。
/// iPhone・iPad では呼ばれない
@MainActor
protocol ChatHoverable: AnyObject {
    func setHovered(_ hovered: Bool)
}

/// 右クリック（長押し）のメニューの項目。端末ごとのメニュー（NSMenu・UIMenu）に組む
enum ChatMenuEntry {
    case item(title: String, symbol: String?, enabled: Bool, action: () -> Void)
    /// 押せない説明の行
    case note(String)
    case separator

    /// 押すと `action` を呼ぶ項目
    static func item(_ title: String, symbol: String?, enabled: Bool = true, action: @escaping () -> Void) -> ChatMenuEntry {
        .item(title: title, symbol: symbol, enabled: enabled, action: action)
    }
}

/// 右クリック（長押し）のメニューを出す部品。中の文（`ChatTextView`）とほかの部品は、近い親のメニューを使う
@MainActor
protocol ChatMenuProviding: AnyObject {
    func chatMenu() -> [ChatMenuEntry]?
}

/// 上から下へ並べる view（UIView はもとから上から下）
class ChatFlippedView: PlatformView {
    #if os(macOS)
    override var isFlipped: Bool { true }

    /// 近い親のメニュー（`ChatMenuProviding`）
    override func menu(for event: NSEvent) -> NSMenu? {
        ChatMenu.nearest(from: self) ?? super.menu(for: event)
    }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        // 地を描かない所は透かす（UIView の既定では、draw(_:) を持つ view の塗らない所が黒くなる）
        isOpaque = false
        backgroundColor = nil
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    #endif
}

@MainActor
enum ChatMenu {
    /// `view` から親へたどって最初に見つかったメニュー
    static func entries(from view: PlatformView) -> [ChatMenuEntry]? {
        var current: PlatformView? = view
        while let candidate = current {
            if let provider = candidate as? ChatMenuProviding { return provider.chatMenu() }
            current = candidate.superview
        }
        return nil
    }

    #if os(macOS)
    static func nearest(from view: PlatformView) -> NSMenu? {
        entries(from: view).map(menu)
    }

    static func menu(_ entries: [ChatMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        entries.map(item).forEach(menu.addItem)
        return menu
    }

    static func item(_ entry: ChatMenuEntry) -> NSMenuItem {
        switch entry {
        case .item(let title, let symbol, let enabled, let action):
            let item = NSMenuItem(title: title, action: #selector(ChatMenuAction.run), keyEquivalent: "")
            let target = ChatMenuAction(action)
            item.target = target
            item.representedObject = target
            item.image = symbol.flatMap { PlatformImage(systemSymbolName: $0, accessibilityDescription: nil) }
            item.isEnabled = enabled
            return item
        case .note(let text):
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .separator:
            return .separator()
        }
    }
    #else
    static func menu(_ entries: [ChatMenuEntry]) -> UIMenu {
        var sections: [[UIMenuElement]] = [[]]
        for entry in entries {
            switch entry {
            case .item(let title, let symbol, let enabled, let action):
                let item = UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }) { _ in action() }
                if !enabled { item.attributes = .disabled }
                sections[sections.count - 1].append(item)
            case .note(let text):
                // 説明は直前の項目の下に添える（UIMenu に押せない行は無い）
                if let last = sections[sections.count - 1].popLast() as? UIAction {
                    last.subtitle = text
                    sections[sections.count - 1].append(last)
                } else {
                    let item = UIAction(title: text) { _ in }
                    item.attributes = .disabled
                    sections[sections.count - 1].append(item)
                }
            case .separator:
                sections.append([])
            }
        }
        let groups = sections.filter { !$0.isEmpty }
        if groups.count == 1 { return UIMenu(children: groups[0]) }
        return UIMenu(children: groups.map { UIMenu(options: .displayInline, children: $0) })
    }
    #endif
}

#if os(macOS)
final class ChatMenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() { action() }
}
#endif

/// 描く手伝い。今の描画の外観（ライト・ダーク）で色を解く
@MainActor
enum ChatDrawing {
    private static var context: CGContext? {
        #if os(macOS)
        NSGraphicsContext.current?.cgContext
        #else
        UIGraphicsGetCurrentContext()
        #endif
    }

    #if os(macOS)
    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
    #else
    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: rect, cornerRadius: radius)
    }
    #endif

    /// 角丸の地と、内側に引く枠（SwiftUI の `strokeBorder`）
    static func box(_ rect: CGRect, radius: CGFloat, fill: PlatformColor?, stroke: PlatformColor? = nil, lineWidth: CGFloat = 1) {
        if let fill {
            fill.setFill()
            roundedPath(rect, radius: radius).fill()
        }
        if let stroke {
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = roundedPath(inset, radius: max(radius - lineWidth / 2, 0))
            path.lineWidth = lineWidth
            stroke.setStroke()
            path.stroke()
        }
    }

    /// 角丸の形で切り抜いて `draw` を描く
    static func clipped(_ rect: CGRect, radius: CGFloat, _ draw: () -> Void) {
        guard let context else { return }
        context.saveGState()
        roundedPath(rect, radius: radius).addClip()
        draw()
        context.restoreGState()
    }

    /// 画像を `rect` に描く（上から下の座標）
    static func image(_ image: CGImage, in rect: CGRect) {
        #if os(macOS)
        PlatformImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #else
        UIImage(cgImage: image).draw(in: rect)
        #endif
    }

    /// SF Symbols の画像を `tint` で塗って `rect` の真ん中に描く。`angle` は度（時計回り）
    static func symbol(_ image: PlatformImage, in rect: CGRect, tint: PlatformColor, angle: CGFloat = 0) {
        guard let context else { return }
        let size = image.size
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        if angle != 0 {
            context.translateBy(x: rect.midX, y: rect.midY)
            // 上から下の座標では、正の角度が時計回り
            context.rotate(by: angle * .pi / 180)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        #if os(macOS)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        tint.setFill()
        // 画像の形で色を切り抜く（sourceAtop では半透明の色の下に黒い画像が残る）
        target.fill(using: .sourceIn)
        context.endTransparencyLayer()
        #else
        image.withTintColor(tint.resolvedColor(with: .current), renderingMode: .alwaysOriginal).draw(in: target)
        #endif
        context.restoreGState()
    }
}

extension PlatformColor {
    /// 濃さを `factor` 倍にした色（SwiftUI の `opacity`）。`withAlphaComponent` は濃さを置き換えるので、もとから薄い色（`secondaryLabelColor`）が濃くなる。
    /// 外観で値の替わる色は、描くときの外観で解いてから掛ける
    func fading(_ factor: CGFloat) -> PlatformColor {
        guard factor < 1 else { return self }
        let base = self
        #if os(macOS)
        return PlatformColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return resolved.withAlphaComponent(resolved.alphaComponent * factor)
        }
        #else
        return UIColor { traits in
            let resolved = base.resolvedColor(with: traits)
            var alpha: CGFloat = 1
            resolved.getWhite(nil, alpha: &alpha)
            return resolved.withAlphaComponent(alpha * factor)
        }
        #endif
    }
}

/// SF Symbols の画像
@MainActor
enum ChatSymbol {
    /// 名前・大きさ・太さごとに 1 つ作って使い回す（描くときに読むだけで、書き換えない）。ボタンを作るたびに引くと、
    /// 会話を開いて行を組む間のボタンの手間の 8 割がこれだった
    private static let cache = NSCache<NSString, PlatformImage>()

    static func image(_ name: String, size: CGFloat, weight: PlatformFont.Weight = .regular) -> PlatformImage? {
        let key = "\(name) \(size) \(weight.rawValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        #if os(macOS)
        let image = PlatformImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(PlatformImage.SymbolConfiguration(pointSize: size, weight: weight))
        #else
        let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: symbolWeight(weight)))
        #endif
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    #if os(iOS)
    private static func symbolWeight(_ weight: UIFont.Weight) -> UIImage.SymbolWeight {
        switch weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
    }
    #endif
}

/// 色を付けた SF Symbols の画像 1 つ。`angle` で回す（開閉の印）
final class ChatSymbolView: ChatFlippedView, ChatFitting {
    var image: PlatformImage? {
        didSet { needsDisplay = true }
    }
    var tint: PlatformColor {
        didSet { needsDisplay = true }
    }
    var angle: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    /// 置く枠の一辺（画像を真ん中に描く）。nil なら画像の大きさ
    var side: CGFloat?
    private var turnTask: Task<Void, Never>?

    init(_ name: String, size: CGFloat, weight: PlatformFont.Weight = .regular, tint: PlatformColor, label: String? = nil) {
        image = ChatSymbol.image(name, size: size, weight: weight)
        self.tint = tint
        super.init(frame: .zero)
        setChatAccessibility(label == nil ? nil : .image, label: label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var imageSize: CGSize {
        if let side { return CGSize(width: side, height: side) }
        return image.map { CGSize(width: ceil($0.size.width), height: ceil($0.size.height)) } ?? .zero
    }

    /// `angle` を `duration` 秒で `target` へ回す（`ChatMotion.fast` と同じ、速く始まって緩やかに止まる動き）
    func turn(to target: CGFloat, duration: TimeInterval) {
        turnTask?.cancel()
        let start = angle
        turnTask = Task { [weak self] in
            let began = Date()
            while !Task.isCancelled {
                let progress = min(Date().timeIntervalSince(began) / duration, 1)
                // 3 次の ease-out（Claude Desktop の --cds-ease-snap に近い）
                let eased = 1 - pow(1 - progress, 3)
                self?.angle = start + (target - start) * eased
                if progress >= 1 { return }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    func fit(width: CGFloat) -> CGSize {
        let size = imageSize
        setFrameSize(size)
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let image else { return }
        ChatDrawing.symbol(image, in: bounds, tint: tint, angle: angle)
    }
}

/// 1 行の文の札。字をそのまま描き、入らなければ切り詰める（NSTextField の cell は字の左右に余白を足し、SwiftUI の Text と並びがずれた）
final class ChatLabelView: ChatFlippedView, ChatFitting {
    /// 字の色以外（字・検索の一致の地）
    private var text: NSAttributedString
    var color: PlatformColor {
        didSet { needsDisplay = true }
    }
    private let truncation: NSLineBreakMode
    /// 1 つの読み上げにする。親がまとめて読む（見出し・札）ときは false
    var readsAloud = true {
        didSet { applyAccessibility() }
    }

    init(_ text: NSAttributedString, color: PlatformColor, truncation: NSLineBreakMode = .byTruncatingTail) {
        self.text = text
        self.color = color
        self.truncation = truncation
        super.init(frame: .zero)
        applyAccessibility()
    }

    convenience init(_ string: String, font: PlatformFont, color: PlatformColor, truncation: NSLineBreakMode = .byTruncatingTail) {
        self.init(NSAttributedString(string: string, attributes: [.font: font]), color: color, truncation: truncation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 文を替える（経過の時間）
    var string: String {
        get { text.string }
        set {
            let next = NSMutableAttributedString(attributedString: text)
            next.replaceCharacters(in: NSRange(location: 0, length: next.length), with: newValue)
            text = next
            needsDisplay = true
            applyAccessibility()
        }
    }

    private var drawn: NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        let range = NSRange(location: 0, length: result.length)
        result.addAttributes([.foregroundColor: color, .paragraphStyle: style], range: range)
        return result
    }

    /// 切り詰めないときの大きさ
    var naturalSize: CGSize {
        let size = text.size()
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    func fit(width: CGFloat) -> CGSize {
        let natural = naturalSize
        let size = CGSize(width: min(natural.width, width), height: natural.height)
        setFrameSize(size)
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        drawn.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func applyAccessibility() {
        #if os(iOS)
        setChatAccessibility(readsAloud ? .staticText : nil, label: text.string)
        #endif
    }

    #if os(macOS)
    override func isAccessibilityElement() -> Bool { readsAloud }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text.string }
    #endif
}

/// 印と文を横に並べる（SwiftUI の `Label`）
final class ChatIconLabelView: ChatFlippedView, ChatFitting {
    private let symbol: ChatSymbolView
    private let label: ChatLabelView
    /// 行の高さ（本文の行に並べるとき）
    var minHeight: CGFloat = 0

    init(_ title: String, symbol name: String, font: PlatformFont, color: PlatformColor, symbolColor: PlatformColor? = nil) {
        symbol = ChatSymbolView(name, size: font.pointSize, tint: symbolColor ?? color)
        label = ChatLabelView(title, font: font, color: color)
        label.readsAloud = false
        super.init(frame: .zero)
        addSubview(symbol)
        addSubview(label)
        setChatAccessibility(.staticText, label: title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let icon = symbol.fit(width: width)
        let text = label.fit(width: max(width - icon.width - Space.inline, 0))
        let height = max(icon.height, text.height, minHeight)
        symbol.frame.origin = CGPoint(x: 0, y: ((height - icon.height) / 2).rounded())
        label.frame.origin = CGPoint(x: icon.width + Space.inline, y: ((height - text.height) / 2).rounded())
        let size = CGSize(width: icon.width + Space.inline + text.width, height: height)
        setFrameSize(size)
        return size
    }
}
