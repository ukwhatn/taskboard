import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("ペアリングと端末の token")
struct DevicePairingTests {
    private let machine = MachineID(rawValue: "m-test")
    private let daemonToken = "daemon-token"
    private let authHeader = HTTPField.Name(DaemonAuthHeader.name)!

    private struct Fixture {
        let state: DaemonState
        let store: Store
        let clock: TestClock
        let dependencies: APIServer.Dependencies
    }

    private func makeFixture(clock: TestClock = TestClock(Date(timeIntervalSince1970: 1_800_000_000)), configure: (inout APIServer.Dependencies) -> Void = { _ in }) throws -> Fixture {
        let state = DaemonState(machine: MachineInfo(id: machine, name: "test-mac", daemonVersion: "test"))
        let store = try Store(inMemory: machine)
        var dependencies = testDependencies
        dependencies.store = store
        dependencies.deviceAuth = DeviceAuth(now: { clock.now })
        dependencies.pairings = PairingRegistry(now: { clock.now })
        configure(&dependencies)
        return Fixture(state: state, store: store, clock: clock, dependencies: dependencies)
    }

    private func app(_ fixture: Fixture) -> APIServer.App {
        APIServer.application(state: fixture.state, token: daemonToken, port: 0, dependencies: fixture.dependencies)
    }

    private func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)", .contentType: "application/json"] }

    private func body(_ json: String) -> ByteBuffer { ByteBuffer(string: json) }

    private func createCode(_ client: some TestClientProtocol) async throws -> PairingCode {
        let response = try await client.execute(uri: "/v1/pairings", method: .post, headers: bearer(daemonToken), body: body("{}"))
        #expect(response.status == .ok)
        return try WireJSON.decoder().decode(PairingCode.self, from: response.body)
    }

    private func pair(
        _ client: some TestClientProtocol, code: String, name: String = "iPhone", platform: String = "ios", source: String = "203.0.113.1"
    ) async throws -> TestResponse {
        let payload = try JSONSerialization.data(withJSONObject: ["code": code, "name": name, "platform": platform])
        return try await client.execute(
            uri: "/v1/pair", method: .post,
            headers: [.contentType: "application/json", HTTPField.Name("CF-Connecting-IP")!: source],
            body: ByteBuffer(bytes: payload))
    }

    private func pairDevice(_ client: some TestClientProtocol, name: String = "iPhone", platform: String = "ios") async throws -> PairResponse {
        let code = try await createCode(client)
        let response = try await pair(client, code: code.code, name: name, platform: platform)
        #expect(response.status == .ok, "pair \(response.status)")
        return try WireJSON.decoder().decode(PairResponse.self, from: response.body)
    }

    // MARK: コード

    @Test("コードは 8 文字の Crockford base32 で 5 分後に切れ、ハイフン付き・小文字でも通る")
    func codeFormatAndExpiry() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let code = try await createCode(client)
            #expect(code.code.count == 8)
            #expect(code.code.allSatisfy(PairingCode.alphabet.contains))
            #expect(code.expiresAt == fixture.clock.now.addingTimeInterval(300))

            fixture.clock.advance(300)
            let expired = try await pair(client, code: code.code)
            #expect(expired.status == .badRequest)
            #expect(String(buffer: expired.body).contains("コードが違うか、期限が切れている"))

            let fresh = try await createCode(client)
            fixture.clock.advance(299)
            let typed = "\(fresh.code.prefix(4).lowercased())-\(fresh.code.suffix(4).lowercased())"
            let ok = try await pair(client, code: typed)
            #expect(ok.status == .ok)
            let paired = try WireJSON.decoder().decode(PairResponse.self, from: ok.body)
            #expect(paired.machineID == "m-test")
            #expect(paired.token.count == 64)
            #expect(paired.token != daemonToken)
        }
        // daemon は hash だけを持つ
        let rows = try fixture.store.devices()
        #expect(rows.count == 1)
        #expect(rows[0].tokenHash.count == 64)
    }

    @Test("コードは 1 回しか使えない")
    func codeIsSingleUse() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let code = try await createCode(client)
            #expect(try await pair(client, code: code.code).status == .ok)
            let again = try await pair(client, code: code.code, name: "iPad", platform: "ipados")
            #expect(again.status == .badRequest)
        }
        #expect(try fixture.store.devices().count == 1)
    }

    @Test("同じコードの要求が同時に 2 本来ても、端末は 1 台しかできない")
    func concurrentPairsMakeOneDevice() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.live) { client in
            let code = try await createCode(client)
            async let first = pair(client, code: code.code, name: "A")
            async let second = pair(client, code: code.code, name: "B")
            let statuses = try await [first.status, second.status]
            #expect(statuses.filter { $0 == .ok }.count == 1, "\(statuses)")
            #expect(statuses.filter { $0 == .badRequest }.count == 1, "\(statuses)")
        }
        #expect(try fixture.store.devices().count == 1)
    }

    @Test("予約中のコードは他の要求に渡らず、書けなかったら未使用に戻る")
    func registryReservation() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let registry = PairingRegistry(now: { clock.now })
        let code = await registry.issue().code
        #expect(await registry.reserve(code) == .reserved)
        #expect(await registry.reserve(code) == .invalid)
        await registry.release(code)
        #expect(await registry.reserve(code) == .reserved)
        await registry.consume(code)
        await registry.release(code)
        #expect(await registry.reserve(code) == .invalid)
    }

    @Test("同時に有効なコードは 5 本まで。6 本目を出すと一番古いものが使えなくなる")
    func atMostFiveCodes() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let registry = PairingRegistry(now: { clock.now })
        var codes: [String] = []
        for _ in 0..<6 { codes.append(await registry.issue().code) }
        #expect(await registry.reserve(codes[0]) == .invalid)
        for code in codes.dropFirst() { #expect(await registry.reserve(code) == .reserved) }
    }

    @Test("表に書けなかったら 500 で、同じコードがもう一度使える")
    func databaseFailureReleasesCode() async throws {
        let fixture = try makeFixture()
        try await fixture.store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_device BEFORE INSERT ON device BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        try await app(fixture).test(.router) { client in
            let code = try await createCode(client)
            let failed = try await pair(client, code: code.code)
            #expect(failed.status == .internalServerError)
            try await fixture.store.database.write { db in try db.execute(sql: "DROP TRIGGER fail_device") }
            #expect(try await pair(client, code: code.code).status == .ok)
        }
        #expect(try fixture.store.devices().count == 1)
    }

    @Test("5 分間に 10 回失敗した接続元は 5 分 429。他の接続元と有効なコードには響かない")
    func failureLimitPerSource() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let code = try await createCode(client)
            for attempt in 0..<10 {
                let bad = try await pair(client, code: attempt.isMultiple(of: 2) ? "AAAAAAAA" : "short", source: "198.51.100.7")
                #expect(bad.status == .badRequest)
            }
            let blocked = try await pair(client, code: code.code, source: "198.51.100.7")
            #expect(blocked.status == .tooManyRequests)
            #expect(blocked.headers[.retryAfter] == "300")

            // 別の接続元は同じコードで繋がる（429 でコードは捨てない）
            #expect(try await pair(client, code: code.code, source: "198.51.100.8").status == .ok)

            fixture.clock.advance(300)
            let next = try await createCode(client)
            #expect(try await pair(client, code: next.code, source: "198.51.100.7").status == .ok)
        }
    }

    @Test("失敗は 5 分の窓で数える。窓を過ぎた失敗は数えない")
    func failureWindowSlides() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let registry = PairingRegistry(now: { clock.now })
        for _ in 0..<9 { #expect(await registry.recordFailure(source: "a") == false) }
        clock.advance(301)
        #expect(await registry.recordFailure(source: "a") == false)
        #expect(await registry.retryAfter(source: "a") == nil)
    }

    @Test("入力: name は前後の空白を除いて 1〜64 字、platform は 3 種、コードは 8 文字の Crockford base32")
    func pairInputLimits() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let code = try await createCode(client)
            let tooLong = try await pair(client, code: code.code, name: String(repeating: "あ", count: 65))
            #expect(tooLong.status == .badRequest)
            #expect(try await pair(client, code: code.code, name: "   ").status == .badRequest)
            #expect(try await pair(client, code: code.code, platform: "android").status == .badRequest)
            // I・L・O・U は Crockford base32 に無い
            #expect(try await pair(client, code: "ILOU0000").status == .badRequest)
            #expect(try await pair(client, code: "ABCDEFGH1").status == .badRequest)
            let notJSON = try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"], body: body("x"))
            #expect(notJSON.status == .badRequest)

            // 入力の誤りではコードを使わない
            let ok = try await pair(client, code: code.code, name: "  " + String(repeating: "あ", count: 64) + " ")
            #expect(ok.status == .ok)
        }
        #expect(try fixture.store.devices().map(\.info.name) == [String(repeating: "あ", count: 64)])
    }

    // MARK: 端末の token

    @Test("iPhone の端末の token では 9 本の経路が 403 で印が付き、daemon の token では 403 にならない")
    func deviceTokenForbiddenRoutes() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let device = try await pairDevice(client)
            let other = try await pairDevice(client, name: "iPad")
            let routes: [(String, HTTPRequest.Method)] = [
                ("/v1/pairings", .post), ("/v1/devices/\(other.deviceID)", .delete), ("/v1/import/taskherd", .post), ("/v1/usage/claude", .post),
                ("/v1/feedback/claim", .post), ("/v1/feedback/ack", .post), ("/v1/tasks/1/feedback/take", .post),
                ("/v1/resolve", .get), ("/v1/hooks/stop", .post),
            ]
            for (uri, method) in routes {
                let response = try await client.execute(uri: uri, method: method, headers: bearer(device.token), body: body("{}"))
                #expect(response.status == .forbidden, "\(method) \(uri): \(response.status)")
                #expect(response.headers[authHeader] == DaemonAuthHeader.forbidden, "\(uri)")
            }
            for (uri, method) in routes where !uri.hasPrefix("/v1/devices") {
                let response = try await client.execute(uri: uri, method: method, headers: bearer(daemonToken), body: body("{}"))
                #expect(response.status != .forbidden && response.status != .unauthorized, "\(method) \(uri): \(response.status)")
            }
            // アプリが使う経路は端末の token で通る
            let state = try await client.execute(uri: "/v1/state", method: .get, headers: bearer(device.token))
            #expect(state.status == .ok)
            // オーケストレーターの破棄して再起動（launcher の無い組なので 503 だが、認証は通る）
            let restart = try await client.execute(uri: "/v1/orchestrator/restart", method: .post, headers: bearer(device.token), body: body("{}"))
            #expect(restart.status != .forbidden && restart.status != .unauthorized, "\(restart.status)")
        }
        #expect(try fixture.store.devices().count == 2)
    }

    @Test("iPhone の端末の token でセッションをタスクに紐づけ、外せる（アプリの［セッションを紐づける…］と［このタスクから外す］）")
    func deviceTokenLinksSessions() async throws {
        let base = try makeFixture()
        let cli = GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: URL(fileURLWithPath: "/nonexistent/gh"))
        var dependencies = base.dependencies
        dependencies.hooks = HookService(store: base.store, state: base.state, github: GitHubSync(store: base.store, state: base.state, cli: cli))
        let fixture = Fixture(state: base.state, store: base.store, clock: base.clock, dependencies: dependencies)
        let board = try fixture.store.createBoard(name: "default", columns: nil)
        let task = try fixture.store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x"))
        try await app(fixture).test(.router) { client in
            let device = try await pairDevice(client)
            let link = try await client.execute(
                uri: "/v1/sessions/link", method: .post, headers: bearer(device.token),
                body: body(#"{"paneID":"w1:p3","agent":"codex","agentSessionID":"s-app","cwd":"/w","taskNumber":\#(task.number),"label":""}"#))
            #expect(link.status == .ok, "\(link.status)")
            let linked = try #require(try WireJSON.decoder().decode(TaskResolution.self, from: link.body).task)
            #expect(linked.sessions.map(\.sessionID) == ["s-app"])
            #expect(linked.sessions.first?.agent == "codex")
            #expect(linked.sessions.first?.label == "")
            #expect(linked.sessions.first?.launchArgs == [])
            #expect(await fixture.state.task(number: task.number)?.sessions.map(\.sessionID) == ["s-app"])

            let unlink = try await client.execute(uri: "/v1/tasks/\(task.number)/sessions/s-app", method: .delete, headers: bearer(device.token))
            #expect(unlink.status == .ok, "\(unlink.status)")
            #expect(try WireJSON.decoder().decode(BoardTask.self, from: unlink.body).sessions.isEmpty)
            #expect(await fixture.state.task(number: task.number)?.sessions.isEmpty == true)
        }
        #expect(try fixture.store.task(linkedToSession: "s-app") == nil)
    }

    @Test("Mac の端末の token ではコードを出せ、そのコードで端末を足せる。iPhone・iPad の token では 403")
    func macDeviceIssuesCode() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let mac = try await pairDevice(client, name: "MacBook", platform: "macos")
            let issued = try await client.execute(uri: "/v1/pairings", method: .post, headers: bearer(mac.token), body: body("{}"))
            #expect(issued.status == .ok)
            let code = try WireJSON.decoder().decode(PairingCode.self, from: issued.body)
            #expect(try await pair(client, code: code.code, name: "iPhone").status == .ok)
            for platform in ["ios", "ipados"] {
                let device = try await pairDevice(client, name: platform, platform: platform)
                let refused = try await client.execute(uri: "/v1/pairings", method: .post, headers: bearer(device.token), body: body("{}"))
                #expect(refused.status == .forbidden, "\(platform)")
                #expect(refused.headers[authHeader] == DaemonAuthHeader.forbidden)
            }
        }
        // 時計を止めているので、表の並び（createdAt, id）は id の乱数で決まる
        #expect(Set(try fixture.store.devices().map(\.info.name)) == ["MacBook", "iPhone", "ios", "ipados"])
    }

    @Test("一覧は両方の token で取れ、端末の token では自分の行だけ current")
    func deviceListMarksCurrent() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let phone = try await pairDevice(client, name: "iPhone")
            _ = try await pairDevice(client, name: "iPad")
            let asDevice = try WireJSON.decoder().decode(
                [DeviceInfo].self, from: try await client.execute(uri: "/v1/devices", method: .get, headers: bearer(phone.token)).body)
            #expect(asDevice.map(\.name) == ["iPhone", "iPad"])
            #expect(asDevice.map(\.current) == [true, false])
            let asDaemon = try WireJSON.decoder().decode(
                [DeviceInfo].self, from: try await client.execute(uri: "/v1/devices", method: .get, headers: bearer(daemonToken)).body)
            #expect(asDaemon.map(\.current) == [false, false])
        }
    }

    @Test("止めた token は 401 と印のヘッダ。端末は自分を止められ、無い端末は 404")
    func revokedTokenIsUnauthorized() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let phone = try await pairDevice(client, name: "iPhone")
            let pad = try await pairDevice(client, name: "iPad")
            #expect(try await client.execute(uri: "/v1/devices/\(phone.deviceID)", method: .delete, headers: bearer(daemonToken)).status == .noContent)
            let revoked = try await client.execute(uri: "/v1/state", method: .get, headers: bearer(phone.token))
            #expect(revoked.status == .unauthorized)
            #expect(revoked.headers[authHeader] == DaemonAuthHeader.invalid)

            #expect(try await client.execute(uri: "/v1/devices/\(pad.deviceID)", method: .delete, headers: bearer(pad.token)).status == .noContent)
            #expect(try await client.execute(uri: "/v1/state", method: .get, headers: bearer(pad.token)).status == .unauthorized)
            #expect(try await client.execute(uri: "/v1/devices/\(pad.deviceID)", method: .delete, headers: bearer(daemonToken)).status == .notFound)

            let none = try await client.execute(uri: "/v1/state", method: .get)
            #expect(none.status == .unauthorized)
            #expect(none.headers[authHeader] == DaemonAuthHeader.invalid)
        }
        #expect(try fixture.store.devices().isEmpty)
    }

    @Test("再起動しても表から読んだ端末の token が通る")
    func deviceTokenSurvivesReload() async throws {
        let fixture = try makeFixture()
        let paired = Locked<PairResponse?>(nil)
        try await app(fixture).test(.router) { client in
            let device = try await pairDevice(client)
            paired.update { $0 = device }
        }
        let device = try #require(paired.value)
        let auth = DeviceAuth()
        await auth.load(try fixture.store.devices())
        var dependencies = fixture.dependencies
        dependencies.deviceAuth = auth
        let restarted = APIServer.application(state: fixture.state, token: daemonToken, port: 0, dependencies: dependencies)
        try await restarted.test(.router) { client in
            let response = try await client.execute(uri: "/v1/state", method: .get, headers: bearer(device.token))
            #expect(response.status == .ok)
        }
    }

    @Test("lastSeenAt はメモリでは毎回、表へは端末ごとに 60 秒に 1 回")
    func lastSeenThrottle() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let device = try await pairDevice(client)
            let start = fixture.clock.now
            func stored() throws -> Date? { try fixture.store.devices().first?.info.lastSeenAt }
            func listed() async throws -> Date? {
                let response = try await client.execute(uri: "/v1/devices", method: .get, headers: bearer(daemonToken))
                return try WireJSON.decoder().decode([DeviceInfo].self, from: response.body).first?.lastSeenAt
            }
            #expect(try stored() == nil)

            _ = try await client.execute(uri: "/v1/state", method: .get, headers: bearer(device.token))
            #expect(try stored() == start)

            fixture.clock.advance(59)
            _ = try await client.execute(uri: "/v1/state", method: .get, headers: bearer(device.token))
            #expect(try stored() == start)
            #expect(try await listed() == start.addingTimeInterval(59))

            fixture.clock.advance(1)
            _ = try await client.execute(uri: "/v1/state", method: .get, headers: bearer(device.token))
            #expect(try stored() == start.addingTimeInterval(60))
        }
    }

    @Test("追加と停止で devices.updated を配り、current は false")
    func devicesUpdatedEvents() async throws {
        let fixture = try makeFixture()
        let (id, stream) = await fixture.state.subscribe()
        try await app(fixture).test(.router) { client in
            let device = try await pairDevice(client)
            _ = try await client.execute(uri: "/v1/devices/\(device.deviceID)", method: .delete, headers: bearer(device.token))
        }
        await fixture.state.unsubscribe(id)
        var updates: [[DeviceInfo]] = []
        for await event in stream { if case .devicesUpdated(let devices) = event { updates.append(devices) } }
        #expect(updates.count == 2)
        #expect(updates.first?.map(\.name) == ["iPhone"])
        #expect(updates.first?.map(\.current) == [false])
        #expect(updates.last == [])
    }

    @Test("止めた後に配れなくても 204 で、止めたことは確定する")
    func revokeSucceedsWhenPublishFails() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let device = try await pairDevice(client)
            // 一覧の SELECT だけが落ちる（DELETE は id で引くので通る）
            try await fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE device RENAME COLUMN name TO renamed") }
            let deleted = try await client.execute(uri: "/v1/devices/\(device.deviceID)", method: .delete, headers: bearer(daemonToken))
            #expect(deleted.status == .noContent)
            #expect(try await client.execute(uri: "/v1/state", method: .get, headers: bearer(device.token)).status == .unauthorized)
        }
    }

    // MARK: WebSocket

    /// 閉じるまで受け、受けた text と close code を返す。10 秒で閉じなければこちらから切る（close code は 4401 にならない）
    private func readUntilClosed(_ task: URLSessionWebSocketTask) async -> (messages: [String], closeCode: Int) {
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { task.cancel(with: .goingAway, reason: nil) }
        }
        defer { watchdog.cancel() }
        var messages: [String] = []
        while true {
            do {
                if case .string(let text) = try await task.receive() { messages.append(text) }
            } catch {
                return (messages, task.closeCode.rawValue)
            }
        }
    }

    private func socket(port: Int, path: String, token: String?) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://localhost:\(port)\(path)")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return task
    }

    @Test("止めると端末の WebSocket は 4401 で閉じ、daemon の token の WebSocket は残る")
    func revokeClosesDeviceSockets() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.live) { client in
            let port = try #require(client.port)
            let device = try await pairDevice(client)
            let deviceSocket = socket(port: port, path: "/v1/stream", token: device.token)
            let daemonSocket = socket(port: port, path: "/v1/stream", token: daemonToken)
            let hello = String(decoding: try WireJSON.encoder().encode(StreamClientMessage.hello(epoch: nil, rev: nil)), as: UTF8.self)
            try await deviceSocket.send(.string(hello))
            try await daemonSocket.send(.string(hello))
            // 最初の全体が届いたら register は済んでいる
            _ = try await deviceSocket.receive()
            _ = try await daemonSocket.receive()

            let deleted = try await client.execute(uri: "/v1/devices/\(device.deviceID)", method: .delete, headers: bearer(daemonToken))
            #expect(deleted.status == .noContent)
            let closed = await readUntilClosed(deviceSocket)
            #expect(closed.closeCode == Int(DaemonAuthHeader.revokedCloseCode))

            // daemon の token の接続には devices.updated が届く
            let next = try await daemonSocket.receive()
            if case .string(let text) = next { #expect(text.contains("devices.updated")) } else { Issue.record("text でない") }
            daemonSocket.cancel(with: .goingAway, reason: nil)
        }
    }

    @Test("upgrade の判定 → 止める → register の順なら、データを送らず 4401 で閉じる")
    func revokeBetweenUpgradeAndRegister() async throws {
        let gate = RevokeGate()
        let fixture = try makeFixture { dependencies in
            let auth = dependencies.deviceAuth
            dependencies.socketWillRegister = { await gate.run(auth) }
        }
        try await app(fixture).test(.live) { client in
            let port = try #require(client.port)
            for path in ["/v1/terminal/w1:p1", "/v1/stream"] {
                // 表には残したまま、認証のキャッシュからだけ外す（upgrade の判定は通り、register で断られる）
                let device = try await pairDevice(client)
                await gate.arm(device.deviceID)
                let task = socket(port: port, path: path, token: device.token)
                let closed = await readUntilClosed(task)
                #expect(closed.messages.isEmpty, "\(path)")
                #expect(closed.closeCode == Int(DaemonAuthHeader.revokedCloseCode), "\(path)")
            }
            #expect(await gate.revokedCount == 2)
        }
    }

    @Test("会話の HTTP の口は daemon の token と端末の token で通り、止めた token と token 無しは 401。会話の出来事の WebSocket は端末の token を 4401 で閉じる")
    func conversationRoutes() async throws {
        let fixture = try makeFixture()
        let routes: [(HTTPRequest.Method, String)] = [
            (.post, "/v1/conversations"), (.get, "/v1/conversations"), (.get, "/v1/conversations/c1"),
            (.post, "/v1/conversations/c1/messages"), (.post, "/v1/conversations/c1/attachments"), (.post, "/v1/conversations/c1/files?name=a.txt"), (.post, "/v1/conversations/c1/answers"),
            (.post, "/v1/conversations/c1/control"), (.post, "/v1/conversations/c1/stop"), (.post, "/v1/conversations/c1/resume"), (.post, "/v1/conversations/c1/close"),
            (.delete, "/v1/conversations/c1"), (.get, "/v1/conversations/c1/history"), (.get, "/v1/conversations/c1/workfiles?q=a"), (.get, "/v1/conversations/c1/files/toolu_1"),
            (.get, "/v1/conversations/c1/images/e1a2b3c4-0000-4000-8000-000000000001/0"),
        ]
        try await app(fixture).test(.live) { client in
            let device = try await pairDevice(client)
            let revoked = try await pairDevice(client, name: "iPad", platform: "ipados")
            #expect(try await client.execute(uri: "/v1/devices/\(revoked.deviceID)", method: .delete, headers: bearer(daemonToken)).status == .noContent)
            for (method, uri) in routes {
                for token in [daemonToken, device.token] {
                    let status = try await client.execute(uri: uri, method: method, headers: bearer(token), body: body("{}")).status
                    #expect(status != .forbidden && status != .unauthorized, "\(method) \(uri): \(status)")
                }
                #expect(try await client.execute(uri: uri, method: method, headers: bearer(revoked.token), body: body("{}")).status == .unauthorized, "\(uri)")
                #expect(try await client.execute(uri: uri, method: method, body: body("{}")).status == .unauthorized, "\(uri)")
            }
            let port = try #require(client.port)
            let closed = await readUntilClosed(socket(port: port, path: "/v1/conversations/c1/events", token: device.token))
            #expect(closed.messages.isEmpty && closed.closeCode == Int(DaemonAuthHeader.revokedCloseCode))
        }
    }
}

/// `socketWillRegister` で 1 回だけ端末を止める
private actor RevokeGate {
    private var deviceID: String?
    private(set) var revokedCount = 0

    func arm(_ id: String) { deviceID = id }

    func run(_ auth: DeviceAuth) async {
        guard let deviceID else { return }
        self.deviceID = nil
        await auth.revoke(deviceID: deviceID)
        revokedCount += 1
    }
}
