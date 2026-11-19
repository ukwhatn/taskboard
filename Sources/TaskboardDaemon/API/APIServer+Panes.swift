import Foundation
import Hummingbird
import TaskboardKit

/// セッションの紐づけと hook
extension APIServer {
    static func registerPaneRoutes(v1: RouterGroup<TaskboardRequestContext>, daemonOnly: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        // 端末の token でも通す。アプリの［セッションを紐づける…］が使う（hook と MCP は daemon の token）
        v1.post("sessions/link") { request, context in
            let body = try await request.decode(as: SessionLinkRequest.self, context: context)
            return try json(try await mapStoreError { try await dependencies.requireHooks().link(body) }, encoder)
        }
        daemonOnly.get("resolve") { request, _ in
            let sessionID = request.uri.queryParameters.get("session").map { String($0) }
            return try json(try await dependencies.requireHooks().resolve(agentSessionID: sessionID), encoder)
        }
        daemonOnly.post("hooks/stop") { request, context in
            let body = try await request.decode(as: HookStopRequest.self, context: context)
            return try json(try await mapStoreError { try await dependencies.requireHooks().stop(body) }, encoder)
        }
        daemonOnly.post("hooks/prompt") { request, context in
            let body = try await request.decode(as: HookPromptRequest.self, context: context)
            return try json(try await mapStoreError { try await dependencies.requireHooks().prompt(body) }, encoder)
        }
    }
}
