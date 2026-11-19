import Foundation
import Logging
import NIOCore
import TaskboardKit

/// host の部品（`AgentHostRegistry`）をこのプロセスの中で動かす。`taskboard conversation check` と契約テストが、daemon と host なしで本物の CLI を通す
actor InProcessAgentHost: AgentHostTransport {
    private let registry: AgentHostRegistry
    private var reader: Task<Void, Never>?

    init(logDirectory: URL, logger: Logger) {
        registry = AgentHostRegistry(logDirectory: logDirectory, logger: logger, onIdleAfterDrain: {})
    }

    /// 知らせを順に `route` へ渡す
    func start(route: @escaping @Sendable (AgentHostNotice) async -> Void) async {
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        let sink = AgentHostSink(id: 1, continuation: continuation)
        await registry.attach(sink)
        reader = Task {
            for await buffer in stream {
                sink.written(buffer.readableBytes)
                if case .notice(let notice) = try? AgentHostWire.decodeFrame(Data(buffer.readableBytesView)) { await route(notice) }
            }
        }
    }

    func call(
        _ op: AgentHostRequest.Op, key: String?, argv: [String]?, env: [String: String]?, cwd: String?, data: String?, signal: String?, after: Int?,
        through: Int?, cols: Int?, rows: Int?
    ) async throws -> AgentHostReply {
        let request = AgentHostRequest(id: 0, op: op, key: key, argv: argv, env: env, cwd: cwd, data: data, signal: signal, after: after, through: through, cols: cols, rows: rows)
        let reply = await registry.handle(request, from: 1)
        guard reply.ok else { throw AgentHostClient.Failure.refused(reply.error ?? "") }
        return reply
    }

    /// 残っている子を止める
    func shutdown() async {
        for process in (try? await list()) ?? [] where process.alive { try? await signal(key: process.key, "KILL") }
        reader?.cancel()
    }
}
