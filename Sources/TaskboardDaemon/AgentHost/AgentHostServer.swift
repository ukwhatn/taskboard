import Darwin
import Foundation
import Logging
import NIOCore
import NIOPosix

/// `taskboard agent-host`：daemon とは別の launchd の job で、Claude Code の会話の CLI を子として持つ。
/// daemon を入れ替えても子は止まらず、出力は番号つきで控えておく。socket は support ディレクトリの `agent-host/host.sock`（0600）で、
/// 繋いだ相手の UID が自分と違えば切る
public enum AgentHostServer {
    public static func socketURL(supportDirectory: URL) -> URL {
        directory(supportDirectory: supportDirectory).appending(path: "host.sock")
    }

    static func directory(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: "agent-host", directoryHint: .isDirectory)
    }

    public enum Failure: Error, CustomStringConvertible {
        case alreadyRunning(String)
        case pathTooLong(String)
        case lock(String)

        public var description: String {
            switch self {
            case .alreadyRunning(let path): "別の agent host が \(path) で動いている"
            case .pathTooLong(let path): "socket のパスが長すぎる: \(path)"
            case .lock(let reason): "host.lock を開けない: \(reason)"
            }
        }
    }

    /// 動いている host の子のうち生きている数。確かめられなければ nil（host が動いていない・版が違う・応答が無い。どれかは `isListening` で分ける）
    public static func liveChildren(supportDirectory: URL, timeout: Duration = .seconds(3)) async -> Int? {
        let client = AgentHostClient(socketPath: socketURL(supportDirectory: supportDirectory).path, logger: Logger(label: "uk.whatn.taskboard.install"))
        await client.start()
        defer { Task { await client.stop() } }
        let connected = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in client.events { if case .connected = event { return true } }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard connected, let reply = try? await client.call(.list) else { return nil }
        return (reply.processes ?? []).filter(\.alive).count
    }

    public static func run(supportDirectory: URL, logger: Logger) async throws {
        // drain の応答を書き終える間を置いてから終わる（launchd の KeepAlive が新しい実行ファイルで起こし直す）
        try await run(supportDirectory: supportDirectory, logger: logger, limits: AgentHostRegistry.Limits(), stopsOrphan: { _ in true }) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }

    /// `stopsOrphan` は、親を失った子のうち止めるものを env の印の値で選ぶ（テストは自分が作った子だけを選び、この Mac の会話に触らない）
    static func run(
        supportDirectory: URL, logger: Logger, limits: AgentHostRegistry.Limits, stopsOrphan: @escaping @Sendable (String) -> Bool,
        onDrained: @escaping @Sendable () -> Void
    ) async throws {
        signal(SIGPIPE, SIG_IGN)
        let directory = directory(supportDirectory: supportDirectory)
        let logs = directory.appending(path: "logs", directoryHint: .isDirectory)
        for url in [directory, logs] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(url.path, 0o700)
        }
        let path = socketURL(supportDirectory: supportDirectory).path
        guard path.utf8.count < 104 else { throw Failure.pathTooLong(path) }
        // 2 つの host が同時に起きても、socket を消して作り直すのは lock を取った 1 つだけ。lock は終わるまで（落ちても OS が外す）持つ
        let lock = open(directory.appending(path: "host.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure.lock(String(cString: strerror(errno))) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.alreadyRunning(path) }
        let orphans = await OrphanedChildren.groups(host: directory.path, matching: stopsOrphan)
        if !orphans.isEmpty {
            logger.warning("stopping children left by the previous host", metadata: ["groups": "\(orphans)"])
            await OrphanedChildren.stop(orphans, grace: .seconds(5))
        }
        try await removeStaleSocket(at: path)
        let registry = AgentHostRegistry(limits: limits, logDirectory: logs, hostTag: directory.path, logger: logger, onIdleAfterDrain: onDrained)
        // umask は変えない（プロセス全体の値で、bind を待つ間に同じプロセスで作られるフォルダとファイルの権限まで変わる）。
        // 置き場は 0700 なので、chmod するまでの間もほかのユーザーは socket に届かない
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(unixDomainSocketPath: path) { child in
                peerIsSelf(child).flatMapThrowing { allowed in
                    guard allowed else { throw ChannelError.inappropriateOperationForState }
                    try child.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineFrameDecoder()))
                    // 解放されたら閉じる作り方（非推奨）で包む。host を止めた後に受け付けが終わった子は、NIO が受け口に渡せずに捨てる。
                    // wrappingChannelSynchronously で包んだ子は executeThenClose を通らずに解放されると preconditionFailure で落ちる（AgentHostTests.stopsWithPendingConnections）
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(synchronouslyWrapping: child)
                }
            }
        chmod(path, 0o600)
        logger.info("agent host listening", metadata: ["socket": .string(path)])
        let counter = ConnectionCounter()
        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { inbound in
                for try await connection in inbound {
                    let id = counter.next()
                    group.addTask { await serve(connection, id: id, registry: registry, logger: logger) }
                }
            }
        }
    }

    /// 繋がる socket が残っていれば別の host が動いている。繋がらなければ前の host が残したものなので消す
    static func removeStaleSocket(at path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if await accepts(path) { throw Failure.alreadyRunning(path) }
        unlink(path)
    }

    /// socket で host が待っているか（会話の数を確かめられなかったとき、install-launchd が入れ替えてよいかを決める）
    public static func isListening(supportDirectory: URL) async -> Bool {
        let path = socketURL(supportDirectory: supportDirectory).path
        return FileManager.default.fileExists(atPath: path) ? await accepts(path) : false
    }

    private static func accepts(_ path: String) async -> Bool {
        guard let channel = try? await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(unixDomainSocketPath: path).get() else { return false }
        try? await channel.close()
        return true
    }

    /// 繋いだ相手の UID（`LOCAL_PEERCRED`）が自分と同じか。socket は 0600 だが、root や権限の緩い親ディレクトリに頼らない
    static func peerIsSelf(_ channel: any Channel) -> EventLoopFuture<Bool> {
        guard let provider = channel as? SocketOptionProvider else { return channel.eventLoop.makeSucceededFuture(false) }
        let future: EventLoopFuture<xucred> = provider.unsafeGetSocketOption(
            level: SocketOptionLevel(SOL_LOCAL), name: SocketOptionName(LOCAL_PEERCRED))
        return future.map { $0.cr_uid == getuid() }.recover { _ in false }
    }

    private static func serve(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>, id: Int, registry: AgentHostRegistry, logger: Logger) async {
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        let sink = AgentHostSink(id: id, continuation: continuation)
        await registry.attach(sink)
        try? await connection.executeThenClose { inbound, outbound in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await buffer in stream {
                        guard (try? await outbound.write(buffer)) != nil else { return }
                        sink.written(buffer.readableBytes)
                    }
                }
                group.addTask {
                    // stdin を読まない子への write は終わらないので、1 本の接続で要求を順に待つと、ほかの子への要求（hook の答えなど）まで止まる。
                    // 同じ子への要求は届いた順に、子をまたいでは並べて処理する。signal は詰まった子を止めるので、順を待たない
                    var tails: [String: Task<Void, Never>] = [:]
                    do {
                        for try await line in inbound {
                            guard let request = try? JSONDecoder().decode(AgentHostRequest.self, from: Data(line.readableBytesView)) else {
                                sink.send(AgentHostReply(id: 0, ok: false, error: "要求を読めない"))
                                continue
                            }
                            guard let key = request.key, request.op != .signal else {
                                Task { sink.send(await registry.handle(request, from: id)) }
                                continue
                            }
                            let previous = tails[key]
                            tails[key] = Task {
                                await previous?.value
                                sink.send(await registry.handle(request, from: id))
                            }
                        }
                    } catch {
                        logger.debug("connection closed", metadata: ["error": "\(error)"])
                    }
                    continuation.finish()
                }
                // どちらかが終われば（相手が切った・送り口が溢れた）接続を閉じる
                await group.next()
                group.cancelAll()
            }
        }
        continuation.finish()
        await registry.detach(id)
    }
}

private final class ConnectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
