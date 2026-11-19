import Foundation
import Hummingbird
import HummingbirdTesting
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// codex 0.162.1 の app-server の応答（この Mac の実測から。email と ID は置き換えた）
private enum Reply {
    static let initialize = #"{"userAgent":"taskboard/0.162.1 (Mac OS 26.7.1; arm64) unknown (taskboard; 0)","codexHome":"/Users/test/.codex","platformFamily":"unix","platformOs":"macos"}"#
    static let account = #"{"account":{"type":"chatgpt","email":"someone@example.com","planType":"enterprise_cbp_usage_based"},"requiresOpenaiAuth":true}"#
    static func rateLimits(used: String) -> String {
        #"{"ordinaryUsageAllowed":null,"rateLimits":{"limitId":"codex","limitName":null,"primary":null,"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":null},"individualLimit":{"limit":"6000","used":"\#(used)","remainingPercent":19,"resetsAt":1793491201},"spendControlReached":false,"planType":"enterprise_cbp_usage_based","rateLimitReachedType":null},"rateLimitsByLimitId":null,"rateLimitResetCredits":null,"accountId":"acct","rateLimitUpsell":null}"#
    }
    static let windows = #"{"rateLimits":{"primary":{"usedPercent":13,"windowDurationMins":300,"resetsAt":1791107800},"secondary":{"usedPercent":31,"windowDurationMins":null,"resetsAt":null},"individualLimit":null}}"#
    static let models = #"{"data":[{"id":"gpt-6.1-sol","model":"gpt-6.1-sol","displayName":"GPT-6.1-Sol","hidden":false,"isDefault":true,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"medium","description":"Balanced"}]},{"id":"codex-auto-review","model":"codex-auto-review","displayName":"Codex Auto Review","hidden":true,"isDefault":false,"defaultReasoningEffort":"low","supportedReasoningEfforts":[]}],"nextCursor":null}"#
    static let connectors = #"{"data":[{"name":"codex_apps","runtimeStatus":null,"authStatus":"bearerToken","tools":{"a":{"name":"a"},"b":{"name":"b"}},"toolsError":null,"resources":[]},{"name":"context7","runtimeStatus":null,"authStatus":"notLoggedIn","tools":{},"toolsError":"boom","resources":[]}],"nextCursor":null}"#
    static let rateLimitsUpdated = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":null,"secondary":null,"credits":null,"individualLimit":null,"spendControlReached":null,"planType":null,"rateLimitReachedType":null}}}"#
}

/// 行を返す偽の app-server。method ごとの応答（result の JSON か、nil なら error）を `replies` で引く
final class FakeAppServer: CodexChannel, @unchecked Sendable {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var replies: [String: String?]
    private var calls: [String] = []
    private var terminated = false

    init(replies: [String: String?]) {
        self.replies = replies
        (lines, continuation) = AsyncStream<Data>.makeStream()
    }

    var methods: [String] { lock.withLock { calls } }
    var isTerminated: Bool { lock.withLock { terminated } }
    func count(_ method: String) -> Int { methods.filter { $0 == method }.count }

    func setReply(_ method: String, _ reply: String?) { lock.withLock { replies[method] = reply } }

    func write(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let method = object["method"] as? String else { return }
        lock.withLock { calls.append(method) }
        guard let id = object["id"] else { return }
        let idJSON = String(decoding: try JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), as: UTF8.self)
        let reply: String?? = lock.withLock { replies[method] }
        switch reply {
        case .some(.some(let result)): continuation.yield(Data(#"{"id":\#(idJSON),"result":\#(result)}"#.utf8))
        case .some(.none), .none:
            continuation.yield(Data(#"{"id":\#(idJSON),"error":{"code":-32600,"message":"Invalid request: unknown variant `\#(method)`"}}"#.utf8))
        }
    }

    func push(_ line: String) { continuation.yield(Data(line.utf8)) }

    /// 子が終わった
    func exit() { continuation.finish() }

    func terminate() {
        lock.withLock { terminated = true }
        continuation.finish()
    }
}

/// 起こした偽物を順に持つ
final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeAppServer] = []
    let replies: [String: String?]

    init(replies: [String: String?]) { self.replies = replies }

    var all: [FakeAppServer] { lock.withLock { made } }

    var launch: CodexMachine.Launch {
        { [self] in
            let server = FakeAppServer(replies: replies)
            lock.withLock { made.append(server) }
            return server
        }
    }
}

@Suite("codex のマシンの接続")
struct CodexMachineTests {
    static let full: [String: String?] = [
        "initialize": Reply.initialize, "account/read": Reply.account, "account/rateLimits/read": Reply.rateLimits(used: "4839.66"),
        "model/list": Reply.models, "mcpServerStatus/list": Reply.connectors,
    ]
    static let fast = CodexMachine.Timing(
        request: .seconds(2), refresh: .seconds(3600), coalesce: .milliseconds(100), restartFirst: .milliseconds(50), restartMax: .milliseconds(200),
        healthy: .seconds(3600))

    func makeState() -> DaemonState {
        DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("握手してから 4 つを読み、利用枠を state に入れる。email は持たない")
    func handshakeAndReads() async throws {
        let state = makeState()
        let launches = Launches(replies: Self.full)
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        let machine = CodexMachine(state: state, launch: launches.launch, timing: Self.fast, now: { at })
        let run = Task { await machine.run() }
        defer { run.cancel() }

        #expect(await eventually { await machine.connectors != nil })
        let server = try #require(launches.all.first)
        #expect(Array(server.methods.prefix(6)) == ["initialize", "initialized", "account/read", "account/rateLimits/read", "model/list", "mcpServerStatus/list"])
        #expect(await machine.version == "0.162.1")
        #expect(await machine.account == CodexMachineInfo.Account(kind: "chatgpt", planType: "enterprise_cbp_usage_based"))
        #expect(await machine.models == [
            CodexMachineInfo.Model(id: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", isDefault: true, hidden: false, defaultEffort: "medium", efforts: ["low", "medium"]),
            CodexMachineInfo.Model(id: "codex-auto-review", displayName: "Codex Auto Review", isDefault: false, hidden: true, defaultEffort: "low", efforts: []),
        ])
        #expect(await machine.connectors == [
            CodexMachineInfo.Connector(name: "codex_apps", authStatus: "bearerToken", runtimeStatus: nil, toolCount: 2, toolsError: false),
            CodexMachineInfo.Connector(name: "context7", authStatus: "notLoggedIn", runtimeStatus: nil, toolCount: 0, toolsError: true),
        ])
        let monthly = try #require(await state.usageSnapshot().codex?.monthly)
        #expect(abs(monthly.usedPercent - 80.661) < 0.001)
        #expect(monthly.used == 4839.66)
        #expect(monthly.limit == 6000)
        #expect(monthly.resetsAt == Date(timeIntervalSince1970: 1_793_491_201))
        #expect(await state.usageSnapshot().codex?.fetchedAt == at)
        #expect(await state.usageSnapshot().codex?.primary == nil)
        #expect(!"\(await machine.account as Any)".contains("someone@example.com"))
    }

    @Test("rateLimits/updated は合図にして、続けて届いた分はまとめて 1 回だけ読み直す。従量の枠は消えない")
    func coalescedRefresh() async throws {
        let state = makeState()
        let launches = Launches(replies: Self.full)
        let machine = CodexMachine(state: state, launch: launches.launch, timing: Self.fast)
        let run = Task { await machine.run() }
        defer { run.cancel() }
        #expect(await eventually { await machine.connectors != nil })
        let server = try #require(launches.all.first)
        #expect(server.count("account/rateLimits/read") == 1)

        server.setReply("account/rateLimits/read", Reply.rateLimits(used: "5400"))
        for _ in 0..<5 { server.push(Reply.rateLimitsUpdated) }
        #expect(await eventually { server.count("account/rateLimits/read") == 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.count("account/rateLimits/read") == 2)
        #expect(await state.usageSnapshot().codex?.monthly?.used == 5400)
        #expect(abs((await state.usageSnapshot().codex?.monthly?.usedPercent ?? 0) - 90) < 0.001)
    }

    @Test("method の無い古い codex では、その値を無しにして続ける")
    func olderServer() async throws {
        let state = makeState()
        await state.setCodex(CodexUsage(primary: nil, secondary: nil, monthly: .init(usedPercent: 1, used: nil, limit: nil, resetsAt: nil), fetchedAt: nil))
        var replies = Self.full
        replies["account/rateLimits/read"] = .some(nil)
        replies["mcpServerStatus/list"] = .some(nil)
        replies["model/list"] = #"{"unexpected":true}"#
        let launches = Launches(replies: replies)
        let machine = CodexMachine(state: state, launch: launches.launch, timing: Self.fast)
        let run = Task { await machine.run() }
        defer { run.cancel() }

        #expect(await eventually { launches.all.first?.count("mcpServerStatus/list") == 1 })
        #expect(await eventually { await state.usageSnapshot().codex == nil })
        #expect(await machine.account != nil)
        #expect(await machine.models == nil)
        #expect(await machine.connectors == nil)
        #expect(launches.all.count == 1)
        #expect(launches.all.first?.isTerminated == false)
    }

    @Test("コネクタの読み直しは、前に読んでから 30 秒たつまで読まず、同時に頼まれても 1 回だけ読む")
    func connectorRefresh() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_792_000_000))
        let launches = Launches(replies: Self.full)
        let machine = CodexMachine(state: makeState(), launch: launches.launch, timing: Self.fast, now: { clock.now })
        let run = Task { await machine.run() }
        defer { run.cancel() }
        #expect(await eventually { await machine.info().connected })
        let server = try #require(launches.all.first)
        #expect(server.count("mcpServerStatus/list") == 1)

        let early = await machine.refreshConnectors()
        #expect(server.count("mcpServerStatus/list") == 1)
        #expect(early.connectorsReadAt == Date(timeIntervalSince1970: 1_792_000_000))

        clock.advance(31)
        async let first = machine.refreshConnectors()
        async let second = machine.refreshConnectors()
        let (a, b) = await (first, second)
        #expect(server.count("mcpServerStatus/list") == 2)
        #expect(a.connectorsReadAt == Date(timeIntervalSince1970: 1_792_000_031))
        #expect(a == b)
        #expect(a.connectors?.map(\.name) == ["codex_apps", "context7"])
        #expect(a.version == "0.162.1")
        let encoded = String(decoding: try WireJSON.encoder().encode(a), as: UTF8.self)
        #expect(!encoded.contains("someone@example.com"))
        #expect(!encoded.contains("acct"))
    }

    @Test("子と繋がっていないときは読まずに、繋がっていないと返す")
    func refreshWithoutChild() async {
        let machine = CodexMachine(state: makeState(), launch: { throw CodexLaunchError.notFound }, timing: Self.fast)
        let info = await machine.refreshConnectors()
        #expect(info == CodexMachineInfo(connected: false, logins: []))
    }

    @Test("API：GET /v1/codex は読んだ値を、POST /v1/codex/connectors/refresh は読み直した値を返す。マシンの接続が無ければ 503")
    func routes() async throws {
        let state = makeState()
        let launches = Launches(replies: Self.full)
        let machine = CodexMachine(state: state, launch: launches.launch, timing: Self.fast)
        let run = Task { await machine.run() }
        defer { run.cancel() }
        #expect(await eventually { await machine.info().connected })
        var dependencies = APIServer.Dependencies()
        dependencies.codex = machine
        let app = APIServer.application(state: state, token: "t", port: 0, dependencies: dependencies)
        try await app.test(.router) { client in
            let got = try await client.execute(uri: "/v1/codex", method: .get, headers: [.authorization: "Bearer t"])
            #expect(got.status == .ok)
            let info = try WireJSON.decoder().decode(CodexMachineInfo.self, from: got.body)
            #expect(info.account == CodexMachineInfo.Account(kind: "chatgpt", planType: "enterprise_cbp_usage_based"))
            #expect(info.models?.count == 2)
            let refreshed = try await client.execute(uri: "/v1/codex/connectors/refresh", method: .post, headers: [.authorization: "Bearer t"])
            #expect(refreshed.status == .ok)
            #expect(try WireJSON.decoder().decode(CodexMachineInfo.self, from: refreshed.body).connectors?.count == 2)
        }
        let bare = APIServer.application(state: state, token: "t", port: 0, dependencies: APIServer.Dependencies())
        try await bare.test(.router) { client in
            let response = try await client.execute(uri: "/v1/codex", method: .get, headers: [.authorization: "Bearer t"])
            #expect(response.status == .serviceUnavailable)
        }
    }

    @Test("窓のある契約は primary・secondary に入れる")
    func windows() throws {
        let snapshot = try JSONDecoder().decode(RateLimitsBox.self, from: Data(Reply.windows.utf8)).rateLimits
        let usage = try #require(CodexMachine.usage(snapshot, at: Date(timeIntervalSince1970: 0)))
        #expect(usage.primary == UsageWindow(usedPercent: 13, resetsAt: Date(timeIntervalSince1970: 1_791_107_800), windowSeconds: 18_000))
        #expect(usage.secondary == UsageWindow(usedPercent: 31, resetsAt: nil, windowSeconds: 0))
        #expect(usage.monthly == nil)
        let empty = try JSONDecoder().decode(RateLimitsBox.self, from: Data(#"{"rateLimits":{"primary":null}}"#.utf8)).rateLimits
        #expect(CodexMachine.usage(empty, at: Date()) == nil)
    }

    @Test("used と limit が読めなければ 100 − remainingPercent")
    func remainingPercentFallback() throws {
        let raw = #"{"rateLimits":{"individualLimit":{"limit":"","used":"x","remainingPercent":28,"resetsAt":1793491200}}}"#
        let snapshot = try JSONDecoder().decode(RateLimitsBox.self, from: Data(raw.utf8)).rateLimits
        #expect(CodexMachine.usage(snapshot, at: Date())?.monthly?.usedPercent == 72)
    }

    @Test("子が終わったら起こし直し、新しい世代で読み直す。daemon の終わりで子を止める")
    func restartsAfterExit() async throws {
        let state = makeState()
        let launches = Launches(replies: Self.full)
        let machine = CodexMachine(state: state, launch: launches.launch, timing: Self.fast)
        let run = Task { await machine.run() }
        #expect(await eventually { await machine.connectors != nil })
        let first = try #require(launches.all.first)
        first.exit()
        #expect(await eventually { launches.all.count == 2 && launches.all[1].count("mcpServerStatus/list") == 1 })
        #expect(first.isTerminated)

        await machine.shutdown()
        #expect(await eventually { launches.all[1].isTerminated })
        run.cancel()
        await run.value
        #expect(launches.all.allSatisfy { $0.isTerminated })
    }

    @Test("起こせないときも、間をおいて起こし直す")
    func retriesLaunchFailures() async throws {
        let attempts = Counter()
        let machine = CodexMachine(
            state: makeState(), launch: { attempts.increment(); throw CodexLaunchError.notFound }, timing: Self.fast)
        let run = Task { await machine.run() }
        #expect(await eventually { attempts.value >= 3 })
        run.cancel()
        await run.value
    }

    @Test("ログインシェルの PATH の先頭から codex を引く")
    func executableLookup() {
        let found = CodexAppServerProcess.executable(path: "/usr/bin:/a/bin:/b/bin") { $0 == "/a/bin/codex" || $0 == "/b/bin/codex" }
        #expect(found?.path == "/a/bin/codex")
        #expect(CodexAppServerProcess.executable(path: "") { _ in true } == nil)
    }

    @Test("userAgent から版を読む")
    func version() {
        #expect(CodexMachine.version(userAgent: "taskboard/0.162.1 (Mac OS 26.7.1; arm64) unknown (taskboard; 0)") == "0.162.1")
        #expect(CodexMachine.version(userAgent: "taskboard") == nil)
        #expect(CodexMachine.version(userAgent: "taskboard/ (x)") == nil)
    }
}

private struct RateLimitsBox: Decodable {
    var rateLimits: RateLimitSnapshot
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
