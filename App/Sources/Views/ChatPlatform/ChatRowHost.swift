import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 一覧の 1 行の host。中身（`ChatRowContent`）から AppKit・UIKit の行を組み、中身か見た目が変わったときだけ組み直す。
/// 組むときに読んだ観察できる値（生成中の文・画像の縮小版・Run の出力）が変わったら、この行だけ組み直して一覧に知らせる
final class ChatRowHost: ChatFlippedView {
    private var content: ChatRowContent?
    private var look: ChatRowContext.Look?
    private var inputs = ChatRowInputs()
    private var context: ChatRowContext?
    private var state: ChatRowState?
    private var row: ChatPart?
    /// 組み直すたびに上がる（前に組んだ行の観察の知らせを捨てる）
    private var generation = 0
    /// 検索で今見ている発言の部品
    private(set) weak var focus: PlatformView?
    /// 中身が変わって測り直すとき
    var changed: (() -> Void)?

    /// 行の下の端からはみ出して描く分
    var overflow: CGFloat { (row as? ChatOverflowing)?.overflow ?? 0 }

    /// 中身か見た目が変わっていれば組み直す。組み直したら true
    @discardableResult
    func configure(_ content: ChatRowContent, context: ChatRowContext, state: ChatRowState) -> Bool {
        self.context = context
        self.state = state
        let inputs = context.inputs(for: content)
        let rebuilds = content != self.content || context.look != look || inputs != self.inputs
        guard rebuilds else { return false }
        self.content = content
        look = context.look
        self.inputs = inputs
        build()
        return true
    }

    /// 組み直して一覧に知らせる（開閉・観察している値の変化）
    private func rebuild() {
        build()
        changed?()
    }

    private func build() {
        guard let content, let context, let state else { return }
        #if DEBUG
        DebugCounters.hit("ChatRowHost.build")
        #endif
        generation += 1
        let generation = generation
        row?.removeFromSuperview()
        let marks = ChatRowMarks()
        let factory = ChatRowFactory(context: context, state: state, marks: marks) { [weak self] in self?.rebuild() }
        let built = withObservationTracking {
            factory.make(content)
        } onChange: { [weak self] in
            // 知らせは値が変わる前に来るので、変わった後に組み直す。Task にすると、主 actor の今の仕事（ほかの行の描き直し）が終わるまで走らない
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.rebuild()
                }
            }
        }
        addSubview(built)
        row = built
        focus = marks.focus
    }

    /// 使い回す前に中身を捨てる
    func clear() {
        generation += 1
        row?.removeFromSuperview()
        row = nil
        content = nil
        look = nil
        context = nil
        focus = nil
        changed = nil
    }

    /// `width` で並べた行の高さ（次の行との間へはみ出す分は含めない）
    func fit(width: CGFloat) -> CGFloat {
        guard let row else { return 0 }
        let size = row.fit(width: width)
        row.frame.origin = .zero
        return size.height
    }

    /// 行の部品の無い所はこの host で受けない（次の行と重なる、帯のはみ出しの所）
    #if os(macOS)
    override func hitTest(_ point: CGPoint) -> PlatformView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    #else
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// 帯がはみ出した所（行の下の端の外）も、中の部品が受けるなら受ける
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard let row else { return false }
        return row.point(inside: convert(point, to: row), with: event)
    }
    #endif
}

/// 検索で今見ている発言の周りの枠
final class ChatFocusRingView: ChatFlippedView {
    override func draw(_ dirtyRect: CGRect) {
        ChatDrawing.box(bounds, radius: Radius.control, fill: nil, stroke: ChatPalette.Platform.controlAccent.fading(0.6), lineWidth: 1.5)
    }

    #if os(macOS)
    override func hitTest(_ point: CGPoint) -> PlatformView? { nil }
    #else
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    #endif
}
