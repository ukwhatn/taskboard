import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("APIServer")
struct APIServerTests {
    private func makeState() -> DaemonState {
        DaemonState(
            machine: MachineInfo(
                id: MachineID(rawValue: "m-test"), name: "test-mac", daemonVersion: "test"))
    }

    @Test("health は認証なしで返り、state は token が要る")
    func authGate() async throws {
        let state = makeState()
        let app = APIServer.application(state: state, token: "secret-token", port: 0, dependencies: testDependencies)
        try await app.test(.router) { client in
            let health = try await client.execute(uri: "/v1/health", method: .get)
            #expect(health.status == .ok)
            let info = try WireJSON.decoder().decode(HealthInfo.self, from: health.body)
            #expect(info.machineID.rawValue == "m-test")

            let noToken = try await client.execute(uri: "/v1/state", method: .get)
            #expect(noToken.status == .unauthorized)

            let wrong = try await client.execute(uri: "/v1/state", method: .get, headers: [.authorization: "Bearer secret-tokem"])
            #expect(wrong.status == .unauthorized)
            #expect(wrong.headers[HTTPField.Name(DaemonAuthHeader.name)!] == DaemonAuthHeader.invalid)

            let notBearer = try await client.execute(uri: "/v1/state", method: .get, headers: [.authorization: "secret-token"])
            #expect(notBearer.status == .unauthorized)

            let ok = try await client.execute(uri: "/v1/state", method: .get, headers: [.authorization: "Bearer secret-token"])
            #expect(ok.status == .ok)
            let snapshot = try WireJSON.decoder().decode(StateSnapshot.self, from: ok.body)
            #expect(snapshot.machine.name == "test-mac")
        }
    }

    @Test("token の無い・違う WebSocket は 101 の後、データ無しで 4401 で閉じる")
    func websocketAuthGate() async throws {
        let state = makeState()
        let app = APIServer.application(state: state, token: "secret-token", port: 0, dependencies: testDependencies)
        try await app.test(.live) { client in
            let port = try #require(client.port)
            // hummingbird-websocket 2.8.0 は upgrade の判定で断ると印の無い 400 しか返せないので、101 の後に 4401 で閉じる
            for (path, token) in [("/v1/stream", nil), ("/v1/stream", "secret-tokem"), ("/v1/terminal/w1:p1", "secret-tokem"), ("/v1/terminal/w1:p1", nil)] {
                var request = URLRequest(url: URL(string: "ws://localhost:\(port)\(path)")!)
                if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let task = URLSession.shared.webSocketTask(with: request)
                task.resume()
                // 閉じなければ 10 秒でこちらから切る（close code は 4401 にならない）
                let watchdog = Task {
                    try? await Task.sleep(for: .seconds(10))
                    if !Task.isCancelled { task.cancel(with: .goingAway, reason: nil) }
                }
                var messages = 0
                while (try? await task.receive()) != nil { messages += 1 }
                watchdog.cancel()
                #expect((task.response as? HTTPURLResponse)?.statusCode == 101, "\(path)")
                #expect(messages == 0, "\(path)")
                #expect(task.closeCode.rawValue == Int(DaemonAuthHeader.revokedCloseCode), "\(path)")
            }
            // WebSocket でない経路は upgrade を名乗っても認証で止まり、handler は動かない（失敗した upgrade は 400）
            let notSocket = try await client.execute(
                uri: "/v1/state", method: .get,
                headers: [.upgrade: "websocket", .connection: "Upgrade", .secWebSocketVersion: "13", .secWebSocketKey: "dGhlIHNhbXBsZSBub25jZQ=="])
            #expect(notSocket.status.code / 100 == 4, "status \(notSocket.status)")
        }
    }

    @Test("DaemonState の変化は購読者に届く")
    func stateBroadcast() async throws {
        let state = makeState()
        let (id, stream) = await state.subscribe()
        let conversation = Conversation(
            id: "c1", machine: MachineID(rawValue: "m-test"), taskNumber: nil, agentSessionID: "s1", cwd: "/repo", runner: .host, phase: .idle,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        await state.upsert(conversation)
        await state.removeConversation(id: "c1")
        await state.setAgentHost(AgentHostInfo(connected: true))
        await state.unsubscribe(id)

        var received: [DaemonEvent] = []
        for await event in stream { received.append(event) }
        #expect(received == [.conversationUpdated(conversation), .conversationRemoved(conversation.key), .machineUpdated(await state.machineInfo())])
    }
}
