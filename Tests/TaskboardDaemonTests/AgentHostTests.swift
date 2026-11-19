import Foundation
import Logging
import NIOCore
import NIOPosix
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// 一時ディレクトリで host を動かし、client で繋ぐ。終わったら子を止めて host を畳む
private final class HostFixture: @unchecked Sendable {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// 接続の間に届いた hello と、key ごとの知らせ（`notices` が渡した所まで）
    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var hello: AgentHostReply?
        private var notices: [String: [AgentHostNotice]] = [:]
        private var handedOut: [String: Int] = [:]

        func connected(_ reply: AgentHostReply) { lock.withLock { hello = reply } }
        func append(_ notice: AgentHostNotice) { lock.withLock { notices[notice.key, default: []].append(notice) } }
        var connectedReply: AgentHostReply? { lock.withLock { hello } }

        /// まだ渡していない `key` の知らせを `count` 個まで取る。`all` なら足りなくても取る
        func take(_ key: String, count: Int, all: Bool) -> [AgentHostNotice]? {
            lock.withLock {
                let start = handedOut[key] ?? 0
                let pending = (notices[key] ?? [])[start...]
                guard pending.count >= count || all else { return nil }
                let taken = Array(pending.prefix(count))
                handedOut[key] = start + taken.count
                return taken
            }
        }
    }

    let directory: URL
    let server: Task<Void, any Error>
    let client: AgentHostClient
    private let drainFlag = Flag()
    private let received: Received
    private let reader: Task<Void, Never>

    var drained: Bool { drainFlag.isSet }

    /// `orphanMarker` は、起動時に止める親を失った子の env の印の値（テストが作った子だけを止める）
    /// `onNotice` は届いた知らせを受け取った順にもう 1 か所へ渡す（daemon の部品に流すテスト）
    init(
        limits: AgentHostRegistry.Limits = .init(), orphanMarker: String? = nil, directory given: URL? = nil,
        onNotice: (@Sendable (AgentHostNotice) -> Void)? = nil
    ) async throws {
        // unix socket のパスは 104 バイトまでなので、短い /tmp に置く
        let directory = given ?? URL(fileURLWithPath: "/tmp/tbah-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let flag = drainFlag
        server = Task {
            try await AgentHostServer.run(
                supportDirectory: directory, logger: Logger(label: "test"), limits: limits, stopsOrphan: { $0 == orphanMarker }
            ) { flag.set() }
        }
        let client = AgentHostClient(socketPath: AgentHostServer.socketURL(supportDirectory: directory).path, logger: Logger(label: "test"))
        self.client = client
        let received = Received()
        self.received = received
        // 読み手は 1 本で、接続の間ずっと読む。待つ側が時間切れで読み手を取り消すと AsyncStream ごと終わり、後の知らせが全部届かなくなる
        reader = Task {
            for await event in client.events {
                switch event {
                case .connected(let hello): received.connected(hello)
                case .notice(let notice):
                    received.append(notice)
                    onNotice?(notice)
                default: break
                }
            }
        }
        await client.start()
    }

    func connected(timeout: Duration = .seconds(30)) async throws -> AgentHostReply {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let hello = received.connectedReply { return hello }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentHostClient.Failure.notConnected
    }

    /// まだ受け取っていない `key` の知らせを `count` 個待つ（時間切れなら届いた分）。
    /// 上限は長くとる: 負荷の高い Mac では、起こした子が走り出すまでに 3 秒かかった（swift test の全体の始まり）
    func notices(_ key: String, count: Int, timeout: Duration = .seconds(30)) async -> [AgentHostNotice] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let notices = received.take(key, count: count, all: false) { return notices }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return received.take(key, count: count, all: true) ?? []
    }

    func close() async {
        for shell in (try? await client.call(.shellList).shells) ?? [] { _ = try? await client.call(.shellClose, key: shell.key) }
        if let processes = try? await client.call(.list).processes {
            for process in processes where process.alive { _ = try? await client.call(.signal, key: process.key, signal: "KILL") }
        }
        await client.stop()
        reader.cancel()
        server.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 1 行読むたびに JSON で返す子（Claude Code の stream-json と同じく 1 行 1 JSON）
private let echoScript = #"while IFS= read -r line; do printf '{"echo":"%s"}\n' "$line"; done; echo '{"bye":true}'"#

@Suite("agent host", .serialized)
struct AgentHostTests {
    @Test("hello に版と起動時刻、socket は 0600 でディレクトリは 0700")
    func hello() async throws {
        let host = try await HostFixture()
        defer { Task { await host.close() } }
        let hello = try await host.connected()
        #expect(hello.protocolVersion == AgentHostWire.protocolVersion && hello.startedAt != nil)
        let socket = AgentHostServer.socketURL(supportDirectory: host.directory).path
        let socketMode = (try FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? Int) ?? 0
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: (socket as NSString).deletingLastPathComponent)[.posixPermissions] as? Int) ?? 0
        #expect(socketMode & 0o777 == 0o600 && directoryMode & 0o777 == 0o700)
        await host.close()
    }

    @Test("起こした子に書くと、出力が番号つきで届き、入力を閉じると最後の行の後に終わりが届く")
    func spawnWriteExit() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        let spawned = try await host.client.call(.spawn, key: "c1", argv: ["/bin/sh", "-c", echoScript], env: ["PATH": "/usr/bin:/bin"], cwd: "/tmp")
        #expect((spawned.pid ?? 0) > 0)
        try await host.client.call(.subscribe, key: "c1", after: 0)
        try await host.client.call(.write, key: "c1", data: "一行目\nsecond\n")
        try await host.client.call(.closeInput, key: "c1")
        let notices = await host.notices("c1", count: 4)
        #expect(notices.map(\.event) == [.output, .output, .output, .exit])
        #expect(notices.prefix(3).map(\.seq) == [1, 2, 3])
        #expect(notices.prefix(3).map(\.line) == [#"{"echo":"一行目"}"#, #"{"echo":"second"}"#, #"{"bye":true}"#])
        #expect(notices.last?.exit == AgentHostExit(status: 0, signal: nil))
        let list = try await host.client.call(.list).processes ?? []
        #expect(list.first?.key == "c1" && list.first?.alive == false && list.first?.lastSeq == 3)
        await host.close()
    }

    @Test("起こした子の env に、起こした host の置き場の印を渡す（次の host が残った子を見分ける）")
    func spawnTagsHost() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        try await host.client.call(
            .spawn, key: "c1", argv: ["/bin/sh", "-c", #"printf '{"host":"%s"}\n' "$TASKBOARD_AGENT_HOST""#], env: ["PATH": "/usr/bin:/bin"], cwd: "/tmp")
        try await host.client.call(.subscribe, key: "c1", after: 0)
        let notices = await host.notices("c1", count: 2)
        #expect(notices.first?.line == #"{"host":"\#(AgentHostServer.directory(supportDirectory: host.directory).path)"}"#)
        await host.close()
    }

    @Test("答えを待たずに続けて送った同じ子への要求は、届いた順に処理される")
    func sameKeyInOrder() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(unixDomainSocketPath: AgentHostServer.socketURL(supportDirectory: host.directory).path) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineFrameDecoder()))
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        let count = 30
        var requests = [
            AgentHostRequest(id: 1, op: .spawn, key: "c1", argv: ["/bin/sh", "-c", echoScript], env: ["PATH": "/usr/bin:/bin"], cwd: "/tmp"),
            AgentHostRequest(id: 2, op: .subscribe, key: "c1", after: 0),
        ]
        requests += (0..<count).map { AgentHostRequest(id: 3 + $0, op: .write, key: "c1", data: "\($0)\n") }
        var buffer = ByteBuffer()
        for request in requests { buffer.writeImmutableBuffer(try AgentHostWire.encode(request)) }
        let echoed = try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(buffer)
            var echoed: [String] = []
            var failures: [String] = []
            for try await line in inbound {
                switch try AgentHostWire.decodeFrame(Data(line.readableBytesView)) {
                case .reply(let reply) where !reply.ok: failures.append(reply.error ?? "")
                case .notice(let notice) where notice.event == .output: echoed.append(notice.line ?? "")
                default: break
                }
                if echoed.count == count || !failures.isEmpty { break }
            }
            #expect(failures.isEmpty)
            return echoed
        }
        #expect(echoed == (0..<count).map { #"{"echo":"\#($0)"}"# })
        await host.close()
    }

    @Test("stdin を読まない子への書き込みが詰まっても、ほかの子への書き込みと、その子への signal は待たされない（同じ子への要求は順に処理する）")
    func stuckChildDoesNotBlockOthers() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        try await host.client.call(.spawn, key: "stuck", argv: ["/bin/sleep", "20"], env: ["PATH": "/usr/bin:/bin"], cwd: "/tmp")
        try await host.client.call(.spawn, key: "c1", argv: ["/bin/sh", "-c", echoScript], env: ["PATH": "/usr/bin:/bin"], cwd: "/tmp")
        try await host.client.call(.subscribe, key: "c1", after: 0)
        try await host.client.call(.subscribe, key: "stuck", after: 0)
        // 送り口は書ける間は 1 回目を受け取って返すので、詰まるのは 2 回目から。子は読まないので 2 回目は終わらない
        let client = host.client
        let stuck = Task {
            for _ in 0..<2 { _ = try? await client.call(.write, key: "stuck", data: String(repeating: "x", count: 1 << 20) + "\n") }
        }
        try await Task.sleep(for: .milliseconds(300))
        /// 時間内に答えが返ったか。call は取り消しに応じないので、task group で待たない
        func answered(_ timeout: Duration, _ call: @escaping @Sendable () async throws -> Void) async -> Bool {
            let (results, result) = AsyncStream<Bool>.makeStream()
            Task { result.yield((try? await call()) != nil) }
            Task {
                try? await Task.sleep(for: timeout)
                result.yield(false)
            }
            for await answered in results { return answered }
            return false
        }
        #expect(await answered(.seconds(2)) { try await client.call(.write, key: "c1", data: "ok\n") }, "ほかの子への書き込みが返る")
        #expect(await host.notices("c1", count: 1).first?.line == #"{"echo":"ok"}"#)
        #expect(await answered(.seconds(2)) { try await client.call(.list) })
        #expect(await answered(.seconds(2)) { try await client.call(.signal, key: "stuck", signal: "KILL") }, "詰まった子も止められる")
        #expect(await host.notices("stuck", count: 1).first?.event == .exit)
        _ = await stuck.value
        await host.close()
    }

    @Test("繋ぎ直したら控えから続きを読み直せる。trim した分は gap で知らせる")
    func replayAndTrim() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        _ = try await host.client.call(.spawn, key: "c2", argv: ["/bin/sh", "-c", echoScript], env: [:], cwd: "/tmp")
        try await host.client.call(.subscribe, key: "c2", after: 0)
        try await host.client.call(.write, key: "c2", data: "a\nb\nc\n")
        _ = await host.notices("c2", count: 3)
        try await host.client.call(.unsubscribe, key: "c2")
        try await host.client.call(.subscribe, key: "c2", after: 1)
        let replay = await host.notices("c2", count: 2)
        #expect(replay.map(\.seq) == [2, 3], "after より後の行だけ送り直す")
        try await host.client.call(.unsubscribe, key: "c2")
        try await host.client.call(.trim, key: "c2", through: 2)
        try await host.client.call(.subscribe, key: "c2", after: 0)
        let trimmed = await host.notices("c2", count: 2)
        #expect(trimmed.first?.event == .gap && trimmed.first?.through == 2)
        #expect(trimmed.last?.seq == 3)
        await host.close()
    }

    @Test("控えの上限を超えたら古い行を落とし、上限を超えた 1 行は捨てて長さだけ知らせる")
    func limits() async throws {
        var limits = AgentHostRegistry.Limits()
        limits.keptBytes = 40
        limits.lineBytes = 64
        let host = try await HostFixture(limits: limits)
        _ = try await host.connected()
        _ = try await host.client.call(.spawn, key: "c3", argv: ["/bin/sh", "-c", echoScript], env: [:], cwd: "/tmp")
        try await host.client.call(.subscribe, key: "c3", after: 0)
        let long = String(repeating: "x", count: 100)
        try await host.client.call(.write, key: "c3", data: "one\ntwo\n\(long)\nthree\n")
        let live = await host.notices("c3", count: 4)
        #expect(live.map(\.event) == [.output, .output, .oversize, .output])
        #expect(live[2].seq == 3 && (live[2].bytes ?? 0) > 100)
        try await host.client.call(.unsubscribe, key: "c3")
        try await host.client.call(.subscribe, key: "c3", after: 0)
        let replay = await host.notices("c3", count: 3)
        #expect(replay.first?.event == .gap, "40 バイトに収まらない古い行は落ちている")
        #expect(replay.last?.line == #"{"echo":"three"}"#)
        await host.close()
    }

    @Test("既定の 1 行の上限（16MB）は控えの上限（32MB）より小さい。受けたばかりの行が控えからすぐ落ちない")
    func defaultLimits() {
        let limits = AgentHostRegistry.Limits()
        #expect(limits.lineBytes == 16 << 20)
        #expect(limits.keptBytes == 32 << 20)
    }

    @Test("同じ key が動いている間は起こさない。signal で止めると終わり方に signal が入る")
    func duplicateAndSignal() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        _ = try await host.client.call(.spawn, key: "c4", argv: ["/bin/sh", "-c", "sleep 30"], env: [:], cwd: "/tmp")
        await #expect(throws: AgentHostClient.Failure.self) {
            try await host.client.call(.spawn, key: "c4", argv: ["/bin/sh", "-c", "sleep 30"], env: [:], cwd: "/tmp")
        }
        try await host.client.call(.subscribe, key: "c4", after: 0)
        try await host.client.call(.signal, key: "c4", signal: "TERM")
        let exit = await host.notices("c4", count: 1)
        #expect(exit.first?.event == .exit && exit.first?.exit?.signal == SIGTERM)
        await #expect(throws: AgentHostClient.Failure.self) { try await host.client.call(.signal, key: "c4", signal: "TERM") }
        await host.close()
    }

    @Test("key は英数字と - _ だけ。無いコマンドは起こせない")
    func invalid() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        await #expect(throws: AgentHostClient.Failure.self) {
            try await host.client.call(.spawn, key: "../x", argv: ["/bin/sh"], env: [:], cwd: "/tmp")
        }
        await #expect(throws: AgentHostClient.Failure.self) {
            try await host.client.call(.spawn, key: "c5", argv: ["/no/such/binary"], env: [:], cwd: "/tmp")
        }
        await host.close()
    }

    @Test("drain は子が全部終わってから終わる。drain の間は起こさない")
    func drain() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        _ = try await host.client.call(.spawn, key: "c6", argv: ["/bin/sh", "-c", "sleep 30"], env: [:], cwd: "/tmp")
        try await host.client.call(.drain)
        #expect(!host.drained, "子が動いている間は終わらない")
        await #expect(throws: AgentHostClient.Failure.self) {
            try await host.client.call(.spawn, key: "c7", argv: ["/bin/sh", "-c", "true"], env: [:], cwd: "/tmp")
        }
        try await host.client.call(.subscribe, key: "c6", after: 0)
        try await host.client.call(.signal, key: "c6", signal: "KILL")
        _ = await host.notices("c6", count: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.drained)
        await host.close()
    }

    @Test("子の標準エラーは key ごとのログに 0600 で書く")
    func stderrLog() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        _ = try await host.client.call(.spawn, key: "c8", argv: ["/bin/sh", "-c", "echo oops >&2"], env: [:], cwd: "/tmp")
        try await host.client.call(.subscribe, key: "c8", after: 0)
        _ = await host.notices("c8", count: 1)
        let log = host.directory.appending(path: "agent-host/logs/c8.log")
        // 終わりの知らせは、標準エラーを書き終える前に届くことがある
        for _ in 0..<40 where (try? String(contentsOf: log, encoding: .utf8)) != "oops\n" { try await Task.sleep(for: .milliseconds(50)) }
        #expect((try? String(contentsOf: log, encoding: .utf8)) == "oops\n")
        let mode = (try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o777 == 0o600)
        await host.close()
    }

    @Test("lock を持つ host がいる間は、同じ置き場で 2 つ目の host を起こせない")
    func secondHostRefused() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        await #expect(throws: AgentHostServer.Failure.self) {
            try await AgentHostServer.run(
                supportDirectory: host.directory, logger: Logger(label: "test"), limits: .init(), stopsOrphan: { _ in false }
            ) {}
        }
        let socket = AgentHostServer.socketURL(supportDirectory: host.directory).path
        #expect(FileManager.default.fileExists(atPath: socket), "2 つ目は 1 つ目の socket を消さない")
        _ = try await host.client.call(.list)
        await host.close()
    }

    @Test("繋いだまま取り出していない接続があるうちに host を止めても落ちない（受け付けた接続を全部閉じてから終わる）")
    func stopsWithPendingConnections() async throws {
        for _ in 0..<20 {
            let directory = URL(fileURLWithPath: "/tmp/tbah-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let server = Task {
                try await AgentHostServer.run(supportDirectory: directory, logger: Logger(label: "test"), limits: .init(), stopsOrphan: { _ in false }) {}
            }
            let path = AgentHostServer.socketURL(supportDirectory: directory).path
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: path) {
                try #require(ContinuousClock.now < deadline, "host が socket を作らない")
                try await Task.sleep(for: .milliseconds(10))
            }
            var channels: [any Channel] = []
            for _ in 0..<8 {
                if let channel = try? await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(unixDomainSocketPath: path).get() {
                    channels.append(channel)
                }
            }
            server.cancel()
            _ = await server.result
            for channel in channels { try? await channel.close() }
        }
    }

    @Test("起動時に、前の host が残した子（env の印と同じ置き場の host の印を持ち、親が launchd のもの）の process group を止める。ほかの置き場の host の子と印の無いものは止めない")
    func stopsOrphans() async throws {
        let marker = "test-orphan-\(UUID().uuidString.prefix(8))"
        // OS の実行ファイル（/bin/sleep）の env は他のプロセスから読めないので、写して ad hoc で署名し直したものを使う（Claude Code の CLI も OS のものではない）
        let tools = URL(fileURLWithPath: "/tmp/tbor-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        let sleeper = tools.appending(path: "sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleeper)
        let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "-s", "-", sleeper.path])
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        let directory = URL(fileURLWithPath: "/tmp/tbah-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let host = AgentHostServer.directory(supportDirectory: directory).path

        /// 子の頭（sh）がすぐ終わり、孫の sleep が親を失って launchd に付く（host が落ちて残った CLI と同じ形）。頭の pid（group）と孫の pid を返す
        func orphan(_ environment: [String: String]) async throws -> (group: pid_t, pid: pid_t) {
            let spawned = try AgentHostProcess.spawn(
                argv: ["/bin/sh", "-c", "'\(sleeper.path)' 60 </dev/null >/dev/null 2>&1 & echo $!"],
                environment: ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }, cwd: "/tmp")
            close(spawned.input)
            let handle = FileHandle(fileDescriptor: spawned.output, closeOnDealloc: true)
            let printed = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            close(spawned.errors)
            _ = AgentHostProcess.waitForExit(spawned.pid)
            let pid = try #require(pid_t(printed))
            // sh は fork した直後に終わるので、孫がまだ写した sleep を exec していない（/bin/sh のままで env を読めない）ことがある。読めるまで待つ
            let deadline = ContinuousClock.now + .seconds(5)
            while ProcessTable.arguments(of: pid)?.environment[OrphanedChildren.marker] != marker {
                try #require(ContinuousClock.now < deadline, "孫が sleep を exec しない")
                try await Task.sleep(for: .milliseconds(10))
            }
            return (spawned.pid, pid)
        }

        let left = try await orphan([OrphanedChildren.marker: marker, OrphanedChildren.hostMarker: host])
        let otherHost = try await orphan([OrphanedChildren.marker: marker, OrphanedChildren.hostMarker: "/tmp/another/agent-host"])
        let untagged = try await orphan([OrphanedChildren.marker: marker])
        defer { for other in [otherHost, untagged] { killpg(other.group, SIGKILL) } }
        #expect(ProcessTable.processes(uid: geteuid()).first { $0.pid == left.pid }?.ppid == 1)
        #expect(await OrphanedChildren.groups(host: host) { $0 == marker } == [left.group], "group は終わった頭の pid のまま")

        let fixture = try await HostFixture(orphanMarker: marker, directory: directory)
        _ = try await fixture.connected()
        #expect(kill(left.pid, 0) == -1 && errno == ESRCH)
        #expect(kill(otherHost.pid, 0) == 0 && kill(untagged.pid, 0) == 0)
        await fixture.close()
    }

    @Test("残った子と見なすのは、同じ置き場の host の印を持ち、アプリ（.app の中の実行ファイル）でないもの")
    func orphanCandidates() {
        let host = "/Users/u/Library/Application Support/taskboard/agent-host"
        func process(_ executable: String, _ tag: String?) -> ProcessTable.Arguments {
            var environment = [OrphanedChildren.marker: "c1"]
            environment[OrphanedChildren.hostMarker] = tag
            return ProcessTable.Arguments(executable: executable, argv: [executable], environment: environment)
        }
        #expect(OrphanedChildren.isChild(process("/Users/u/.local/bin/claude", host), of: host))
        #expect(!OrphanedChildren.isChild(process("/Users/u/.local/bin/claude", "/tmp/tb/agent-host"), of: host))
        #expect(!OrphanedChildren.isChild(process("/Users/u/.local/bin/claude", nil), of: host))
        #expect(!OrphanedChildren.isChild(process("/Users/u/Applications/Taskboard.app/Contents/MacOS/Taskboard", host), of: host))
    }

    @Test("KERN_PROCARGS2 の中身から実行ファイル・argv・env を読む。apple の文字列は env に入れない")
    func parseProcargs() {
        func bytes(argc: Int32, _ parts: [String]) -> [UInt8] {
            withUnsafeBytes(of: argc) { Array($0) } + parts.flatMap { Array($0.utf8) + [0] }
        }
        let full = bytes(argc: 2, ["/bin/sh", "", "", "sh", "-c", "A=1", "\(OrphanedChildren.marker)=c1", "B=日本語=x", "", "executable_path=/bin/sh", "A=apple"])
        #expect(
            ProcessTable.parse(procargs: full)
                == .init(executable: "/bin/sh", argv: ["sh", "-c"], environment: ["A": "1", OrphanedChildren.marker: "c1", "B": "日本語=x"]))
        #expect(ProcessTable.parse(procargs: bytes(argc: 1, ["/bin/sh", "sh"]))?.environment == [:], "env が無い")
        #expect(ProcessTable.parse(procargs: bytes(argc: 3, ["/bin/sh", "sh"])) == .init(executable: "/bin/sh", argv: ["sh"], environment: [:]), "argv が途中で切れている")
        #expect(ProcessTable.parse(procargs: [UInt8]()) == nil)
        #expect(ProcessTable.parse(procargs: bytes(argc: -1, ["x"])) == nil)
    }

    @Test("自分のプロセスの argv・env を KERN_PROCARGS2 で、開始時刻を KERN_PROC_PID で読める")
    func ownProcess() throws {
        let own = try #require(ProcessTable.arguments(of: getpid()))
        #expect(own.environment["PATH"] == ProcessInfo.processInfo.environment["PATH"])
        #expect(own.argv == CommandLine.arguments)
        let entry = try #require(ProcessTable.process(getpid()))
        #expect(entry.pgid == getpgrp())
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        #expect(entry.startedAt > 0 && entry.startedAt <= now)
        #expect(ProcessTable.processes(uid: geteuid()).first { $0.pid == getpid() } == entry)
    }
}

/// シェルの出力（base64 の `data`）をつないだ文字
private func shellText(_ notices: [AgentHostNotice]) -> String {
    String(decoding: notices.compactMap { $0.data.flatMap { Data(base64Encoded: $0) } }.joined(), as: UTF8.self)
}

private let shellEnvironment = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ ", "HOME": "/tmp"]

@Suite("agent host のシェル", .serialized)
struct AgentHostShellTests {
    /// `marker` が出力に出るまで知らせを読む（時間切れなら届いた分）
    private func read(_ host: HostFixture, _ key: String, until marker: String, timeout: Duration = .seconds(20)) async -> (text: String, notices: [AgentHostNotice]) {
        let deadline = ContinuousClock.now + timeout
        var notices: [AgentHostNotice] = []
        while ContinuousClock.now < deadline, !shellText(notices).contains(marker) {
            notices += await host.notices(key, count: 1, timeout: .milliseconds(200))
        }
        return (shellText(notices), notices)
    }

    /// `parent` の子の `name` が端末の前面のプロセスグループになるまで待つ
    private func foregroundChild(of parent: pid_t, named name: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            for child in ProcessTable.processes(uid: geteuid()) where child.ppid == parent {
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, child.pid]
                var info = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.stride
                guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { continue }
                let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if command == name, info.kp_eproc.e_tpgid == info.kp_eproc.e_pgid { return true }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func type(_ host: HostFixture, _ key: String, _ text: String) async throws {
        try await host.client.call(.shellInput, key: key, data: Data(text.utf8).base64EncodedString())
    }

    @Test("擬似端末で起こしたシェルに書くと出力が位置つきで届き、大きさを変えると stty に出る。Ctrl-C は前面のコマンドを止める（擬似端末が制御端末）")
    func inputOutputResizeInterrupt() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        let opened = try await host.client.call(.shellOpen, key: "s1", argv: ["/bin/sh", "-i"], env: shellEnvironment, cwd: "/tmp", cols: 100, rows: 30)
        #expect((opened.pid ?? 0) > 0)
        let again = try await host.client.call(.shellOpen, key: "s1", argv: ["/bin/sh", "-i"], env: shellEnvironment, cwd: "/tmp", cols: 80, rows: 24)
        #expect(again.pid == opened.pid, "生きているシェルは起こし直さない")
        let subscribed = try await host.client.call(.shellSubscribe, key: "s1")
        #expect(subscribed.offset != nil)
        try await type(host, "s1", "pwd; stty size; echo d-$((40+2))\n")
        let first = await read(host, "s1", until: "d-42")
        #expect(first.text.contains("/tmp") && first.text.contains("30 100") && first.text.contains("d-42"))
        let offsets = first.notices.compactMap(\.seq)
        #expect(offsets == offsets.sorted() && offsets.first == subscribed.offset, "位置は購読した所の続きから増える")

        try await host.client.call(.shellResize, key: "s1", cols: 120, rows: 40)
        try await type(host, "s1", "stty size\n")
        #expect(await read(host, "s1", until: "40 120").text.contains("40 120"))

        try await type(host, "s1", "sleep 30\n")
        // 前面に入る前の Ctrl-C は sleep に届かない（負荷の下で 300 ms 待つだけでは足りなかった）
        #expect(await foregroundChild(of: try #require(opened.pid), named: "sleep"))
        try await type(host, "s1", "\u{3}")
        try await type(host, "s1", "echo after-$((1+1))\n")
        // 止まらなければ、後の入力は sleep が終わる 30 秒後まで動かない
        let interrupted = await read(host, "s1", until: "after-2", timeout: .seconds(5))
        #expect(interrupted.text.contains("after-2"), "\(interrupted.text)")
        await host.close()
    }

    @Test("購読し直すと、ためた出力が応答で届く（上限を超えた分は古い方から行の区切りで落とす）。閉じると終わりが届き、一覧から消える")
    func replayAndClose() async throws {
        let host = try await HostFixture(limits: AgentHostRegistry.Limits(shellKeptBytes: 4_096))
        _ = try await host.connected()
        try await host.client.call(.shellOpen, key: "s2", argv: ["/bin/sh", "-i"], env: shellEnvironment, cwd: "/tmp", cols: 80, rows: 24)
        try await host.client.call(.shellSubscribe, key: "s2")
        try await type(host, "s2", "i=0; while [ $i -lt 1000 ]; do echo line-$i; i=$((i+1)); done; echo end-$((6*7))\n")
        let streamed = await read(host, "s2", until: "end-42")
        #expect(streamed.text.contains("line-999"))
        try await host.client.call(.shellUnsubscribe, key: "s2")
        let replay = try await host.client.call(.shellSubscribe, key: "s2")
        let kept = String(decoding: Data(base64Encoded: replay.data ?? "") ?? Data(), as: UTF8.self)
        #expect(kept.utf8.count <= 4_096 && kept.contains("end-42") && !kept.contains("line-0\r"))
        #expect(kept.hasPrefix("line-"), "行の区切りから始まる: \(kept.prefix(40))")
        // 読み終えた後にもプロンプトが出る
        #expect((replay.offset ?? 0) >= (streamed.notices.last.map { $0.seq! + Data(base64Encoded: $0.data!)!.count } ?? .max))

        #expect(try await host.client.call(.shellList).shells?.map(\.key) == ["s2"])
        try await host.client.call(.shellClose, key: "s2")
        let deadline = ContinuousClock.now + .seconds(10)
        var exited = false
        while ContinuousClock.now < deadline, !exited {
            exited = await host.notices("s2", count: 1, timeout: .milliseconds(200)).contains { $0.event == .shellExit }
        }
        #expect(exited)
        #expect(try await host.client.call(.shellList).shells?.isEmpty == true)
        await host.close()
    }

    @Test("シェルは会話の子の標準入力の口を持ち出さない（会話の子の入力を閉じると EOF が届く）")
    func doesNotInheritConversationPipes() async throws {
        let host = try await HostFixture()
        _ = try await host.connected()
        try await host.client.call(.spawn, key: "c1", argv: ["/bin/sh", "-c", echoScript], env: ["PATH": "/usr/bin:/bin"], cwd: "/tmp")
        try await host.client.call(.subscribe, key: "c1", after: 0)
        try await host.client.call(.shellOpen, key: "s3", argv: ["/bin/sh", "-i"], env: shellEnvironment, cwd: "/tmp", cols: 80, rows: 24)
        try await host.client.call(.closeInput, key: "c1")
        let notices = await host.notices("c1", count: 2, timeout: .seconds(10))
        #expect(notices.map(\.event) == [.output, .exit])
        await host.close()
    }
}

/// 画面の口に届いたもの（文は電文に読み戻す）
private final class ShellScreen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ConversationShells.Outgoing] = []
    private var reader: Task<Void, Never>?
    let id: UUID

    init(_ shells: ConversationShells, key: String, cols: Int, rows: Int) async {
        id = await shells.join(key: key, cols: cols, rows: rows)
        let id = id
        reader = Task { [self] in
            while let item = await shells.next(id) { lock.withLock { items.append(item) } }
        }
    }

    var messages: [TerminalServerMessage] {
        lock.withLock { items }.compactMap {
            guard case .text(let text) = $0 else { return nil }
            return try? WireJSON.decoder().decode(TerminalServerMessage.self, from: Data(text.utf8))
        }
    }

    var output: String {
        String(decoding: lock.withLock { items }.compactMap { if case .binary(let data) = $0 { data } else { nil } }.joined(), as: UTF8.self)
    }

    var ended: Bool { lock.withLock { items }.contains { if case .end = $0 { true } else { false } } }

    func wait(_ what: String, timeout: Duration = .seconds(20), until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("\(what) が届かない: \(messages) \(output.suffix(300))")
        return false
    }
}

@Suite("会話のシェルの中継", .serialized)
struct ConversationShellsTests {
    @Test("シェルを扱えない版の host に繋がっていると、daemon の中でシェルを開く。一覧に出て、終わると消える")
    func fallbackForOutdatedHost() async throws {
        let box = ShellsBox()
        let host = try await HostFixture { box.shells?.deliver($0) }
        _ = try await host.connected()
        let logs = FileManager.default.temporaryDirectory.appending(path: "shell-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logs) }
        let shells = ConversationShells(host: host.client, fallback: InProcessAgentHost(logDirectory: logs, logger: Logger(label: "test")), logger: Logger(label: "test"))
        box.shells = shells
        await shells.hostConnected(version: 1)
        let key = ConversationShells.key(conversation: "old-host")
        try await shells.open(key: key, argv: ["/bin/sh", "-i"], env: shellEnvironment, cwd: "/tmp")
        #expect(try await shells.liveKeys() == [key])
        #expect(try await host.client.call(.shellList).shells?.isEmpty ?? true, "古い host には送らない")

        let a = await ShellScreen(shells, key: key, cols: 80, rows: 24)
        await shells.handle(a.id, .input(Data("echo in-daemon-$((5+6)); exit\n".utf8)))
        #expect(await a.wait("出力", until: { a.output.contains("in-daemon-11") }))
        #expect(await a.wait("閉じる", until: { a.ended }))
        #expect(try await shells.liveKeys() == [])
        await shells.leave(a.id)
        await host.close()
    }

    @Test("開いた画面には前の出力を全画面で送る。書くと操作権を取り、取られた画面は観察に戻る。シェルが終わると画面を閉じる")
    func relay() async throws {
        let box = ShellsBox()
        let host = try await HostFixture { box.shells?.deliver($0) }
        let hello = try await host.connected()
        let shells = ConversationShells(host: host.client, logger: Logger(label: "test"))
        box.shells = shells
        let key = ConversationShells.key(conversation: "t1")
        await #expect(throws: ConversationShells.Failure.self) {
            try await shells.open(key: key, argv: ["/bin/sh", "-i"], env: shellEnvironment, cwd: "/tmp")
        }
        await shells.hostConnected(version: hello.protocolVersion)
        try await shells.open(key: key, argv: ["/bin/sh", "-i"], env: shellEnvironment, cwd: "/tmp")

        let a = await ShellScreen(shells, key: key, cols: 100, rows: 30)
        guard await a.wait("A の最初の frame", until: { if case .frame(_, true, 80, 24) = a.messages.first { true } else { false } }) else { return }
        #expect(a.messages.contains(.mode(.observe)))
        await shells.handle(a.id, .input(Data("stty size; echo a-$((2+2))\n".utf8)))
        guard await a.wait("A の出力", until: { a.output.contains("a-4") }) else { return }
        #expect(a.output.hasPrefix("\u{1b}c"))
        #expect(a.output.contains("30 100"), "書いた画面が操作権を取り、擬似端末をその大きさにする")
        #expect(a.messages.contains(.mode(.control)))

        let b = await ShellScreen(shells, key: key, cols: 80, rows: 24)
        guard await b.wait("B の前の出力", until: { b.output.contains("a-4") }) else { return }
        guard case .frame(_, true, 100, 30) = b.messages.first else {
            Issue.record("\(b.messages)")
            return
        }
        await shells.handle(b.id, .acquire(takeover: false))
        guard await b.wait("B の busy", until: { b.messages.contains(.controllerBusy) }) else { return }
        await shells.handle(b.id, .acquire(takeover: true))
        guard await a.wait("A の controlLost", until: { a.messages.contains(.controlLost(.takenOver)) }) else { return }
        #expect(await a.wait("A の大きさ", until: { a.messages.contains { if case .frame(_, false, 80, 24) = $0 { true } else { false } } }))
        await shells.handle(a.id, .input(Data("echo no\n".utf8)))
        #expect(await a.wait("A の busy", until: { a.messages.contains(.controllerBusy) }))

        // 書いた後に繋いだ画面には、その前の問い合わせを流さない（流すとエミュレータが答え直し、入力になる）
        await shells.handle(b.id, .input(Data("printf 'q-\\033[c-q'; echo; echo asked-$((3+4))\n".utf8)))
        guard await b.wait("問い合わせ", until: { b.output.contains("asked-7") }) else { return }
        #expect(b.output.contains("q-\u{1b}[c-q"), "最初に流すときは問い合わせを残す")
        await shells.handle(b.id, .input(Data("echo later-$((4+5))\n".utf8)))
        guard await b.wait("later", until: { b.output.contains("later-9") }) else { return }
        let c = await ShellScreen(shells, key: key, cols: 80, rows: 24)
        guard await c.wait("C の前の出力", until: { c.output.contains("later-9") }) else { return }
        #expect(c.output.contains("q--q") && !c.output.contains("\u{1b}[c"))
        await shells.leave(c.id)

        await shells.handle(b.id, .input(Data("stty size; exit\n".utf8)))
        #expect(await b.wait("B の大きさ", until: { b.output.contains("24 80") }))
        for screen in [a, b] {
            #expect(await screen.wait("閉じる", until: { screen.ended }))
            #expect(screen.messages.contains(.closed(reason: .paneNotFound, message: "シェルが終わった")))
        }
        await shells.leave(a.id)
        await shells.leave(b.id)
        await host.close()
    }
}

@Suite("端末への問い合わせを落とす")
struct TerminalQueriesTests {
    @Test("問い合わせの列だけを落とし、文字・色・カーソルの移動・UTF-8 は残す")
    func removing() {
        let input = "a\u{1b}[c日本\u{1b}[>0c\u{1b}[31mred\u{1b}[0m\u{1b}[6n\u{1b}[?2004$p\u{1b}]11;?\u{07}\u{1b}[2J\u{1b}[>q\u{1b}[?u\u{1b}[18tz"
        let output = TerminalQueries.removing(from: Data(input.utf8))
        #expect(String(decoding: output, as: UTF8.self) == "a日本\u{1b}[31mred\u{1b}[0m\u{1b}[2Jz")
        #expect(TerminalQueries.removing(from: Data()).isEmpty)
        #expect(TerminalQueries.removing(from: Data("ls\r\n".utf8)) == Data("ls\r\n".utf8))
        // UTF-8 の途中で切れた末尾も、そのまま戻す
        let cut = Data("あ".utf8).prefix(2)
        #expect(TerminalQueries.removing(from: Data("x".utf8) + cut) == Data("x".utf8) + cut)
    }
}

private final class ShellsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConversationShells?
    var shells: ConversationShells? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
