import Foundation
import Synchronization
import TaskboardKit
import Testing
import UserNotifications
@testable import Taskboard

/// daemon の口の代わり。ホストごとに応答を決め、届いた要求を覚える
private final class StubDaemon: URLProtocol {
    struct Reply: Sendable {
        var status: Int
        var body: String = ""
    }

    struct Received: Sendable {
        var method: String
        var path: String
        var body: Data
    }

    private static let replies = Mutex<[String: @Sendable (Received) -> Reply]>([:])
    private static let received = Mutex<[String: [Received]]>([:])

    static func session(host: String, _ reply: @escaping @Sendable (Received) -> Reply) -> URLSession {
        replies.withLock { $0[host] = reply }
        received.withLock { $0[host] = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDaemon.self]
        return URLSession(configuration: configuration)
    }

    static func requests(_ host: String) -> [Received] {
        received.withLock { $0[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let reply = Self.replies.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let got = Received(method: request.httpMethod ?? "GET", path: url.path(), body: request.httpBody ?? Self.read(request.httpBodyStream))
        Self.received.withLock { $0[host, default: []].append(got) }
        let answer = reply(got)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func connection(_ name: String, host: String, paired: Bool) -> SavedConnection {
    SavedConnection(
        id: UUID(), name: name, url: URL(string: "https://\(host)")!, token: "device-token", access: nil, pairedDeviceID: paired ? "dev-\(name)" : nil)
}

private let token = Data((0..<32).map { UInt8($0) })
private let tokenHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

@Suite struct ProvisioningProfileTests {
    /// 署名の前後に挟まれた plist（実物の `embedded.mobileprovision` と同じ並び）
    private func profile(_ environment: String?) -> Data {
        let entitlements = environment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Name</key><string>iOS Team Provisioning Profile: uk.whatn.taskboard.ios</string>
            <key>Entitlements</key><dict><key>application-identifier</key><string>TEAM123456.uk.whatn.taskboard.ios</string>\(entitlements)</dict></dict></plist>
            """
        return Data([0x30, 0x82, 0x0f, 0x3c, 0x06, 0x09]) + Data(plist.utf8) + Data([0xa0, 0x82, 0x0b, 0x00, 0x30])
    }

    @Test("開発のプロファイルは sandbox、配布のプロファイルとプロファイルの無いアプリは production")
    func environmentFromProfile() {
        #expect(PushEnvironment.detect(profile: profile("development"), simulator: false) == .sandbox)
        #expect(PushEnvironment.detect(profile: profile("production"), simulator: false) == .production)
        #expect(PushEnvironment.detect(profile: nil, simulator: false) == .production)
    }

    @Test("シミュレータはプロファイルに関わらず sandbox")
    func simulatorIsSandbox() {
        #expect(PushEnvironment.detect(profile: nil, simulator: true) == .sandbox)
        #expect(PushEnvironment.detect(profile: profile("production"), simulator: true) == .sandbox)
    }

    @Test("plist の無いデータと、aps-environment の無いプロファイルは読めない")
    func unreadable() {
        #expect(ProvisioningProfile.apsEnvironment(Data()) == nil)
        #expect(ProvisioningProfile.apsEnvironment(Data("<?xml version=\"1.0\"?> 終わりの無い plist".utf8)) == nil)
        #expect(ProvisioningProfile.apsEnvironment(profile(nil)) == nil)
        #expect(ProvisioningProfile.apsEnvironment(profile("development")) == "development")
    }
}

@Suite struct PushPlanTests {
    @Test("QRコードで追加した接続先だけに、付けた名前と接続先の id で登録する")
    func onlyPairedConnections() {
        let studio = connection("Mac Studio", host: "studio.example.com", paired: true)
        let manual = connection("Mac mini", host: "mini.example.com", paired: false)
        let plan = PushPlan.registrations(
            connections: [studio, manual], token: tokenHex, environment: .sandbox, topic: "uk.whatn.taskboard.ios",
            kinds: [.question, .approval], turns: .background, sound: false, isHidden: { _ in false })
        #expect(plan.keys.sorted() == [studio.fleetID])
        #expect(plan[studio.fleetID] == PushRegistration(
            token: tokenHex, environment: .sandbox, topic: "uk.whatn.taskboard.ios", kinds: [.approval, .question], turns: .background, sound: false,
            machineName: "Mac Studio", connection: studio.fleetID))
    }

    @Test("画面で隠している接続先は種類を空にし、ターンの完了も出さない")
    func hiddenMachineHasNoKinds() {
        let studio = connection("Mac Studio", host: "studio.example.com", paired: true)
        let secondMac = connection("Mac mini", host: "mini.example.com", paired: true)
        let plan = PushPlan.registrations(
            connections: [studio, secondMac], token: tokenHex, environment: .sandbox, topic: "t", kinds: Set(NotifyKind.allCases), turns: .always, sound: true,
            isHidden: { $0 == secondMac.fleetID })
        #expect(plan[studio.fleetID]?.kinds == NotifyKind.allCases)
        #expect(plan[studio.fleetID]?.turns == .always)
        #expect(plan[secondMac.fleetID]?.kinds == [])
        #expect(plan[secondMac.fleetID]?.turns == TurnNotify.never)
    }

    @Test("前面で届いた通知: ターンの完了は「常に」のときだけ出し、ほかの通知は設定に関わらず出す")
    func foregroundPresentation() {
        #expect(InboxNotifier.presentation(turn: true, setting: .always) == [.banner, .sound, .list])
        #expect(InboxNotifier.presentation(turn: true, setting: .background).isEmpty)
        #expect(InboxNotifier.presentation(turn: true, setting: .never).isEmpty)
        #expect(InboxNotifier.presentation(turn: false, setting: .never) == [.banner, .sound, .list])
    }

    @Test("長い名前は daemon の上限で切る")
    func longNameIsCut() {
        let long = connection(String(repeating: "長", count: 80), host: "long.example.com", paired: true)
        let plan = PushPlan.registrations(
            connections: [long], token: tokenHex, environment: .production, topic: "t", kinds: [], sound: true, isHidden: { _ in false })
        #expect(plan[long.fleetID]?.machineName.count == PushRegistration.machineNameLimit)
        #expect(plan[long.fleetID]?.kinds == [])
    }
}

@MainActor
@Suite struct InboxNotifierPushTests {
    @Test("APNs が届くマシンの項目はローカル通知にしない")
    func deliveredByPushIsNotPostedLocally() async throws {
        let fleet = Fleet()
        fleet.add(id: "conn:studio", source: try FixtureSource.named("stress"))
        for _ in 0..<100 where fleet.allMachines.values.contains(where: { $0.machine == nil }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let items = InboxNotifier.loud(fleet.inbox.items)
        let machines = Set(items.map(\.machine))
        #expect(!items.isEmpty)
        let all = Set(NotifyKind.allCases)
        #expect(InboxNotifier.fresh(items, baselined: machines, known: [], kinds: all, deliveredByPush: []).count == items.count)
        #expect(InboxNotifier.fresh(items, baselined: machines, known: [], kinds: all, deliveredByPush: machines).isEmpty)
        // 基準を取る前・既知の項目は、APNs と関係なく鳴らさない
        #expect(InboxNotifier.fresh(items, baselined: [], known: [], kinds: all, deliveredByPush: []).isEmpty)
        #expect(InboxNotifier.fresh(items, baselined: machines, known: Set(items.map(\.id)), kinds: all, deliveredByPush: []).isEmpty)
    }
}

@MainActor
@Suite struct PushAnswerTests {
    @Test("［常に許可］は、通知が運んだ候補の id を添えた許可。候補の無い通知には答えない")
    func alwaysAllow() throws {
        let info: [AnyHashable: Any] = [
            PushPayload.connection: "conn:studio", PushPayload.conversation: "c1", PushPayload.request: "r1", PushPayload.suggestion: "2",
        ]
        let answer = try #require(PushCenter.Answer(actionID: PushPayload.alwaysAllowAction, userInfo: info))
        #expect(answer.target == .init(conversation: "c1", request: "r1", allow: true, suggestion: "2"))
        var noSuggestion = info
        noSuggestion[PushPayload.suggestion] = nil
        #expect(PushCenter.Answer(actionID: PushPayload.alwaysAllowAction, userInfo: noSuggestion) == nil)
        // 許可・拒否は候補を運ぶ通知でも、ただの許可・拒否
        #expect(PushCenter.Answer(actionID: PushPayload.allowAction, userInfo: info)?.target == .init(conversation: "c1", request: "r1", allow: true, suggestion: nil))
    }

    private let info: [AnyHashable: Any] = [
        PushPayload.connection: "conn:studio", PushPayload.conversation: "c1", PushPayload.request: "r1",
        PushPayload.item: "studio/conversation/c1", PushPayload.url: "taskboard://conversation/studio/c1",
    ]

    @Test("通知そのものを押したときと、応答に要る値が欠けた通知は答えない")
    func notAnAnswer() {
        #expect(PushCenter.Answer(actionID: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info) == nil)
        var missing = info
        missing[PushPayload.request] = nil
        #expect(PushCenter.Answer(actionID: PushPayload.allowAction, userInfo: missing) == nil)
        #expect(PushCenter.Answer(actionID: PushPayload.allowAction, userInfo: info)?.url == URL(string: "taskboard://conversation/studio/c1"))
    }

    @Test("接続先を消した後の通知は答えない")
    func unknownConnection() async throws {
        let center = PushCenter(environment: .sandbox, topic: "t")
        let request = try #require(PushCenter.Answer(actionID: PushPayload.allowAction, userInfo: info))
        #expect(await center.answer(request, connections: [])
            .failure?.text == "応答できませんでした。通知の接続先が見つかりません。")
    }

    @Test("会話の問いの通知は、問いの id で会話に答え、答え済み（409）なら会話を開く知らせにする")
    func conversationAnswer() async throws {
        for (status, body, expected) in [
            (204, "", PushCenter.AnswerOutcome.answered),
            (409, #"{"error":{"message":"not waiting","code":"notWaiting"}}"#, .stale),
        ] {
            let host = "conv-\(status).test"
            let session = StubDaemon.session(host: host) { _ in .init(status: status, body: body) }
            let center = PushCenter(environment: .sandbox, topic: "t", session: session)
            var studio = connection("Mac Studio", host: host, paired: true)
            studio.id = UUID()
            let info: [AnyHashable: Any] = [
                PushPayload.connection: studio.fleetID, PushPayload.conversation: "c1", PushPayload.request: "r1",
                PushPayload.url: "taskboard://conversation/m/c1",
            ]
            let answer = try #require(PushCenter.Answer(actionID: PushPayload.denyAction, userInfo: info))
            #expect(answer.target == .init(conversation: "c1", request: "r1", allow: false, suggestion: nil))
            #expect(await center.answer(answer, connections: [studio]) == expected)
            let requests = StubDaemon.requests(host)
            #expect(requests.map(\.path) == ["/v1/conversations/c1/answers"])
            let sent = try WireJSON.decoder().decode(ConversationAnswerRequest.self, from: try #require(requests.first?.body))
            #expect(sent == ConversationAnswerRequest(requestID: "r1", allow: false))
        }
    }
}

@MainActor
@Suite struct PushCenterSyncTests {
    private struct Setup {
        let center: PushCenter
        let studio: SavedConnection
        let manual: SavedConnection
        let host: String
    }

    private func setup(_ reply: @escaping @Sendable (StubDaemon.Received) -> StubDaemon.Reply) -> Setup {
        let host = "sync-\(UUID().uuidString.prefix(8)).example.com"
        let center = PushCenter(environment: .sandbox, topic: "uk.whatn.taskboard.ios", session: StubDaemon.session(host: host, reply))
        center.set(authorization: .allowed)
        center.receive(token: token)
        return Setup(center: center, studio: connection("Mac Studio", host: host, paired: true), manual: connection("Mac mini", host: host, paired: false), host: host)
    }

    private func settle(_ center: PushCenter) async throws {
        for _ in 0..<100 where center.entries.values.contains(where: { $0.registered == nil && $0.failure == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    private func sync(_ s: Setup, kinds: Set<NotifyKind> = Set(NotifyKind.allCases), hidden: Bool = false, force: Bool = false) {
        s.center.sync(connections: [s.studio, s.manual], kinds: kinds, sound: true, isHidden: { _ in hidden }, force: force)
    }

    @Test("登録できた接続先は届く。手で入れた接続先には送らない。同じ中身は送り直さない")
    func registersOnce() async throws {
        let s = setup { _ in .init(status: 200, body: #"{"delivering":true}"#) }
        sync(s)
        try await settle(s.center)
        let requests = StubDaemon.requests(s.host)
        #expect(requests.map { "\($0.method) \($0.path)" } == ["PUT /v1/devices/current/push"])
        let sent = try JSONDecoder().decode(PushRegistration.self, from: try #require(requests.first?.body))
        #expect(sent.token == tokenHex)
        #expect(sent.connection == s.studio.fleetID)
        #expect(s.center.deliveringConnections == [s.studio.fleetID])
        #expect(s.center.status(for: s.studio, hidden: false) == .delivering)
        #expect(s.center.status(for: s.manual, hidden: false) == .manualConnection)
        sync(s)
        try await settle(s.center)
        #expect(StubDaemon.requests(s.host).count == 1)
    }

    @Test("通知の種類を変えたり、1台だけ表示で隠したりしたら送り直す")
    func resendsOnChange() async throws {
        let s = setup { _ in .init(status: 200, body: #"{"delivering":true}"#) }
        sync(s)
        try await settle(s.center)
        sync(s, kinds: [.question])
        try await settle(s.center)
        sync(s, kinds: [.question], hidden: true)
        try await settle(s.center)
        let kinds = try StubDaemon.requests(s.host).map { try JSONDecoder().decode(PushRegistration.self, from: $0.body).kinds }
        #expect(kinds == [NotifyKind.allCases, [.question], []])
        #expect(s.center.status(for: s.studio, hidden: true) == .hidden)
    }

    @Test("接続先のMacに鍵が無ければ届かないと出し、ローカル通知を止めない")
    func notSending() async throws {
        let s = setup { _ in .init(status: 200, body: #"{"delivering":false}"#) }
        sync(s)
        try await settle(s.center)
        #expect(s.center.deliveringConnections.isEmpty)
        #expect(s.center.status(for: s.studio, hidden: false) == .notSending)
    }

    @Test("口の無い古い daemon には、前面に戻るまで送り直さない")
    func oldDaemonRetriesOnForeground() async throws {
        let s = setup { _ in .init(status: 404) }
        sync(s)
        try await settle(s.center)
        #expect(s.center.deliveringConnections.isEmpty)
        #expect(s.center.status(for: s.studio, hidden: false).text
            == "登録できませんでした。接続先のMacのTaskboardがこの操作に対応していません。接続先のMacのTaskboardを更新してください。")
        sync(s)
        try await settle(s.center)
        #expect(StubDaemon.requests(s.host).count == 1)
        sync(s, force: true)
        try await settle(s.center)
        #expect(StubDaemon.requests(s.host).count == 2)
    }

    @Test("通知が許可されなくなったら登録を外し、ローカル通知に戻す")
    func deniedUnregisters() async throws {
        let s = setup { request in request.method == "DELETE" ? .init(status: 204) : .init(status: 200, body: #"{"delivering":true}"#) }
        sync(s)
        try await settle(s.center)
        s.center.set(authorization: .denied)
        #expect(s.center.deliveringConnections.isEmpty)
        sync(s)
        try await Task.sleep(for: .milliseconds(100))
        #expect(StubDaemon.requests(s.host).map(\.method) == ["PUT", "DELETE"])
        #expect(s.center.status(for: s.studio, hidden: false) == .notAuthorized)
        sync(s)
        try await Task.sleep(for: .milliseconds(50))
        #expect(StubDaemon.requests(s.host).count == 2)
    }

    @Test("許可されていないまま起動したら、前の起動で登録したかもしれない接続先に 1 度だけ解除を送る")
    func deniedAtLaunchUnregistersOnce() async throws {
        let s = setup { _ in .init(status: 204) }
        s.center.set(authorization: .denied)
        sync(s)
        try await Task.sleep(for: .milliseconds(100))
        sync(s)
        try await Task.sleep(for: .milliseconds(50))
        #expect(StubDaemon.requests(s.host).map { "\($0.method) \($0.path)" } == ["DELETE /v1/devices/current/push"])
    }

    @Test("トークンが届くまでは送らない")
    func waitsForToken() async throws {
        let host = "notoken-\(UUID().uuidString.prefix(8)).example.com"
        let center = PushCenter(environment: .sandbox, topic: "t", session: StubDaemon.session(host: host) { _ in .init(status: 200, body: #"{"delivering":true}"#) })
        center.set(authorization: .allowed)
        let studio = connection("Mac Studio", host: host, paired: true)
        center.sync(connections: [studio], kinds: [], sound: true, isHidden: { _ in false })
        try await Task.sleep(for: .milliseconds(50))
        #expect(StubDaemon.requests(host).isEmpty)
        #expect(center.status(for: studio, hidden: false) == .pending)
    }
}
