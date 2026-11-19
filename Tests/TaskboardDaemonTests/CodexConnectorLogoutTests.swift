import Foundation
import Hummingbird
import HummingbirdTesting
import TaskboardKit
import TestSupport
import Testing

@testable import TaskboardDaemon

/// 渡された名前を控え、決めた失敗を投げる `codex mcp logout` の偽物
private final class Logouts: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var failure: CodexMachine.LogoutError?
    var all: [String] { lock.withLock { names } }
    var command: CodexMachine.Logout {
        { [self] name in
            lock.withLock { names.append(name) }
            if let failure { throw failure }
        }
    }
}

@Suite("codex のコネクタの認証の解除")
struct CodexConnectorLogoutTests {
    static func replies(auth: String = "oAuth") -> [String: String?] {
        var replies = CodexMachineTests.full
        replies["config/mcpServer/reload"] = "{}"
        replies["mcpServerStatus/list"] =
            #"{"data":[{"name":"tbprobe","runtimeStatus":null,"authStatus":"\#(auth)","tools":{"a":{"name":"a"}},"toolsError":null,"resources":[]}],"nextCursor":null}"#
        return replies
    }

    private struct World {
        let machine: CodexMachine
        let launches: Launches
        let logouts: Logouts
        let run: Task<Void, Never>
        var server: FakeAppServer { launches.all.last! }
    }

    private func world(_ replies: [String: String?] = replies(), connect: Bool = true) async throws -> World {
        let launches = Launches(replies: replies)
        let logouts = Logouts()
        let clock = TestClock(Date(timeIntervalSince1970: 1_792_000_000))
        let launch: CodexMachine.Launch
        if connect {
            launch = launches.launch
        } else {
            launch = { throw CodexLaunchError.notFound }
        }
        let machine = CodexMachine(
            state: DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t")),
            launch: launch, timing: CodexMachineTests.fast, now: { clock.now },
            logout: logouts.command)
        let run = Task { await machine.run() }
        if connect { #expect(await eventually { await machine.info().connected }) }
        return World(machine: machine, launches: launches, logouts: logouts, run: run)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    // MARK: マシンの接続

    @Test("読んだコネクタの名前だけを渡して解除し、app-server に設定を読み直させてから、30 秒たっていなくてもコネクタを読み直した値を返す")
    func logsOutAndRereads() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        let before = w.server.methods.count
        w.server.setReply("mcpServerStatus/list", Self.replies(auth: "notLoggedIn")["mcpServerStatus/list"]!)
        let info = try await w.machine.logout(name: "tbprobe")
        #expect(w.logouts.all == ["tbprobe"])
        #expect(Array(w.server.methods.dropFirst(before)) == ["config/mcpServer/reload", "mcpServerStatus/list"])
        #expect(info.connectors?.map(\.authStatus) == ["notLoggedIn"])
    }

    @Test("app-server が設定の読み直しを断っても、コネクタは読み直す")
    func rereadsWithoutReload() async throws {
        var replies = Self.replies()
        replies["config/mcpServer/reload"] = .some(nil)
        let w = try await world(replies)
        defer { w.run.cancel() }
        let reads = w.server.count("mcpServerStatus/list")
        _ = try await w.machine.logout(name: "tbprobe")
        #expect(w.server.count("mcpServerStatus/list") == reads + 1)
    }

    @Test("読んだ一覧に無い名前は、codex を走らせずに断る")
    func refusesUnknownName() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        let reads = w.server.count("mcpServerStatus/list")
        await #expect(throws: CodexMachine.LogoutError.unknownConnector) { _ = try await w.machine.logout(name: "nosuch") }
        await #expect(throws: CodexMachine.LogoutError.unknownConnector) { _ = try await w.machine.logout(name: "--help") }
        #expect(w.logouts.all.isEmpty)
        #expect(w.server.count("mcpServerStatus/list") == reads)
    }

    @Test("コネクタを読めない古い codex では、どの名前も断る")
    func refusesWhenConnectorsUnreadable() async throws {
        var replies = Self.replies()
        replies["mcpServerStatus/list"] = .some(nil)
        let w = try await world(replies)
        defer { w.run.cancel() }
        await #expect(throws: CodexMachine.LogoutError.unknownConnector) { _ = try await w.machine.logout(name: "tbprobe") }
        #expect(w.logouts.all.isEmpty)
    }

    @Test("マシンの接続が無ければ解除しない")
    func refusesWithoutConnection() async throws {
        let w = try await world(connect: false)
        defer { w.run.cancel() }
        await #expect(throws: CodexMachine.LogoutError.notConnected) { _ = try await w.machine.logout(name: "tbprobe") }
        #expect(w.logouts.all.isEmpty)
    }

    @Test("解除に失敗したら、その失敗を投げて、app-server には何も送らない")
    func failureSkipsReread() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        let before = w.server.methods.count
        w.logouts.failure = .refused
        await #expect(throws: CodexMachine.LogoutError.refused) { _ = try await w.machine.logout(name: "tbprobe") }
        #expect(w.server.methods.count == before)
    }

    // MARK: codex の実行

    /// 引数・環境の変数・stdin を置き場の `args`・`env` に残し、出力に秘密に見える文を出す。`FAKE_EXIT`・`FAKE_SLEEP` で振る舞いを替える
    private static let fakeCodex = SharedExecutable(
        name: "tb-test-codex-logout.sh",
        script: """
            #!/bin/sh
            dir="$(dirname "$0")"
            printf '%s\\n' "$@" > "$dir/args"
            printf '%s\\n' "$FAKE_MARK" > "$dir/env"
            pwd > "$dir/cwd"
            echo "Removed OAuth credentials for '$4'. token=secret-out"
            echo "Error: No MCP server named '$4' found in configuration. token=secret-err" >&2
            [ -n "$FAKE_SLEEP" ] && exec sleep "$FAKE_SLEEP"
            exit "${FAKE_EXIT:-0}"
            """)

    private struct Fake {
        let directory: URL
        let install: CodexInstall

        init(environment: [String: String] = [:]) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "codex-logout-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            install = CodexInstall(
                executable: try CodexConnectorLogoutTests.fakeCodex.link(in: directory, as: "codex"),
                environment: ["PATH": "/usr/bin:/bin", "FAKE_MARK": "from-install"].merging(environment) { $1 })
        }

        func read(_ file: String) -> String? { try? String(contentsOf: directory.appending(path: file), encoding: .utf8) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("codex mcp logout に、名前を `--` の後の 1 つの引数として渡す。環境は install のもの、作業フォルダはホーム")
    func runsCodexWithArguments() async throws {
        let fake = try Fake()
        defer { fake.remove() }
        let logout = CodexConnectors.logout(install: { fake.install })
        try await logout("tbprobe")
        try await logout("-x; touch /tmp/pwned $(id)")
        #expect(fake.read("args") == "mcp\nlogout\n--\n-x; touch /tmp/pwned $(id)\n")
        #expect(fake.read("env") == "from-install\n")
        #expect(fake.read("cwd").map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path }
            == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }

    @Test("終了コードが 0 以外なら refused、時間内に終わらなければ timedOut、codex が無ければ codexUnavailable。出力の文は失敗に載せない")
    func failureKinds() async throws {
        let failing = try Fake(environment: ["FAKE_EXIT": "1"])
        let sleeping = try Fake(environment: ["FAKE_SLEEP": "30"])
        defer {
            failing.remove()
            sleeping.remove()
        }
        let refused = await #expect(throws: CodexMachine.LogoutError.self) { try await CodexConnectors.logout(install: { failing.install })("tbprobe") }
        #expect(refused == .refused)
        let timedOut = await #expect(throws: CodexMachine.LogoutError.self) {
            try await CodexConnectors.logout(install: { sleeping.install }, timeout: .milliseconds(300))("tbprobe")
        }
        #expect(timedOut == .timedOut)
        let missing = await #expect(throws: CodexMachine.LogoutError.self) {
            try await CodexConnectors.logout(install: { throw CodexLaunchError.notFound })("tbprobe")
        }
        #expect(missing == .codexUnavailable)
        for error in [refused, timedOut, missing] { #expect(!"\(String(describing: error))".contains("secret")) }
    }

    // MARK: API

    private static func status(_ client: some TestClientProtocol, _ name: String) async throws -> HTTPResponse.Status {
        try await post(client, CodexConnectorLogoutRequest(name: name)).status
    }

    private static func post(_ client: some TestClientProtocol, _ body: some Encodable) async throws -> TestResponse {
        try await client.execute(
            uri: "/v1/codex/connectors/logout", method: .post, headers: [.authorization: "Bearer t", .contentType: "application/json"],
            body: ByteBuffer(bytes: try WireJSON.encoder().encode(body)))
    }

    @Test("API：解除すると読み直した値を 200 で返し、空の名前と一覧に無い名前は 400、codex の失敗は 502、接続が無ければ 503")
    func route() async throws {
        let w = try await world()
        defer { w.run.cancel() }
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
        var dependencies = APIServer.Dependencies()
        dependencies.codex = w.machine
        let app = APIServer.application(state: state, token: "t", port: 0, dependencies: dependencies)
        try await app.test(.router) { client in
            w.server.setReply("mcpServerStatus/list", Self.replies(auth: "notLoggedIn")["mcpServerStatus/list"]!)
            let ok = try await Self.post(client, CodexConnectorLogoutRequest(name: "tbprobe"))
            #expect(ok.status == .ok)
            #expect(try WireJSON.decoder().decode(CodexMachineInfo.self, from: ok.body).connectors?.first?.authStatus == "notLoggedIn")
            #expect(w.logouts.all == ["tbprobe"])
            #expect(try await Self.status(client, "") == .badRequest)
            #expect(try await Self.status(client, "nosuch") == .badRequest)
            #expect(w.logouts.all == ["tbprobe"])
            w.logouts.failure = .refused
            #expect(try await Self.status(client, "tbprobe") == .badGateway)
            w.logouts.failure = .timedOut
            #expect(try await Self.status(client, "tbprobe") == .badGateway)
            w.logouts.failure = .codexUnavailable
            #expect(try await Self.status(client, "tbprobe") == .serviceUnavailable)
        }
        let down = try await world(connect: false)
        defer { down.run.cancel() }
        dependencies.codex = down.machine
        let offline = APIServer.application(state: state, token: "t", port: 0, dependencies: dependencies)
        try await offline.test(.router) { client in
            let status = try await Self.status(client, "tbprobe")
            #expect(status == .serviceUnavailable)
        }
        let bare = APIServer.application(state: state, token: "t", port: 0, dependencies: APIServer.Dependencies())
        try await bare.test(.router) { client in
            let status = try await Self.status(client, "tbprobe")
            #expect(status == .serviceUnavailable)
        }
    }
}
