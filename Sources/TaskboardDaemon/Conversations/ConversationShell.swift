import Foundation
import TaskboardKit

/// 会話の actor の殻のうち、engine に依らない分（子プロセスの状態と待ち・出来事の流れと購読・差分・統計・止める段・名前）。
/// engine ごとの actor が欄を持ち、ここが同じ手順を 1 つだけ持つ（`ConversationRecordKeeping` と同じ形）
protocol ConversationShell: ConversationRecordKeeping, LiveConversation {
    var shared: ConversationContext { get }
    var child: ConversationChild { get set }
    /// 子を起こすたびに増やす（前の子の知らせと待ちを今の子と取り違えない）
    var generation: Int { get }
    /// host の行のうち読み終えた番号
    var appliedSeq: Int { get }
    var reader: Task<Void, Never>? { get set }
    var inboxStream: AsyncStream<AgentHostNotice> { get }
    /// host の知らせを 1 つ読む（engine ごと）
    func handle(_ notice: AgentHostNotice) async
    var replayWaiters: [CheckedContinuation<Void, Never>] { get set }
    var resultWaiters: [CheckedContinuation<Void, Never>] { get set }
    var exitWaiters: [CheckedContinuation<Void, Never>] { get set }
    var log: ConversationEventLog { get set }
    var deltaFlush: Task<Void, Never>? { get set }
    var retired: Bool { get set }
    var startTask: Task<Void, any Error>? { get }
    /// 問いに答えている途中
    var isAnswering: Bool { get }
    var diff: ConversationDiffSummary? { get set }
    var diffScheduled: Bool { get set }
    var stats: ConversationStats? { get set }
    /// 送った発言の受付の状態（uuid ごと）
    var accepted: [String: String] { get }
    var lastActive: Date { get }
    var compaction: ConversationCompaction? { get set }
    /// 今のターンの最後の応答と使っているツール（配った発言から拾う）
    var turnActivity: ConversationTurnActivity { get set }
    /// CLI に会話の名前を送る
    func sendTitle(_ title: String) async throws
}

extension ConversationShell {
    var recordStore: Store { shared.store }
    func currentDate() -> Date { shared.now() }
    var noticeChangedHandler: @Sendable (String) async -> Void { shared.noticeChanged }
}


// MARK: 子プロセス

extension ConversationShell {
    func setChild(_ next: ConversationChild) {
        child = next
        shared.slots.setLive(id, next.isRunning)
    }

    /// 入力を閉じると決めた（動いていなければ何もしない）
    func refuseInput() {
        if child.isRunning { child = .running(acceptsInput: false) }
    }

    /// その回の子がまだ動いていれば signal を送る（その間に終わって起こし直した子には送らない）
    func signalIfStill(_ target: Int, _ signal: String) async {
        guard child.isRunning, generation == target else { return }
        try? await shared.host.signal(key: id, signal)
    }

    /// 子が終わるのを待ち、終わったら true。`generation` を渡すと、その回の子が終わった（起こし直された）ことも終わりに数える
    func waitForExit(timeout: Duration, generation target: Int? = nil) async -> Bool {
        func gone() -> Bool { !child.isRunning || (target.map { generation != $0 } ?? false) }
        guard !gone() else { return true }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            exitWaiters.append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.releaseExitWaiters()
            }
        }
        return gone()
    }

    func releaseExitWaiters() {
        for waiter in exitWaiters { waiter.resume() }
        exitWaiters.removeAll()
    }

    func releaseResultWaiters() {
        for waiter in resultWaiters { waiter.resume() }
        resultWaiters.removeAll()
    }

    func releaseReplayWaiters() {
        for waiter in replayWaiters { waiter.resume() }
        replayWaiters.removeAll()
    }

    /// `ConversationService.connected` の突き合わせで、受け直すだけでよいか。読んでいない会話と、止まった扱いなのに host で子が生きている会話
    /// （起こし直しを host に断られた）は引き取り直す
    func resubscribes(to process: AgentHostProcessInfo) -> Bool { reader != nil && (child.isRunning || !process.alive) }

    /// daemon と host の接続が繋ぎ直された（host は起き直していない）。host は接続ごとに購読を持つので、読んだ所の続きから受け直す。
    /// 入力を閉じると決めた会話（止める・defer・続けられない）は閉じ直す（切れている間に閉じようとして届かなかったかもしれない。2 回閉じても害は無い）
    func resubscribe() async {
        guard reader != nil else { return }
        do {
            try await shared.host.subscribe(key: id, after: appliedSeq)
        } catch {
            shared.logger.warning("conversation resubscribe failed", metadata: ["conversation": .string(id), "error": "\(error)"])
            return
        }
        if child == .running(acceptsInput: false) { try? await shared.host.closeInput(key: id) }
    }

    /// host に自分の key の生きた子があれば、起こし直さずに引き取る（daemon が起き直した後、突き合わせより先に起こす口が来たとき。
    /// 記録はそれより前に「起こせなかった」に書き換わっていることがあるので、記録でなく host の一覧で決める）
    func adoptLeftRunning() async -> Bool {
        guard let process = try? await shared.host.list().first(where: { $0.key == id }), process.alive else { return false }
        // 一覧を待つ間に、突き合わせの側が引き取っていることがある
        if !child.isRunning { await attach(process: process) }
        return child.isRunning
    }

    func startReading() {
        guard reader == nil else { return }
        reader = Task { [inboxStream] in
            for await notice in inboxStream { await self.handle(notice) }
        }
    }

    /// 捨てる所を先に記録に書いてから、host の控えを切る
    func trim(through seq: Int) async {
        guard (try? writeRecord { $0.trimmedThrough = max($0.trimmedThrough, seq) }) != nil else { return }
        try? await shared.host.trim(key: id, through: seq)
    }
}

// MARK: 出来事と購読

extension ConversationShell {
    /// 出来事を配る。生成中の差分は同じ block の分を `deltaBatch` ためてから 1 つにする（ほかの出来事の前には出し切る）
    func emit(_ kind: ConversationEvent.Kind) {
        flushDelta()
        log.emit(kind, at: shared.now())
        if case .messages(let messages, _) = kind, turnActivity.note(messages) { shared.publishTool(id, turnActivity.toolName) }
    }

    /// ターンが始まった。控えの読み直しの分は、記録に時刻が無いときだけ今の時刻で書く（daemon が起き直す前に書いた時刻を残す）。様子は呼んだ側が配る
    func beginTurn(replaying: Bool) {
        if turnActivity.reset() { shared.publishTool(id, nil) }
        guard !replaying || record.turnStartedAt == nil else { return }
        record.turnStartedAt = Store.storedDate(shared.now())
        saveTurn()
    }

    /// ターンが終わった。応答を書いたターンなら、それを最後の応答にする（応答の無いターンは前の応答を残す）。
    /// 控えの読み直しで同じ応答を読んだら、前に書いた時刻を残す
    func endTurn(replaying: Bool) {
        let activity = turnActivity
        let reply = activity.reply.map { String($0.prefix(ConversationReply.limit)) }
        if turnActivity.reset() { shared.publishTool(id, nil) }
        guard let reply, !(replaying && record.lastReply == reply) else { return }
        record.lastReply = reply
        record.lastReplyAt = Store.storedDate(shared.now())
        saveTurn()
        publishState()
    }

    private func saveTurn() {
        do {
            try shared.store.updateConversationTurn(id: id, turnStartedAt: record.turnStartedAt, lastReply: record.lastReply, lastReplyAt: record.lastReplyAt)
        } catch {
            shared.logger.warning("conversation turn not saved", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
    }

    func emitDelta(messageID: String, index: Int = 0, block: ConversationEvent.DeltaBlock, text: String) {
        guard log.appendDelta(messageID: messageID, index: index, block: block, text: text, at: shared.now()) else { return }
        deltaFlush?.cancel()
        let delay = shared.timing.deltaBatch
        deltaFlush = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.flushDelta()
        }
    }

    func flushDelta() {
        deltaFlush?.cancel()
        deltaFlush = nil
        log.flushDelta(at: shared.now())
    }

    /// コードブロックの Run の出来事（`ConversationEventLog.emitRun`）
    func emitRun(_ update: ConversationRunUpdate) {
        flushDelta()
        log.emitRun(update, at: shared.now())
    }

    /// `/v1/stream` の購読（`ConversationEventLog.subscribe`）。消した会話は断る
    func subscribe(_ outbox: StreamOutbox, key: UUID, epoch clientEpoch: String?, after: Int, subagents: Bool = false) -> Bool {
        guard !retired else {
            log.refuse(outbox)
            return false
        }
        flushDelta()
        log.subscribe(outbox, key: key, epoch: clientEpoch, after: after, subagents: subagents, at: shared.now())
        return true
    }

    func unsubscribe(key: UUID) { log.unsubscribe(key: key) }

    /// E1 の購読（`ConversationEventLog.watch`）。消した会話はすぐ終える
    func events(after: Int) -> AsyncStream<ConversationEvent> {
        guard !retired else {
            let (stream, continuation) = AsyncStream<ConversationEvent>.makeStream()
            continuation.finish()
            return stream
        }
        flushDelta()
        let watched = log.watch(after: after, state: snapshot(), at: shared.now())
        watched.continuation.onTermination = { [weak self] _ in Task { await self?.unwatch(watched.key) } }
        return watched.stream
    }

    func unwatch(_ key: UUID) { log.unwatch(key) }

    /// 記録を消す前：動いている・起こしている・答えている途中なら断る。以後は起こさず、購読は `removed` で終える
    func retire() throws {
        guard !child.isRunning, startTask == nil, !isAnswering else { throw ConversationError.live(id) }
        retired = true
        log.close()
    }

    /// 記録を消せなかった：戻す
    func unretire() { retired = false }
}

// MARK: 差分・統計・受付

extension ConversationShell {
    /// 差分の要約を `diffBatch` だけまとめてから取り直す（ターンの終わり・ファイルを書くツールの結果・Run の終わり）
    func refreshDiffSoon() {
        guard !diffScheduled else { return }
        diffScheduled = true
        let delay = shared.timing.diffBatch
        Task {
            try? await Task.sleep(for: delay)
            await self.refreshDiff()
        }
    }

    func refreshDiff() async {
        diffScheduled = false
        guard let summary = await shared.diff(record.cwd) else { return }
        setDiff(summary)
    }

    /// 差分の画面で取った要約（会話の状態の数も合わせる）
    func setDiff(_ summary: ConversationDiffSummary) {
        guard summary != diff else { return }
        diff = summary
        publishState()
    }

    /// 今の会話 ID の値を書き換えて、記録に残す。`session` が今の会話でなければ（取っている間に `/clear`・フォーク・巻き戻しが起きた）捨てる
    func updateStats(for session: String, _ change: (inout ConversationStats) -> Void) {
        guard session == record.agentSessionId else { return }
        var next = stats?.agentSessionID == session ? stats! : ConversationStats(agentSessionID: session, at: shared.now())
        change(&next)
        var compared = next
        compared.at = stats?.at ?? compared.at
        guard compared != stats else { return }
        next.at = shared.now()
        stats = next
        do {
            try shared.store.updateConversationStats(id: id, next)
        } catch {
            shared.logger.warning("conversation stats not saved", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
        publishState()
    }

    /// その uuid の発言を受けたか（待ち行列に入っただけでも。取り消されたものは受けていない）。待たずに今の控えで答える
    func received(_ uuid: String) -> Bool {
        guard let state = accepted[uuid] else { return false }
        return state != "cancelled"
    }
}

// MARK: 止める・名前・制御

extension ConversationShell {
    /// 動いていて空いている・画面に出ていない・裏のタスクが無いと分かっている・答えている途中でない・起こしている途中でない・利用枠の上限で待っていない
    var isQuiet: Bool { isResting && log.viewers == 0 }

    /// 止めてよい：動いていて空いている・画面に出ていない・裏のタスクが無いと分かっている・答えている途中でない・起こしている途中でない・
    /// `cutoff` より後に使っていない・タスクに結ばれている（結ばれていない会話は止めると記録を消すので、人が止める）
    func isStoppable(before cutoff: Date) -> Bool {
        isQuiet && lastActive < cutoff && record.taskNumber != nil && record.purposeValue != .orchestrator
    }

    /// 起こした側の会話を終了したとき：委譲先が空いていれば止める（生成中・問いの待ち・裏のタスクのある委譲先は動かしたまま）
    func stopIfResting() async {
        guard isResting else { return }
        await stop(.taskboard)
    }

    func endCompaction() {
        guard compaction != nil else { return }
        compaction = nil
        publishState()
    }

    /// 自動の題を付け直す（タスクの題が変わったとき）。人が付けた名前がある間は CLI に送らない（CLI は名前を出したまま）
    func rename(_ title: String) async throws {
        if record.customTitle == nil { try await sendTitle(title) }
        try writeRecord { $0.title = title }
        publishState()
    }

    /// 人が付けた名前を替える。nil なら外して自動の題に戻し、CLI にも自動の題を送る。
    /// 送る前に記録を書く（送っている間に CLI が送り返した名前を、自動の題と取り違えない）
    func setCustomTitle(_ name: String?) async throws {
        try writeRecord { $0.customTitle = name }
        publishState()
        if let shown = record.displayTitle { try await sendTitle(shown) }
    }

    func taskID(_ request: ConversationControlRequest) throws -> String {
        guard let id = request.value, !id.isEmpty else { throw ConversationError.invalid("タスクの id が空") }
        return id
    }
}
