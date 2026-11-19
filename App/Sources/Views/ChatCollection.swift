#if os(iOS)
import SwiftUI
import TaskboardKit
import UIKit

/// iPhone・iPad の会話の一覧。行の中身は Mac の一覧と同じ部品（`ChatRowFactory`）で UIKit の view に組み、スクロールの位置と下端の追従は UIKit が持つ。
/// 下端へは、一覧の layout が終わった後に 1 回だけ `contentOffset` を合わせて送る（SwiftUI のスクロールの確定と通知の往復を通さない）。
/// 追従を外すのは人が上へ送ったとき、付け直すのは人が下端まで送ったときだけ（`ChatBottomPin`）
struct ChatCollection: UIViewRepresentable {
    typealias Item = ChatListItem

    /// 送る先の行。`alignTop` は組の中の発言（組の行の上端へ送る）
    struct Target: Equatable {
        var id: String
        var alignTop: Bool
    }

    let items: [Item]
    /// 行を組むのに使うもの。`look` が変わったら置いている行を組み直す
    let context: ChatRowContext
    let spacing: CGFloat
    /// 行の中身の幅の上限（真ん中に置く）
    let columnWidth: CGFloat
    let verticalInset: CGFloat
    let horizontalInset: CGFloat
    @Binding var pinned: Bool
    /// 変わったら下端へ送る（［最新のメッセージへ］、会話をまとめて受けたとき）
    let bottomRequest: Int
    /// 検索で今見ている行。あるあいだは下端へ追従しない
    let target: Target?
    /// 前・次の人の発言へ送る
    let jumpTarget: (token: Int, id: String?)
    let reachedTop: (() -> Void)?
    /// 追従が収まらずに外したとき（記録に残す）
    let followLimited: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FollowingCollectionView {
        let view = FollowingCollectionView(frame: .zero, collectionViewLayout: ChatCollectionLayout())
        view.backgroundColor = UIColor(ChatPalette.surface)
        view.allowsSelection = false
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: FollowingCollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.layout?.setSpacing(spacing, verticalInset: verticalInset, horizontalInset: horizontalInset)
        coordinator.apply(items: items, context: self.context, columnWidth: columnWidth)
        coordinator.setPinned(pinned)
        coordinator.follow(bottomRequest: bottomRequest, target: target, jump: jumpTarget)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: ChatCollection?
        private weak var view: FollowingCollectionView?
        var layout: ChatCollectionLayout? { view?.collectionViewLayout as? ChatCollectionLayout }
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var items: [String: Item] = [:]
        private var order: [String] = []
        private var context = ChatRowContext.empty
        private var columnWidth: CGFloat = .greatestFiniteMagnitude
        /// 開閉の状態と発言の操作。行を外して置き直しても残す
        private let state = ChatRowState()
        /// 行を載せているセル（使い回しの列に入ったものは `rowID` が無い）
        private let cells = NSHashTable<ChatCollectionCell>.weakObjects()
        private var pinned = true
        private var topPad = ChatTopPad()
        private var dragging = false
        private var lastPosition: ChatBottomPin.Position?
        private var bottomRequest: Int?
        private var targetID: String?
        private var jumpToken: Int?
        /// 同じ runloop の中で下端へ送った回数。layout のたびに送るので、送った位置が次の layout でまた動く往復を数えて止める
        private var followsThisTurn = 0

        func attach(_ view: FollowingCollectionView) {
            self.view = view
            let registration = UICollectionView.CellRegistration<ChatCollectionCell, String> { [weak self] cell, _, id in
                guard let self, let item = self.items[id] else { return }
                cell.chatLayout = self.layout
                self.cells.add(cell)
                cell.show(id: id, content: item.content, context: self.context, state: self.state, columnWidth: self.columnWidth)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { collection, indexPath, id in
                collection.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            view.didLayout = { [weak self] in self?.didLayout() }
        }

        func apply(items new: [Item], context: ChatRowContext, columnWidth: CGFloat) {
            guard let dataSource, let view, let layout else { return }
            let ids = new.map(\.id)
            state.setActions(context.messageActions)
            self.context = context
            if self.columnWidth != columnWidth {
                self.columnWidth = columnWidth
                layout.invalidateLayout()
            }
            var next: [String: Item] = [:]
            next.reserveCapacity(new.count)
            for item in new { next[item.id] = item }
            items = next
            // 置いている行は中身か見た目か会話から引くものが変わっていれば組み直し、測り直す（中身の比べは host がする）
            for cell in cells.allObjects {
                guard let id = cell.rowID, let item = next[id] else { continue }
                cell.show(id: id, content: item.content, context: context, state: state, columnWidth: columnWidth)
            }
            guard ids != order else { return }
            // 上に古いページが足されたら、見ていた行を同じ所に残す（下端に追従している間は下端へ送るので要らない）
            let anchor = !pinned && ids.first != order.first ? layout.anchor(atOffset: view.contentOffset.y + view.adjustedContentInset.top) : nil
            layout.setRows(ids, estimates: new.map(\.estimate))
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            order = ids
            dataSource.apply(snapshot, animatingDifferences: false)
            if let anchor, let top = layout.offset(for: anchor) { view.contentOffset.y = top - view.adjustedContentInset.top }
        }

        func setPinned(_ value: Bool) {
            guard value != pinned else { return }
            pinned = value
            layout?.followsBottom = value
            if value { view?.setNeedsLayout() }
        }

        func follow(bottomRequest request: Int, target: Target?, jump: (token: Int, id: String?)) {
            guard let view else { return }
            if bottomRequest != request {
                let first = bottomRequest == nil
                bottomRequest = request
                if !first, target == nil { setPinnedFromList(true) }
                view.setNeedsLayout()
            }
            if target?.id != targetID {
                targetID = target?.id
                if let target { scroll(to: target.id, position: target.alignTop ? .top : .centeredVertically, in: view) }
            }
            if jumpToken != jump.token {
                let first = jumpToken == nil
                jumpToken = jump.token
                guard !first else { return }
                if let id = jump.id {
                    setPinnedFromList(false)
                    scroll(to: id, position: .top, in: view)
                } else {
                    setPinnedFromList(true)
                    view.setNeedsLayout()
                }
            }
        }

        private func scroll(to id: String, position: UICollectionView.ScrollPosition, in view: UICollectionView) {
            guard let indexPath = dataSource?.indexPath(for: id) else { return }
            view.layoutIfNeeded()
            view.scrollToItem(at: indexPath, at: position, animated: false)
        }

        /// 一覧の側で追従を付け外しし、SwiftUI の状態へ返す（view の更新の中で書かないよう、次の runloop で）
        private func setPinnedFromList(_ value: Bool) {
            guard value != pinned else { return }
            pinned = value
            layout?.followsBottom = value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent?.pinned != value else { return }
                self.parent?.pinned = value
            }
        }

        private func didLayout() {
            guard let view else { return }
            #if DEBUG
            recordRowFrames(view)
            #endif
            // 中身が見えている所より短いあいだは、上に余白を足して下に寄せる（チャットは新しい発言が下に来る）
            let free = view.bounds.height - (view.adjustedContentInset.top - view.contentInset.top) - view.adjustedContentInset.bottom - view.contentSize.height
            if let pad = topPad.next(
                free: free, current: view.contentInset.top, contentHeight: view.contentSize.height, width: view.bounds.width, now: ProcessInfo.processInfo.systemUptime)
            {
                view.contentInset.top = pad
            }
            guard pinned, !dragging, !view.isDecelerating, targetID == nil else { return }
            let inset = view.adjustedContentInset
            let bottom = ChatBottomPin.bottomOffset(contentHeight: view.contentSize.height, boundsHeight: view.bounds.height, insetTop: inset.top, insetBottom: inset.bottom)
            guard abs(view.contentOffset.y - bottom) > 0.5 else { return }
            followsThisTurn += 1
            if followsThisTurn == 1 {
                DispatchQueue.main.async { [weak self] in self?.followsThisTurn = 0 }
            }
            // 1 回の layout で送った位置が、次の layout でまた動くのは行の高さの測り直しで、数回で収まる。収まらなければ追従を外して記録する
            guard followsThisTurn <= 8 else {
                setPinnedFromList(false)
                parent?.followLimited()
                return
            }
            view.contentOffset.y = bottom
        }

        private func position(_ view: UIScrollView) -> ChatBottomPin.Position {
            let inset = view.adjustedContentInset
            return ChatBottomPin.Position(
                scrollOffset: view.contentOffset.y, contentHeight: view.contentSize.height, boundsHeight: view.bounds.height, insetTop: inset.top, insetBottom: inset.bottom)
        }

        // MARK: 人が送ったとき

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            dragging = true
            lastPosition = position(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            dragging = decelerate
            if !decelerate {
                layout?.entersFromTop = false
                scrollView.setNeedsLayout()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            dragging = false
            layout?.entersFromTop = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            #if DEBUG
            // 位置だけ動いて layout が走らない回も、画面の行の位置を控える（控えが古いと、計測が行の動きを 1 段遅れて数える）
            if let view = scrollView as? UICollectionView { recordRowFrames(view) }
            #endif
            let new = position(scrollView)
            defer { lastPosition = new }
            let adjusted = layout?.takeAdjustment() ?? 0
            guard dragging || scrollView.isDecelerating, let old = lastPosition else { return }
            let moved = new.offset - old.offset - adjusted
            if abs(moved) > 0.5 { layout?.entersFromTop = moved < 0 }
            setPinnedFromList(ChatBottomPin.pinned(pinned, from: old, to: new, byUser: true))
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            setPinnedFromList(false)
            return true
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            guard let id = dataSource?.itemIdentifier(for: indexPath), case .loader(loading: false) = items[id]?.content, let reachedTop = parent?.reachedTop else { return }
            DispatchQueue.main.async(execute: reachedTop)
        }

        #if DEBUG
        private func recordRowFrames(_ view: UICollectionView) {
            var frames: [String: CGFloat] = [:]
            for indexPath in view.indexPathsForVisibleItems {
                guard let id = dataSource?.itemIdentifier(for: indexPath), let frame = view.layoutAttributesForItem(at: indexPath)?.frame else { continue }
                frames[id] = frame.minY - view.contentOffset.y
            }
            DebugRowFrames.minY = frames
        }
        #endif
    }
}

/// 会話の一覧の並べ方。縦に 1 列で、行の高さは測った値を行の id ごとに控え、測るまでは見積もりで数える（`RowHeights`）。
/// 上端が見えている所より上にある行の高さが測り直しで変わったら、見えている中身が動かないよう位置をその分だけずらす（下端に追従している間は下端へ送るのでずらさない）
final class ChatCollectionLayout: UICollectionViewLayout {
    private var heights = RowHeights(spacing: 0, topInset: 0, bottomInset: 0)
    private var estimates: [Double] = []
    private var horizontalInset: CGFloat = 0
    private var width: CGFloat = 0
    var followsBottom = true

    func setSpacing(_ spacing: CGFloat, verticalInset: CGFloat, horizontalInset: CGFloat) {
        guard heights.spacing != Double(spacing) || heights.topInset != Double(verticalInset) || self.horizontalInset != horizontalInset else { return }
        let ids = heights.ids
        heights = RowHeights(spacing: Double(spacing), topInset: Double(verticalInset), bottomInset: Double(verticalInset))
        heights.setRows(ids, estimates: estimates)
        self.horizontalInset = horizontalInset
        invalidateLayout()
    }

    /// 並びを替える。中身が変わった行も、測り直すまでは前に測った高さで数える
    func setRows(_ ids: [String], estimates: [CGFloat]) {
        self.estimates = estimates.map(Double.init)
        heights.setRows(ids, estimates: self.estimates)
        invalidateLayout()
    }

    /// 中身が変わって測り直す行
    private var stale: Set<String> = []

    func markStale(_ ids: [String]) { stale.formUnion(ids) }

    /// 人が上へ（前の発言へ）送っている間。このとき初めて測った行は上端から入ってきた行なので、上へ伸ばす
    /// （上端が表示の中にあっても、下へ伸ばすと見ていた行が押し下げられる）
    var entersFromTop = false
    /// 測った行の分だけ位置をずらした量。一覧がまだ受け取っていない分（`takeAdjustment`）
    private var adjustment: CGFloat = 0

    /// 位置の変化のうち、行の高さに合わせてこの layout がずらした分を返して控えを空にする
    func takeAdjustment() -> CGFloat {
        defer { adjustment = 0 }
        return adjustment
    }

    /// 測った高さ。測っていないか、中身が変わった後なら nil
    func measuredHeight(of id: String) -> CGFloat? {
        guard !stale.contains(id), heights.isMeasured(id), let index = heights.index(of: id) else { return nil }
        return CGFloat(heights.height(of: index))
    }

    func anchor(atOffset y: CGFloat) -> RowHeights.Anchor? { heights.anchor(at: Double(y)) }
    func offset(for anchor: RowHeights.Anchor) -> CGFloat? { heights.offset(for: anchor).map { CGFloat($0) } }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let newWidth = collectionView.bounds.width
        if newWidth != width {
            width = newWidth
            heights.forgetMeasured()
        }
    }

    override var collectionViewContentSize: CGSize { CGSize(width: width, height: CGFloat(heights.totalHeight)) }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = CGRect(x: horizontalInset, y: CGFloat(heights.top(of: index)), width: max(width - horizontalInset * 2, 1), height: CGFloat(heights.height(of: index)))
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        heights.rows(in: Double(rect.minY)...Double(max(rect.maxY, rect.minY))).map(attributes(at:))
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < heights.ids.count ? attributes(at: indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != width
    }

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes, withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        guard abs(preferred.size.height - original.size.height) > 0.5 else {
            // 見積もりどおりだった行も、測ったと控える（控えないと画面に戻るたびに測り直す）
            let index = original.indexPath.item
            if index < heights.ids.count, !heights.isMeasured(heights.ids[index]) || stale.contains(heights.ids[index]) {
                stale.remove(heights.ids[index])
                heights.setMeasured(heights.ids[index], heights.height(of: index))
            }
            return false
        }
        return true
    }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes, withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let index = original.indexPath.item
        guard index < heights.ids.count else { return context }
        let top = heights.top(of: index)
        let delta = Double(preferred.size.height) - heights.height(of: index)
        let first = !heights.isMeasured(heights.ids[index])
        stale.remove(heights.ids[index])
        heights.setMeasured(heights.ids[index], Double(preferred.size.height))
        context.contentSizeAdjustment = CGSize(width: 0, height: delta)
        // 下の行は位置が動くので、見えている分の位置も作り直させる（測った行しか作り直さないと、行が重なって描かれる）
        if let collectionView {
            let below = collectionView.indexPathsForVisibleItems.filter { $0.item > index }
            if !below.isEmpty { context.invalidateItems(at: below) }
        }
        if !followsBottom, let collectionView, top < Double(collectionView.contentOffset.y + collectionView.adjustedContentInset.top) || (entersFromTop && first) {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            adjustment += CGFloat(delta)
        }
        return context
    }

}

/// 行（`ChatRowHost`）を載せ、その高さを自分で測るセル。UIKit が測るのは flow と compositional の layout の中だけで、自前の layout ではセルが見積もりの高さのまま描かれる。
/// 測った高さが残っていて中身が変わっていない行は測らない。中身は列の幅（`columnWidth` まで）で真ん中に置く。
/// 長押しは、押した所の近い親のメニュー（`ChatMenuProviding`）を出し、無ければ押した文の［コピー］
final class ChatCollectionCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    private(set) var rowID: String?
    weak var chatLayout: ChatCollectionLayout?
    private let host = ChatRowHost()
    private let focusRing = ChatFocusRingView()
    private var columnWidth: CGFloat = .greatestFiniteMagnitude
    /// 最後に並べた幅。組み直したら nil にして並べ直す
    private var fittedWidth: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        // 発言の操作の帯は、行の下の端から次の行との間へはみ出して描く
        clipsToBounds = false
        contentView.clipsToBounds = false
        contentView.addSubview(host)
        focusRing.isHidden = true
        contentView.addSubview(focusRing)
        contentView.addInteraction(UIContextMenuInteraction(delegate: self))
        host.changed = { [weak self] in self?.contentChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 行を載せる。前と同じ中身と見た目なら組み直さない
    func show(id: String, content: ChatRowContent, context: ChatRowContext, state: ChatRowState, columnWidth: CGFloat) {
        let reused = rowID != id
        rowID = id
        if self.columnWidth != columnWidth {
            self.columnWidth = columnWidth
            fittedWidth = nil
        }
        if host.configure(content, context: context, state: state), !reused { contentChanged() } else if reused { fittedWidth = nil }
    }

    /// 中身が変わったので、測り直して並べ直す
    private func contentChanged() {
        fittedWidth = nil
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowID = nil
        fittedWidth = nil
    }

    override func invalidateIntrinsicContentSize() {
        if let rowID { chatLayout?.markStale([rowID]) }
        super.invalidateIntrinsicContentSize()
    }

    /// 置ける幅のうち行の中身に使う幅と左の端
    private func column(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let used = min(width, columnWidth)
        return (((width - used) / 2).rounded(), max(used, 1))
    }

    @discardableResult
    private func fitHost(width: CGFloat) -> CGFloat {
        let column = column(in: width)
        let height = host.fit(width: column.width)
        host.frame = CGRect(x: column.x, y: 0, width: column.width, height: height)
        fittedWidth = width
        placeFocusRing()
        return height
    }

    private func placeFocusRing() {
        guard let focus = host.focus else {
            focusRing.isHidden = true
            return
        }
        focusRing.isHidden = false
        focusRing.frame = focus.convert(focus.bounds, to: contentView).insetBy(dx: -Space.inline, dy: -Space.inline)
        focusRing.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if fittedWidth != bounds.width { fitHost(width: bounds.width) }
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        if let rowID, let height = chatLayout?.measuredHeight(of: rowID), fittedWidth != nil {
            attributes.size.height = height
            return attributes
        }
        attributes.size.height = fitHost(width: layoutAttributes.size.width).rounded(.up)
        return attributes
    }

    // MARK: 押す・長押し

    /// 行の部品の無い所は受けない（次の行と重なる、帯のはみ出しの所。一覧が送りを受ける）
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === contentView ? nil : hit
    }

    /// 帯がはみ出した所も、帯のボタンが受けるなら受ける
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || host.point(inside: convert(point, to: host), with: event)
    }

    /// 押した所の部品と、そのメニュー
    private func menuTarget(at location: CGPoint) -> (view: UIView, entries: [ChatMenuEntry])? {
        guard let hit = host.hitTest(contentView.convert(location, to: host), with: nil) ?? deepest(at: location) else { return nil }
        var current: UIView? = hit
        while let view = current, view !== host {
            if let provider = view as? ChatMenuProviding, let entries = provider.chatMenu(), !entries.isEmpty { return (view, entries) }
            current = view.superview
        }
        // メニューを持つ親が無い文は、その文の［コピー］
        current = hit
        while let view = current, view !== host {
            if let text = view as? ChatTextView, !text.string.isEmpty {
                let string = text.string
                return (text, [.item(String(localized: "コピー"), symbol: "doc.on.doc") { Pasteboard.copy(string) }])
            }
            if let grid = view as? ChatTableGridView {
                let string = grid.plainText
                return (grid, [.item(String(localized: "コピー"), symbol: "doc.on.doc") { Pasteboard.copy(string) }])
            }
            current = view.superview
        }
        return nil
    }

    /// 押せない部品（文）の上は hitTest が返さないことがあるので、位置から一番奥の view を探す
    private func deepest(at location: CGPoint) -> UIView? {
        var current: UIView = host
        while let next = current.subviews.last(where: { !$0.isHidden && $0.frame.contains(current.convert(location, from: contentView)) }) {
            current = next
        }
        return current === host ? nil : current
    }

    private var menuView: UIView?

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let target = menuTarget(at: location) else { return nil }
        menuView = target.view
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in ChatMenu.menu(target.entries) }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let view = menuView, view.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = ChatPalette.Platform.surface
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds.insetBy(dx: -Space.inline, dy: -Space.inline), cornerRadius: Radius.control)
        return UITargetedPreview(view: view, parameters: parameters)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        menuView = nil
    }
}

/// layout が終わった後に知らせる一覧（下端への追従を合わせる所）
final class FollowingCollectionView: UICollectionView {
    var didLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}
#endif

