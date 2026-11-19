import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 開いた行の中身のカード。1pt の枠と角丸 8 で囲み、行どうしに区切り線を引く。各行の内側は 10×8（`ChatOutlineCard`）
final class ChatOutlineCardView: ChatFlippedView, ChatFitting {
    private let rows: [ChatPart]
    private var lines: [CGFloat] = []
    var background: PlatformColor?

    init(rows: [ChatPart], background: PlatformColor? = nil) {
        self.rows = rows
        self.background = background
        super.init(frame: .zero)
        rows.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let padding = ChatMetrics.toolBodyPadding
        var y: CGFloat = 0
        lines = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                lines.append(y)
                y += 1
            }
            let size = row.fit(width: max(width - padding.width * 2, 1))
            row.frame.origin = CGPoint(x: padding.width, y: y + padding.height)
            y += size.height + padding.height * 2
        }
        let size = CGSize(width: width, height: y)
        setFrameSize(size)
        needsDisplay = true
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        ChatDrawing.box(bounds, radius: Radius.box, fill: background)
        ChatPalette.Platform.border.setFill()
        for y in lines { CGRect(x: 0, y: y, width: bounds.width, height: 1).fill() }
        ChatDrawing.box(bounds, radius: Radius.box, fill: nil, stroke: ChatPalette.Platform.border)
    }
}

/// 子を左から右へ並べ、入らなければ折り返す（`FlowRow`）
final class ChatFlowView: ChatFlippedView, ChatFitting {
    private let items: [ChatPart]
    private let spacing: CGFloat
    private let lineSpacing: CGFloat

    init(items: [ChatPart], spacing: CGFloat = Space.inline, lineSpacing: CGFloat = Space.inline) {
        self.items = items
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        super.init(frame: .zero)
        items.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for item in items {
            let size = item.fit(width: width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            item.frame.origin = CGPoint(x: x, y: y)
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        let size = CGSize(width: min(widest, width), height: items.isEmpty ? 0 : y + lineHeight)
        setFrameSize(size)
        return size
    }
}

/// 子を縦に並べる入れ物。`indent` だけ右に下げ、子どうしに `spacing` を空ける。
/// `hugs` なら幅を一番広い子に合わせる（吹き出しの中）。`trailing` なら子を右に寄せる
class ChatStackView: ChatFlippedView, ChatFitting {
    private(set) var items: [ChatPart]
    var spacing: CGFloat
    var indent: CGFloat
    var hugs = false
    var trailing = false
    /// 中を 1 つの読み上げにまとめるときの名前（中の部品は読み上げない）
    var accessibilityGroupLabel: String? {
        didSet {
            #if os(iOS)
            setChatAccessibility(accessibilityGroupLabel == nil ? nil : .staticText, label: accessibilityGroupLabel)
            #endif
        }
    }

    init(_ items: [ChatPart], spacing: CGFloat = 0, indent: CGFloat = 0) {
        self.items = items
        self.spacing = spacing
        self.indent = indent
        super.init(frame: .zero)
        items.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        var y: CGFloat = 0
        let inner = max(width - indent, 1)
        var sizes: [CGSize] = []
        for (index, item) in items.enumerated() {
            if index > 0 { y += spacing }
            let size = item.fit(width: inner)
            sizes.append(size)
            item.frame.origin = CGPoint(x: indent, y: y)
            y += size.height
        }
        let used = hugs ? min((sizes.map(\.width).max() ?? 0) + indent, width) : width
        if trailing {
            for (index, item) in items.enumerated() { item.frame.origin.x = used - sizes[index].width }
        }
        let size = CGSize(width: used, height: y)
        setFrameSize(size)
        return size
    }

    #if os(macOS)
    override func isAccessibilityElement() -> Bool { accessibilityGroupLabel != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { accessibilityGroupLabel != nil ? .staticText : super.accessibilityRole() }
    override func accessibilityLabel() -> String? { accessibilityGroupLabel ?? super.accessibilityLabel() }
    override func accessibilityChildren() -> [Any]? { accessibilityGroupLabel != nil ? [] : super.accessibilityChildren() }
    #endif
}

/// 子を横に並べる入れ物。縦は真ん中に揃え、`trailing` の子は右の端に寄せる（`HStack` と `Spacer`）
final class ChatRowStackView: ChatFlippedView, ChatFitting {
    private let leading: [ChatPart]
    private let trailing: [ChatPart]
    private let spacing: CGFloat
    /// 幅を中身に合わせる（false なら置ける幅いっぱい）
    var hugs = false

    init(_ leading: [ChatPart], trailing: [ChatPart] = [], spacing: CGFloat = Space.row) {
        self.leading = leading
        self.trailing = trailing
        self.spacing = spacing
        super.init(frame: .zero)
        (leading + trailing).forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let trailingSizes = trailing.map { $0.fit(width: width) }
        let trailingWidth = trailingSizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(trailing.count)
        var room = max(width - trailingWidth, 0)
        var leadingSizes: [CGSize] = []
        for item in leading {
            let size = item.fit(width: room)
            leadingSizes.append(size)
            room = max(room - size.width - spacing, 0)
        }
        let height = (leadingSizes + trailingSizes).map(\.height).max() ?? 0
        var x: CGFloat = 0
        for (index, item) in leading.enumerated() {
            item.frame.origin = CGPoint(x: x, y: ((height - leadingSizes[index].height) / 2).rounded())
            x += leadingSizes[index].width + spacing
        }
        let used = hugs && trailing.isEmpty ? max(x - spacing, 0) : width
        var right = used
        for (index, item) in trailing.enumerated().reversed() {
            right -= trailingSizes[index].width
            item.frame.origin = CGPoint(x: right, y: ((height - trailingSizes[index].height) / 2).rounded())
            right -= spacing
        }
        let size = CGSize(width: used, height: height)
        setFrameSize(size)
        return size
    }
}

/// 文の view を部品として並べる
final class ChatTextBlock: ChatFlippedView, ChatFitting {
    let text = ChatTextView()
    /// 幅を中身に合わせる（吹き出し）。false なら置ける幅いっぱい
    var hugs = false

    init(_ string: NSAttributedString, hugs: Bool = false) {
        self.hugs = hugs
        super.init(frame: .zero)
        text.set(string)
        addSubview(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let used = hugs ? min(text.idealWidth(), width) : width
        let height = text.fit(width: used)
        text.frame.origin = .zero
        let size = CGSize(width: used, height: height)
        setFrameSize(size)
        return size
    }
}

/// 決まった高さの部品（空き・区切り線）。`line` の太さの線を真ん中に引く
final class ChatSpacerView: ChatFlippedView, ChatFitting {
    private let height: CGFloat
    private let color: PlatformColor?
    private let line: CGFloat
    /// 幅（nil なら置ける幅いっぱい）
    var width: CGFloat?

    init(height: CGFloat, color: PlatformColor? = nil, line: CGFloat? = nil) {
        self.height = height
        self.color = color
        self.line = line ?? height
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let size = CGSize(width: self.width ?? width, height: height)
        setFrameSize(size)
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let color else { return }
        color.setFill()
        CGRect(x: 0, y: (bounds.height - line) / 2, width: bounds.width, height: line).fill()
    }
}

/// 回る印（`ProgressView().controlSize(.small)`）。窓に置かれている間だけ回す（一覧の外の行・畳んだ組の中では回らない）。
/// `label` があれば読み上げる
final class ChatSpinnerView: ChatFlippedView, ChatFitting {
    #if os(macOS)
    private let indicator = NSProgressIndicator()
    #else
    private let indicator = UIActivityIndicatorView(style: .medium)
    #endif
    private let side: CGFloat

    init(side: CGFloat = 16, label: String? = nil) {
        self.side = side
        super.init(frame: .zero)
        #if os(macOS)
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = true
        indicator.setAccessibilityElement(false)
        #else
        indicator.hidesWhenStopped = false
        indicator.isAccessibilityElement = false
        // UIKit の印は 20pt で、枠より大きいときは縮める
        let natural = indicator.intrinsicContentSize.width
        if natural > side { indicator.transform = CGAffineTransform(scaleX: side / natural, y: side / natural) }
        #endif
        addSubview(indicator)
        if let label { setChatAccessibility(.progress, label: label) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let size = CGSize(width: side, height: side)
        #if os(macOS)
        indicator.frame = CGRect(origin: .zero, size: size)
        #else
        indicator.center = CGPoint(x: side / 2, y: side / 2)
        #endif
        setFrameSize(size)
        return size
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { indicator.stopAnimation(nil) } else { indicator.startAnimation(nil) }
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { indicator.stopAnimating() } else { indicator.startAnimating() }
    }
    #endif
}
