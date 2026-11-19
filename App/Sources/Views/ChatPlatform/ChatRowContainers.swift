import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import TaskboardKit

/// 発言の行。下に操作の帯（コピー・巻き戻し・フォーク）を付け、Mac ではポインタが行のどこかにあるときだけ出す（0.1 秒待って出す）。
/// iPhone・iPad は hover が無いので帯を出さず、長押しのメニューから操作する（帯の高さも取らない）。
/// Mac は出していない間も帯の高さを取っておき（出し入れで下の行が動かない）、帯の下の端は次の行との間に入れる。
/// 帯はポインタが乗ったときに初めて作る（全部の行で先に作ると、会話を開いて行を組む手間の 3 割が帯のボタンだった）
final class ChatMessageContainerView: ChatFlippedView, ChatFitting, ChatHoverable, ChatMenuProviding, ChatOverflowing {
    private let content: ChatPart
    private let makeBar: () -> ChatRowStackView
    private var bar: ChatRowStackView?
    private let trailing: Bool
    private let revealed: Bool
    private let menuBuilder: () -> [ChatMenuEntry]
    private var showTask: Task<Void, Never>?
    private var slot: CGFloat = 0
    /// 最後に並べた幅と本文の高さ（後から作った帯を置く）
    private var placed: (width: CGFloat, body: CGFloat)?

    var overflow: CGFloat { reservesBar ? ChatMetrics.actionBarOverlap : 0 }

    private var reservesBar: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    init(content: ChatPart, bar: @escaping () -> ChatRowStackView, trailing: Bool, revealed: Bool, menu: @escaping () -> [ChatMenuEntry]) {
        self.content = content
        makeBar = bar
        self.trailing = trailing
        self.revealed = revealed
        menuBuilder = menu
        super.init(frame: .zero)
        addSubview(content)
        #if os(macOS)
        if revealed {
            let bar = loadBar()
            bar.alphaValue = 1
            bar.isHidden = false
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let body = content.fit(width: width)
        content.frame.origin = .zero
        placed = (width, body.height)
        if let bar { place(bar) }
        slot = reservesBar ? body.height + ChatMetrics.actionBar - ChatMetrics.actionBarOverlap : body.height
        let result = CGSize(width: width, height: slot)
        setFrameSize(CGSize(width: width, height: slot + overflow))
        return result
    }

    private func place(_ bar: ChatRowStackView) {
        guard let placed else { return }
        let size = bar.fit(width: placed.width)
        let x = trailing ? placed.width - size.width : ChatMetrics.assistantInset - Space.inline / 2
        bar.frame = CGRect(x: x, y: placed.body + (ChatMetrics.actionBar - size.height) / 2, width: size.width, height: size.height)
    }

    private func loadBar() -> ChatRowStackView {
        if let bar { return bar }
        let bar = makeBar()
        #if os(macOS)
        bar.alphaValue = 0
        #endif
        bar.isHidden = true
        addSubview(bar)
        place(bar)
        self.bar = bar
        return bar
    }

    func setHovered(_ hovered: Bool) {
        #if os(macOS)
        guard !revealed else { return }
        showTask?.cancel()
        // 視差効果を減らす設定では、待たずに出し、動かさずに替える（`ChatMotion`）
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if hovered, reduceMotion {
            let bar = loadBar()
            bar.isHidden = false
            bar.alphaValue = 1
        } else if hovered {
            let bar = loadBar()
            showTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.1))
                guard !Task.isCancelled else { return }
                self?.show(bar)
            }
        } else if let bar, reduceMotion {
            bar.alphaValue = 0
            bar.isHidden = true
        } else if let bar {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.06
                bar.animator().alphaValue = 0
            }
            // アニメーションの終わりの知らせは来ないことがある（窓の外の行）。来ないと見えない帯のボタンが押せるまま残るので、時間で隠す
            showTask = Task {
                try? await Task.sleep(for: .seconds(0.06))
                guard !Task.isCancelled else { return }
                bar.isHidden = true
            }
        }
        #endif
    }

    #if os(macOS)
    private func show(_ bar: ChatRowStackView) {
        bar.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            bar.animator().alphaValue = 1
        }
    }
    #endif

    func chatMenu() -> [ChatMenuEntry]? { menuBuilder() }

    #if os(macOS)
    /// 帯を下へはみ出して描く分は、帯のボタンの所だけ受ける（次の行の上の端を取らない）
    override func hitTest(_ point: CGPoint) -> PlatformView? {
        let hit = super.hitTest(point)
        guard hit === self, convert(point, from: superview).y > slot else { return hit }
        return nil
    }
    #else
    /// 帯を下へはみ出して描く分は、帯のボタンの所だけ受ける（次の行の上の端を取らない）
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if point.y <= slot { return super.point(inside: point, with: event) }
        guard let bar, !bar.isHidden else { return false }
        return bar.frame.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if point.y > slot, let bar, !bar.isHidden { return bar.hitTest(convert(point, to: bar), with: event) }
        return super.hitTest(point, with: event)
    }
    #endif
}

/// 右クリックのメニューだけを付ける
final class ChatMenuView: ChatFlippedView, ChatFitting, ChatMenuProviding {
    private let content: ChatPart
    private let menuBuilder: () -> [ChatMenuEntry]

    init(content: ChatPart, menu: @escaping () -> [ChatMenuEntry]) {
        self.content = content
        menuBuilder = menu
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let size = content.fit(width: width)
        content.frame.origin = .zero
        setFrameSize(size)
        return size
    }

    func chatMenu() -> [ChatMenuEntry]? { menuBuilder() }
}

/// 人の発言の吹き出し。右に寄せ、地は墨 5%、角丸 10、内側 12×8。幅は中身に合わせ、列の 85% と `ChatMetrics.bubbleMaxWidth` の狭い方まで
final class ChatBubbleView: ChatFlippedView, ChatFitting {
    private let content: ChatPart
    private let fonts: ChatFonts
    private let opacity: CGFloat
    private var bubble = CGRect.zero

    /// `opacity` は地の濃さ（送っている発言。中の字の濃さは中身が持つ）
    init(content: ChatPart, fonts: ChatFonts, opacity: CGFloat = 1) {
        self.content = content
        self.fonts = fonts
        self.opacity = opacity
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let padding = ChatMetrics.bubblePadding
        let limit = min(width * ChatMetrics.bubbleShare, ChatMetrics.bubbleMaxWidth)
        let inner = content.fit(width: max(limit - padding.width * 2, 1))
        let top = fonts.turnGap - fonts.itemGap
        bubble = CGRect(x: width - inner.width - padding.width * 2, y: top, width: inner.width + padding.width * 2, height: inner.height + padding.height * 2)
        content.frame.origin = CGPoint(x: bubble.minX + padding.width, y: bubble.minY + padding.height)
        let size = CGSize(width: width, height: bubble.maxY)
        setFrameSize(size)
        needsDisplay = true
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        ChatDrawing.box(bubble, radius: Radius.card, fill: ChatPalette.Platform.fill.fading(opacity))
    }
}

/// 中の部品を、置ける幅の中で真ん中か右に寄せる
final class ChatAlignView: ChatFlippedView, ChatFitting {
    enum Alignment { case center, trailing }

    private let content: ChatPart
    private let alignment: Alignment

    init(_ content: ChatPart, alignment: Alignment) {
        self.content = content
        self.alignment = alignment
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let inner = content.fit(width: width)
        let x = alignment == .center ? ((width - inner.width) / 2).rounded() : width - inner.width
        content.frame.origin = CGPoint(x: x, y: 0)
        let size = CGSize(width: width, height: inner.height)
        setFrameSize(size)
        return size
    }
}

/// 真ん中に文を置き、左右に線を引く区切りの行（会話を圧縮した所）。線は `draw(_:)` で描く
final class ChatDividerView: ChatFlippedView, ChatFitting {
    private let label: ChatPart

    init(label: ChatPart) {
        self.label = label
        super.init(frame: .zero)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let inner = label.fit(width: max(width - Space.section * 2, 1))
        label.frame.origin = CGPoint(x: ((width - inner.width) / 2).rounded(), y: 0)
        let size = CGSize(width: width, height: inner.height)
        setFrameSize(size)
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        ChatPalette.Platform.fillStronger.setFill()
        let y = (bounds.height / 2).rounded() - 0.25
        CGRect(x: 0, y: y, width: max(label.frame.minX - Space.row, 0), height: 0.5).fill()
        let right = label.frame.maxX + Space.row
        CGRect(x: right, y: y, width: max(bounds.width - right, 0), height: 0.5).fill()
    }
}

/// 人の発言に添えた画像の縮小版。押すと大きく開く（`ChatSentImageViewer`）。右クリックは発言のメニューの頭に［画像をコピー］
final class ChatThumbnailView: ChatPressableView, ChatFitting, ChatMenuProviding {
    private let image: CGImage?
    private let placeholder: PlatformImage?
    private var spinner: ChatSpinnerView?
    private let ref: ChatSentImageRef
    private let access: ChatSentImageAccess?

    init(ref: ChatSentImageRef, access: ChatSentImageAccess?, fonts: ChatFonts) {
        self.ref = ref
        self.access = access
        image = access?.feed.files.thumbnails[ref.id]
        placeholder = ChatSymbol.image("photo", size: fonts.size)
        super.init(frame: .zero)
        let state = access?.feed.files.state(ref)
        if image == nil, case .loading = state {
            let spinner = ChatSpinnerView()
            addSubview(spinner)
            self.spinner = spinner
        }
        if let access {
            action = { access.open(ref) }
            // 縮小版は読み込んだら取り置きに入り、行を組み直したときに出る
            if state == nil { Task { await access.load(ref) } }
        }
        isEnabled = access != nil
        toolTip = ref.name
        setChatAccessibility(access == nil ? .image : .button, label: ref.name, help: access == nil ? "" : String(localized: "画像を大きく表示します"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func chatMenu() -> [ChatMenuEntry]? {
        let parent = superview.flatMap { ChatMenu.entries(from: $0) }
        guard case .loaded(.image(let data)) = access?.feed.files.state(ref) else { return parent }
        let copy = ChatMenuEntry.item(String(localized: "画像をコピー"), symbol: "doc.on.doc") { Pasteboard.copy(image: data) }
        guard let parent, !parent.isEmpty else { return [copy] }
        return [copy, .separator] + parent
    }

    func fit(width: CGFloat) -> CGSize {
        let size = CGSize(width: ChatMetrics.thumbnail, height: ChatMetrics.thumbnail)
        setFrameSize(size)
        if let spinner {
            let inner = spinner.fit(width: size.width)
            spinner.frame.origin = CGPoint(x: (size.width - inner.width) / 2, y: (size.height - inner.height) / 2)
        }
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        ChatDrawing.box(bounds, radius: Radius.control, fill: ChatPalette.Platform.fill)
        if let image {
            ChatDrawing.clipped(bounds, radius: Radius.control) {
                // 縦横の比を保って枠を埋める
                let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                ChatDrawing.image(image, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            }
        } else if spinner == nil, let placeholder {
            ChatDrawing.symbol(placeholder, in: bounds, tint: ChatPalette.Platform.secondaryLabel)
        }
        ChatDrawing.box(bounds, radius: Radius.control, fill: nil, stroke: ChatPalette.Platform.secondaryLabel.fading(0.2))
    }
}

/// 会話の末尾の、engine が今していることの行。回る印と経過の時間で、止まっていないことを示す（`ConversationActivityRow`）
final class ChatActivityRowView: ChatFlippedView, ChatFitting {
    private let row: ChatRowStackView
    private let elapsed: ChatLabelView
    private let activity: ConversationActivity
    private let live: Bool
    private var timer: Timer?

    init(activity: ConversationActivity, fonts: ChatFonts, stop: (() -> Void)?, live: Bool, today: Date) {
        self.activity = activity
        self.live = live
        let now = live ? Date() : today
        let digits = PlatformFont.monospacedDigitSystemFont(ofSize: fonts.platformCaption.pointSize, weight: .regular)
        elapsed = ChatLabelView(ConversationActivityRow.clockText(activity, now: now), font: digits, color: ChatPalette.Platform.mutedText)
        func title(_ text: String) -> ChatLabelView {
            ChatLabelView(text, font: fonts.platformSubheadline, color: ChatPalette.Platform.secondaryText)
        }
        switch activity {
        case .compacting(let compaction):
            var items: [ChatPart] = [ChatSpinnerView(), title(String(localized: "会話を圧縮しています…"))]
            if let chars = compaction.outputChars {
                items.append(ChatLabelView(String(localized: "要約\(chars.formatted())字"), font: fonts.platformCaption, color: ChatPalette.Platform.mutedText))
            }
            row = ChatRowStackView(items + [elapsed])
        case .apiRetry(let retry):
            row = ChatRowStackView([
                ChatSpinnerView(), title(ConversationActivityRow.retryTitle(kind: retry.kind, status: retry.status)),
                ChatLabelView(ConversationActivityRow.retryProgress(retry), font: digits, color: ChatPalette.Platform.mutedText), elapsed,
            ])
        case .stalled:
            let button = ChatButtonView(title: String(localized: "生成を停止"), bordered: true, enabled: stop != nil) { stop?() }
            row = ChatRowStackView([
                ChatSymbolView("exclamationmark.circle", size: fonts.platformCaption.pointSize, tint: .systemOrange),
                title(String(localized: "応答が止まっています")),
                elapsed,
            ], trailing: [button])
        }
        super.init(frame: .zero)
        addSubview(row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let inner = row.fit(width: width)
        row.frame.origin = .zero
        let size = CGSize(width: width, height: inner.height)
        setFrameSize(size)
        return size
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged()
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        windowChanged()
    }
    #endif

    private func windowChanged() {
        timer?.invalidate()
        timer = nil
        guard live, window != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        elapsed.string = ConversationActivityRow.clockText(activity, now: Date())
        row.fit(width: row.frame.width)
    }
}
