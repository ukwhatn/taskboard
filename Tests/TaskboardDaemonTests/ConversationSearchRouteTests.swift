import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("会話の全文検索の口：GET /v1/conversations/search")
struct ConversationSearchRouteTests {
    private let token = "daemon-token"
    private let machine = MachineID(rawValue: "m-test")

    private func serve(search: Bool = true, _ body: @escaping @Sendable (any TestClientProtocol, ConversationRecord) async throws -> Void) async throws {
        let store = try Store(inMemory: machine)
        let record = try store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: "s1", cwd: "/w", runner: .none))
        try store.addConversationSearch(
            conversation: record.id, source: Store.ConversationSearchSource(source: "s1", position: 10, end: nil, mark: nil),
            entries: [Store.ConversationSearchEntry(messageID: "u1#0", role: .user, at: Date(timeIntervalSince1970: 1_792_000_000), text: "索引を作る", position: 0)])
        var dependencies = APIServer.Dependencies()
        dependencies.store = store
        if search {
            dependencies.conversationSearch = ConversationSearchIndex(
                store: store, sources: .init(segments: { _ in [] }, codexHistory: { _, _ in throw CancellationError() }))
        }
        let app = APIServer.application(state: DaemonState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t")), token: token, port: 0, dependencies: dependencies)
        try await app.test(.router) { client in try await body(client, record) }
    }

    private func get(_ client: some TestClientProtocol, _ query: String) async throws -> TestResponse {
        try await client.execute(uri: "/v1/conversations/search?\(query)", method: .get, headers: [.authorization: "Bearer \(token)"])
    }

    @Test("語に合う会話を返す（`conversations/{id}` に取られない）。索引を作り終える前は indexing")
    func returnsHits() async throws {
        try await serve { client, record in
            let response = try await get(client, "q=%E7%B4%A2%E5%BC%95&limit=5")
            #expect(response.status == .ok)
            let decoded = try WireJSON.decoder().decode(ConversationSearchResponse.self, from: response.body)
            #expect(decoded.hits.map(\.conversationID) == [record.id])
            #expect(decoded.hits.first?.messageID == "u1#0" && decoded.hits.first?.role == .user)
            #expect(decoded.indexing)
            let empty = try WireJSON.decoder().decode(ConversationSearchResponse.self, from: try await get(client, "q=").body)
            #expect(empty.hits.isEmpty)
        }
    }

    @Test("作り直しの要求は daemon の token で 204（`conversations/{id}/…` に取られない）。要求の後は indexing")
    func rebuild() async throws {
        try await serve { client, _ in
            let response = try await client.execute(uri: "/v1/conversations/search/rebuild", method: .post, headers: [.authorization: "Bearer \(token)"])
            #expect(response.status == .noContent)
            let after = try WireJSON.decoder().decode(ConversationSearchResponse.self, from: try await get(client, "q=%E7%B4%A2%E5%BC%95").body)
            #expect(after.indexing)
        }
    }

    @Test("limit の範囲の外と、長すぎる語は 400。索引が無ければ 503")
    func rejects() async throws {
        try await serve { client, _ in
            for query in ["q=a&limit=0", "q=a&limit=101", "q=\(String(repeating: "a", count: 201))"] {
                let status = try await get(client, query).status
                #expect(status == .badRequest, "\(query)")
            }
        }
        try await serve(search: false) { client, _ in
            let status = try await get(client, "q=a").status
            #expect(status == .serviceUnavailable)
        }
    }
}
