import SwiftUI
import TaskboardKit

/// 端末。画面に出たときに `AppModel.takeTerminal` から接続を受け取り（離れて間もないセッションは前の接続と画面のまま）、離れたら預ける。
/// 接続と端末エミュレータは init で作らない。親が描き直されるたびに init は呼ばれ、作った分は使われずに捨てられる
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    let key: TerminalKey
    let source: any DaemonWriter
    /// シェルが終わって（exit して）daemon が接続を閉じたとき
    var ended: () -> Void = {}

    @State private var controller: TerminalPaneController?

    var body: some View {
        Group {
            if let controller {
                TerminalPaneContent(controller: controller)
            } else {
                Color.clear
            }
        }
        .onAppear {
            let controller = model.takeTerminal(key, source: source)
            self.controller = controller
            controller.attach()
        }
        .onDisappear {
            if let controller { model.parkTerminal(controller) }
        }
        .onChange(of: controller?.phase) { _, phase in
            if case .closed(.paneNotFound, _) = phase { ended() }
        }
    }
}

/// 端末本体。接続状態の帯と、操作の引き継ぎ確認を持つ。
/// 操作中は枠いっぱいに描いて pane をその大きさに合わせ、表示のみの間は pane の実寸のまま枠の中央に置く（入り切らなければ縮める）
private struct TerminalPaneContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let controller: TerminalPaneController

    @State private var actionsOwner = UUID()
    @AppStorage(AppPreferences.terminalFontSizeKey) private var fontSize = SessionTextSize.terminalDefault

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            GeometryReader { geometry in
                surface(in: geometry.size)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onAppear { reportGrid(geometry.size) }
                    .onChange(of: geometry.size) { _, size in reportGrid(size) }
                    .onChange(of: controller.cellSize.map { [$0.width, $0.height] }) { _, _ in reportGrid(geometry.size) }
            }
        }
        .onAppear {
            model.present(sessionActions: actions)
            model.activeTerminal = controller
            controller.engine.requestFocus()
        }
        .onDisappear {
            model.withdraw(sessionActions: actions)
            if model.activeTerminal === controller { model.activeTerminal = nil }
        }
        .onChange(of: fontSize) { _, size in controller.setFontSize(size) }
    }

    private var actions: SessionViewActions {
        let key = AppPreferences.terminalFontSizeKey, value = SessionTextSize.terminalDefault
        return SessionViewActions(
            owner: actionsOwner,
            find: {},
            zoomIn: { SessionTextSize.adjust(key, default: value, by: SessionTextSize.step) },
            zoomOut: { SessionTextSize.adjust(key, default: value, by: -SessionTextSize.step) },
            zoomReset: { SessionTextSize.adjust(key, default: value, by: nil) })
    }

    /// 表示のみと操作中で view の形を変えない（if で分けると、切り替わるたびに端末の view と surface が作り直され、画面とエミュレータのモードが消える）
    private func surface(in available: CGSize) -> some View {
        let fixed = fixedSize()
        let scale = fixed.map { min(1, available.width / $0.width, available.height / $0.height) } ?? 1
        return controller.engine.makeView()
            #if os(iOS)
            .background(Color.black.opacity(0.0001))  // 端末のタップで focus を取れるように当たり判定を持たせる
            .onTapGesture { controller.engine.requestFocus() }
            #endif
            .frame(width: fixed?.width, height: fixed?.height)
            .scaleEffect(scale)
            .frame(width: available.width, height: available.height)
            .background(Color.secondary.opacity(fixed == nil ? 0 : 0.06))
    }

    /// 表示のみの間は pane の実寸。操作中・操作権を取りに行っている間・大きさがまだ分からない間は nil（枠いっぱい）
    private func fixedSize() -> CGSize? {
        guard controller.phase != .controlling, !controller.awaitingControl, let frame = controller.frameSize, let cell = controller.cellSize else { return nil }
        let padding = controller.engine.padding
        // 半セル足す。ghostty は格子を切り捨てで数えるので、pt と px の端数でちょうどの幅だと 1 列足りなくなる（iPad で実測）
        return CGSize(
            width: (CGFloat(frame.cols) + 0.5) * cell.width + padding.width * 2,
            height: (CGFloat(frame.rows) + 0.5) * cell.height + padding.height * 2)
    }

    private func reportGrid(_ size: CGSize) {
        guard let cell = controller.cellSize, cell.width > 0, cell.height > 0 else { return }
        let padding = controller.engine.padding
        controller.setAvailableGrid(
            cols: Int((size.width - padding.width * 2) / cell.width),
            rows: Int((size.height - padding.height * 2) / cell.height))
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: Space.row) {
            Group {
                switch controller.phase {
                case .connecting:
                    Label("接続しています…", systemImage: "antenna.radiowaves.left.and.right")
                case .observing where controller.awaitingControl:
                    Label("接続しています…", systemImage: "antenna.radiowaves.left.and.right")
                case .observing:
                    Label("表示のみ", systemImage: "eye")
                case .controlling:
                    Label("操作中", systemImage: "keyboard")
                case .busy:
                    Label("ほかのデバイスで操作中", systemImage: "person.2")
                case .closed(let reason, _):
                    Label(closedLabel(reason), systemImage: "xmark.circle")
                case .disconnected:
                    Label(UserFacingError.reconnecting, systemImage: "wifi.slash")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let notice = controller.notice {
                Text(notice).font(.callout).foregroundStyle(.orange).lineLimit(2)
                Button("閉じる") { controller.dismissNotice() }.buttonStyle(.borderless).font(.callout).hitTarget()
            }
            Spacer()
            if controller.phase == .busy {
                Button("引き継ぐ") { controller.takeOver() }.font(.callout)
            }
            if controller.phase == .controlling {
                Button("操作を返す") { controller.release() }.buttonStyle(.borderless).font(.callout).hitTarget()
            }
        }
        .padding(.horizontal, inset)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private func closedLabel(_ reason: TerminalCloseReason) -> String {
        switch reason {
        case .paneNotFound: String(localized: "このセッションは終了しました")
        case .queueOverflow: String(localized: "出力が多いため、接続し直しています…")
        }
    }
}
