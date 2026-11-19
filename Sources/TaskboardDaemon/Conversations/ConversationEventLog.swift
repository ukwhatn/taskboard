import Foundation
import Logging
import TaskboardKit

/// 会話の出来事の控え（会話ごとの番号つき）と、その購読（`/v1/stream` の接続と E1 の購読）。engine に依らない。
/// 会話の actor の中で値として持つ。生成中の差分をためる時間は actor が測り、`flushDelta` を呼ぶ
struct ConversationEventLog {
    static let limit = 2_000
    /// 1 つの購読が読まずにためてよい出来事の数。最初に控えを全部（と gap と会話の状態）送っても収まる大きさ
    static let subscriberLimit = limit * 2

    let conversationID: String
    /// daemon の起動ごとの印（`DaemonState.epoch`）。seq は起動ごとに 1 から数え直すので、購読の続きはこれが同じときだけ送る
    let epoch: String
    let logger: Logger
    private var events: [ConversationEvent] = []
    private var nextSeq = 1
    /// 控えの上限で落とした最後の seq。これより前から購読し直す接続には `gap` から送る（終わった発言の差分を詰めて外した分は数えない）
    private var droppedThrough = 0
    /// `/v1/stream` の購読（接続の id → 送り口）。数が「画面に出ている」の数
    private var streamSubscribers: [UUID: StreamOutbox] = [:]
    /// サブエージェントの発言も受ける購読（ほかの購読と E1 の購読には外して送る）
    private var subagentSubscribers: Set<UUID> = []
    /// E1 の購読（daemon の token の `…/events` と check）。状態の出来事も流す
    private var watchers: [UUID: AsyncStream<ConversationEvent>.Continuation] = [:]
    private let encoder = WireJSON.encoder()

    private struct PendingDelta {
        var messageID: String
        var index: Int
        var block: ConversationEvent.DeltaBlock
        var text: String
    }
    private var pendingDelta: PendingDelta?

    /// message の id → block の進み。止まっていて終わった発言も届いた block の差分を控えから外す
    private var blockProgress: [String: BlockProgress] = [:]
    private struct BlockProgress {
        var started: Set<Int> = []
        var stopped: Set<Int> = []
        /// 終わった発言が届いた時点で始まっていた block（CLI は終わった発言を block の終わりの前に送る版も後に送る版もある）
        var finished: Set<Int> = []
    }

    init(conversationID: String, epoch: String, logger: Logger) {
        self.conversationID = conversationID
        self.epoch = epoch
        self.logger = logger
    }

    var lastSeq: Int { nextSeq - 1 }
    /// 購読している接続の数（画面に出ているか）
    var viewers: Int { streamSubscribers.count }

    // MARK: 積む

    /// 出来事を控えに積んで配る。ためている差分を先に出す
    mutating func emit(_ kind: ConversationEvent.Kind, at: Date) {
        flushDelta(at: at)
        let event = ConversationEvent(seq: nextSeq, conversationID: conversationID, at: at, kind: kind)
        nextSeq += 1
        events.append(event)
        if events.count > Self.limit {
            let overflow = events.count - Self.limit
            droppedThrough = events[overflow - 1].seq
            events.removeFirst(overflow)
        }
        deliver(event)
    }

    /// 生成中の差分。同じ block の分はためて 1 つの出来事にする。新しくためはじめたら true（呼ぶ側が間をおいて `flushDelta` を呼ぶ）
    mutating func appendDelta(messageID: String, index: Int, block: ConversationEvent.DeltaBlock, text: String, at: Date) -> Bool {
        if var buffered = pendingDelta, buffered.messageID == messageID, buffered.index == index, buffered.block == block {
            buffered.text += text
            pendingDelta = buffered
            return false
        }
        flushDelta(at: at)
        pendingDelta = PendingDelta(messageID: messageID, index: index, block: block, text: text)
        return true
    }

    mutating func flushDelta(at: Date) {
        guard let buffered = pendingDelta else { return }
        pendingDelta = nil
        emit(.delta(messageID: buffered.messageID, index: buffered.index, block: buffered.block, text: buffered.text), at: at)
    }

    /// コードブロックの Run の出来事。控えに積まず、今の購読にだけ流す（購読し直した画面は `GET …/runs/{run}` で取り直す。
    /// 10 分の Run の出力で控えが埋まり、発言が先に落ちないように）
    mutating func emitRun(_ update: ConversationRunUpdate, at: Date) {
        flushDelta(at: at)
        let event = ConversationEvent(seq: nextSeq, conversationID: conversationID, at: at, kind: .run(update))
        nextSeq += 1
        deliver(event)
    }

    /// 会話の中身を替えた：控えを捨てて `reset` を流す（購読している画面は手元の発言を捨てて履歴を取り直す）
    mutating func reset(at: Date) {
        flushDelta(at: at)
        events.removeAll()
        droppedThrough = nextSeq - 1
        blockProgress.removeAll()
        emit(.reset, at: at)
    }

    // MARK: 終わった差分を詰める

    mutating func blockStarted(messageID: String, index: Int) {
        blockProgress[messageID, default: BlockProgress()].started.insert(index)
    }

    mutating func blockStopped(messageID: String, index: Int) {
        blockProgress[messageID, default: BlockProgress()].stopped.insert(index)
        compact(message: messageID)
    }

    /// 終わった発言が届いた（その発言の、始まっていた block は終わった扱い）
    mutating func messageFinished(_ messageID: String) {
        guard var progress = blockProgress[messageID] else { return }
        progress.finished.formUnion(progress.started)
        blockProgress[messageID] = progress
        compact(message: messageID)
    }

    /// 終わった発言の、止まった block の差分を控えから外す（2,000 件が差分で埋まり、終わった発言が先に落ちないように。外した分は `gap` にしない）
    private mutating func compact(message messageID: String) {
        guard let progress = blockProgress[messageID] else { return }
        let done = progress.stopped.intersection(progress.finished)
        guard !done.isEmpty else { return }
        events.removeAll { event in
            switch event.kind {
            case .blockStart(let m, let index, _, _), .delta(let m, let index, _, _), .blockStop(let m, let index): m == messageID && done.contains(index)
            default: false
            }
        }
        blockProgress[messageID]?.stopped.subtract(done)
    }

    /// ターンが終わった：残っている差分を全部控えから外す（その発言は `messages` で届いている）
    mutating func compactTurn() {
        events.removeAll { event in
            switch event.kind {
            case .blockStart, .delta, .blockStop: true
            default: false
            }
        }
        blockProgress.removeAll()
    }

    // MARK: 購読

    /// `/v1/stream` の購読。`subscribed` → `after` より後の控えを seq の順 → 以後の出来事、の順に `outbox` に積む。積むのと登録が同じ turn なので落ちも重なりも無い。
    /// 手元に発言のある接続（`after` > 0）が、上限で落とした番号より前から求めたときと、daemon の起動が違うときは、先に `gap` を送って控えを全部送る。
    /// 会話の様子は購読に入れない（`DaemonState` の `conversation.updated` で届く）
    mutating func subscribe(_ outbox: StreamOutbox, key: UUID, epoch clientEpoch: String?, after: Int, subagents: Bool, at: Date) {
        flushDelta(at: at)
        let through = nextSeq - 1
        push(StreamServerFrame.subscribed(conversation: conversationID, epoch: epoch, through: through), to: outbox)
        let gap = after > 0 && (clientEpoch != epoch || after < droppedThrough || after > through)
        if gap { push(.conversation(ConversationEvent(seq: droppedThrough, conversationID: conversationID, at: at, kind: .gap)), to: outbox) }
        for event in events where gap || event.seq > after { push(.conversation(subagents ? event : event.strippedOfSubagents ?? event), to: outbox) }
        streamSubscribers[key] = outbox
        if subagents { subagentSubscribers.insert(key) } else { subagentSubscribers.remove(key) }
    }

    mutating func unsubscribe(key: UUID) {
        streamSubscribers.removeValue(forKey: key)
        subagentSubscribers.remove(key)
    }

    /// 消した会話の購読を断る
    func refuse(_ outbox: StreamOutbox) {
        outbox.pushUnsubscribed(conversation: conversationID, reason: StreamServerFrame.removed)
    }

    /// E1 の購読：`after` より後の出来事を送ってから続きを送る。控えから落ちた分があれば先に `gap` を、続けて会話の様子を送る。
    /// 読むのが遅れて待ちが `subscriberLimit` を超えたら、その購読を終える（黙って途中を落とさない。読む側は最後の番号から取り直す）。
    /// 終わったときの `unwatch` は呼ぶ側が `onTermination` で付ける
    mutating func watch(after: Int, state: Conversation, at: Date) -> (stream: AsyncStream<ConversationEvent>, key: UUID, continuation: AsyncStream<ConversationEvent>.Continuation) {
        let (stream, continuation) = AsyncStream<ConversationEvent>.makeStream(bufferingPolicy: .bufferingOldest(Self.subscriberLimit))
        flushDelta(at: at)
        if after < droppedThrough || after > nextSeq - 1 {
            continuation.yield(ConversationEvent(seq: droppedThrough, conversationID: conversationID, at: at, kind: .gap))
        }
        continuation.yield(ConversationEvent(seq: nextSeq - 1, conversationID: conversationID, at: at, kind: .conversation(state)))
        for event in events where event.seq > after { continuation.yield(event.strippedOfSubagents ?? event) }
        let key = UUID()
        watchers[key] = continuation
        return (stream, key, continuation)
    }

    mutating func unwatch(_ key: UUID) { watchers.removeValue(forKey: key) }

    /// 会話の様子を E1 の購読に流す（控えには入れない）
    mutating func publish(_ state: Conversation, at: Date) {
        let event = ConversationEvent(seq: nextSeq - 1, conversationID: conversationID, at: at, kind: .conversation(state))
        for (key, continuation) in watchers {
            if case .dropped = continuation.yield(event) {
                watchers.removeValue(forKey: key)
                continuation.finish()
            }
        }
    }

    /// 記録を消す：購読を `removed` で終える
    mutating func close() {
        for (_, outbox) in streamSubscribers { refuse(outbox) }
        streamSubscribers.removeAll()
        subagentSubscribers.removeAll()
        for (_, continuation) in watchers { continuation.finish() }
        watchers.removeAll()
    }

    @discardableResult
    private func push(_ frame: StreamServerFrame, to outbox: StreamOutbox) -> Bool {
        guard let data = try? encoder.encode(frame) else { return false }
        return outbox.push(data, conversation: conversationID)
    }

    private mutating func deliver(_ event: ConversationEvent) {
        let stripped = event.strippedOfSubagents
        for (key, continuation) in watchers {
            if case .dropped = continuation.yield(stripped ?? event) {
                logger.warning("conversation subscriber fell behind", metadata: ["conversation": .string(conversationID)])
                watchers.removeValue(forKey: key)
                continuation.finish()
            }
        }
        guard !streamSubscribers.isEmpty, let frame = try? encoder.encode(StreamServerFrame.conversation(event)) else { return }
        let strippedFrame = stripped.flatMap { try? encoder.encode(StreamServerFrame.conversation($0)) }
        for (key, outbox) in streamSubscribers {
            guard outbox.push(subagentSubscribers.contains(key) ? frame : strippedFrame ?? frame, conversation: conversationID) else {
                streamSubscribers.removeValue(forKey: key)
                continue
            }
            if outbox.pending(conversation: conversationID) > Self.subscriberLimit {
                logger.warning("conversation stream subscriber fell behind", metadata: ["conversation": .string(conversationID)])
                streamSubscribers.removeValue(forKey: key)
                outbox.pushUnsubscribed(conversation: conversationID, reason: StreamServerFrame.behind)
            }
        }
    }
}
