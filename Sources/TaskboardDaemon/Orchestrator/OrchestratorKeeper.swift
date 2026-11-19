// ui-copy:ignore-file
// このファイルの文（オーケストレーターの失敗の文（lastError））は、MCP の応答・保存される状態・ログに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation
import Logging
import TaskboardKit

/// オーケストレーターを常駐させる。設定で常駐が入っていて、オーケストレーターの会話（purpose が `orchestrator` の会話。1 台に 1 つ）が
/// 動いていなければ起こす。記録が止まっていれば同じ会話を `--resume` で戻し、無ければ新しく起こして起動の指示を送る。
/// あわせて `orchestrator.updated` を状態が変わるたびに配り、ターンが終わったら transcript から返事を拾う。
///
/// - 設定の引数を会話の項目に読み替えられないか、会話を起こせなかったら `lastError` に残し、`retryDelay` あけて再び試す（設定を変えたら待たない）
/// - daemon を再起動しても host の会話は残るので、引き取るだけで起こし直さない
public actor OrchestratorKeeper {
    let store: Store
    let state: DaemonState
    let conversations: ConversationService
    let interval: Duration
    let retryDelay: TimeInterval
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.whatn.taskboardd.orchestrator")

    static let title = "オーケストレーター"

    /// transcript の書き込みは idle の通知より遅れることがある
    private var replyAttempts = 3
    private var replyRetryInterval: Duration = .seconds(1)

    func setReplyRetry(attempts: Int, interval: Duration) {
        replyAttempts = attempts
        replyRetryInterval = interval
    }

    private var lastFailureAt: Date?
    /// 最後に配った返事の元（assistant の文の id）。同じ文を 2 度返事にしない
    private var lastReplyID: String?
    /// 会話を起こしている・破棄して再起動している間。見回りは何もせず、指示は終わるまで待たせる
    private var busy = false {
        didSet {
            guard !busy else { return }
            let waiters = busyWaiters
            busyWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }
    /// `busy` が明けるのを待っている呼び出し（`waitWhileBusy`）
    private var busyWaiters: [CheckedContinuation<Void, Never>] = []
    /// 起こせなかった理由と最後の返事。`info()` が `OrchestratorInfo` に載せて配る
    private var lastError: String?
    private var lastReply: OrchestratorReply?

    init(
        store: Store, state: DaemonState, conversations: ConversationService, interval: Duration = .seconds(30), retryDelay: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.state = state
        self.conversations = conversations
        self.interval = interval
        self.retryDelay = retryDelay
        self.now = now
    }

    public func run() async {
        // host に繋がって会話を引き取ってから見る（引き取る前に見ると、動いている会話を止まっていると見て起こし直す）
        await state.waitForAgentHost()
        await state.observe(every: interval, sweepFirst: true, handle: { await self.handle($0) }, sweep: { await self.tick() })
    }

    func tick() async {
        await keepRunning()
        await publish()
    }

    private func keepRunning() async {
        let settings = (try? store.settings()) ?? .defaults
        guard settings.orchestrator.enabled, !busy else { return }
        let record = await conversations.orchestratorRecord()
        if let record, await conversations.isLive(record.id) {
            lastError = nil
            return
        }
        if let failed = lastFailureAt, now().timeIntervalSince(failed) < retryDelay { return }
        do {
            try await startConversation(settings.orchestrator.agentArgs, prompt: nil, resuming: record)
        } catch {
            await failed("会話を起こせない: \(error)")
        }
    }

    /// 設定の引数を会話の項目に読み替える。読み替えられなければ投げる
    private func conversationRequest(_ agentArgs: [String]) async throws -> ConversationStartRequest {
        var request = try await conversations.launchRequest(kind: .claude, agentArgs: agentArgs, cwd: NSHomeDirectory(), taskNumber: nil)
        request.title = Self.title
        return request
    }

    /// 止まっている記録があれば同じ会話を戻し、無ければ新しく起こして起動の指示（`prompt` か既定の指示）を送る
    private func startConversation(_ agentArgs: [String], prompt: String?, resuming record: ConversationRecord?) async throws {
        busy = true
        defer { busy = false }
        var request = try await conversationRequest(agentArgs)
        if let record {
            request.resumeAgentSessionID = record.agentSessionId
        } else {
            request.prompt = prompt ?? OrchestratorInfo.startPrompt
        }
        let conversation = try await conversations.start(request, purpose: .orchestrator)
        lastFailureAt = nil
        lastError = nil
        logger.info("orchestrator conversation started", metadata: ["conversation": .string(conversation.id), "resumed": .stringConvertible(record != nil)])
    }

    /// 設定を変えたとき。常駐を切ったら、動いている会話を止める（会話の記録は残す）。入れたら待たずに試す
    public func settingsChanged(from old: MachineSettings, to new: MachineSettings) async {
        if old.orchestrator.enabled, !new.orchestrator.enabled, let record = await conversations.orchestratorRecord() {
            try? await conversations.stop(record.id, cause: .taskboard)
        }
        lastFailureAt = nil
        await tick()
    }

    // MARK: 人と agent の操作（`/v1/orchestrator/*`）

    /// 今の様子（`GET /v1/orchestrator`）
    public func info() async throws -> OrchestratorInfo {
        var info = OrchestratorInfo(enabled: try store.settings().orchestrator.enabled)
        info.lastError = lastError
        info.lastReply = lastReply
        info.conversationID = await conversations.orchestratorRecord()?.id
        return info
    }

    /// 手動で起こす（`POST /v1/orchestrator/start`）。`request` の引数を会話の項目に読み替えて起こす（止まった記録があれば戻す）
    public func start(_ request: LaunchRequest) async throws -> OrchestratorInfo {
        await waitWhileBusy()
        let record = await conversations.orchestratorRecord()
        if let record, await conversations.isLive(record.id) { throw ConversationError.orchestratorRunning }
        try await startConversation(request.agentArgs, prompt: request.prompt.isEmpty ? nil : request.prompt, resuming: record)
        await publish()
        return try await info()
    }

    /// 今の会話を破棄して新しく起こす（`POST /v1/orchestrator/restart`。人が押した操作なので、常駐を切っていても起こす）。
    /// 古い会話を親に持つ委譲先の親は新しい会話に移す
    public func restart() async throws -> OrchestratorInfo {
        await waitWhileBusy()
        busy = true
        defer { busy = false }
        let settings = try store.settings()
        var request = try await conversationRequest(settings.orchestrator.agentArgs)
        let old = await conversations.orchestratorRecord()
        if let old { try await conversations.stop(old.id, cause: .taskboard) }
        request.prompt = OrchestratorInfo.startPrompt
        let created = try await conversations.start(request, purpose: .orchestrator)
        if let old {
            await conversations.reparent(fromConversation: old.id, to: created.id)
            try await conversations.delete(old.id)
        }
        lastFailureAt = nil
        lastError = nil
        await publish()
        return try await info()
    }

    /// 指示を送る（`POST /v1/orchestrator/prompt`）。発言として送る（止まっていれば起こす。生成中なら待ち行列）
    public func prompt(_ text: String) async throws -> OrchestratorInfo {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversationError.invalid("text が要る") }
        await waitWhileBusy()
        guard let record = await conversations.orchestratorRecord() else { throw ConversationError.orchestratorMissing }
        _ = try await conversations.send(record.id, ConversationSendRequest(text: text, clientMessageID: UUID().uuidString.lowercased()))
        return try await info()
    }

    /// 会話を起こしている間は待つ（actor の中で await を挟むので、ほかの呼び出しが割り込む）。
    /// 明けたら待っていた全部を起こすので、起きたら確かめ直す（先に起きた方がまた busy にしていることがある）
    private func waitWhileBusy() async {
        while busy { await withCheckedContinuation { busyWaiters.append($0) } }
    }

    func handle(_ event: DaemonEvent) async {
        switch event {
        case .stateSnapshot, .conversationRemoved:
            await publish()
        default:
            return
        }
    }

    /// 会話のターンが終わって空いた（`ConversationService.onIdle`）。オーケストレーターの会話なら返事を拾う
    func conversationIdle(_ id: String) async {
        guard await conversations.orchestratorRecord()?.id == id, let url = await conversations.transcriptURL(id) else { return }
        await captureReply(from: url)
    }

    private func failed(_ reason: String) async {
        lastFailureAt = now()
        lastError = reason
        logger.warning("orchestrator not started", metadata: ["error": .string(reason)])
        await publish()
    }

    private func publish() async {
        guard let info = try? await info() else { return }
        await state.setOrchestrator(info)
    }

    /// 最後の user の発話より後の assistant の文を返事にする。まだ書かれていなければ読み直し、見つからなければ出さない
    private func captureReply(from url: URL) async {
        for attempt in 0..<replyAttempts {
            if attempt > 0 { try? await Task.sleep(for: replyRetryInterval) }
            guard let reply = OrchestratorReplyReader.latest(inTranscript: url), reply.id != lastReplyID else { continue }
            lastReplyID = reply.id
            lastReply = OrchestratorReply(text: String(reply.text.prefix(OrchestratorReplyReader.limit)), at: now())
            await publish()
            return
        }
    }
}

extension ConversationError {
    static let orchestratorRunning = ConversationError(status: 409, code: .orchestratorRunning, description: "オーケストレーターは既に動いている")
    static let orchestratorMissing = ConversationError(status: 409, code: .orchestratorMissing, description: "オーケストレーターの会話が無い")
}

/// transcript から、最後の user の発話（tool の結果・Claude Code の通知は除く）より後の assistant の文を取り出す
enum OrchestratorReplyReader {
    /// 返事の上限（字）
    static let limit = 2000
    /// 末尾から読む量
    static let tailBytes = 4 << 20

    struct Reply: Equatable {
        /// 最後の assistant の文の id
        var id: String
        var text: String
        /// ターンの最後の文（委譲先の知らせに載せる報告）
        var last: String
    }

    static func latest(in messages: [ChatMessage]) -> Reply? {
        let start = messages.lastIndex(where: \.isHumanPrompt).map { $0 + 1 } ?? 0
        let texts = messages[start...].filter { $0.role == .assistant && $0.kind == .text && !$0.isThinking }
        guard let last = texts.last else { return nil }
        return Reply(id: last.id, text: texts.map(\.text).joined(separator: "\n\n"), last: last.text)
    }

    static func latest(inTranscript url: URL) -> Reply? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.read(upToCount: Int(size - start))) ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[data.index(after: newline)...] }
        // 書きかけの最後の行は改行が無いので、cursor が持ち越して読まない
        var cursor = TranscriptCursor()
        return latest(in: cursor.feed(data))
    }
}
