import Foundation
import Hummingbird
import TaskboardKit

extension APIServer {
    /// 案件の Slack アプリの設定（アプリの案件の設定）と、受けた依頼の読み出し・返信（MCP の slack_get・slack_reply。この Mac の token だけ）
    static func registerSlackRoutes(v1: RouterGroup<TaskboardRequestContext>, daemonOnly: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("boards/{id}/slack") { _, context in
            let id = try context.parameters.require("id")
            return try json(try await mapStoreError { try await requireSlack(dependencies).info(board: id) }, encoder)
        }
        v1.put("boards/{id}/slack") { request, context in
            let id = try context.parameters.require("id")
            let body = try await request.decode(as: BoardSlackUpdate.self, context: context)
            return try json(try await mapStoreError { try await requireSlack(dependencies).update(board: id, body) }, encoder)
        }
        v1.delete("boards/{id}/slack") { _, context in
            let id = try context.parameters.require("id")
            try await requireSlack(dependencies).remove(board: id)
            return Response(status: .noContent)
        }
        v1.get("boards/{id}/slack/channels") { _, context in
            let id = try context.parameters.require("id")
            return try json(try await mapStoreError { try await requireSlack(dependencies).channels(board: id) }, encoder)
        }
        daemonOnly.get("slack/requests/{id}") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            return try json(try await mapStoreError { try await requireSlack(dependencies).detail(id: id) }, encoder)
        }
        daemonOnly.post("slack/requests/{id}/reply") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decode(as: SlackReplyRequest.self, context: context)
            return try json(try await mapStoreError { try await requireSlack(dependencies).reply(id: id, text: body.text, status: body.status ?? .done) }, encoder)
        }
    }

    static func requireSlack(_ dependencies: Dependencies) throws -> SlackBridge {
        guard let slack = dependencies.slack else { throw APIError.unavailable("Slack の連携が動いていない") }
        return slack
    }
}
