import Foundation
import Hummingbird
import TaskboardKit

extension APIServer {
    /// Devin のセッションの起動・様子・メッセージ（`DevinSync`）。セッションの id は `devin-<id>`・`<id>`・URL のどれでもよい
    static func registerDevinRoutes(v1: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.post("devin/sessions") { request, context in
            let body = try await request.decode(as: DevinStartRequest.self, context: context)
            guard !body.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.invalid("prompt is empty") }
            guard body.maxAcuLimit > 0 else { throw APIError.invalid("max_acu_limit must be positive") }
            if let number = body.taskNumber, try mapStoreError({ try dependencies.requireStore().task(number: number) }) == nil {
                throw APIError.notFound(.task, "task #\(number) not found")
            }
            return try json(try await mapDevinError { try await requireDevin(dependencies).start(body) }, encoder)
        }
        v1.get("devin/sessions/{id}") { _, context in
            let id = try devinID(context)
            return try json(try await mapDevinError { try await requireDevin(dependencies).detail(id) }, encoder)
        }
        v1.post("devin/sessions/{id}/message") { request, context in
            let id = try devinID(context)
            let body = try await request.decode(as: DevinMessageRequest.self, context: context)
            guard !body.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.invalid("message is empty") }
            return try json(try await mapDevinError { try await requireDevin(dependencies).message(id, body.message) }, encoder)
        }
    }

    private static func requireDevin(_ dependencies: Dependencies) throws -> DevinSync {
        guard let devin = dependencies.devin else { throw APIError.unavailable("Devin sync is not running") }
        return devin
    }

    /// Hummingbird は path の引数を decode しない
    private static func devinID(_ context: TaskboardRequestContext) throws -> String {
        let raw = try context.parameters.require("id")
        guard let id = DevinSession.id(from: raw.removingPercentEncoding ?? raw) else { throw APIError.invalid("not a Devin session id: \(raw)") }
        return id
    }

    private static func mapDevinError<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await mapStoreError(body)
        } catch let error as DevinError {
            switch error {
            case .notConfigured, .unreadableConfig, .unreadableToken: throw APIError.unavailable(error.message)
            case .notFound: throw APIError.notFound(.session, error.message)
            case .unknownAccount, .ambiguousAccount: throw APIError.invalid(error.message)
            default: throw APIError(.badGateway, .unavailable, error.message)
            }
        }
    }
}
