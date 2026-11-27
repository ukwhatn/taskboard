import Foundation
import Hummingbird
import TaskboardKit

extension APIServer {
    /// 端末（アプリ）の設定の写し。アプリは設定が変わるたびと接続のたびに報告し、MCP は名前と種類を省いて値だけを書く
    static func registerClientPrefsRoutes(v1: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("clients/prefs") { _, _ in
            try json(try dependencies.requireStore().clientPrefs(), encoder)
        }
        v1.put("clients/{id}/prefs") { request, context in
            let raw = try context.parameters.require("id")
            let id = raw.removingPercentEncoding ?? raw
            let body = try await request.decode(as: ClientPrefsReport.self, context: context)
            let (prefs, changed) = try await mapStoreError { try dependencies.requireStore().mergeClientPrefs(id: id, body) }
            if changed { await state.publishClientPrefs(prefs) }
            return try json(prefs, encoder)
        }
    }
}
