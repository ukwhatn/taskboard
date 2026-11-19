import Foundation

/// `GET /v1/stream`（WebSocket）でアプリが送る 1 通。JSON は `{"type": "...", ...}`。
/// 状態は繋ぐたびに `hello` の番号の続きから、会話の発言は `subscribe` した会話だけを受ける
public enum StreamClientMessage: Hashable, Sendable {
    /// 繋いだら最初に送る。前の接続で受けた daemon の起動の印（`epoch`）と状態の番号（`rev`）。無ければ状態の全体を受ける
    case hello(epoch: String?, rev: Int?)
    /// 会話の出来事を読む。`after` は手元の最後の seq、`epoch` はその seq を受けた daemon の起動の印（違えば `gap` から始まる）。
    /// `subagents` はサブエージェントの発言（`ChatMessage.parentToolID`）も受けるか（前の版のアプリは送らず、本筋だけを受ける）
    case subscribe(conversation: String, epoch: String?, after: Int, subagents: Bool = false)
    case unsubscribe(conversation: String)
}

extension StreamClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, epoch, rev, conversation, after, subagents
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(epoch: try c.decodeIfPresent(String.self, forKey: .epoch), rev: try c.decodeIfPresent(Int.self, forKey: .rev))
        case "subscribe":
            self = .subscribe(
                conversation: try c.decode(String.self, forKey: .conversation), epoch: try c.decodeIfPresent(String.self, forKey: .epoch),
                after: try c.decodeIfPresent(Int.self, forKey: .after) ?? 0, subagents: try c.decodeIfPresent(Bool.self, forKey: .subagents) ?? false)
        case "unsubscribe":
            self = .unsubscribe(conversation: try c.decode(String.self, forKey: .conversation))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown message \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let epoch, let rev):
            try c.encode("hello", forKey: .type)
            try c.encodeIfPresent(epoch, forKey: .epoch)
            try c.encodeIfPresent(rev, forKey: .rev)
        case .subscribe(let conversation, let epoch, let after, let subagents):
            try c.encode("subscribe", forKey: .type)
            try c.encode(conversation, forKey: .conversation)
            try c.encodeIfPresent(epoch, forKey: .epoch)
            try c.encode(after, forKey: .after)
            if subagents { try c.encode(true, forKey: .subagents) }
        case .unsubscribe(let conversation):
            try c.encode("unsubscribe", forKey: .type)
            try c.encode(conversation, forKey: .conversation)
        }
    }
}

/// `GET /v1/stream` で daemon が送る 1 通
public enum StreamServerFrame: Hashable, Sendable {
    /// 状態の全体。手元の状態を捨てて置き換える（merge しない）。`rev` から先は `event` で届く
    case state(epoch: String, rev: Int, snapshot: StateSnapshot)
    /// `hello` の番号の続きから送れる。続けて控えの `event` が届く
    case resume(epoch: String, rev: Int)
    /// 状態の出来事。`rev` は 1 つずつ増える。`event` が nil なのは、この版が知らない種類（番号だけ進める）
    case event(rev: Int, event: DaemonEvent?)
    /// 購読を始めた。続けて `after` より後の控えを seq の順に送り、`through` より後は起きたときに送る
    case subscribed(conversation: String, epoch: String, through: Int)
    /// 購読した会話の出来事
    case conversation(ConversationEvent)
    /// 購読が終わった（`behind`：読むのが遅れた。最後の seq から購読し直す、`removed`：記録を消した、`missing`：会話が無い）
    case unsubscribed(conversation: String, reason: String)

    public static let behind = "behind"
    public static let removed = "removed"
    public static let missing = "missing"

    /// この版が知らない `type` なら nil（JSON の形が壊れているときは投げる）
    public static func decodeIfKnown(_ data: Data, decoder: JSONDecoder) throws -> StreamServerFrame? {
        do {
            return try decoder.decode(StreamServerFrame.self, from: data)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.last?.stringValue == CodingKeys.type.stringValue {
            return nil
        }
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case type, epoch, rev, snapshot, data, conversation, through, reason
    }
}

extension StreamServerFrame: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "state":
            self = .state(
                epoch: try c.decode(String.self, forKey: .epoch), rev: try c.decode(Int.self, forKey: .rev),
                snapshot: try c.decode(StateSnapshot.self, forKey: .snapshot))
        case "resume":
            self = .resume(epoch: try c.decode(String.self, forKey: .epoch), rev: try c.decode(Int.self, forKey: .rev))
        case "event":
            let rev = try c.decode(Int.self, forKey: .rev)
            do {
                self = .event(rev: rev, event: try c.decode(DaemonEvent.self, forKey: .data))
            } catch DecodingError.dataCorrupted(let context) where context.codingPath.last?.stringValue == "event" {
                // 新しい daemon が足した種類。番号は進める（飛ばすと続きから受けられなくなる）
                self = .event(rev: rev, event: nil)
            }
        case "subscribed":
            self = .subscribed(
                conversation: try c.decode(String.self, forKey: .conversation), epoch: try c.decode(String.self, forKey: .epoch),
                through: try c.decode(Int.self, forKey: .through))
        case "conversation":
            self = .conversation(try c.decode(ConversationEvent.self, forKey: .data))
        case "unsubscribed":
            self = .unsubscribed(conversation: try c.decode(String.self, forKey: .conversation), reason: try c.decode(String.self, forKey: .reason))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown frame \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .state(let epoch, let rev, let snapshot):
            try c.encode("state", forKey: .type)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(rev, forKey: .rev)
            try c.encode(snapshot, forKey: .snapshot)
        case .resume(let epoch, let rev):
            try c.encode("resume", forKey: .type)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(rev, forKey: .rev)
        case .event(let rev, let event):
            try c.encode("event", forKey: .type)
            try c.encode(rev, forKey: .rev)
            try c.encodeIfPresent(event, forKey: .data)
        case .subscribed(let conversation, let epoch, let through):
            try c.encode("subscribed", forKey: .type)
            try c.encode(conversation, forKey: .conversation)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(through, forKey: .through)
        case .conversation(let event):
            try c.encode("conversation", forKey: .type)
            try c.encode(event, forKey: .data)
        case .unsubscribed(let conversation, let reason):
            try c.encode("unsubscribed", forKey: .type)
            try c.encode(conversation, forKey: .conversation)
            try c.encode(reason, forKey: .reason)
        }
    }
}

/// `/v1/stream` の 1 本の接続（`DaemonClient.openStream`）。`frames` を読み、`send` で `hello`・`subscribe`・`unsubscribe` を送る。
/// 20 秒ごとに ping を送り、10 秒 pong が来なければ切る（URLSession は server の ping に自分で答えるだけで、切れたことが分からないため）
public final class DaemonStreamConnection: Sendable {
    public let frames: AsyncThrowingStream<StreamServerFrame, any Error>
    private let task: URLSessionWebSocketTask
    private let continuation: AsyncThrowingStream<StreamServerFrame, any Error>.Continuation

    public static let pingInterval: Duration = .seconds(20)
    public static let pongTimeout: Duration = .seconds(10)
    /// 状態の全体（Studio で 1MB）と、会話の控え
    public static let maximumMessageSize = 64 << 20

    init(task: URLSessionWebSocketTask, upgradeError: @escaping @Sendable (URLSessionWebSocketTask) -> (any Error)?) {
        self.task = task
        let (frames, continuation) = AsyncThrowingStream<StreamServerFrame, any Error>.makeStream()
        self.frames = frames
        self.continuation = continuation
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()
        let reader = Task {
            let decoder = WireJSON.decoder()
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: continue
                    }
                    if let frame = try StreamServerFrame.decodeIfKnown(data, decoder: decoder) { continuation.yield(frame) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: upgradeError(task) ?? error)
            }
        }
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled else { return }
                guard await task.ping(timeout: Self.pongTimeout) else {
                    task.cancel(with: .goingAway, reason: nil)
                    continuation.finish(throwing: SessionSourceError.disconnected)
                    return
                }
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            pinger.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    /// 送る。切れていれば投げる
    public func send(_ message: StreamClientMessage) async throws {
        let data = try WireJSON.encoder().encode(message)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func close() {
        continuation.finish()
    }
}

extension URLSessionWebSocketTask {
    /// ping を送り、pong が `timeout` までに来たら true
    public func ping(timeout: Duration) async -> Bool {
        let result = PingResult()
        sendPing { error in result.set(error == nil) }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = result.value { return value }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return result.value ?? false
    }

    fileprivate final class PingResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool? { lock.withLock { stored } }
        func set(_ value: Bool) { lock.withLock { if stored == nil { stored = value } } }
    }
}
