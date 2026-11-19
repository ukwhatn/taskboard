import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing
import TestSupport

@testable import TaskboardDaemon

@Suite("通知の登録・テストの口")
struct PushRoutesTests {
    private let machine = MachineID(rawValue: "m-push-api")
    private let daemonToken = "daemon-token"

    private struct Fixture {
        let state: DaemonState
        let store: Store
        let keys: TestKeys
        let fake: FakeAPNs
        let dependencies: APIServer.Dependencies
        func remove() {
            keys.remove()
        }
    }

    private func makeFixture(installKey: Bool = true, keyEnvironment: PushEnvironment? = nil) async throws -> Fixture {
        let state = DaemonState(machine: MachineInfo(id: machine, name: "test-mac", daemonVersion: "test"))
        let store = try Store(inMemory: machine)
        let keys = try TestKeys(environment: keyEnvironment, install: installKey)
        let fake = FakeAPNs()
        var dependencies = APIServer.Dependencies()
        dependencies.store = store
        dependencies.push = PushService(store: store, sender: APNsSender(keys: keys.store, transport: fake))
        for id in ["d1", "d2"] {
            try store.insertDevice(DeviceInfo(id: id, name: "iPhone \(id)", platform: .ios, createdAt: Date()), tokenHash: DeviceAuth.hash(token: "token-\(id)"))
        }
        await dependencies.deviceAuth.load(try store.devices())
        return Fixture(state: state, store: store, keys: keys, fake: fake, dependencies: dependencies)
    }

    private func app(_ fixture: Fixture) -> APIServer.App {
        APIServer.application(state: fixture.state, token: daemonToken, port: 0, dependencies: fixture.dependencies)
    }

    private func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)", .contentType: "application/json"] }

    private func registrationBody(token: String = String(repeating: "a", count: 64), environment: PushEnvironment = .sandbox, topic: String = "uk.whatn.taskboard.ios")
        throws -> ByteBuffer
    {
        let body = PushRegistration(
            token: token, environment: environment, topic: topic, kinds: [.approval, .question], sound: true, machineName: "Studio", connection: "conn-1")
        return ByteBuffer(bytes: try WireJSON.encoder().encode(body))
    }

    private func register(_ client: some TestClientProtocol, as device: String, _ body: ByteBuffer) async throws -> TestResponse {
        try await client.execute(uri: "/v1/devices/current/push", method: .put, headers: bearer("token-\(device)"), body: body)
    }

    private func delivering(_ response: TestResponse) throws -> Bool {
        try WireJSON.decoder().decode(PushRegistrationResponse.self, from: response.body).delivering
    }

    // MARK: 登録

    @Test("daemon の token と誤ったトークン・topic は 400。端末の token なら保存し、鍵があれば delivering は true")
    func registerValidation() async throws {
        let f = try await makeFixture()
        defer { f.remove() }
        try await app(f).test(.router) { client in
            let byDaemon = try await client.execute(uri: "/v1/devices/current/push", method: .put, headers: bearer(daemonToken), body: try registrationBody())
            #expect(byDaemon.status == .badRequest)
            #expect(String(buffer: byDaemon.body).contains("端末の token で呼ぶ"))
            for body in [
                try registrationBody(token: "xyz"), try registrationBody(token: String(repeating: "a", count: 63)),
                try registrationBody(token: String(repeating: "g", count: 64)), try registrationBody(topic: ""),
            ] {
                #expect(try await register(client, as: "d1", body).status == .badRequest)
            }
            #expect(try f.store.pushTargets().isEmpty)

            let ok = try await register(client, as: "d1", try registrationBody(token: String(repeating: "A", count: 64)))
            #expect(ok.status == .ok)
            #expect(try delivering(ok))
            #expect(try WireJSON.decoder().decode(PushRegistrationResponse.self, from: ok.body).turns == true, "ターンの完了も送る版と知らせる")
            let target = try #require(try f.store.pushTargets().first)
            #expect(target.deviceID == "d1")
            #expect(target.registration.token == String(repeating: "a", count: 64))
            #expect(target.registration.kinds == [.approval, .question])
            #expect(target.registration.machineName == "Studio")
            #expect(target.registration.connection == "conn-1")
        }
    }

    @Test("鍵が無い・鍵の環境と違うときは delivering が false")
    func deliveringWithoutKey() async throws {
        let none = try await makeFixture(installKey: false)
        defer { none.remove() }
        try await app(none).test(.router) { client in
            let response = try await register(client, as: "d1", try registrationBody())
            #expect(response.status == .ok)
            #expect(try !delivering(response))
        }
        let sandboxOnly = try await makeFixture(keyEnvironment: .sandbox)
        defer { sandboxOnly.remove() }
        try await app(sandboxOnly).test(.router) { client in
            let sandbox = try await register(client, as: "d1", try registrationBody(environment: .sandbox))
            #expect(try delivering(sandbox))
            let production = try await register(client, as: "d1", try registrationBody(environment: .production))
            #expect(try !delivering(production))
        }
    }

    @Test("同じトークンを別の端末が登録したら、前の端末の登録を消す。DELETE で自分の登録を消し、端末を止めると登録も消える")
    func sameTokenAndRemoval() async throws {
        let f = try await makeFixture()
        defer { f.remove() }
        try await app(f).test(.router) { client in
            _ = try await register(client, as: "d1", try registrationBody())
            _ = try await register(client, as: "d2", try registrationBody())
            #expect(try f.store.pushTargets().map(\.deviceID) == ["d2"])

            let byDaemon = try await client.execute(uri: "/v1/devices/current/push", method: .delete, headers: bearer(daemonToken))
            #expect(byDaemon.status == .badRequest)
            let removed = try await client.execute(uri: "/v1/devices/current/push", method: .delete, headers: bearer("token-d2"))
            #expect(removed.status == .noContent)
            #expect(try f.store.pushTargets().isEmpty)

            _ = try await register(client, as: "d1", try registrationBody())
            let revoked = try await client.execute(uri: "/v1/devices/d1", method: .delete, headers: bearer(daemonToken))
            #expect(revoked.status == .noContent)
            #expect(try f.store.pushTargets().isEmpty)
            let devices = try await client.execute(uri: "/v1/devices", method: .get, headers: bearer(daemonToken))
            #expect(try WireJSON.decoder().decode([DeviceInfo].self, from: devices.body).map(\.id) == ["d2"])
        }
    }

    // MARK: テスト

    @Test("テストの通知は daemon の token だけ。鍵が無ければ 503、あれば登録のある端末ごとの結果を返す")
    func pushTest() async throws {
        let f = try await makeFixture()
        defer { f.remove() }
        try await app(f).test(.router) { client in
            _ = try await register(client, as: "d1", try registrationBody())
            let byDevice = try await client.execute(uri: "/v1/push/test", method: .post, headers: bearer("token-d1"), body: ByteBuffer(string: "{}"))
            #expect(byDevice.status == .forbidden)
            let response = try await client.execute(uri: "/v1/push/test", method: .post, headers: bearer(daemonToken), body: ByteBuffer(string: "{}"))
            #expect(response.status == .ok)
            let results = try WireJSON.decoder().decode([PushTestResult].self, from: response.body)
            #expect(results == [PushTestResult(deviceID: "d1", deviceName: "iPhone d1", status: 200, reason: nil)])
            let payload = try #require(try f.fake.payloads().first)
            let alert = try #require((payload["aps"] as? [String: Any])?["alert"] as? [String: Any])
            #expect(alert as NSDictionary == ["title": "通知のテスト", "subtitle": "Studio", "body": "アプリを閉じていても、このデバイスに通知が届きます。"])
            #expect(payload[PushPayload.connection] as? String == "conn-1")
        }
        let none = try await makeFixture(installKey: false)
        defer { none.remove() }
        try await app(none).test(.router) { client in
            let response = try await client.execute(uri: "/v1/push/test", method: .post, headers: bearer(daemonToken), body: ByteBuffer(string: "{}"))
            #expect(response.status == .serviceUnavailable)
        }
    }
}
