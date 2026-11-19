import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// 開いた戻り先のアドレスを控える
private final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var fails = false
    var all: [URL] { lock.withLock { urls } }
    func open(_ url: URL) throws {
        lock.withLock { urls.append(url) }
        if fails { throw URLError(.cannotConnectToHost) }
    }
}

@Suite("codex のコネクタの認証")
struct CodexConnectorLoginTests {
    static let page = "https://auth.example.com/authorize?response_type=code&client_id=c&redirect_uri=http%3A%2F%2F127.0.0.1%3A5555%2Fcallback&state=st-1"
    static let callback = "http://127.0.0.1:5555/callback?code=abc&state=st-1"

    static func replies(loginId: String? = "L1", page: String = page) -> [String: String?] {
        var replies = CodexMachineTests.full
        let id = loginId.map { #","loginId":"\#($0)""# } ?? ""
        replies["mcpServer/oauth/login"] = #"{"authorizationUrl":"\#(page)"\#(id)}"#
        return replies
    }

    static func completed(_ name: String, loginId: String?, success: Bool) -> String {
        let id = loginId.map { #","loginId":"\#($0)""# } ?? ""
        return #"{"method":"mcpServer/oauthLogin/completed","params":{"name":"\#(name)","threadId":null\#(id),"success":\#(success),"error":"secret detail"}}"#
    }

    private struct World {
        let machine: CodexMachine
        let launches: Launches
        let opened: Opened
        let clock: TestClock
        let run: Task<Void, Never>
        var server: FakeAppServer { launches.all.last! }
    }

    private func world(_ replies: [String: String?] = replies()) async throws -> World {
        let launches = Launches(replies: replies)
        let opened = Opened()
        let clock = TestClock(Date(timeIntervalSince1970: 1_792_000_000))
        let machine = CodexMachine(
            state: DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t")),
            launch: launches.launch, timing: CodexMachineTests.fast, now: { clock.now }, openCallback: { try opened.open($0) })
        let run = Task { await machine.run() }
        #expect(await eventually { await machine.info().connected })
        return World(machine: machine, launches: launches, opened: opened, clock: clock, run: run)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("認証を始めると認証のページと loginId を返し、待ちを info に出す。戻り先のアドレスは 1 度だけ開く")
    func startAndCallback() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        let login = try await w.machine.startLogin(name: "tbprobe")
        #expect(login == CodexConnectorLogin(loginId: "L1", authorizationURL: Self.page))
        #expect(await w.machine.info().logins == [.init(id: "L1", name: "tbprobe", state: .waiting)])
        try await w.machine.deliverCallback(loginId: "L1", url: "  \(Self.callback)\n")
        #expect(w.opened.all.map(\.absoluteString) == [Self.callback])
        await #expect(throws: CodexOAuthLogins.Failure.noLogin) { try await w.machine.deliverCallback(loginId: "L1", url: Self.callback) }
        #expect(w.opened.all.count == 1)
    }

    @Test(
        "待っている認証の redirect_uri と port・path・state が違うアドレスや、callback の条件を満たさないアドレスは開かない",
        arguments: [
            "http://127.0.0.1:5556/callback?code=abc&state=st-1", "http://127.0.0.1:5555/other?code=abc&state=st-1",
            "http://127.0.0.1:5555/callback?code=abc&state=st-2", "https://127.0.0.1:5555/callback?code=abc&state=st-1",
            "http://example.com:5555/callback?code=abc&state=st-1", "http://u:p@127.0.0.1:5555/callback?code=abc&state=st-1",
            "http://127.0.0.1:5555/callback?code=abc&state=st-1#f", "http://127.0.0.1:5555/callback?state=st-1",
            "http://127.0.0.1:5555/callback?code=\(String(repeating: "a", count: 4100))&state=st-1",
        ])
    func refusesMismatchedCallbacks(url: String) async throws {
        let w = try await world()
        defer { w.run.cancel() }
        _ = try await w.machine.startLogin(name: "tbprobe")
        await #expect(throws: CodexOAuthLogins.Failure.callbackMismatch) { try await w.machine.deliverCallback(loginId: "L1", url: url) }
        #expect(w.opened.all.isEmpty)
    }

    @Test("localhost の戻り先と error の付いた戻り先は開く")
    func acceptsLocalhostAndError() async throws {
        let page = "https://auth.example.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A6000%2Fcb&state=s"
        let w = try await world(Self.replies(page: page))
        defer { w.run.cancel() }
        _ = try await w.machine.startLogin(name: "tbprobe")
        try await w.machine.deliverCallback(loginId: "L1", url: "http://localhost:6000/cb?error=access_denied&state=s")
        #expect(w.opened.all.count == 1)
    }

    @Test("開けなかった戻り先は、もう一度送れる")
    func retriesUnreachableCallback() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        _ = try await w.machine.startLogin(name: "tbprobe")
        w.opened.fails = true
        await #expect(throws: CodexOAuthLogins.Failure.callbackUnreachable) { try await w.machine.deliverCallback(loginId: "L1", url: Self.callback) }
        w.opened.fails = false
        try await w.machine.deliverCallback(loginId: "L1", url: Self.callback)
        #expect(w.opened.all.count == 2)
    }

    @Test("完了の知らせは loginId で照らし合わせ、30 秒たっていなくてもコネクタを読み直す。違う loginId の知らせは捨てる")
    func completionByLoginID() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        _ = try await w.machine.startLogin(name: "tbprobe")
        let reads = w.server.count("mcpServerStatus/list")
        w.server.push(Self.completed("tbprobe", loginId: "OTHER", success: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await w.machine.info().logins == [.init(id: "L1", name: "tbprobe", state: .waiting)])
        w.server.push(Self.completed("tbprobe", loginId: "L1", success: true))
        #expect(await eventually { await w.machine.info().logins == [.init(id: "L1", name: "tbprobe", state: .succeeded)] })
        #expect(await eventually { w.server.count("mcpServerStatus/list") == reads + 1 })
        await #expect(throws: CodexOAuthLogins.Failure.noLogin) { try await w.machine.deliverCallback(loginId: "L1", url: Self.callback) }
    }

    @Test("loginId を返さない古い codex では認証を始めない。loginId の無い完了の知らせは捨てる。失敗も結果に残す")
    func requiresLoginID() async throws {
        let old = try await world(Self.replies(loginId: nil))
        defer { old.run.cancel() }
        await #expect(throws: CodexOAuthLogins.Failure.outdated) { _ = try await old.machine.startLogin(name: "tbprobe") }

        let w = try await world()
        defer { w.run.cancel() }
        _ = try await w.machine.startLogin(name: "tbprobe")
        w.server.push(Self.completed("tbprobe", loginId: nil, success: true))
        w.server.push(Self.completed("other", loginId: "L1", success: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await w.machine.info().logins == [.init(id: "L1", name: "tbprobe", state: .waiting)])
        w.server.push(Self.completed("tbprobe", loginId: "L1", success: false))
        #expect(await eventually { await w.machine.info().logins == [.init(id: "L1", name: "tbprobe", state: .failed)] })
    }

    @Test("時間が過ぎた待ちは失敗になり、その後に届いた完了の知らせで成功にしない")
    func expiredLoginIgnoresLateCompletion() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        _ = try await w.machine.startLogin(name: "tbprobe")
        w.clock.advance(601)
        w.server.push(Self.completed("tbprobe", loginId: "L1", success: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await w.machine.info().logins == [.init(id: "L1", name: "tbprobe", state: .failed)])

        _ = try await w.machine.startLogin(name: "other")
        w.clock.advance(601)
        #expect(await w.machine.info().logins?.first { $0.name == "other" }?.state == .failed)
    }

    @Test("取り消した・時間が過ぎた・子が終わった待ちの戻り先は開かない")
    func dropsWaits() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        _ = try await w.machine.startLogin(name: "tbprobe")
        await w.machine.cancelLogin(loginId: "L1")
        await #expect(throws: CodexOAuthLogins.Failure.noLogin) { try await w.machine.deliverCallback(loginId: "L1", url: Self.callback) }

        _ = try await w.machine.startLogin(name: "tbprobe")
        w.clock.advance(601)
        await #expect(throws: CodexOAuthLogins.Failure.noLogin) { try await w.machine.deliverCallback(loginId: "L1", url: Self.callback) }
        #expect(await w.machine.info().logins == [.init(id: "L1", name: "tbprobe", state: .failed)])

        _ = try await w.machine.startLogin(name: "tbprobe")
        let first = w.server
        first.exit()
        #expect(await eventually { w.launches.all.count == 2 })
        await #expect(throws: CodexOAuthLogins.Failure.noLogin) { try await w.machine.deliverCallback(loginId: "L1", url: Self.callback) }
        #expect(w.opened.all.isEmpty)
    }

    @Test("codex が断った認証と、開いてはいけない認証のページは始めない")
    func refusesStart() async throws {
        var replies = Self.replies(page: "javascript:alert(1)")
        let w = try await world(replies)
        defer { w.run.cancel() }
        await #expect(throws: CodexOAuthLogins.Failure.unopenablePage) { _ = try await w.machine.startLogin(name: "tbprobe") }
        replies["mcpServer/oauth/login"] = .some(nil)
        let refusing = try await world(replies)
        defer { refusing.run.cancel() }
        await #expect(throws: CodexOAuthLogins.Failure.refused("Invalid request: unknown variant `mcpServer/oauth/login`")) {
            _ = try await refusing.machine.startLogin(name: "tbprobe")
        }
        #expect(await refusing.machine.info().logins == [])
    }

    private static func post(_ client: some TestClientProtocol, _ path: String, _ body: some Encodable) async throws -> TestResponse {
        try await client.execute(
            uri: path, method: .post, headers: [.authorization: "Bearer t", .contentType: "application/json"],
            body: ByteBuffer(bytes: try WireJSON.encoder().encode(body)))
    }

    @Test("API：認証を始めると認証のページを返し、戻り先は 204、違うアドレスと待ちの無い認証は 400。取り消しは 204")
    func routes() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        var dependencies = APIServer.Dependencies()
        dependencies.codex = w.machine
        let app = APIServer.application(state: DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t")), token: "t", port: 0, dependencies: dependencies)
        try await app.test(.router) { client in
            let started = try await Self.post(client, "/v1/codex/connectors/login", CodexConnectorLoginRequest(name: "tbprobe"))
            #expect(started.status == .ok)
            #expect(try WireJSON.decoder().decode(CodexConnectorLogin.self, from: started.body).loginId == "L1")
            let wrong = try await Self.post(client, "/v1/codex/connectors/login/callback", CodexConnectorCallbackRequest(loginId: "L1", callbackURL: "http://127.0.0.1:1/x"))
            #expect(wrong.status == .badRequest)
            let ok = try await Self.post(client, "/v1/codex/connectors/login/callback", CodexConnectorCallbackRequest(loginId: "L1", callbackURL: Self.callback))
            #expect(ok.status == .noContent)
            let cancelled = try await Self.post(client, "/v1/codex/connectors/login/cancel", CodexConnectorLoginCancel(loginId: "L1"))
            #expect(cancelled.status == .noContent)
            let gone = try await Self.post(client, "/v1/codex/connectors/login/callback", CodexConnectorCallbackRequest(loginId: "L1", callbackURL: Self.callback))
            #expect(gone.status == .badRequest)
        }
        #expect(w.opened.all.count == 1)
    }
}
