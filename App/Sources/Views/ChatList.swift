#if os(macOS)
import AppKit
import SwiftUI
import TaskboardKit

/// Mac の会話の一覧。NSScrollView の中に、見えている行と上下のゆとり（上 1,600・下 600 pt）だけを置き、外れた host は使い回す。
/// 行の中身は AppKit の部品で組む（`ChatRowFactory`。行ごとの NSHostingView は、測りとレイアウト・当たり判定・ホバーの見張りが行の数だけ重くなった）。
/// 行の高さは id ごとに控え（`RowHeights`）、測っていない行は見積もりで数える。上の行の高さが変わったり上に行が足されたりしたら、表示の上端の行が動かないように位置を直す。
/// ホバーは一覧の 1 つの tracking area で受けて、ポインタの下の部品に配る（`ChatHoverable`）
struct ChatList: NSViewRepresentable {
    typealias Item = ChatListItem

    /// 送り先の行。`token` が替わったときだけ送る
    struct Target: Equatable {
        let id: String
        /// 行の上端を表示の上端に揃える（false なら行の真ん中を表示の真ん中に）
        let alignTop: Bool
        let token: String
    }

    let items: [Item]
    let context: ChatRowContext
    let spacing: CGFloat
    let verticalInset: CGFloat
    let horizontalInset: CGFloat
    let columnWidth: CGFloat
    /// 下端に追従しているかを知らせる先。追従は一覧が持ち、人が上へ送ると外れ、人が下端まで戻すと付く（`ChatBottomPin`）
    @Binding var pinned: Bool
    /// 替わったら下端へ送って追従を付ける（［最新のメッセージへ］と、履歴を読み込んだとき）
    let bottomRequest: Int
    let target: Target?
    /// 前・次の人の発言へ送る要求。表示の上端から数える
    var jump = ChatJumpRequest()
    /// 一番上の行が見えたとき（古いページを読む）。一番上の行の id が替わるまでは 1 回だけ呼ぶ
    let reachedTop: (() -> Void)?

    func makeNSView(context: Context) -> ChatListView {
        ChatListView()
    }

    func updateNSView(_ view: ChatListView, context: Context) {
        let binding = $pinned
        view.pinnedChanged = { value in
            // 画面の更新の途中で state を書き換えない
            DispatchQueue.main.async { if binding.wrappedValue != value { binding.wrappedValue = value } }
        }
        view.update(self)
    }

    /// 中身に大きさを聞かない（外側の stack が測るたびに行を並べ直さない）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatListView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// `ChatList` の AppKit の側
final class ChatListView: NSView {
    /// 表示の上と下に足して置く範囲
    static let overscanAbove: CGFloat = 1600
    static let overscanBelow: CGFloat = 600
    /// 足して置く範囲を広げる回数。行を 1 つも置いていない回と幅が変わった回は見えている範囲だけを組み、続く回ごとに広げる
    /// （会話を開いた回と右に 2 つ目を並べた回に、足す範囲まで 1 回で組むと、主スレッドが 100 ms 近く止まった）
    private static let reachSteps = 3

    private let scrollView = ChatListScrollView()
    private let document = ChatFlippedView()
    private let focusRing = ChatFocusRingView()
    private var heights = RowHeights(spacing: 0, topInset: 0, bottomInset: 0)
    private var contents: [ChatRowContent] = []
    private var context = ChatRowContext.empty
    private let state = ChatRowState()
    private var horizontalInset: CGFloat = 0
    private var columnLimit: CGFloat = 0
    private var column: CGFloat = 0
    /// 置いている行（id → host）と、使い回す host
    private var hosts: [String: ChatRowHost] = [:]
    private var spare: [ChatRowHost] = []
    /// 測り直す行（置いたばかりの行と、中身が変わった行）
    private var stale: Set<String> = []
    private var pinned = true
    private var holdsPosition = false
    private var bottomRequest: Int?
    private var targetToken: String?
    /// 前に受けた `ChatJumpRequest.token`。初めて受けたときは送らない（作り直した画面に前の要求が残っている）
    private var jumpToken: Int?
    private var reachedTop: (() -> Void)?
    /// 上端の行が見えて `reachedTop` を呼んだときの一番上の行
    private var reachedTopFor: String?
    private var lastPosition: ChatBottomPin.Position?
    private var liveScrolling = false
    private var tiling = false
    /// 足して置く範囲の今の段（`reachSteps` で全部）
    private var reach = ChatListView.reachSteps
    private var widening = false
    /// ポインタの下の部品とその親（ホバーを渡している先）
    private var hovered: [Weak] = []
    /// 最後に受けたポインタの位置（窓の座標）。窓の外なら nil
    private var pointer: CGPoint?
    var pinnedChanged: ((Bool) -> Void)?
    /// 選び始めた所と、今の端（`ChatListView` の「選ぶ」）
    private var selectionAnchor: SelectionPoint?
    private var selectionFocus: SelectionPoint?
    /// 押したまま選んでいる（送りを人の操作として扱う）
    private var selecting = false

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        focusRing.isHidden = true
        document.addSubview(focusRing)
        addSubview(scrollView)
        // 行の onHover と同じく、アプリが前面に無くてもホバーを受ける
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(_ list: ChatList) {
        context = list.context
        horizontalInset = list.horizontalInset
        columnLimit = list.columnWidth
        reachedTop = list.reachedTop
        holdsPosition = list.target != nil
        let ids = list.items.map(\.id)
        contents = list.items.map(\.content)
        if heights.spacing != Double(list.spacing) || heights.topInset != Double(list.verticalInset) {
            heights = RowHeights(spacing: Double(list.spacing), topInset: Double(list.verticalInset), bottomInset: Double(list.verticalInset))
        }
        if ids != heights.ids {
            let anchor = pinned ? nil : heights.anchor(at: offset)
            heights.setRows(ids, estimates: list.items.map { Double($0.estimate) })
            for (id, host) in hosts where heights.index(of: id) == nil {
                recycle(host)
                hosts[id] = nil
                stale.remove(id)
            }
            resizeDocument()
            if let anchor, let y = heights.offset(for: anchor) { scroll(to: CGFloat(y)) }
        }
        if bottomRequest != list.bottomRequest {
            if bottomRequest != nil {
                pinned = true
                pinnedChanged?(true)
            }
            bottomRequest = list.bottomRequest
        }
        state.setActions(context.messageActions)
        // 置いている行のうち、中身か見た目が変わった行だけ組み直す
        for (id, host) in hosts {
            if let index = heights.index(of: id), host.configure(contents[index], context: context, state: state) { stale.insert(id) }
        }
        if let target = list.target, target.token != targetToken {
            targetToken = target.token
            tile()
            scroll(toRow: target.id, alignTop: target.alignTop)
        } else if list.target == nil {
            targetToken = nil
        }
        if jumpToken != list.jump.token {
            if jumpToken != nil {
                tile()
                jump(forward: list.jump.forward)
            }
            jumpToken = list.jump.token
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        tile()
    }

    // MARK: 並べる

    /// 置いている行の枠（テスト用）
    var rowFrames: [CGRect] { hosts.values.map(\.frame) }

    /// 表示の上端にかかる行と、下端に揃っているか（テスト用）
    var topRowID: String? {
        let edge = Double(offset) + heights.spacing
        return heights.ids.indices.last { heights.top(of: $0) <= edge + 1 }.map { heights.ids[$0] }
    }
    var isAtBottom: Bool { offset >= document.frame.height - viewport - 1 }

    private var offset: CGFloat { scrollView.contentView.bounds.origin.y }
    private var viewport: CGFloat { scrollView.contentView.bounds.height }

    /// 見えている範囲の行を置いて測り、高さが変わったら位置を直して置き直す
    private func tile() {
        guard !tiling, bounds.width > 0 else { return }
        tiling = true
        defer { tiling = false }
        let available = max(bounds.width - horizontalInset * 2, 0)
        let width = min(available, columnLimit)
        if width != column {
            column = width
            heights.forgetMeasured()
            stale.formUnion(hosts.keys)
            // 測り直すのは見えている行だけにし、足す範囲の行は外して続く回で置き直す
            reach = 0
        }
        if hosts.isEmpty { reach = 0 }
        let share = CGFloat(reach) / CGFloat(Self.reachSteps)
        for _ in 0..<6 {
            let anchor = pinned && !holdsPosition ? nil : heights.anchor(at: offset)
            let range = heights.rows(in: Double(offset - Self.overscanAbove * share)...Double(offset + viewport + Self.overscanBelow * share))
            place(range)
            var moved = false
            for index in range where stale.contains(heights.ids[index]) {
                let id = heights.ids[index]
                guard let host = hosts[id] else { continue }
                stale.remove(id)
                if heights.setMeasured(id, Double(host.fit(width: column))) { moved = true }
            }
            resizeDocument()
            if pinned && !holdsPosition {
                scroll(to: document.frame.height - viewport)
            } else if moved, let anchor, let y = heights.offset(for: anchor) {
                scroll(to: CGFloat(y))
            }
            if !moved { break }
        }
        let x = max(horizontalInset + (bounds.width - horizontalInset * 2 - column) / 2, 0)
        var focus: NSView?
        for (id, host) in hosts {
            guard let index = heights.index(of: id) else { continue }
            // 発言の操作の帯は、行の下の端から次の行との間へはみ出して描く
            let frame = CGRect(x: x, y: heights.top(of: index), width: column, height: heights.height(of: index) + host.overflow)
            if host.frame != frame { host.frame = frame }
            if let target = host.focus { focus = target }
        }
        placeFocusRing(around: focus)
        showSelection()
        noticeTop()
        if reach < Self.reachSteps, !heights.ids.isEmpty, !widening {
            // 次の回に広げる（この回の描画を先に出す）
            widening = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                widening = false
                reach = min(reach + 1, Self.reachSteps)
                needsLayout = true
            }
        }
    }

    /// `range` の行に host を置き、外れた行の host を外す
    private func place(_ range: Range<Int>) {
        let wanted = Set(range.map { heights.ids[$0] })
        for (id, host) in hosts where !wanted.contains(id) {
            recycle(host)
            hosts[id] = nil
            stale.remove(id)
        }
        for index in range where hosts[heights.ids[index]] == nil {
            let id = heights.ids[index]
            let host = spare.popLast() ?? ChatRowHost()
            host.changed = { [weak self] in self?.rowChanged(id) }
            document.addSubview(host, positioned: .below, relativeTo: focusRing)
            host.configure(contents[index], context: context, state: state)
            hosts[id] = host
            stale.insert(id)
        }
    }

    private func recycle(_ host: ChatRowHost) {
        host.removeFromSuperview()
        host.clear()
        if spare.count < 24 { spare.append(host) }
    }

    /// 行の中身が変わった（開閉した・観察している値が変わった）。測り直してホバーを配り直す
    private func rowChanged(_ id: String) {
        guard hosts[id] != nil else { return }
        stale.insert(id)
        needsLayout = true
        updateHover()
    }

    private func resizeDocument() {
        let height = max(CGFloat(heights.totalHeight), viewport)
        let size = CGSize(width: bounds.width, height: height)
        if document.frame.size != size { document.setFrameSize(size) }
    }

    /// 検索で今見ている発言の周りの枠（`padding(-Space.inline)` の角丸）
    private func placeFocusRing(around view: NSView?) {
        guard let view else {
            focusRing.isHidden = true
            return
        }
        let frame = view.convert(view.bounds, to: document).insetBy(dx: -Space.inline, dy: -Space.inline)
        if focusRing.frame != frame { focusRing.frame = frame }
        focusRing.isHidden = false
    }

    // MARK: ホバー

    override func mouseMoved(with event: NSEvent) {
        pointer = event.locationInWindow
        updateHover()
    }

    override func mouseEntered(with event: NSEvent) {
        pointer = event.locationInWindow
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        updateHover()
    }

    /// ポインタの下の部品と、その親のうちホバーを受けるものに知らせる
    private func updateHover() {
        var next: [NSView] = []
        if let pointer, let clip = document.superview, bounds.contains(convert(pointer, from: nil)) {
            var view = document.hitTest(clip.convert(pointer, from: nil))
            while let current = view, current !== document {
                if current is ChatHoverable { next.append(current) }
                view = current.superview
            }
        }
        for entry in hovered {
            guard let view = entry.view, !next.contains(where: { $0 === view }) else { continue }
            (view as? ChatHoverable)?.setHovered(false)
        }
        for view in next where !hovered.contains(where: { $0.view === view }) {
            (view as? ChatHoverable)?.setHovered(true)
        }
        hovered = next.map(Weak.init)
    }

    private struct Weak {
        weak var view: NSView?
    }

    // MARK: 送る

    private func scroll(to y: CGFloat) {
        let target = min(max(y, 0), max(document.frame.height - viewport, 0)).rounded()
        guard target != offset else { return }
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// 表示の上端より上（前）か下（次）の、いちばん近い人の発言の行を上端に揃える。次が無ければ下端へ戻して追従を付ける
    private func jump(forward: Bool) {
        let edge = Double(offset) + heights.spacing
        let prompts = contents.indices.filter { index in
            if case .row(let row) = contents[index] { row.isPrompt } else { false }
        }
        let next = forward ? prompts.first { heights.top(of: $0) > edge + 1 } : prompts.last { heights.top(of: $0) < edge - 1 }
        guard let next else {
            guard forward else { return }
            pinned = true
            pinnedChanged?(true)
            scroll(to: document.frame.height - viewport)
            return
        }
        if pinned {
            pinned = false
            pinnedChanged?(false)
        }
        scroll(toRow: heights.ids[next], alignTop: true)
    }

    private func scroll(toRow id: String, alignTop: Bool) {
        guard let index = heights.index(of: id) else { return }
        let top = CGFloat(heights.top(of: index))
        if alignTop {
            scroll(to: top - CGFloat(heights.spacing))
        } else {
            scroll(to: top + CGFloat(heights.height(of: index)) / 2 - viewport / 2)
        }
        needsLayout = true
    }

    @objc private func scrolled() {
        let position = ChatBottomPin.Position(offset: offset, contentHeight: document.frame.height, viewportHeight: viewport)
        if let last = lastPosition, !tiling {
            let byUser = liveScrolling || scrollView.isWheelTurning || selecting
            let next = ChatBottomPin.pinned(pinned, from: last, to: position, byUser: byUser)
            if next != pinned {
                pinned = next
                pinnedChanged?(next)
            }
        }
        lastPosition = position
        if !tiling { needsLayout = true }
        // 中身が動くとポインタの下の部品が替わる
        if pointer != nil { updateHover() }
    }

    @objc private func liveScrollStarted() { liveScrolling = true }
    @objc private func liveScrollEnded() { liveScrolling = false }

    /// 一番上の行が見えたら、一番上の行が替わるまで 1 回だけ知らせる
    private func noticeTop() {
        guard let reachedTop, let first = heights.ids.first, reachedTopFor != first, !heights.ids.isEmpty else { return }
        guard heights.rows(in: Double(offset)...Double(offset + viewport)).contains(0) else { return }
        reachedTopFor = first
        DispatchQueue.main.async { reachedTop() }
    }
}

// MARK: 選ぶ

/// 会話の一覧の選択。文（`ChatSelectableText` の片。文の部品と表の升目）と行をまたいで選ぶ。端は行の id・行の中の何番目の片か（上から、同じ高さなら左から）・何文字目かで持つ。
/// 画面の外へ流れて host を外した行も、コピーするときに組み直して文を取る（行の中身から同じ順に組まれる）
extension ChatListView {
    struct SelectionPoint: Equatable {
        let row: String
        let text: Int
        let character: Int
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.showSelection() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.showSelection() }
        return true
    }

    /// 文の無い所（行の余白・行の間）で押しても、いちばん近い文から選び始める。動かさずに離せば選択を外す
    override func mouseDown(with event: NSEvent) {
        beginSelection(with: event)
    }

    var hasSelection: Bool { ordered != nil }

    /// 文の上で押した。離すまで追い、端が表示の外へ出たら送る。二度押しは語、三度押しは文の全体を選ぶ
    func beginSelection(with event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        guard let start = point(at: event.locationInWindow) else { return clearSelection() }
        let clicks = event.clickCount
        let initial = unit(at: start, clicks: clicks)
        selectionAnchor = initial.lower
        selectionFocus = initial.upper
        showSelection()
        selecting = true
        defer { selecting = false }
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var last = event
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { last = next }
            if document.autoscroll(with: last) { layoutSubtreeIfNeeded() }
            guard let point = point(at: last.locationInWindow) else { continue }
            let reached = unit(at: point, clicks: clicks)
            let backward = order(reached.lower).lexicographicallyPrecedes(order(initial.lower))
            let anchor = backward ? initial.upper : initial.lower
            let focus = backward ? reached.lower : reached.upper
            if anchor != selectionAnchor || focus != selectionFocus {
                selectionAnchor = anchor
                selectionFocus = focus
                showSelection()
            }
        }
        if selectionAnchor == selectionFocus { clearSelection() }
    }

    /// 押した回数の単位（1 回は字の位置、2 回は語、3 回は文の全体）で、`point` を含む範囲の両端
    private func unit(at point: SelectionPoint, clicks: Int) -> (lower: SelectionPoint, upper: SelectionPoint) {
        guard clicks >= 2, let slot = slot(for: point) else { return (point, point) }
        let range = clicks == 2
            ? slot.view.wordRange(piece: slot.index, at: point.character) : NSRange(location: 0, length: (slot.piece.string as NSString).length)
        return (SelectionPoint(row: point.row, text: point.text, character: range.location),
                SelectionPoint(row: point.row, text: point.text, character: NSMaxRange(range)))
    }

    private func order(_ point: SelectionPoint) -> [Int] {
        [heights.index(of: point.row) ?? -1, point.text, point.character]
    }

    func clearSelection() {
        guard selectionAnchor != nil else { return }
        selectionAnchor = nil
        selectionFocus = nil
        showSelection()
    }

    /// 右クリックのメニュー。選んでいれば頭に［コピー］を足す
    func menu(adding menu: NSMenu?) -> NSMenu? {
        guard hasSelection else { return menu }
        let result = menu ?? NSMenu()
        if !result.items.isEmpty { result.insertItem(.separator(), at: 0) }
        result.insertItem(ChatMenu.item(.item(String(localized: "コピー"), symbol: "doc.on.doc") { [weak self] in self?.copy(nil) }), at: 0)
        return result
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 選んだ文。文どうしは改行（表の同じ行の升目はタブ）、行どうしは空の行でつなぐ
    func selectedText() -> String {
        guard let (start, end) = ordered else { return "" }
        var rows: [String] = []
        for index in start.row...end.row {
            var row = ""
            for (ordinal, piece) in rowPieces(index).enumerated() {
                let string = piece.string as NSString
                guard let range = range(row: index, text: ordinal, length: string.length) else { continue }
                if !row.isEmpty { row += piece.sameLine ? "\t" : "\n" }
                row += string.substring(with: range)
            }
            if !row.isEmpty { rows.append(row) }
        }
        return rows.joined(separator: "\n\n")
    }

    /// 始まりと終わり（行は今の並びの添字）。行が消えていれば選択を外す
    private var ordered: (start: (row: Int, text: Int, character: Int), end: (row: Int, text: Int, character: Int))? {
        guard let selectionAnchor, let selectionFocus, let a = heights.index(of: selectionAnchor.row), let f = heights.index(of: selectionFocus.row) else { return nil }
        let first = (a, selectionAnchor.text, selectionAnchor.character)
        let second = (f, selectionFocus.text, selectionFocus.character)
        return first <= second ? (first, second) : (second, first)
    }

    /// 行 `row` の `text` 番目の文（長さ `length`）にかかる範囲
    private func range(row: Int, text: Int, length: Int) -> NSRange? {
        guard let (start, end) = ordered else { return nil }
        let key = (row, text)
        guard key >= (start.row, start.text), key <= (end.row, end.text) else { return nil }
        let lower = key == (start.row, start.text) ? min(start.character, length) : 0
        let upper = key == (end.row, end.text) ? min(end.character, length) : length
        return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
    }

    /// 置いている行の文に、かかる範囲と地の色を渡す
    func showSelection() {
        if selectionAnchor != nil, ordered == nil {
            selectionAnchor = nil
            selectionFocus = nil
        }
        let emphasized = window?.isKeyWindow == true && window?.firstResponder === self
        for (id, host) in hosts {
            guard let index = heights.index(of: id) else { continue }
            var ordinal = 0
            for view in Self.selectables(in: host) {
                let ranges = view.selectionPieces.map { piece in
                    defer { ordinal += 1 }
                    return range(row: index, text: ordinal, length: (piece.string as NSString).length)
                }
                view.showSelection(ranges, emphasized: emphasized)
            }
        }
    }

    /// 行の文の片（読む順）。host を外した行は、同じ幅で組み直して取る
    private func rowPieces(_ index: Int) -> [ChatSelectionPiece] {
        if let host = hosts[heights.ids[index]] { return Self.slots(in: host).map(\.piece) }
        let host = ChatRowHost()
        host.configure(contents[index], context: context, state: state)
        _ = host.fit(width: column)
        defer { host.clear() }
        return Self.slots(in: host).map(\.piece)
    }

    /// 片を持つ部品と、その中の何番目の片か。`frame` は host の座標
    private struct Slot {
        let view: any ChatSelectableText
        let index: Int
        let piece: ChatSelectionPiece
        let frame: CGRect
    }

    private func slot(for point: SelectionPoint) -> Slot? {
        guard let host = hosts[point.row] else { return nil }
        let slots = Self.slots(in: host)
        return slots.indices.contains(point.text) ? slots[point.text] : nil
    }

    /// 行の中の片を持つ部品（片の並びは `slots` と同じ順になる）
    private static func selectables(in host: NSView) -> [any ChatSelectableText] {
        var found: [any ChatSelectableText] = []
        func walk(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                if let text = child as? any ChatSelectableText { found.append(text) } else { walk(child) }
            }
        }
        walk(host)
        return found
    }

    /// 行の中の片を、上から（同じ高さなら左から）並べる
    private static func slots(in host: NSView) -> [Slot] {
        let slots = selectables(in: host).flatMap { view in
            view.selectionPieces.enumerated().map { Slot(view: view, index: $0, piece: $1, frame: view.convert($1.frame, to: host)) }
        }
        return slots.sorted { ($0.frame.minY.rounded(), $0.frame.minX) < ($1.frame.minY.rounded(), $1.frame.minX) }
    }

    /// 窓の座標の `location` に近い文の位置。行と行の間なら上の行、文の無い行なら上の行の文の末尾
    private func point(at location: CGPoint) -> SelectionPoint? {
        guard !heights.ids.isEmpty else { return nil }
        let y = Double(document.convert(location, from: nil).y)
        let below = heights.ids.indices.last { heights.top(of: $0) <= y } ?? 0
        for index in stride(from: below, through: 0, by: -1) {
            guard let host = hosts[heights.ids[index]] else { return nil }
            let slots = Self.slots(in: host)
            guard let last = slots.last else { continue }
            if index != below {
                return SelectionPoint(row: heights.ids[index], text: slots.count - 1, character: (last.piece.string as NSString).length)
            }
            let local = host.convert(location, from: nil)
            let ordinal = slots.firstIndex { $0.frame.contains(local) } ?? slots.lastIndex { $0.frame.minY <= local.y } ?? 0
            let slot = slots[ordinal]
            let character = slot.view.characterIndex(piece: slot.index, at: slot.view.convert(location, from: nil))
            return SelectionPoint(row: heights.ids[index], text: ordinal, character: character)
        }
        return nil
    }
}

extension ChatListView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? hasSelection : true
    }
}

/// ホイールを回した直後かを持つ NSScrollView（ホイールは phase が付かず、live scroll の知らせも来ない）
final class ChatListScrollView: NSScrollView {
    private var wheeledAt: TimeInterval = 0

    var isWheelTurning: Bool { ProcessInfo.processInfo.systemUptime - wheeledAt < 0.25 }

    override func scrollWheel(with event: NSEvent) {
        wheeledAt = ProcessInfo.processInfo.systemUptime
        super.scrollWheel(with: event)
    }
}
#endif
