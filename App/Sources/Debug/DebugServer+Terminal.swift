#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// 端末
    func respondTerminal(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/terminal/text"):
            guard let terminal = model.activeTerminal else { return .json(404, ["error": "端末が開いていない"]) }
            return .json(200, ["phase": terminal.phaseLabel, "text": terminal.engine.viewportText() as Any])
        case ("POST", "/terminal/input"), ("POST", "/terminal/paste"):
            // 宛先の pane を名指しさせる。確かめている間に利用者が窓を触ると、開いている端末が人のセッションに替わることがある
            guard let terminal = model.activeTerminal else { return .json(404, ["error": "端末が開いていない"]) }
            guard let pane = request.jsonBody?["pane"] as? String, terminal.key.pane.rawValue == pane else {
                return .json(409, ["error": "開いている端末が pane と違う", "active": terminal.key.pane.rawValue])
            }
            guard let text = request.jsonBody?["text"] as? String else { return .json(400, ["error": "text が要る"]) }
            if request.path == "/terminal/paste" { terminal.pasteText(text) } else { terminal.typeText(text) }
            return .json(200, ["ok": true])
        case ("POST", "/terminal/takeover"):
            guard let terminal = model.activeTerminal else { return .json(404, ["error": "端末が開いていない"]) }
            terminal.takeOver()
            return .json(200, ["ok": true])
        case ("POST", "/terminal/release"):
            guard let terminal = model.activeTerminal else { return .json(404, ["error": "端末が開いていない"]) }
            terminal.release()
            return .json(200, ["ok": true])
        default:
            return nil
        }
    }
}
#endif
