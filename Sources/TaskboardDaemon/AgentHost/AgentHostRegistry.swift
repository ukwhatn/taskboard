import Darwin
import Foundation
import Logging
import NIOCore
import NIOPosix

/// host が持つ子と、その出力の控え。子の出力の行に key ごとの番号を振って控え、購読している接続に渡す。
/// 何を控えから捨ててよいかは daemon が `trim` で決める（host は子の中身を知らない）
actor AgentHostRegistry {
    struct Limits: Sendable {
        /// 1 行の上限。超えた行は捨てて `oversize` で知らせる
        var lineBytes = 16 << 20
        /// 1 つの子の控えの上限。超えたら古い行から捨てて `gap` で知らせる
        var keptBytes = 32 << 20
        /// 1 つの子の標準エラーのログの上限。超えたら 1 世代残して回す
        var logBytes = 1 << 20
        /// 1 つのシェルがためておく出力（繋ぎ直した画面に先に送る分）
        var shellKeptBytes = 1 << 20
    }

    private struct Child {
        var generation: Int
        var pid: pid_t
        var startedAt: Date
        var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?
        var alive = true
        var outputDone = false
        var exit: AgentHostExit?
        var lines: [(seq: Int, line: String)] = []
        var keptBytes = 0
        var subscribers: Set<Int> = []
    }

    let limits: Limits
    let logDirectory: URL
    private let hostTag: String?
    let logger: Logger
    let startedAt = Date()
    private var children: [String: Child] = [:]
    /// key ごとの最後の番号。子を起こし直しても続きから振る（daemon は番号で読み直すので戻さない）
    private var lastSeq: [String: Int] = [:]
    /// key ごとの、控えから捨てた最後の番号
    private var droppedThrough: [String: Int] = [:]
    private var generation = 0
    private var sinks: [Int: AgentHostSink] = [:]
    private(set) var draining = false
    private let onIdleAfterDrain: @Sendable () -> Void
    let shells: AgentHostShells

    /// `hostTag` は子の env に `OrphanedChildren.hostMarker` で渡す値（次の host が残った子を見分ける）。nil なら渡さない（daemon の中の host）
    init(limits: Limits = Limits(), logDirectory: URL, hostTag: String? = nil, logger: Logger, onIdleAfterDrain: @escaping @Sendable () -> Void) {
        self.hostTag = hostTag
        shells = AgentHostShells(limits: AgentHostShells.Limits(keptBytes: limits.shellKeptBytes), hostTag: hostTag, logger: logger)
        self.limits = limits
        self.logDirectory = logDirectory
        self.logger = logger
        self.onIdleAfterDrain = onIdleAfterDrain
    }

    // MARK: 接続

    func attach(_ sink: AgentHostSink) async {
        sinks[sink.id] = sink
        await shells.attach(sink)
    }

    func detach(_ id: Int) async {
        sinks[id] = nil
        for key in children.keys { children[key]?.subscribers.remove(id) }
        await shells.detach(id)
    }

    // MARK: 要求

    func handle(_ request: AgentHostRequest, from connection: Int) async -> AgentHostReply {
        do {
            switch request.op {
            case .hello:
                return AgentHostReply(
                    id: request.id, ok: true, protocolVersion: AgentHostWire.protocolVersion, pid: getpid(), startedAt: startedAt.timeIntervalSince1970)
            case .spawn:
                let pid = try await spawn(key: try Self.key(request), argv: request.argv ?? [], env: request.env, cwd: request.cwd)
                return AgentHostReply(id: request.id, ok: true, pid: pid)
            case .write:
                try await write(key: try Self.key(request), data: request.data ?? "")
            case .closeInput:
                try await closeInput(key: try Self.key(request))
            case .signal:
                try signal(key: try Self.key(request), name: request.signal ?? "")
            case .subscribe:
                try subscribe(key: try Self.key(request), after: request.after ?? 0, connection: connection)
            case .unsubscribe:
                children[try Self.key(request)]?.subscribers.remove(connection)
            case .trim:
                trim(key: try Self.key(request), through: request.through ?? 0)
            case .list:
                return AgentHostReply(id: request.id, ok: true, processes: list())
            case .drain:
                // シェルは待たない（入れ替えで閉じる）
                draining = true
                exitIfDrained()
            case .shellList:
                return AgentHostReply(id: request.id, ok: true, shells: await shells.list())
            case .shellOpen:
                guard !draining else { throw Failure.draining }
                return try await shells.handle(request, key: try Self.key(request), from: connection)
            case .shellInput, .shellResize, .shellClose, .shellSubscribe, .shellUnsubscribe:
                return try await shells.handle(request, key: try Self.key(request), from: connection)
            }
            return AgentHostReply(id: request.id, ok: true)
        } catch {
            return AgentHostReply(id: request.id, ok: false, error: String(describing: error))
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case invalidKey
        case running(String)
        case unknown(String)
        case notRunning(String)
        case draining
        case invalidSignal(String)
        case missing(String)

        var description: String {
            switch self {
            case .invalidKey: "key は英数字・-・_ の 1〜64 文字"
            case .running(let key): "\(key) は動いている"
            case .unknown(let key): "\(key) が無い"
            case .notRunning(let key): "\(key) は終わっている"
            case .draining: "入れ替えを待っているので起こさない"
            case .invalidSignal(let name): "知らない signal: \(name)"
            case .missing(let field): "\(field) が要る"
            }
        }
    }

    /// stderr のログのファイル名に使うので、パスの区切りを含められない形に限る
    static func key(_ request: AgentHostRequest) throws -> String {
        guard let key = request.key, (1...64).contains(key.count),
            key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" })
        else { throw Failure.invalidKey }
        return key
    }

    private func spawn(key: String, argv: [String], env: [String: String]?, cwd: String?) async throws -> pid_t {
        guard !draining else { throw Failure.draining }
        if children[key]?.alive == true { throw Failure.running(key) }
        guard !argv.isEmpty else { throw Failure.missing("argv") }
        guard let cwd else { throw Failure.missing("cwd") }
        var environment = env ?? ProcessInfo.processInfo.environment
        environment[OrphanedChildren.hostMarker] = hostTag
        let process = try AgentHostProcess.spawn(argv: argv, environment: environment, cwd: cwd)
        generation += 1
        let generation = generation
        children[key] = Child(generation: generation, pid: process.pid, startedAt: Date())
        droppedThrough[key] = lastSeq[key] ?? 0
        Thread.detachNewThread { [weak self] in
            let exit = AgentHostProcess.waitForExit(process.pid)
            Task { await self?.exited(key: key, generation: generation, exit: exit) }
        }
        do {
            let channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .takingOwnershipOfDescriptors(input: process.output, output: process.input) { [limits] channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(BoundedLineDecoder(maximumLength: limits.lineBytes)))
                        return try NIOAsyncChannel<AgentHostLine, ByteBuffer>(
                            wrappingChannelSynchronously: channel, configuration: .init(isOutboundHalfClosureEnabled: true))
                    }
                }
            let errors: NIOAsyncChannel<ByteBuffer, Never>
            do {
                errors = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .takingOwnershipOfDescriptor(input: process.errors) { channel in
                        channel.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, Never>(wrappingChannelSynchronously: channel) }
                    }
            } catch {
                // 作った channel を executeThenClose で閉じずに捨てると、NIO が preconditionFailure で落ちる
                try? await channel.executeThenClose { _, _ in }
                throw error
            }
            let log = AgentHostLog(url: logDirectory.appending(path: "\(key).log"), limit: limits.logBytes)
            Task.detached {
                try? await errors.executeThenClose { inbound in
                    for try await chunk in inbound { log.append(chunk) }
                }
            }
            Task.detached { [weak self] in
                try? await channel.executeThenClose { inbound, outbound in
                    await self?.attachWriter(key: key, generation: generation, writer: outbound)
                    for try await line in inbound { await self?.received(key: key, generation: generation, line: line) }
                }
                await self?.outputClosed(key: key, generation: generation)
            }
        } catch {
            kill(-process.pid, SIGKILL)
            throw error
        }
        logger.info("spawned", metadata: ["key": .string(key), "pid": .stringConvertible(process.pid)])
        return process.pid
    }

    private func attachWriter(key: String, generation: Int, writer: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        guard children[key]?.generation == generation else { return }
        children[key]?.writer = writer
    }

    private func write(key: String, data: String) async throws {
        guard let child = children[key] else { throw Failure.unknown(key) }
        guard child.alive, let writer = child.writer else { throw Failure.notRunning(key) }
        try await writer.write(ByteBuffer(string: data))
    }

    private func closeInput(key: String) async throws {
        guard let child = children[key] else { throw Failure.unknown(key) }
        child.writer?.finish()
        children[key]?.writer = nil
    }

    private func signal(key: String, name: String) throws {
        guard let child = children[key] else { throw Failure.unknown(key) }
        guard child.alive else { throw Failure.notRunning(key) }
        let number: Int32
        switch name {
        case "INT": number = SIGINT
        case "TERM": number = SIGTERM
        case "KILL": number = SIGKILL
        default: throw Failure.invalidSignal(name)
        }
        // 子は自分の process group の頭なので、group に送ると子が起こしたものにも届く
        kill(-child.pid, number)
    }

    private func subscribe(key: String, after: Int, connection: Int) throws {
        guard children[key] != nil, let sink = sinks[connection] else { throw Failure.unknown(key) }
        let dropped = droppedThrough[key] ?? 0
        if after < dropped {
            sink.send(AgentHostNotice(event: .gap, key: key, through: dropped))
        }
        for entry in children[key]!.lines where entry.seq > after {
            sink.send(AgentHostNotice(event: .output, key: key, seq: entry.seq, line: entry.line))
        }
        if let child = children[key], !child.alive, child.outputDone {
            sink.send(AgentHostNotice(event: .exit, key: key, exit: child.exit))
        }
        children[key]?.subscribers.insert(connection)
    }

    private func trim(key: String, through: Int) {
        guard var child = children[key] else { return }
        let removed = child.lines.prefix { $0.seq <= through }
        guard !removed.isEmpty else { return }
        child.keptBytes -= removed.reduce(0) { $0 + $1.line.utf8.count }
        child.lines.removeFirst(removed.count)
        children[key] = child
        droppedThrough[key] = max(droppedThrough[key] ?? 0, removed.last!.seq)
    }

    private func list() -> [AgentHostProcessInfo] {
        children.sorted { $0.key < $1.key }.map { key, child in
            AgentHostProcessInfo(
                key: key, pid: child.pid, alive: child.alive, exit: child.exit, lastSeq: lastSeq[key] ?? 0,
                firstSeq: child.lines.first?.seq ?? ((lastSeq[key] ?? 0) + 1), keptBytes: child.keptBytes, startedAt: child.startedAt.timeIntervalSince1970)
        }
    }

    // MARK: 子から

    private func received(key: String, generation: Int, line: AgentHostLine) {
        guard var child = children[key], child.generation == generation else { return }
        let seq = (lastSeq[key] ?? 0) + 1
        lastSeq[key] = seq
        let notice: AgentHostNotice
        switch line {
        case .line(let text):
            child.lines.append((seq, text))
            child.keptBytes += text.utf8.count
            var droppedNow: Int?
            while child.keptBytes > limits.keptBytes, child.lines.count > 1 {
                let first = child.lines.removeFirst()
                child.keptBytes -= first.line.utf8.count
                droppedNow = first.seq
            }
            if let droppedNow {
                droppedThrough[key] = max(droppedThrough[key] ?? 0, droppedNow)
                logger.warning("output buffer full", metadata: ["key": .string(key), "through": .stringConvertible(droppedNow)])
            }
            notice = AgentHostNotice(event: .output, key: key, seq: seq, line: text)
        case .oversize(let bytes):
            notice = AgentHostNotice(event: .oversize, key: key, seq: seq, bytes: bytes)
        }
        children[key] = child
        for id in child.subscribers { sinks[id]?.send(notice) }
    }

    private func outputClosed(key: String, generation: Int) {
        guard children[key]?.generation == generation, children[key]?.outputDone == false else { return }
        children[key]?.outputDone = true
        finishIfDone(key: key)
    }

    private func exited(key: String, generation: Int, exit: AgentHostExit) {
        guard children[key]?.generation == generation else { return }
        children[key]?.alive = false
        children[key]?.exit = exit
        children[key]?.writer?.finish()
        children[key]?.writer = nil
        logger.info("exited", metadata: ["key": .string(key), "status": "\(exit.status.map(String.init) ?? "-")", "signal": "\(exit.signal.map(String.init) ?? "-")"])
        finishIfDone(key: key)
        // 出力の口を孫が握っていると EOF が来ない。終わってから 2 秒待っても来なければ、読み終えたことにする
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.outputClosed(key: key, generation: generation)
        }
    }

    /// 終わりの知らせは、子が終わって出力も読み終えてから 1 回だけ送る（最後の行より先に終わりが届かないように）
    private func finishIfDone(key: String) {
        guard let child = children[key], !child.alive, child.outputDone else { return }
        let notice = AgentHostNotice(event: .exit, key: key, exit: child.exit)
        for id in child.subscribers { sinks[id]?.send(notice) }
        exitIfDrained()
    }

    private func exitIfDrained() {
        guard draining, !children.values.contains(where: \.alive) else { return }
        onIdleAfterDrain()
    }
}

/// 接続ごとの送り口。届くのを待たずに積み、別の Task が順に書く。daemon が読まずに `limit` を超えたら接続を切る
/// （切れば daemon は繋ぎ直して、番号で続きから読み直す）
final class AgentHostSink: @unchecked Sendable {
    let id: Int
    private let continuation: AsyncStream<ByteBuffer>.Continuation
    private let lock = NSLock()
    private var pending = 0
    private var closed = false
    let limit: Int

    init(id: Int, limit: Int = 64 << 20, continuation: AsyncStream<ByteBuffer>.Continuation) {
        self.id = id
        self.limit = limit
        self.continuation = continuation
    }

    func send<T: Encodable>(_ value: T) {
        guard let buffer = try? AgentHostWire.encode(value) else { return }
        let overflow = lock.withLock { () -> Bool in
            guard !closed else { return false }
            pending += buffer.readableBytes
            if pending > limit {
                closed = true
                return true
            }
            return false
        }
        if overflow {
            continuation.finish()
        } else {
            continuation.yield(buffer)
        }
    }

    func written(_ bytes: Int) { lock.withLock { pending -= bytes } }

    var isClosed: Bool { lock.withLock { closed } }
}

/// 子の標準エラーのログ。0600 で書き、上限を超えたら `.1` に回す
final class AgentHostLog: @unchecked Sendable {
    let url: URL
    let limit: Int
    private let lock = NSLock()

    init(url: URL, limit: Int) {
        self.url = url
        self.limit = limit
    }

    func append(_ chunk: ByteBuffer) {
        lock.withLock {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size + chunk.readableBytes > limit {
                let rotated = url.appendingPathExtension("1")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(chunk.readableBytesView))
        }
    }
}
