import Foundation
import Hummingbird
import TaskboardKit

/// セッションの紐づけを外す。結ぶ `POST /v1/sessions/link` と同じく、daemon の token（MCP と CLI）と端末の token（アプリ）の両方で通す。
/// pane は止めない。外した後のタスク（会話ごと外れたら、行が消えたほかのタスクも）は Store の流れから `task.updated` で配る
extension APIServer {
    static func registerSessionLinkRoutes(v1: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.delete("tasks/{number}/sessions/{session_id}") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            let raw = try context.parameters.require("session_id")
            let sessionID = raw.removingPercentEncoding ?? raw
            guard let store = dependencies.store else { throw APIError.unavailable("store が無い") }
            // host の会話の ID なら会話ごと外れ、ほかのタスクに残った行も消える
            return try json(try mapStoreError { try store.unlinkSession(task: number, sessionID: sessionID) }, encoder)
        }
    }
}
