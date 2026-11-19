import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import TaskboardKit

/// コードの塊と、その下の Run の出力
final class ChatCodeBlockView: ChatFlippedView, ChatFitting {
    private let box: ChatCodeBoxView
    private let output: ChatRunOutputView?

    init(code: String, language: String?, look: ChatMarkdownLook) {
        let runnable = language.map(ConversationRunRequest.languages.contains) == true
        let codeRun = runnable ? look.codeRun : nil
        let entry = codeRun.flatMap { $0.actions.entry($0.messageID, code) }
        var run: (() -> Void)?
        if let codeRun, let language { run = { codeRun.actions.start(code, language, codeRun.messageID) } }
        box = ChatCodeBoxView(code: code, diff: DiffCode.isDiff(language), look: look, run: run, running: entry?.status == .running)
        output = entry.flatMap { entry in codeRun.map { codeRun in ChatRunOutputView(entry: entry, fonts: look.fonts, cancel: { codeRun.actions.cancel(entry.id) }, reset: codeRun.actions.reset) } }
        super.init(frame: .zero)
        addSubview(box)
        if let output { addSubview(output) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        var height = box.fit(width: width).height
        box.frame.origin = .zero
        if let output {
            height += MarkdownMetrics.tightSpacing
            let size = output.fit(width: width)
            output.frame.origin = CGPoint(x: 0, y: height)
            height += size.height
        }
        let size = CGSize(width: width, height: height)
        setFrameSize(size)
        return size
    }
}

/// チャットのコードの塊の箱（`ChatCodeBox`）。幅は中身に合わせ（`ChatMetrics.codeMinWidth` から列の幅まで。長い行は折り返す）、
/// 地は 1 段上の面、1pt の枠、角丸 8。右上の文の横に［実行］（シェルの塊だけ）と［コピー］
final class ChatCodeBoxView: ChatFlippedView, ChatFitting {
    private let code: ChatPaddingView
    private let buttons: ChatRowStackView

    init(code: String, diff: Bool, look: ChatMarkdownLook, run: (() -> Void)?, running: Bool) {
        let text = ChatAttributed.plain(code, font: look.fonts.platformCode, color: ChatPalette.Platform.label, line: look.fonts.codeLine, query: look.query)
        if diff { ChatAttributed.markDiff(text) }
        let block = ChatTextBlock(text, hugs: true)
        self.code = ChatPaddingView(block, horizontal: ChatMetrics.codePadding.width, vertical: ChatMetrics.codePadding.height)
        var items: [ChatPart] = []
        if let run {
            let button = ChatIconButtonView(label: String(localized: "実行"), symbol: "play", help: String(localized: "会話のシェルで実行"), action: run)
            button.isEnabled = !running
            items.append(button)
        }
        items.append(ChatCopyButtonView(text: code))
        buttons = ChatRowStackView(items, spacing: Space.inline / 2)
        buttons.hugs = true
        super.init(frame: .zero)
        addSubview(self.code)
        addSubview(buttons)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let pad = Space.inline / 2
        let bar = buttons.fit(width: width)
        let barWidth = bar.width + pad * 2
        let natural = code.fit(width: .greatestFiniteMagnitude).width
        let used = min(max(natural + barWidth, ChatMetrics.codeMinWidth), width)
        let inner = code.fit(width: max(used - barWidth, 1))
        code.frame.origin = .zero
        buttons.frame.origin = CGPoint(x: used - barWidth + pad, y: pad)
        let size = CGSize(width: used, height: max(inner.height, bar.height + pad * 2))
        setFrameSize(size)
        return size
    }

    override func draw(_ dirtyRect: CGRect) {
        ChatDrawing.box(bounds, radius: Radius.box, fill: ChatPalette.Platform.raised, stroke: ChatPalette.Platform.border)
    }
}

/// コードの塊の下の Run の出力（`CodeRunOutput`）。状態と、動いている間の［停止］、終わった後の［シェルを再起動］、出力（長ければ枠の中で送る）、上限で切った印
final class ChatRunOutputView: ChatFlippedView, ChatFitting {
    private let card: ChatOutlineCardView

    init(entry: ConversationRunStore.Entry, fonts: ChatFonts, cancel: @escaping () -> Void, reset: @escaping () -> Void) {
        let caption = PlatformFont.preferredFont(forTextStyle: .caption1)
        let status = ChatIconLabelView(Self.statusLabel(entry), symbol: Self.statusSymbol(entry), font: caption, color: Self.statusColor(entry))
        status.minHeight = fonts.line
        var trailing: [ChatPart] = []
        if entry.status == .running {
            trailing.append(ChatButtonView(title: String(localized: "停止"), symbol: "stop.fill", bordered: false, help: String(localized: "実行を停止"), action: cancel))
        } else {
            trailing.append(
                ChatButtonView(
                    title: String(localized: "シェルを再起動"), symbol: "arrow.counterclockwise", bordered: false, help: String(localized: "変数と作業フォルダを元に戻す"),
                    action: reset))
        }
        var body: [ChatPart] = []
        if !entry.output.isEmpty {
            let text = ChatAttributed.plain(entry.output, font: fonts.platformCode, color: ChatPalette.Platform.text, line: fonts.line, query: nil)
            body.append(ChatCappedView(ChatTextBlock(text), maxHeight: ConversationMetrics.runOutputHeight))
        } else if entry.status != .running {
            body.append(ChatLabelView(String(localized: "（出力はありません）"), font: caption, color: ChatPalette.Platform.mutedText))
        }
        if entry.truncated {
            body.append(ChatLabelView(String(localized: "先頭の1MBだけを表示しています。"), font: .preferredFont(forTextStyle: .caption2), color: ChatPalette.Platform.mutedText))
        }
        card = ChatOutlineCardView(rows: [ChatRowStackView([status], trailing: trailing), ChatStackView(body, spacing: Space.inline)], background: ChatPalette.Platform.raised)
        super.init(frame: .zero)
        addSubview(card)
        #if os(macOS)
        setChatAccessibility(.group, label: String(localized: "実行の結果"))
        #else
        // iPhone・iPad は中の文とボタンを 1 つずつ読む（まとめると［停止］が押せない）
        accessibilityLabel = String(localized: "実行の結果")
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let size = card.fit(width: width)
        card.frame.origin = .zero
        setFrameSize(size)
        return size
    }

    private static func statusLabel(_ entry: ConversationRunStore.Entry) -> String {
        switch entry.status {
        case .running: String(localized: "実行中…")
        case .succeeded: String(localized: "完了")
        case .failed: entry.exitCode.map { String(localized: "失敗（終了コード\($0)）") } ?? String(localized: "失敗")
        case .cancelled: String(localized: "停止済み")
        case .timedOut: String(localized: "10分を超えたため停止しました")
        }
    }

    private static func statusSymbol(_ entry: ConversationRunStore.Entry) -> String {
        switch entry.status {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .timedOut: "clock.badge.exclamationmark"
        }
    }

    private static func statusColor(_ entry: ConversationRunStore.Entry) -> PlatformColor {
        switch entry.status {
        case .running: ChatPalette.Platform.generating
        case .failed, .timedOut: ChatPalette.Platform.danger
        case .succeeded, .cancelled: ChatPalette.Platform.mutedText
        }
    }
}

/// 中身が `maxHeight` を超えたら、その高さで切って縦に送る（超えなければ送る枠を作らない。会話の一覧のホイールを取らない）
final class ChatCappedView: ChatFlippedView, ChatFitting {
    private let content: ChatPart
    private let maxHeight: CGFloat
    #if os(macOS)
    private var scroll: NSScrollView?
    #else
    private var scroll: UIScrollView?
    #endif

    init(_ content: ChatPart, maxHeight: CGFloat) {
        self.content = content
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) -> CGSize {
        let inner = content.fit(width: width)
        guard inner.height > maxHeight else {
            scroll?.removeFromSuperview()
            scroll = nil
            if content.superview !== self { addSubview(content) }
            content.frame.origin = .zero
            let size = CGSize(width: width, height: inner.height)
            setFrameSize(size)
            return size
        }
        #if os(macOS)
        let scroll = self.scroll ?? {
            let view = NSScrollView()
            view.drawsBackground = false
            view.contentView.drawsBackground = false
            view.hasVerticalScroller = true
            view.autohidesScrollers = true
            view.scrollerStyle = .overlay
            view.documentView = ChatFlippedView()
            addSubview(view)
            self.scroll = view
            return view
        }()
        if content.superview !== scroll.documentView { scroll.documentView?.addSubview(content) }
        content.frame.origin = .zero
        scroll.documentView?.setFrameSize(inner)
        #else
        let scroll = self.scroll ?? {
            let view = UIScrollView()
            view.scrollsToTop = false
            addSubview(view)
            self.scroll = view
            return view
        }()
        if content.superview !== scroll { scroll.addSubview(content) }
        content.frame.origin = .zero
        scroll.contentSize = inner
        #endif
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: maxHeight)
        let size = CGSize(width: width, height: maxHeight)
        setFrameSize(size)
        return size
    }
}
