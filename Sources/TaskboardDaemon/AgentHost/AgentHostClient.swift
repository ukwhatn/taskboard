import Foundation
import Logging
import NIOCore
import NIOPosix

/// daemon から agent host への 1 本の接続。切れたら 1 秒ごとに繋ぎ直し、繋がるたびに `connected`（host の hello）を知らせる。
/// 番号は host が起き直すと 1 から振り直されるので、受ける側は hello の `startedAt` が変わったら読み直す位置を 0 に戻す
actor AgentHostClient {
    enum Event: Sendable {
        case connected(AgentHostReply)
        case disconnected
        /// 版の違う host に入れ替えを頼んだ。値はまだ動いている子の key（会話の id）
        case draining([String])
        case notice(AgentHostNotice)
    }

    enum Failure: Error, CustomStringConvertible {
        case notConnected
        case disconnected
        case refused(String)
        case incompatible(Int?)

        var description: String {
            switch self {
            case .notConnected: "agent host に繋がっていない"
            case .disconnected: "agent host との接続が切れた"
            case .refused(let message): "agent host が断った: \(message)"
            case .incompatible(let version): "agent host の版が合わない（protocol \(version.map(String.init) ?? "?")）"
            }
        }
    }

    let socketPath: String
    let logger: Logger
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>?
    private var pending: [Int: CheckedContinuation<AgentHostReply, any Error>] = [:]
    private var nextID = 0
    private var loop: Task<Void, Never>?
    private(set) var hello: AgentHostReply?

    init(socketPath: String, logger: Logger) {
        self.socketPath = socketPath
        self.logger = logger
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        continuation.finish()
    }

    /// 要求を送って応答を待つ。`ok` でない応答は `refused` で投げる
    @discardableResult
    func call(_ op: AgentHostRequest.Op, key: String? = nil, argv: [String]? = nil, env: [String: String]? = nil, cwd: String? = nil,
              data: String? = nil, signal: String? = nil, after: Int? = nil, through: Int? = nil, cols: Int? = nil, rows: Int? = nil) async throws -> AgentHostReply {
        guard let outbound else { throw Failure.notConnected }
        nextID += 1
        let request = AgentHostRequest(
            id: nextID, op: op, key: key, argv: argv, env: env, cwd: cwd, data: data, signal: signal, after: after, through: through, cols: cols, rows: rows)
        let buffer = try AgentHostWire.encode(request)
        let reply = try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<AgentHostReply, any Error>) in
            pending[request.id] = waiter
            Task { await self.send(buffer, id: request.id, through: outbound) }
        }
        guard reply.ok else { throw Failure.refused(reply.error ?? "") }
        return reply
    }

    private func send(_ buffer: ByteBuffer, id: Int, through outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) async {
        do {
            try await outbound.write(buffer)
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: Failure.disconnected)
        }
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connect(unixDomainSocketPath: socketPath) { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineFrameDecoder()))
                            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                        }
                    }
                try await channel.executeThenClose { inbound, outbound in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await line in inbound { await self.received(Data(line.readableBytesView)) }
                        }
                        self.outbound = outbound
                        let hello = try await self.call(.hello)
                        guard let version = hello.protocolVersion, (AgentHostWire.oldestServedVersion...AgentHostWire.protocolVersion).contains(version) else {
                            // host は daemon と同じ実行ファイルなので、起き直せば版が揃う。子が全部終わってから終わってもらう
                            let alive = (try? await self.call(.list))?.processes?.filter(\.alive).map(\.key) ?? []
                            try? await self.call(.drain)
                            self.continuation.yield(.draining(alive.sorted()))
                            throw Failure.incompatible(hello.protocolVersion)
                        }
                        self.hello = hello
                        self.continuation.yield(.connected(hello))
                        try await group.next()
                        group.cancelAll()
                    }
                }
            } catch {
                if outbound != nil { logger.warning("agent host connection ended", metadata: ["error": "\(error)"]) }
            }
            disconnected()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func received(_ data: Data) {
        guard let frame = try? AgentHostWire.decodeFrame(data) else {
            logger.warning("unreadable frame from agent host", metadata: ["bytes": .stringConvertible(data.count)])
            return
        }
        switch frame {
        case .reply(let reply): pending.removeValue(forKey: reply.id)?.resume(returning: reply)
        case .notice(let notice): continuation.yield(.notice(notice))
        }
    }

    private func disconnected() {
        let wasConnected = hello != nil
        outbound = nil
        hello = nil
        for (_, waiter) in pending { waiter.resume(throwing: Failure.disconnected) }
        pending.removeAll()
        if wasConnected { continuation.yield(.disconnected) }
    }
}
