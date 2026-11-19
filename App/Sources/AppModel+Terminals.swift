import Foundation
import TaskboardKit

/// 端末の接続の相手（会話の作業フォルダのシェル）。シェルの ID はマシンごとなので、マシンと組にする
struct TerminalKey: Hashable, Sendable, CustomStringConvertible {
    var machine: MachineID
    var pane: PaneID

    var description: String { "\(machine.rawValue)/\(pane.rawValue)" }
}

extension AppModel {
    /// 画面に出す端末の接続。離れて間もない端末なら前の接続と画面をそのまま使う（`TerminalShelf`）
    func takeTerminal(_ key: TerminalKey, source: any DaemonWriter) -> TerminalPaneController {
        let fontSize = SessionTextSize.current(AppPreferences.terminalFontSizeKey, default: SessionTextSize.terminalDefault)
        let controller = terminalShelf.take(key, source: source) {
            let engine = GhosttyTerminalEngine(fontSize: fontSize)
            return TerminalPaneController(key: key, source: source, engine: engine, fontSize: fontSize)
        }
        controller.setFontSize(fontSize)
        return controller
    }

    /// 画面から外れた端末を預ける。どれだけ残し、操作権を返すかは `TerminalShelf` と `TerminalPaneController.holdsControlWhileParked`
    func parkTerminal(_ controller: TerminalPaneController) {
        terminalShelf.park(controller)
    }
}
