import CryptoKit
import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// APNs の代わり。送られた要求を覚え、決めた答えを順に返す（尽きたら 200）
final class FakeAPNs: APNsTransport {
    let requests = Locked<[URLRequest]>([])
    let responses: Locked<[APNsHTTPResponse]>

    init(_ responses: [APNsHTTPResponse] = []) { self.responses = Locked(responses) }

    func post(_ request: URLRequest) async throws -> APNsHTTPResponse {
        requests.update { $0.append(request) }
        var next = APNsHTTPResponse(status: 200, body: Data(), protocolName: "h2")
        responses.update { if !$0.isEmpty { next = $0.removeFirst() } }
        return next
    }

    static func reason(_ status: Int, _ reason: String) -> APNsHTTPResponse {
        APNsHTTPResponse(status: status, body: Data(#"{"reason":"\#(reason)"}"#.utf8))
    }

    func payloads() throws -> [[String: Any]] {
        try requests.value.map { try #require(JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any]) }
    }
}

/// 鍵を一時ディレクトリに入れた置き場
struct TestKeys {
    let directory: URL
    let key = P256.Signing.PrivateKey()
    var store: APNsKeyStore { APNsKeyStore(directory: directory.appending(path: "apns")) }

    init(environment: PushEnvironment? = nil, install: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "taskboard-apns-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if install { try store.install(keyPEM: key.pemRepresentation, keyID: "KEY1234567", teamID: "TEAM123456", environment: environment) }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func decodeSegment(_ segment: Substring) throws -> Data {
    var text = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    return try #require(Data(base64Encoded: text))
}

private let machine = MachineID(rawValue: "m-push")
private let tokenA = String(repeating: "a", count: 64)
private let tokenB = String(repeating: "b", count: 64)

private func registration(
    token: String = tokenA, kinds: [NotifyKind] = NotifyKind.allCases, turns: TurnNotify? = nil, sound: Bool = true
) -> PushRegistration {
    PushRegistration(
        token: token, environment: .sandbox, topic: "uk.whatn.taskboard.ios", kinds: kinds, turns: turns, sound: sound, machineName: "Studio",
        connection: "conn-1")
}

/// host の会話。`phase` が waiting なら権限の確認（`request`）を 1 つ待っている
private func conversation(_ id: String, _ phase: Conversation.Phase = .waiting, request: String = "r1") -> Conversation {
    let waiting = RequestWaiting(id: "tu-\(request)", since: Date(), permission: .init(tool: "Bash", summary: "touch a.txt"))
    let pending = phase == .waiting ? [ConversationRequest(id: request, kind: .permission, toolName: "Bash", toolUseID: "tu-\(request)", waiting: waiting)] : []
    return Conversation(
        id: id, machine: machine, taskNumber: nil, agentSessionID: "s-\(id)", cwd: "/w", runner: .host, phase: phase, pending: pending, createdAt: Date(),
        updatedAt: Date())
}

/// 権限の確認を待っている会話の通知（受信箱の項目から作る）
private func waitingNotification() throws -> InboxNotification {
    var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
    let waiting = conversation("c2", request: "r2")
    state.conversations[waiting.key] = waiting
    let item = try #require(state.inboxItems().first)
    return try #require(InboxNotification.make(item, machineName: "Studio"))
}

@Suite("APNs の送信")
struct APNsSenderTests {
    @Test("JWT は ES256 の header・iss と iat の claims で、公開鍵で署名を確かめられる")
    func jwtShape() throws {
        let key = P256.Signing.PrivateKey()
        let credentials = APNsCredentials(config: APNsConfig(keyID: "KEY1234567", teamID: "TEAM123456"), key: key)
        let jwt = try APNsJWT.make(credentials: credentials, issuedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let parts = jwt.split(separator: ".")
        #expect(parts.count == 3)
        #expect(!jwt.contains("=") && !jwt.contains("+") && !jwt.contains("/"))
        let header = try #require(JSONSerialization.jsonObject(with: decodeSegment(parts[0])) as? [String: Any])
        #expect(header as NSDictionary == ["alg": "ES256", "kid": "KEY1234567"])
        let claims = try #require(JSONSerialization.jsonObject(with: decodeSegment(parts[1])) as? [String: Any])
        #expect(claims as NSDictionary == ["iss": "TEAM123456", "iat": 1_800_000_000])
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decodeSegment(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test("ヘッダと宛先: sandbox の host、alert・topic・priority 10・1 日後の expiration・64 字の collapse-id")
    func requestHeaders() async throws {
        let keys = try TestKeys()
        defer { keys.remove() }
        let fake = FakeAPNs()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sender = APNsSender(keys: keys.store, transport: fake, now: { now })
        let notification = try waitingNotification()
        let push = APNsPush.inbox(notification, conversation: ("c2", "r2"), machine: machine, registration: registration(), now: now)
        let result = await sender.send(push, deviceToken: tokenA, environment: .sandbox)
        #expect(result == APNsResult(status: 200, reason: nil, protocolName: "h2"))
        let request = try #require(fake.requests.value.first)
        #expect(request.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/\(tokenA)")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "uk.whatn.taskboard.ios")
        #expect(request.value(forHTTPHeaderField: "apns-priority") == "10")
        #expect(request.value(forHTTPHeaderField: "apns-expiration") == "1800086400")
        let collapse = try #require(request.value(forHTTPHeaderField: "apns-collapse-id"))
        #expect(collapse.count == 64)
        // `printf %s m-push/conversation/c2/r2 | shasum -a 256`
        #expect(collapse == "517645f3506d40818019f098a0879b2af4826081b2feaad13543e561411ed410")
        #expect(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)

        _ = await sender.send(push, deviceToken: tokenA, environment: .production)
        #expect(fake.requests.value.last?.url?.host == "api.push.apple.com")
    }

    @Test("JWT は 40 分使い回し、それより古ければ作り直す")
    func jwtLifetime() async throws {
        let keys = try TestKeys()
        defer { keys.remove() }
        let fake = FakeAPNs()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let sender = APNsSender(keys: keys.store, transport: fake, now: { clock.now })
        let push = APNsPush(
            alert: .init(title: "t", subtitle: "", body: "b"), sound: false, threadID: nil, category: nil, custom: [:], topic: "x", collapseID: nil, expiration: clock.now)
        _ = await sender.send(push, deviceToken: tokenA, environment: .sandbox)
        clock.advance(39 * 60)
        _ = await sender.send(push, deviceToken: tokenA, environment: .sandbox)
        clock.advance(2 * 60)
        _ = await sender.send(push, deviceToken: tokenA, environment: .sandbox)
        let bearers = fake.requests.value.map { $0.value(forHTTPHeaderField: "authorization") }
        #expect(bearers[0] == bearers[1])
        #expect(bearers[1] != bearers[2])
    }

    @Test("ExpiredProviderToken なら JWT を作り直して 1 回だけ送り直す")
    func expiredProviderToken() async throws {
        let keys = try TestKeys()
        defer { keys.remove() }
        let fake = FakeAPNs([FakeAPNs.reason(403, "ExpiredProviderToken"), FakeAPNs.reason(403, "ExpiredProviderToken")])
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let sender = APNsSender(keys: keys.store, transport: fake, now: { clock.now })
        let push = APNsPush(
            alert: .init(title: "t", subtitle: "", body: "b"), sound: false, threadID: nil, category: nil, custom: [:], topic: "x", collapseID: nil, expiration: clock.now)
        clock.advance(1)
        let result = await sender.send(push, deviceToken: tokenA, environment: .sandbox)
        #expect(fake.requests.value.count == 2)
        #expect(result.status == 403 && result.reason == "ExpiredProviderToken")
    }

    @Test("鍵が無ければ送らない。入れたら daemon を起動し直さずに送り、環境を付けた鍵はほかの環境に送らない")
    func credentialsReload() async throws {
        let keys = try TestKeys(install: false)
        defer { keys.remove() }
        let fake = FakeAPNs()
        let sender = APNsSender(keys: keys.store, transport: fake)
        let push = APNsPush(
            alert: .init(title: "t", subtitle: "", body: "b"), sound: false, threadID: nil, category: nil, custom: [:], topic: "x", collapseID: nil, expiration: Date())
        #expect(await sender.send(push, deviceToken: tokenA, environment: .sandbox).status == nil)
        #expect(await !sender.delivers(to: .sandbox))
        try keys.store.install(keyPEM: keys.key.pemRepresentation, keyID: "KEY1234567", teamID: "TEAM123456", environment: .sandbox)
        #expect(await sender.delivers(to: .sandbox))
        #expect(await !sender.delivers(to: .production))
        #expect(await sender.send(push, deviceToken: tokenA, environment: .sandbox).status == 200)
        #expect(await sender.send(push, deviceToken: tokenA, environment: .production).status == nil)
        #expect(fake.requests.value.count == 1)
        try keys.store.remove()
        #expect(await !sender.delivers(to: .sandbox))
    }

    @Test("通知の中身: aps の alert・sound・thread-id、外の値の名前。category は確認があるときだけ")
    func payloadShape() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let base = try waitingNotification()
        let push = APNsPush.inbox(base, conversation: ("c2", "r2"), machine: machine, registration: registration(), now: now)
        let object = try #require(JSONSerialization.jsonObject(with: push.payload()) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        #expect(aps["alert"] as? NSDictionary == ["title": "応答待ち", "subtitle": "Studio", "body": "Claude Codeが応答を待っています\nBash：touch a.txt"])
        #expect(aps["sound"] as? String == "default")
        #expect(aps["thread-id"] as? String == "m-push")
        #expect(aps["category"] as? String == PushPayload.permissionCategory)
        #expect(object[PushPayload.item] as? String == "m-push/conversation/c2/r2")
        #expect(object[PushPayload.url] as? String == "taskboard://conversation/m-push/c2")
        #expect(object[PushPayload.connection] as? String == "conn-1")
        #expect(object[PushPayload.machine] as? String == "m-push")
        #expect(object[PushPayload.conversation] as? String == "c2")
        #expect(object[PushPayload.request] as? String == "r2")

        var unconfirmed = base
        unconfirmed.permission = nil
        let quiet = APNsPush.inbox(unconfirmed, machine: machine, registration: registration(sound: false), now: now)
        let quietObject = try #require(JSONSerialization.jsonObject(with: quiet.payload()) as? [String: Any])
        let quietAps = try #require(quietObject["aps"] as? [String: Any])
        #expect(quietAps["sound"] == nil)
        #expect(quietAps["category"] == nil)
        #expect(quietObject[PushPayload.conversation] == nil)
    }

    @Test("4KB を超える本文は切り、「…」で終える（日本語でも英字でも）")
    func payloadTruncation() throws {
        for unit in ["あ", "a", "\""] {
            let push = APNsPush(
                alert: .init(title: "題", subtitle: "", body: String(repeating: unit, count: 5000)), sound: true, threadID: "t", category: nil, custom: ["item": "x"],
                topic: "x", collapseID: nil, expiration: Date())
            let data = push.payload()
            #expect(data.count <= APNsPush.payloadLimit, "\(unit): \(data.count)")
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let body = try #require(((object["aps"] as? [String: Any])?["alert"] as? [String: Any])?["body"] as? String)
            #expect(body.hasSuffix("…"))
            #expect(body.count > 1000)
        }
        let short = APNsPush(
            alert: .init(title: "題", subtitle: "", body: "短い"), sound: false, threadID: nil, category: nil, custom: [:], topic: "x", collapseID: nil, expiration: Date())
        #expect(String(decoding: short.payload(), as: UTF8.self).contains("短い"))
    }
}

@Suite("受信箱の差分を APNs に送る")
struct PushNotifierTests {
    private struct Fixture {
        let state: DaemonState
        let store: Store
        let fake: FakeAPNs
        let keys: TestKeys
        let notifier: PushNotifier
    }

    private func makeFixture(responses: [APNsHTTPResponse] = []) throws -> Fixture {
        let state = DaemonState(machine: MachineInfo(id: machine, name: "test-mac", daemonVersion: "test"))
        let store = try Store(inMemory: machine)
        let fake = FakeAPNs(responses)
        let keys = try TestKeys()
        let push = PushService(store: store, sender: APNsSender(keys: keys.store, transport: fake))
        let notifier = PushNotifier(state: state, push: push, debounce: .milliseconds(50))
        return Fixture(state: state, store: store, fake: fake, keys: keys, notifier: notifier)
    }

    private func addDevice(_ store: Store, id: String, _ registration: PushRegistration?) throws {
        try store.insertDevice(DeviceInfo(id: id, name: "iPhone \(id)", platform: .ios, createdAt: Date()), tokenHash: "hash-\(id)")
        if let registration { _ = try store.setPushRegistration(deviceID: id, registration, at: Date()) }
    }

    @Test("起動した時点の受信箱は送らず、増えた項目だけを送る。止めた種類と種類が空の端末には送らない")
    func diffAndKinds() async throws {
        let f = try makeFixture()
        defer { f.keys.remove() }
        try addDevice(f.store, id: "all", registration(token: tokenA))
        try addDevice(f.store, id: "questions", registration(token: tokenB, kinds: [.question]))
        try addDevice(f.store, id: "none", registration(token: String(repeating: "c", count: 64), kinds: []))
        try addDevice(f.store, id: "unregistered", nil)
        await f.state.upsert(conversation("c1"))
        await f.notifier.start()
        await f.notifier.resync()
        #expect(f.fake.requests.value.isEmpty, "基準は送らない")

        await f.state.upsert(conversation("c2"))
        await f.notifier.resync()
        #expect(f.fake.requests.value.map { $0.url?.lastPathComponent } == [tokenA])
        await f.notifier.resync()
        #expect(f.fake.requests.value.count == 1, "同じ項目は 2 度送らない")
    }

    @Test("出来事を受けたら少しまとめてから送る")
    func debouncedEvents() async throws {
        let f = try makeFixture()
        defer { f.keys.remove() }
        try addDevice(f.store, id: "d", registration())
        await f.notifier.start()
        let waiting = conversation("c3")
        await f.state.upsert(waiting)
        await f.notifier.handle(.conversationUpdated(waiting))
        await f.notifier.handle(.conversationUpdated(waiting))
        #expect(f.fake.requests.value.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while f.fake.requests.value.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.fake.requests.value.count == 1)
    }

    @Test("応答待ちが解けてまた応答待ちになると、また送る")
    func reblocked() async throws {
        let f = try makeFixture()
        defer { f.keys.remove() }
        try addDevice(f.store, id: "d", registration())
        await f.notifier.start()
        await f.state.upsert(conversation("c4"))
        await f.notifier.resync()
        await f.state.upsert(conversation("c4", .running))
        await f.notifier.resync()
        await f.state.upsert(conversation("c4"))
        await f.notifier.resync()
        #expect(f.fake.requests.value.count == 2)
    }

    @Test("会話の問いの通知には会話と問いの id を載せ、本文の 2 行目は最初の問い")
    func conversationRequest() async throws {
        let f = try makeFixture()
        defer { f.keys.remove() }
        try addDevice(f.store, id: "d", registration())
        await f.notifier.start()
        let waiting = RequestWaiting(id: "r1", since: Date(), questions: [AskQuestion(id: "q1", question: "どちらにしますか", options: [])])
        let request = ConversationRequest(id: "r1", kind: .question, toolName: "AskUserQuestion", toolUseID: "tu1", waiting: waiting)
        await f.state.upsert(
            Conversation(
                id: "c1", machine: machine, taskNumber: nil, agentSessionID: "s1", cwd: "/w", runner: .host, phase: .waiting, pending: [request],
                createdAt: Date(), updatedAt: Date()))
        await f.notifier.resync()
        let payload = try #require(try f.fake.payloads().first)
        #expect(payload[PushPayload.conversation] as? String == "c1")
        #expect(payload[PushPayload.request] as? String == "r1")
        #expect(payload[PushPayload.item] as? String == "m-push/conversation/c1/r1")
        #expect(payload[PushPayload.url] as? String == "taskboard://conversation/m-push/c1")
        #expect(((payload["aps"] as? [String: Any])?["alert"] as? [String: Any])?["body"] as? String == "Claude Codeが応答を待っています\nどちらにしますか")
    }

    @Test("会話の権限の確認に許可の規則の候補があれば、［常に許可］つきの category と候補の id を載せ、本文の 3 行目に対象を出す。規則の候補が無ければ載せない")
    func conversationPermissionWithSuggestion() async throws {
        let f = try makeFixture()
        defer { f.keys.remove() }
        try addDevice(f.store, id: "d", registration())
        await f.notifier.start()
        func permission(_ id: String, _ suggestions: [PermissionSuggestion]) -> ConversationRequest {
            ConversationRequest(
                id: id, kind: .permission, toolName: "Bash", toolUseID: "tu-\(id)",
                waiting: RequestWaiting(id: "tu-\(id)", since: Date(), permission: .init(tool: "Bash", summary: "touch a")), suggestions: suggestions)
        }
        let rule = PermissionSuggestion(id: "2", kind: .rule, subject: "Bash(touch a)", scope: .folder)
        let directory = PermissionSuggestion(id: "0", kind: .directory, subject: "/w", scope: .session)
        await f.state.upsert(
            Conversation(
                id: "c1", machine: machine, taskNumber: nil, agentSessionID: "s1", cwd: "/w", runner: .host, phase: .waiting,
                pending: [permission("r1", [directory, rule]), permission("r2", [directory])], createdAt: Date(), updatedAt: Date()))
        await f.notifier.resync()
        let payloads = try f.fake.payloads()
        let withRule = try #require(payloads.first { $0[PushPayload.request] as? String == "r1" })
        let aps = withRule["aps"] as? [String: Any]
        #expect(aps?["category"] as? String == PushPayload.permissionAlwaysCategory)
        #expect(withRule[PushPayload.suggestion] as? String == "2")
        #expect((aps?["alert"] as? [String: Any])?["body"] as? String == "Claude Codeが応答を待っています\nBash：touch a\n常に許可：Bash(touch a)（このフォルダの設定に保存）")
        let without = try #require(payloads.first { $0[PushPayload.request] as? String == "r2" })
        #expect((without["aps"] as? [String: Any])?["category"] as? String == PushPayload.permissionCategory)
        #expect(without[PushPayload.suggestion] == nil)
    }

    @Test("ターンの完了の設定は種類の列に入れて読み戻し、古い daemon が読む種類は変えない")
    func turnsStored() throws {
        let store = try Store(inMemory: machine)
        for (id, turns) in [("a", TurnNotify?.some(.background)), ("b", .always), ("c", .never), ("d", nil)] {
            try addDevice(store, id: id, registration(token: String(repeating: id, count: 64), kinds: [.question], turns: turns))
        }
        let targets = try store.pushTargets()
        #expect(targets.map(\.registration.turns) == [.background, .always, .never, nil])
        #expect(targets.allSatisfy { $0.registration.kinds == [.question] })
        #expect(Store.pushKindsColumn(registration(kinds: [.approval, .question], turns: .always)) == "approval,question,turns=always")
    }

    @Test("ターンの完了: 応答中の会話が入力待ちになったら、設定が「出さない」でなく種類が空でない端末に turn の印つきで送る。まとめる間に始めて終えた分も送る")
    func turnFinished() async throws {
        let f = try makeFixture()
        defer { f.keys.remove() }
        try addDevice(f.store, id: "bg", registration(token: tokenA, turns: .background))
        try addDevice(f.store, id: "never", registration(token: tokenB, turns: .never))
        try addDevice(f.store, id: "old", registration(token: String(repeating: "c", count: 64)))
        try addDevice(f.store, id: "hidden", registration(token: String(repeating: "d", count: 64), kinds: [], turns: .always))
        await f.state.upsert(conversation("c5", .idle))
        await f.notifier.start()
        for phase in [Conversation.Phase.running, .idle] {
            let changed = conversation("c5", phase)
            await f.state.upsert(changed)
            await f.notifier.handle(.conversationUpdated(changed))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while f.fake.requests.value.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.fake.requests.value.map { $0.url?.lastPathComponent } == [tokenA])
        let payload = try #require(try f.fake.payloads().first)
        #expect(payload[PushPayload.turn] as? String == "1")
        let alert = try #require((payload["aps"] as? [String: Any])?["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "応答の完了")
        #expect(alert["subtitle"] as? String == "Studio")
        #expect(alert["body"] as? String == "Claude Codeが応答を終えました")
        await f.notifier.resync()
        #expect(f.fake.requests.value.count == 1, "同じ完了を 2 度送らない")
    }

    @Test("410 と BadDeviceToken・DeviceTokenNotForTopic は登録を消し、ほかの失敗は消さない")
    func deadTokens() async throws {
        let f = try makeFixture(responses: [
            FakeAPNs.reason(410, "Unregistered"), FakeAPNs.reason(400, "BadDeviceToken"), FakeAPNs.reason(400, "DeviceTokenNotForTopic"),
            FakeAPNs.reason(500, "InternalServerError"), FakeAPNs.reason(403, "InvalidProviderToken"),
        ])
        defer { f.keys.remove() }
        let tokens = ["a", "b", "c", "d", "e"].map { String(repeating: $0, count: 64) }
        for (index, token) in tokens.enumerated() { try addDevice(f.store, id: "d\(index)", registration(token: token)) }
        await f.notifier.start()
        await f.state.upsert(conversation("c7"))
        await f.notifier.resync()
        #expect(f.fake.requests.value.count == 5)
        #expect(try f.store.pushTargets().map(\.deviceID) == ["d3", "d4"])
    }

    @Test("鍵が無い間は送らず、入れてもそれまでの項目はまとめて送らない")
    func noKey() async throws {
        let f = try makeFixture()
        defer { f.keys.remove() }
        try f.keys.store.remove()
        try addDevice(f.store, id: "d", registration())
        await f.notifier.start()
        await f.state.upsert(conversation("c8"))
        await f.notifier.resync()
        try f.keys.store.install(keyPEM: f.keys.key.pemRepresentation, keyID: "KEY1234567", teamID: "TEAM123456", environment: nil)
        await f.notifier.resync()
        #expect(f.fake.requests.value.isEmpty)
        await f.state.upsert(conversation("c9"))
        await f.notifier.resync()
        #expect(f.fake.requests.value.count == 1)
    }
}
