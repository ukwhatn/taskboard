import Foundation
import TaskboardKit

/// 画面を離れた端末を、しばらく接続したまま持っておく。切り替えて戻ったときに、接続と操作権の取り直しから始めず、前の画面をすぐ出す。
///
/// 持つのは `keepAlive` の間（nil なら時間で切らない）と、新しい順に `limit` 個まで。過ぎたら `stop()` で接続を切り、数から外れる。
/// Mac は操作権を持ったまま時間で切らずに持つ（`TerminalPaneController.holdsControlWhileParked`）
@MainActor
final class TerminalShelf {
    #if os(macOS)
    static let keepAlive: Duration? = nil
    static let limit = 8
    #else
    static let keepAlive: Duration? = .seconds(30)
    static let limit = 4
    #endif

    private struct Parked {
        let controller: TerminalPaneController
        let expiry: Task<Void, Never>?
    }

    private let keepAlive: Duration?
    private let limit: Int
    /// 古いものが前
    private var parked: [Parked] = []

    init(keepAlive: Duration? = TerminalShelf.keepAlive, limit: Int = TerminalShelf.limit) {
        self.keepAlive = keepAlive
        self.limit = limit
    }

    /// 持っている端末が使えればそれを渡し、無ければ `make` で作る
    func take(_ key: TerminalKey, source: any DaemonWriter, make: () -> TerminalPaneController) -> TerminalPaneController {
        if let index = parked.lastIndex(where: { $0.controller.key == key }) {
            let entry = parked.remove(at: index)
            entry.expiry?.cancel()
            // 接続し直した daemon（別の source）や、中継が終わった pane は持ち越さない
            if entry.controller.uses(source), entry.controller.isReusable { return entry.controller }
            entry.controller.stop()
        }
        return make()
    }

    /// 画面から外れた端末を預かる。同じセッションの前の分と、数を超えた古い分は止める
    func park(_ controller: TerminalPaneController) {
        guard controller.isReusable else { return controller.stop() }
        for entry in parked where entry.controller.key == controller.key && entry.controller !== controller { stop(entry) }
        parked.removeAll { $0.controller.key == controller.key }
        controller.park()
        let expiry = keepAlive.map { keepAlive in
            Task { [weak self] in
                try? await Task.sleep(for: keepAlive)
                guard !Task.isCancelled else { return }
                self?.expire(controller)
            }
        }
        parked.append(Parked(controller: controller, expiry: expiry))
        while parked.count > limit { stop(parked.removeFirst()) }
    }

    var parkedKeys: [TerminalKey] { parked.map(\.controller.key) }

    private func expire(_ controller: TerminalPaneController) {
        guard let index = parked.firstIndex(where: { $0.controller === controller }) else { return }
        parked.remove(at: index).controller.stop()
    }

    private func stop(_ entry: Parked) {
        entry.expiry?.cancel()
        entry.controller.stop()
    }
}
