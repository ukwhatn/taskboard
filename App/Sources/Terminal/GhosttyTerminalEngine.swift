import Combine
import Foundation
import GhosttyTerminal
import OSLog
import SwiftUI
import TaskboardKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// libghostty の in-memory backend。テーマは既定（light: Alabaster / dark: Afterglow）で、`TerminalSurfaceView` が
/// SwiftUI の colorScheme に追従する。
@MainActor
final class GhosttyTerminalEngine: TerminalEngine {
    var onInput: ((Data) -> Void)?
    var onResize: ((_ cols: Int, _ rows: Int) -> Void)?
    var onCellSizeChange: (() -> Void)?
    private var surfaceSizeSubscription: AnyCancellable?
    private var bellSubscription: AnyCancellable?
    private(set) var gridSize: (cols: Int, rows: Int)?
    let padding = CGSize(width: 4, height: 2)
    private let session: InMemoryTerminalSession
    let state: TerminalViewState
    /// SwiftUI が端末の view を作り直すたびに同じ platform view を渡す。新しい view には新しい surface が作られ、
    /// `TerminalShelf` に預けて戻ったときに前の画面が消えるため（surface は view と一緒に解放される）
    private var platformView: TerminalView?
    private static let logger = Logger(subsystem: "uk.whatn.taskboard", category: "terminal")

    init(fontSize: Double = SessionTextSize.terminalDefault) {
        let box = CallbackBox()
        session = InMemoryTerminalSession(
            // 貼り付けは複数の書き出しに分かれて来るので、届いた順に渡す（Task を 1 つずつ作ると順が保証されない）
            write: { data in
                DispatchQueue.main.async { MainActor.assumeIsolated { box.engine?.onInput?(data) } }
            },
            resize: { viewport in
                Task { @MainActor in box.engine?.viewportDidChange(cols: Int(viewport.columns), rows: Int(viewport.rows)) }
            },
            suppressesPixelOnlyResizes: true)
        let settings = TerminalSettings()
        state = TerminalViewState(theme: settings.theme, terminalConfiguration: settings.apply(to: Self.configuration))
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: Float(fontSize), resizeThrottleMilliseconds: 96)
        box.engine = self
        state.makePlatformView = { [weak self] in
            if let view = self?.platformView { return view }
            #if os(macOS)
            let view = TaskboardTerminalView(frame: .zero)
            #else
            let view = TerminalView(frame: .zero)
            #endif
            self?.platformView = view
            return view
        }
        surfaceSizeSubscription = state.$surfaceSize
            .removeDuplicates { $0?.cellWidthPixels == $1?.cellWidthPixels && $0?.cellHeightPixels == $1?.cellHeightPixels }
            .sink { [weak self] _ in Task { @MainActor in self?.onCellSizeChange?() } }
        // libghostty はベルを鳴らさず、埋め込む側に知らせるだけ（`lastBellAt`）
        if settings.bell {
            bellSubscription = state.$lastBellAt.dropFirst().compactMap { $0 }
                .sink { _ in Task { @MainActor in Self.ringBell() } }
        }
    }

    private static func ringBell() {
        #if os(macOS)
        NSSound.beep()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    // `keybind = clear` で ghostty の既定の割り当てを外す。⌘+ / ⌘- / ⌘0 / ⌘F / ⌘J をアプリのメニューが受けるため。
    // 個別に unbind しないのは、キー名を 1 つでも誤ると設定全体が棄却されるから。コピー・貼り付け・全選択だけ戻す
    private static let configuration = TerminalConfiguration()
        .custom("keybind", "clear")
        .custom("keybind", "super+c=copy_to_clipboard")
        .custom("keybind", "super+v=paste_from_clipboard")
        .custom("keybind", "super+a=select_all")
        .custom("window-padding-x", "4")
        .custom("window-padding-y", "2")

    func feed(_ data: Data) {
        session.receive(data)
    }

    func viewportText() -> String? {
        session.readViewportText()
    }

    func paste(_ text: String) {
        state.paste(text: text)
    }

    func requestFocus() {
        state.requestFocus()
    }

    func resignFocus() {
        #if os(macOS)
        if let view = state.attachedPlatformView, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        #else
        state.attachedPlatformView?.resignFirstResponder()
        #endif
    }

    func setFontSize(_ points: Double) {
        // configuration.fontSize を変えると surface が作り直されて画面が消えるので、binding で変える
        if !state.performBindingAction("set_font_size:\(Int(points.rounded()))") {
            Self.logger.warning("set_font_size was not performed")
        }
    }

    var cellSize: CGSize? {
        guard let metrics = state.surfaceSize, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return nil }
        let scale = Self.backingScale(state.attachedPlatformView)
        return CGSize(width: CGFloat(metrics.cellWidthPixels) / scale, height: CGFloat(metrics.cellHeightPixels) / scale)
    }

    func makeView() -> AnyView {
        AnyView(TerminalSurfaceView(context: state))
    }

    private func viewportDidChange(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let gridSize, gridSize.cols == cols, gridSize.rows == rows { return }
        gridSize = (cols, rows)
        onResize?(cols, rows)
    }

    private static func backingScale(_ view: TerminalView?) -> CGFloat {
        #if os(macOS)
        view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        #else
        view?.window?.screen.scale ?? 2
        #endif
    }

    func invalidate() {
        platformView = nil
    }

    /// セッションのコールバックは `@Sendable` で self を捕まえられないので、弱参照の箱を挟む。
    private final class CallbackBox: @unchecked Sendable {
        weak var engine: GhosttyTerminalEngine?
    }
}
