#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit

extension DebugServer {
    /// 会話の表示の操作と利用枠
    func respondChat(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("POST", "/session/actions"):
            // 表示のメニューの［検索…］［拡大］［縮小］［実際のサイズ］と同じ経路。今の画面が受け口を置いていなければ 409
            guard let actions = model.sessionActions else { return .json(409, ["error": "検索と拡大縮小を受ける画面を開いていない"]) }
            switch request.jsonBody?["action"] as? String {
            case "find": actions.find()
            case "zoomIn": actions.zoomIn()
            case "zoomOut": actions.zoomOut()
            case "zoomReset": actions.zoomReset()
            default: return .json(400, ["error": "action は find / zoomIn / zoomOut / zoomReset"])
            }
            return .json(200, ["ok": true, "chatFontSize": SessionTextSize.current(AppPreferences.chatFontSizeKey, default: SessionTextSize.chatDefault)])
        case ("GET", "/usage"):
            // マシンごとの表の行（バーと表が出すもの）
            let rows: [[String: Any]] = model.fleet.machines.sorted { $0.key < $1.key }.map { id, state in
                let usage = model.fleet.usage(fleetID: id) ?? UsageSnapshot()
                return [
                    "machine": state.machine?.name ?? id,
                    "rows": UsageText.rows(usage, now: Date()).map {
                        ["group": $0.group, "label": $0.label, "now": $0.now, "projected": $0.projected as Any, "reset": $0.reset]
                    },
                ]
            }
            return .json(200, ["machines": rows])
        default:
            return nil
        }
    }
}
#endif
