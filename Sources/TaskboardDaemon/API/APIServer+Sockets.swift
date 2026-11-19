import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import TaskboardKit

/// WebSocket の口（stream と会話のシェル）
extension APIServer {
    static func registerSockets(sockets: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder, logger: Logger) {
        /// 認証に落ちた接続は何も送らず 4401 で閉じる。端末の token なら登録し、止められたら 4401 で閉じる
        @Sendable func guardSocket(
            _ context: WebSocketRouterContext<TaskboardRequestContext>, _ outbound: WebSocketOutboundWriter,
            _ body: @escaping @Sendable () async throws -> Void
        ) async throws {
            try await DeviceSocket.run(
                principal: context.requestContext.principal, outbound: outbound, devices: dependencies.deviceAuth,
                willRegister: dependencies.socketWillRegister, logger: logger, body)
        }

        sockets.ws("stream") { request, _ in
            // Cloudflare を通った接続でも圧縮の申し出が届いているかを、ログで見分ける
            let deflate = request.headers[values: .secWebSocketExtensions].contains { $0.contains("permessage-deflate") }
            logger.info("stream upgrade", metadata: ["deflate": .stringConvertible(deflate)])
            return .upgrade()
        } onUpgrade: { inbound, outbound, context in
            try await guardSocket(context, outbound) {
                try await runStream(inbound: inbound, outbound: outbound, state: state, conversations: dependencies.conversations, logger: logger)
            }
        }

        sockets.ws("terminal/{pane_id}") { _, _ in
            .upgrade()
        } onUpgrade: { inbound, outbound, context in
            try await guardSocket(context, outbound) {
                guard let raw = context.requestContext.parameters.get("pane_id"), !raw.isEmpty else {
                    try await outbound.close(.unexpectedServerError, reason: "pane_id が要る")
                    return
                }
                let pane = raw.removingPercentEncoding ?? raw
                let query = context.request.uri.queryParameters
                let size = AgentHostShells.clamp(cols: query.get("cols", as: Int.self) ?? 80, rows: query.get("rows", as: Int.self) ?? 24)
                guard ConversationShells.isShell(pane), let shells = dependencies.conversations?.shells else {
                    try await outbound.close(.unexpectedServerError, reason: TerminalCloseReason.paneNotFound.rawValue)
                    return
                }
                try await relayShell(pane, size: size, shells: shells, inbound: inbound, outbound: outbound)
            }
        }
    }

    /// 会話のシェル（agent host の擬似端末）の画面 1 つ分
    private static func relayShell(
        _ key: String, size: (cols: Int, rows: Int), shells: ConversationShells, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter
    ) async throws {
        let viewer = await shells.join(key: key, cols: size.cols, rows: size.rows)
        let decoder = WireJSON.decoder()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    guard case .text(let text) = message else { continue }
                    guard let client = try? decoder.decode(TerminalClientMessage.self, from: Data(text.utf8)) else { continue }
                    await shells.handle(viewer, client)
                }
            }
            group.addTask {
                while let item = await shells.next(viewer) {
                    switch item {
                    case .text(let text):
                        try await outbound.write(.text(text))
                    case .binary(let data):
                        try await outbound.write(.binary(ByteBuffer(bytes: data)))
                    case .end(let reason):
                        if let reason { try await outbound.close(.normalClosure, reason: reason) }
                        return
                    }
                }
            }
            // 送る側の `next` は取り消しで戻らないので、group が子を待つ前に `leave` で待ちを解く
            var failure: (any Error)?
            do { _ = try await group.next() } catch { failure = error }
            group.cancelAll()
            await shells.leave(viewer)
            if let failure { throw failure }
        }
    }
}
