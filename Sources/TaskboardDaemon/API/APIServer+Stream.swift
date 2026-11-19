import Foundation
import HummingbirdWebSocket
import Logging
import NIOCore
import TaskboardKit

/// `GET /v1/stream`：アプリが daemon ごとに 1 本張る接続。状態の出来事を番号つきで送り、`subscribe` した会話の出来事も同じ送り口に積む。
/// 操作（送る・答える・止める）は HTTP の API のまま
extension APIServer {
    /// 読むのが遅く、送り口が上限を超えた接続を閉じる code（アプリは `hello` の番号で繋ぎ直す）
    static let streamBehindCloseCode: UInt16 = 4408
    /// 1 本の接続で購読できる会話の数
    static let streamSubscriptionLimit = 64
    /// 繋いでから `hello` を待つ時間
    static let streamHelloTimeout: Duration = .seconds(10)

    static func runStream(
        inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, state: DaemonState, conversations: ConversationService?, logger: Logger
    ) async throws {
        enum Part { case reader, writer, timer }
        let outbox = StreamOutbox()
        let opened = StreamOpened()
        try await withThrowingTaskGroup(of: Part.self) { group in
            group.addTask {
                let decoder = WireJSON.decoder()
                var subscribed: Set<String> = []
                do {
                    for try await message in inbound.messages(maxSize: 1 << 16) {
                        guard case .text(let text) = message, let decoded = try? decoder.decode(StreamClientMessage.self, from: Data(text.utf8)) else { continue }
                        guard let streamID = opened.id else {
                            // 最初の 1 通は hello（その前の subscribe は読み捨てる）
                            guard case .hello(let epoch, let rev) = decoded else { continue }
                            opened.set(await state.openStream(epoch: epoch, after: rev, outbox: outbox))
                            continue
                        }
                        switch decoded {
                        case .hello:
                            continue
                        case .subscribe(let id, let epoch, let after, let subagents):
                            guard let conversations, subscribed.contains(id) || subscribed.count < streamSubscriptionLimit else {
                                outbox.pushUnsubscribed(conversation: id, reason: StreamServerFrame.missing)
                                continue
                            }
                            subscribed.insert(id)
                            if await !conversations.subscribe(id, key: streamID, epoch: epoch, after: after, subagents: subagents, outbox: outbox) {
                                subscribed.remove(id)
                            }
                        case .unsubscribe(let id):
                            guard subscribed.remove(id) != nil else { continue }
                            await conversations?.unsubscribe(id, key: streamID)
                        }
                    }
                } catch {}
                // 切れたら購読を外す（「見えている」の数から落とす）
                if let streamID = opened.id {
                    for id in subscribed { await conversations?.unsubscribe(id, key: streamID) }
                }
                return .reader
            }
            group.addTask {
                for await frame in outbox.frames {
                    try await outbound.write(.text(String(decoding: frame.data, as: UTF8.self)))
                    outbox.sent(frame)
                }
                if outbox.isOverflowed {
                    logger.warning("stream fell behind")
                    try await outbound.close(.unknown(streamBehindCloseCode), reason: "behind")
                }
                return .writer
            }
            group.addTask {
                try await Task.sleep(for: streamHelloTimeout)
                if opened.id == nil { outbox.finish() }
                return .timer
            }
            while let part = try await group.next() {
                if part != .timer { break }
            }
            group.cancelAll()
            outbox.finish()
        }
        if let streamID = opened.id { await state.closeStream(streamID) }
    }

    /// `hello` を受けて登録した接続の id（読み手が書き、待ち時間の見張りと後片付けが読む）
    final class StreamOpened: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UUID?
        var id: UUID? { lock.withLock { stored } }
        func set(_ id: UUID) { lock.withLock { stored = id } }
    }

}
