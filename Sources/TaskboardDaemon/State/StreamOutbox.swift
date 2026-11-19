import Foundation
import TaskboardKit

/// `/v1/stream` の 1 本の接続の送り口。状態の出来事（`DaemonState`）と会話の出来事（`ClaudeConversation`）を、生まれた順に 1 列に積む。
/// 積んだまま書けていないバイト数（圧縮の前）が上限を超えたら閉じる（読むのが遅い接続のためにメモリを積み続けない。アプリは `hello` の番号で繋ぎ直す）。
/// 会話ごとの書けていない数も持ち、会話の側が読むのが遅い購読を終えるのに使う
final class StreamOutbox: @unchecked Sendable {
    struct Frame: Sendable {
        var data: Data
        /// 会話の出来事なら会話の id
        var conversation: String?
    }

    static let byteLimit = 8 << 20

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let byteLimit: Int
    private let lock = NSLock()
    private var bytes = 0
    private var perConversation: [String: Int] = [:]
    private var closed = false
    private var overflowed = false

    init(byteLimit: Int = StreamOutbox.byteLimit) {
        self.byteLimit = byteLimit
        (frames, continuation) = AsyncStream<Frame>.makeStream()
    }

    /// 積む。閉じていれば false。上限を超えたら閉じて false
    @discardableResult
    func push(_ data: Data, conversation: String? = nil) -> Bool {
        // 積むのと数えるのを同じ lock の中で行う（別の actor から同時に積んでも、数えた順と届く順が揃う）
        lock.withLock {
            guard !closed else { return false }
            // 空のときは上限より大きい 1 通も積む（状態の全体が上限を超えても、繋ぎ直しを繰り返さない）
            guard bytes == 0 || bytes + data.count <= byteLimit else {
                closed = true
                overflowed = true
                continuation.finish()
                return false
            }
            bytes += data.count
            if let conversation { perConversation[conversation, default: 0] += 1 }
            continuation.yield(Frame(data: data, conversation: conversation))
            return true
        }
    }

    /// 書き終えた（書き手が 1 通ごとに呼ぶ）
    func sent(_ frame: Frame) {
        lock.withLock {
            bytes -= frame.data.count
            if let conversation = frame.conversation {
                let left = (perConversation[conversation] ?? 1) - 1
                perConversation[conversation] = left > 0 ? left : nil
            }
        }
    }

    /// その会話の、積んだまま書けていない数
    func pending(conversation: String) -> Int { lock.withLock { perConversation[conversation] ?? 0 } }

    var isClosed: Bool { lock.withLock { closed } }
    /// 上限を超えて閉じた
    var isOverflowed: Bool { lock.withLock { overflowed } }

    func finish() {
        lock.withLock {
            closed = true
            continuation.finish()
        }
    }
}

extension StreamOutbox {
    /// 会話の購読を終える（`unsubscribed`。`reason` は `StreamServerFrame.missing`・`removed`・`behind`）
    func pushUnsubscribed(conversation: String, reason: String) {
        guard let frame = try? WireJSON.encoder().encode(StreamServerFrame.unsubscribed(conversation: conversation, reason: reason)) else { return }
        push(frame, conversation: conversation)
    }
}
