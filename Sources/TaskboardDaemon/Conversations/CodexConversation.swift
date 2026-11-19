import Foundation
import Logging
import TaskboardKit

/// agent host で動く 1 つの codex の会話（`codex app-server` の stdio。1 つの子に 1 つの thread）。
/// host の出力を 1 行ずつ順に読み、問い・ターンを持ち、出来事を会話ごとの番号つきで配る。daemon が起き直したときは控えを読み直して、
/// 答えていない server の要求（`serverRequest/resolved` が来ていないもの）を問いに戻す。前の daemon が出した要求への応答は id の世代で見分けて捨てる。
/// thread の ID は `thread/start` の応答で決まるので、それまでの記録の会話 ID は会話の id（仮の ID）
actor CodexConversation {
    @dynamicMemberLookup
    struct Context: Sendable {
        var shared: ConversationContext

        subscript<Value>(dynamicMember keyPath: WritableKeyPath<ConversationContext, Value>) -> Value {
            get { shared[keyPath: keyPath] }
            set { shared[keyPath: keyPath] = newValue }
        }

        /// thread に足す taskboard の MCP の server（`taskboard mcp`）。nil なら足さない
        var taskboardMCP: CodexMCP?
        /// thread を戻すのが「書き手がいる」で断られたときに試し直す回数と間（端末の TUI が終わりきる前の数秒）
        var writerRetries = 5
        var writerRetryDelay: Duration = .seconds(1)
        /// コネクタの認証の戻り先のアドレスを、このマシンの上で開く
        var openCallback: CodexMachine.OpenCallback = CodexCallbackOpener.open
        /// `codex mcp logout <名前>`（確かめた版の codex。`CodexConnectors.logout`）
        var logoutConnector: CodexMachine.Logout = { _ in throw CodexMachine.LogoutError.codexUnavailable }
        /// コネクタの認証を待つ長さ
        var connectorLoginLimit: TimeInterval = 600
    }

    struct CodexMCP: Sendable, Equatable {
        var command: String
        var args: [String]
        var env: [String: String] = [:]
    }

    private struct Pending {
        var rpcID: CodexRequestID
        var request: ConversationRequest
        /// MCP の問い（url）の開く先の全文。ここにだけ持ち、［開く］の応答で渡す
        var url: URL? = nil
    }

    nonisolated let id: String
    nonisolated let inbox: AsyncStream<AgentHostNotice>.Continuation
    let inboxStream: AsyncStream<AgentHostNotice>
    var reader: Task<Void, Never>?
    private let context: Context
    var record: ConversationRecord
    private var phase: Conversation.Phase
    var child = ConversationChild.none
    /// 子を起こした（引き取った）回の番号
    var generation = 0
    /// こちらの要求の id。世代は起こすたびに変える（前の daemon・前の子の要求への応答を捨てる）
    private var ids = CodexRequestIDs(generation: 0)
    private var waiters: [CodexRequestID: CheckedContinuation<CodexRPCLine, any Error>] = [:]
    var appliedSeq = 0
    private var replayThrough = 0
    var replayWaiters: [CheckedContinuation<Void, Never>] = []
    /// 答えを待っている server の要求（問いの id → 要求の id と問い）
    private var pending: [String: Pending] = [:]
    private var pendingOrder: [String] = []
    private var answering: Set<String> = []
    /// 今の turn の id（`turn/started` から `turn/completed` まで）
    private var activeTurn: String?
    /// 送った発言の uuid → 受けた状態（`queued`・`started`・`cancelled`。記録から読んだものは `recorded`）
    var accepted: [String: String] = [:]
    /// codex の待ち行列で待っている発言（uuid → 待ち行列の 1 件）。`thread/queue/changed` と起き直しで一覧から読み直す
    private var queued: [String: CodexProtocol.QueuedSubmission] = [:]
    private var queueRefreshing = false
    private var queueRefreshAgain = false
    /// 権限のモードを替えて sandbox が変わった：次の turn に渡す（thread を戻すときは `thread/resume` の sandbox で入る）
    private var pendingSandbox: String?
    /// `thread/start`・`thread/resume` の応答の effort（Plan の settings に載せる。記録に effort が無いとき）
    private var openedEffort: String?
    /// codex が turn/start の `collaborationMode` を断った（この子の間は載せない）
    private var collaborationUnsupported = false
    /// 控えを読み直している間に見た、この daemon が答えられない server の要求（読み終えても解決していなければ断る）
    private var refuseAfterReplay: [String: CodexRequestID] = [:]
    /// 今のターンの item（ファイルの変更の承認の要求に、変えるファイルを出す）
    private var items: [String: CodexItem] = [:]
    /// 控えの読み直しの間に受けた block（読み直しの差分は流さない）
    private var replayedStream = ReplayedStream()
    var resultWaiters: [CheckedContinuation<Void, Never>] = []
    var exitWaiters: [CheckedContinuation<Void, Never>] = []
    var log: ConversationEventLog
    var deltaFlush: Task<Void, Never>?
    var lastActive: Date
    var retired = false
    var startTask: Task<Void, any Error>?
    var stats: ConversationStats?
    private var contextPercent: Int?
    var diff: ConversationDiffSummary?
    var diffScheduled = false
    /// 今の会話に効いている権限の値と、thread を開いたときに読み込んだ指示のファイル
    private var threadSettings = CodexThreadSettings()
    /// codex の置き場（`initialize` の応答の `codexHome`）
    private var codexHome: String?
    /// `/login` の流れ。URL とコードは持たない。`loginID` は終わりの知らせを照らし合わせるためだけに持ち、ログに出さない
    private var loginStage: Conversation.LoginStage?
    /// 圧縮している間の様子（`contextCompaction` の item が始まってから終わるまで）
    var compaction: ConversationCompaction?
    var turnActivity = ConversationTurnActivity()
    /// 最後の turn が中断で終わった。codex は thread が Interrupted の間（次の turn が終わるまで）待ち行列を始めない。失敗で終わった turn では止めない
    private var lastTurnInterrupted = false
    /// サブエージェントの thread → 起こした呼び出しの行の toolID（孫の thread は子の呼び出しの行。最初に名前が出た呼び出しに置き、後の sendInput・wait で動かさない）
    private var subagentTools: [String: String] = [:]
    private var publishedQueuePaused: Bool?
    private var loginID: String?
    /// コネクタの認証（`mcpServer/oauth/login`）の待ちと、終わった認証の成否（loginId → 成否。戻り先を開いた制御が受け取る）
    private var connectorLogins: CodexOAuthLogins
    private var connectorLoginResults: [String: Bool] = [:]
    private var connectorLoginWaiters: [String: [CheckedContinuation<Bool?, Never>]] = [:]
    /// 動いているコマンドの出力の末尾（item の id → 末尾）と、裏のターミナルの processId → item の id
    private var outputs: [String: CodexControls.OutputTail] = [:]
    private var terminalItems: [String: String] = [:]
    /// 終わっていないコマンドの item（id → turn の id。一覧で読み直して見つけたものは turn が分からず空）。
    /// 今のターンのもの以外が裏のターミナル。codex に裏へ回ったことの知らせは無く、自分で終わっても止めても `item/completed` が届く（実測）
    private var runningCommands: [String: String] = [:]
    /// 裏のターミナルの数が分かっているか。控えの行が落ちた・控えを読み直した後は、一覧を読み直すまで分からない
    private var backgroundKnown = true
    private var backgroundRefreshing = false
    let commands: [ConversationCommand]? = nil

    init(record: ConversationRecord, context: Context) {
        id = record.id
        self.record = record
        self.context = context
        log = ConversationEventLog(conversationID: record.id, epoch: context.epoch, logger: context.logger)
        phase = .stopped
        lastActive = context.now()
        (inboxStream, inbox) = AsyncStream<AgentHostNotice>.makeStream()
        for uuid in record.recentMessages { accepted[uuid] = Self.recorded }
        stats = record.statsValue
        connectorLogins = CodexOAuthLogins(limit: context.connectorLoginLimit)
    }

    static let recorded = "recorded"
    static let queuedState = "queued"
    /// 状態の DB が無い codex の `thread/queue/*` の断り（0.162.1）
    static let queueUnavailable = "user message queue is unavailable"
    /// `turn/steer` の断りのうち、turn が無い・替わったもの（0.162.1。data が無いので文で分ける）
    static let turnGone = ["no active turn to steer", "expected active turn id"]
    /// ほかの process が thread を開いているときの断りの文（0.162.1）
    static let activeWriter = "already has an active writer"

    /// 会話の codex の thread の ID。`thread/start` の前は nil
    private var threadID: String? { record.agentSessionId == record.id ? nil : record.agentSessionId }

    static func reservationKey(_ threadID: String) -> String { SessionReservations.key(.codex, threadID) }

    // MARK: 起こす・引き取る・止まる

    /// 子を起こし、thread を始める（thread があれば `thread/resume`）。`resume` は口を揃えるためで、thread の有無で決まる
    func start(resume: Bool, withinSoft: Bool) async throws {
        guard !child.isRunning else { return }
        guard !retired else { throw ConversationError.removed(id) }
        if let startTask { return try await startTask.value }
        let task = Task { try await self.startNow(withinSoft: withinSoft) }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    var wakesForViewer: Bool {
        !child.isRunning && !retired && startTask == nil && record.stopCause?.keepsStopped != true
    }

    private func startNow(withinSoft: Bool) async throws {
        if await adoptLeftRunning() { return }
        guard context.slots.reserve(id, withinSoft: withinSoft) else {
            throw ConversationError.limit(withinSoft ? context.slots.soft : context.slots.hard)
        }
        defer { context.slots.release(id) }
        if context.slots.overSoft {
            let makeRoom = context.makeRoom
            let id = id
            Task { await makeRoom(id) }
        }
        if let threadID, !context.reservations.reserve(Self.reservationKey(threadID), owner: id) { throw ConversationError.running(threadID) }
        do {
            try await launch()
        } catch {
            if !child.isRunning { context.reservations.release(owner: id) }
            throw error
        }
    }

    private func launch() async throws {
        let launch = try await context.launch()
        startReading()
        replayThrough = appliedSeq
        setChild(.none)
        do {
            let through = appliedSeq
            try writeRecord { $0.startProcess(through: through) }
        } catch {
            throw ConversationError.failed("会話の記録を書けない: \(error)")
        }
        do {
            _ = try await context.host.spawn(key: id, argv: [launch.executable, "app-server"], env: Self.environment(launch.environment, conversationID: id), cwd: record.cwd)
        } catch {
            updateRecord {
                $0.runner = Conversation.Runner.none.rawValue
                $0.lastExit = ConversationStopCause.startFailed.lastExit
            }
            throw ConversationError.failed("会話を起こせない: \(error)")
        }
        beginGeneration()
        setChild(.running(acceptsInput: true))
        setPhase(.starting)
        do {
            try await context.host.subscribe(key: id, after: appliedSeq)
            let initialized = try await call("initialize", CodexProtocol.Initialize(
                clientInfo: .init(name: "taskboard", title: "taskboard", version: "1"), capabilities: .init(experimentalApi: true)))
            codexHome = CodexControls.result(initialized)?["codexHome"] as? String
            try await context.host.write(key: id, CodexRPC.notification(method: "initialized"))
            try await openThread()
        } catch {
            await terminate(reason: "起こした後に失敗した: \(error)")
            throw error as? ConversationError ?? ConversationError.failed("会話を起こせない: \(error)")
        }
        if phase == .starting { setPhase(.idle) }
        refreshDiffSoon()
    }

    /// 起こしたか引き取った：世代を進める（その世代の id の要求だけを待つ）
    private func beginGeneration() {
        generation += 1
        collaborationUnsupported = false
        // 前の daemon の世代と重ならないよう、時刻から取る
        ids = CodexRequestIDs(generation: Int(context.now().timeIntervalSince1970 * 1000) % 1_000_000_000_000 + generation)
    }

    /// thread を始めるか戻す。始めたら、仮の会話 ID を thread の ID に替える
    private func openThread() async throws {
        let instructions = await guideText()
        // config は `-c` と同じ点区切りの鍵で上書きする（`mcp_servers` の表ごと渡すと、ユーザーのほかの MCP の server が消える）
        let mcp = context.taskboardMCP.map {
            ["mcp_servers.taskboard": CodexProtocol.ThreadStart.MCPServer(command: $0.command, args: $0.args, env: $0.env.merging(["TASKBOARD_CONVERSATION_ID": id]) { $1 })]
        }
        let permissions = CodexPermissions(mode: record.permissionMode)
        if let threadID {
            let params = CodexProtocol.ThreadResume(
                threadId: threadID, model: record.model, approvalPolicy: permissions.approvalPolicy, sandbox: permissions.sandbox,
                developerInstructions: instructions, config: mcp)
            var attempt = 0
            while true {
                do {
                    try applyOpened(await call("thread/resume", params))
                    refreshQueueSoon()
                    return
                } catch let error as ConversationError where error.description.contains(Self.activeWriter) && attempt < context.writerRetries {
                    attempt += 1
                    try await Task.sleep(for: context.writerRetryDelay)
                }
            }
        }
        let line = try await call(
            "thread/start",
            CodexProtocol.ThreadStart(
                cwd: record.cwd, model: record.model, approvalPolicy: permissions.approvalPolicy, sandbox: permissions.sandbox,
                developerInstructions: instructions, config: mcp))
        let thread = try line.result(CodexProtocol.ThreadOpened.self).thread.id
        guard context.reservations.reserve(Self.reservationKey(thread), owner: id) else { throw ConversationError.running(thread) }
        do {
            record = try context.store.switchConversationSession(id: id, agentSessionID: thread, discarding: id, at: context.now()) { _ in }
        } catch {
            throw ConversationError.failed("会話の記録を書けない: \(error)")
        }
        try applyOpened(line)
    }

    /// `/new`・`/clear`：子を起こし直して新しい thread を始める（1 つの子に 1 つの thread）。前の thread は会話のタスクに結んだまま残す。
    /// 記録を仮の会話 ID に戻してから起こすので、起こす途中で止まっても、次に起こすときに新しい thread を始める
    private func startNewThread() async throws {
        guard threadID != nil else { return }
        if child.isRunning {
            // 裏のターミナルは子と一緒に終わるので、動いている間は替えない
            guard isResting else { throw ConversationError.busy(id, "生成中か、質問・裏のタスクが残っている") }
            refuseInput()
            updateRecord { $0.lastExit = ConversationStopCause.suspended.lastExit }
            await finishStopping()
            guard !child.isRunning else { throw ConversationError.failed("前のプロセスが終わらない") }
        }
        do {
            record = try context.store.switchConversationSession(id: id, agentSessionID: id, at: context.now()) { _ in }
        } catch {
            throw ConversationError.failed("会話の記録を書けない: \(error)")
        }
        contextPercent = nil
        replayedStream.clear()
        flushDelta()
        log.reset(at: context.now())
        try await start(resume: false, withinSoft: false)
    }

    private func applyOpened(_ line: CodexRPCLine) throws {
        let opened = try line.result(CodexProtocol.ThreadOpened.self)
        threadSettings = CodexThreadSettings()
        openedEffort = opened.reasoningEffort
        if let result = CodexControls.result(line) { threadSettings.applyOpened(result) }
        updateStats(for: opened.thread.id) {
            $0.model = opened.model ?? $0.model
            $0.engineVersion = opened.thread.cliVersion ?? $0.engineVersion
        }
        publishState()
    }

    private func guideText() async -> String? {
        guard let task = record.taskNumber else { return nil }
        return await context.guide(task)
    }

    /// daemon が起き直したとき：host にある key を引き取り、控えを終わりまで読む（答えていない要求を問いに戻す）。読み終えるか `ConversationTiming.replay` まで返らない
    func attach(process: AgentHostProcessInfo, prewarmed: Bool) async {
        startReading()
        beginGeneration()
        setChild(process.alive ? .running(acceptsInput: true) : .none)
        replayThrough = process.lastSeq
        if process.alive, let threadID { _ = context.reservations.reserve(Self.reservationKey(threadID), owner: id) }
        if process.alive, record.runnerValue != .host {
            updateRecord {
                $0.runner = Conversation.Runner.host.rawValue
                $0.lastExit = nil
            }
        }
        setPhase(process.alive ? .idle : .stopped)
        do {
            try await context.host.subscribe(key: id, after: 0)
        } catch {
            context.logger.warning("conversation attach failed", metadata: ["conversation": .string(id), "error": "\(error)"])
            return
        }
        // 控えの頭（ターンの終わりまで切ってある）より前に始まったコマンドは見えないので、読み終えたら一覧で突き合わせる
        if process.alive { backgroundKnown = false }
        await waitForReplay(timeout: context.timing.replay)
        if process.alive {
            refreshDiffSoon()
            refreshBackgroundSoon()
            refreshQueueSoon()
        }
    }

    private var replayed: Bool { appliedSeq >= replayThrough && child != .none }
    private var replaying: Bool { appliedSeq <= replayThrough }

    private func startBlock(_ itemID: String, _ block: ConversationEvent.DeltaBlock) {
        if replaying {
            replayedStream.start(messageID: itemID, index: 0, block: block)
        } else {
            log.blockStarted(messageID: itemID, index: 0)
            emit(.blockStart(messageID: itemID, index: 0, block: block, toolName: nil))
        }
    }

    private func delta(_ itemID: String, _ block: ConversationEvent.DeltaBlock, _ text: String) {
        if replaying {
            replayedStream.append(messageID: itemID, index: 0, text: text)
        } else {
            emitDelta(messageID: itemID, block: block, text: text)
        }
    }

    private func waitForReplay(timeout: Duration) async {
        guard !replayed else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            replayWaiters.append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.releaseReplayWaiters()
            }
        }
    }

    func hostRestarted() async {
        appliedSeq = 0
        replayThrough = 0
        guard child.isRunning else { return }
        await exited(.hostRestarted)
    }

    // MARK: 送る・答える・制御

    func send(_ request: ConversationSendRequest) async throws -> ConversationSendOutcome {
        guard UUID(uuidString: request.clientMessageID) != nil else { throw ConversationError.invalid("client_message_id は UUID") }
        let uuid = request.clientMessageID.lowercased()
        if accepted[uuid] != nil { return .duplicate }
        let text = try ConversationSendText.compose(request, engine: .codex)
        var input: [CodexProtocol.UserInput] = text.isEmpty ? [] : [.text(text)]
        for attachment in request.attachments {
            guard let url = context.attachments?.file(id: attachment) else {
                throw ConversationError(status: 404, code: .attachmentMissing, description: "添付 \(attachment) が無い")
            }
            input.append(.localImage(path: url.path(percentEncoded: false)))
        }
        clearResumeWaits()
        if !child.acceptsInput {
            try await wake()
            if accepted[uuid] != nil { return .duplicate }
            guard child.acceptsInput else { throw ConversationError.stopped(id) }
        }
        lastActive = context.now()
        try await submit(input, uuid: uuid)
        return .accepted
    }

    func deliver(text: String, uuid: String, wake policy: ConversationWakePolicy) async throws -> ConversationDeliveryOutcome {
        if let state = accepted[uuid] { return state == "cancelled" ? .cancelled : .delivered }
        if !child.acceptsInput {
            switch policy {
            case .always: break
            case .unlessStoppedByPerson: guard record.stopCause?.keepsStopped != true else { return .busy }
            case .never: return .busy
            }
            try await wake()
            if accepted[uuid] != nil { return .delivered }
            guard child.acceptsInput else { throw ConversationError.stopped(id) }
        }
        guard phase == .idle else { return .busy }
        lastActive = context.now()
        do {
            try await submit([.text(text)], uuid: uuid)
        } catch let error as ConversationError where error.code == .sessionCommandFailed {
            // 応答が切れたのか断られたのか分からない。同じ uuid で状態を見直す
            context.logger.warning("conversation delivery unconfirmed", metadata: ["conversation": .string(id), "error": "\(error)"])
            return .unknown
        }
        return .delivered
    }

    func deliveryState(_ uuid: String) async -> ConversationDeliveryOutcome {
        guard let state = accepted[uuid] else { return .unknown }
        return state == "cancelled" ? .cancelled : .delivered
    }

    /// 発言を入れる。生成中なら codex の待ち行列に入れ（区切りで codex が始める）、空いていれば turn を始める。
    /// 待ち行列の無い codex では今の turn に足し（`turn/steer`）、turn が先に終わっていたら turn を始める
    private func submit(_ input: [CodexProtocol.UserInput], uuid: String) async throws {
        guard let threadID else { throw ConversationError.stopped(id) }
        if let turn = activeTurn {
            if try await enqueue(input, uuid: uuid, threadID: threadID) { return }
            switch try await steer(input, uuid: uuid, threadID: threadID, turn: turn) {
            case .steered:
                remember(uuid)
                return
            case .notSteerable(let kind):
                throw ConversationError.failed("\(kind) の turn には足せない")
            case .noTurn:
                break
            }
        }
        let permissions = CodexPermissions(mode: record.permissionMode)
        let sandbox = pendingSandbox
        func start(_ mode: CodexProtocol.CollaborationMode?) async throws -> CodexRPCLine {
            try await call(
                "turn/start",
                CodexProtocol.TurnStart(
                    threadId: threadID, clientUserMessageId: uuid, input: input, model: record.model, effort: record.effort,
                    approvalPolicy: permissions.approvalPolicy, sandboxPolicy: sandbox.map(CodexProtocol.SandboxPolicy.init(mode:)), collaborationMode: mode),
                returningFailure: true)
        }
        let mode = collaborationMode()
        var line = try await start(mode)
        if mode != nil, case .failure(_, let code, _) = line.kind {
            // 古い codex が experimental の欄を断ったとき：欄なしで送り直し、この子の間は載せない（発言を落とさない）
            line = try await start(nil)
            if case .failure = line.kind {} else {
                collaborationUnsupported = true
                context.logger.notice("codex collaborationMode unsupported", metadata: ["conversation": .string(id), "code": .stringConvertible(code)])
            }
        }
        if case .failure(_, _, let message) = line.kind { throw ConversationError.failed("turn/start を断られた: \(message)") }
        if pendingSandbox == sandbox { pendingSandbox = nil }
        remember(uuid)
    }

    /// codex の待ち行列に入れる。codex に待ち行列が無ければ false
    private func enqueue(_ input: [CodexProtocol.UserInput], uuid: String, threadID: String) async throws -> Bool {
        let line = try await call(
            "thread/queue/add", CodexProtocol.QueueAdd(threadId: threadID, input: input, clientUserMessageId: uuid), returningFailure: true)
        if case .failure(_, _, let message) = line.kind {
            if message == Self.queueUnavailable { return false }
            throw ConversationError.failed("thread/queue/add を断られた: \(message)")
        }
        markQueued(uuid, try line.result(CodexProtocol.QueueAdded.self).queuedSubmission)
        return true
    }

    private enum SteerOutcome {
        case steered
        /// turn が無い・替わった
        case noTurn
        /// 圧縮・review の turn で足せない（`compact`・`review`）
        case notSteerable(String)
    }

    /// 今の turn に足す。断られた理由のうち、turn が無い・足せない turn のほかは失敗にする
    private func steer(_ input: [CodexProtocol.UserInput], uuid: String, threadID: String, turn: String) async throws -> SteerOutcome {
        let line = try await call(
            "turn/steer", CodexProtocol.TurnSteer(threadId: threadID, clientUserMessageId: uuid, input: input, expectedTurnId: turn), returningFailure: true)
        guard case .failure(_, _, let message) = line.kind else { return .steered }
        if let refused = try? line.errorData(CodexProtocol.NotSteerable.self) { return .notSteerable(refused.codexErrorInfo.activeTurnNotSteerable.turnKind) }
        if Self.turnGone.contains(where: message.hasPrefix) { return .noTurn }
        throw ConversationError.failed("turn/steer を断られた: \(message)")
    }

    /// ［今すぐ送信］：生成中なら今の turn に足して待ち行列から消す。圧縮・review の turn なら待ち行列に残して知らせる。
    /// 空いていれば codex に待ち行列のその 1 件を始めさせる（turn/start で送ると、空いたときに codex が同じ発言を始めることがある）
    private func sendQueuedNow(_ uuid: String) async throws -> ConversationControlResponse {
        guard accepted[uuid] == Self.queuedState, let submission = queued[uuid], let threadID else { return Self.sendNowResponse(.nothingWaiting) }
        if let turn = activeTurn, let input = submission.input {
            switch try await steer(input, uuid: uuid, threadID: threadID, turn: turn) {
            case .steered:
                remember(uuid)
                do {
                    _ = try await call("thread/queue/delete", CodexProtocol.QueueItem(threadId: threadID, queuedSubmissionId: submission.id))
                } catch {
                    context.logger.warning("codex steered message left in queue", metadata: ["conversation": .string(id), "error": "\(error)"])
                }
                return Self.sendNowResponse(.delivering)
            case .notSteerable(let kind):
                emit(.notice(kind == "review" ? ConversationScreenText.steerAfterReview : ConversationScreenText.steerAfterCompaction))
                return Self.sendNowResponse(.delivering)
            case .noTurn:
                break
            }
        }
        let line = try await call(
            "thread/queue/start", CodexProtocol.QueueItem(threadId: threadID, queuedSubmissionId: submission.id), returningFailure: true)
        if case .failure(_, _, let message) = line.kind {
            // もう始まっていた・消えていた
            guard accepted[uuid] == Self.queuedState, !message.hasPrefix("queued submission not found") else { return Self.sendNowResponse(.nothingWaiting) }
            // ほかの turn が動いている：待ち行列に残り、空いたら codex が始める
            if message.hasPrefix("thread already has an active or pending turn") { return Self.sendNowResponse(.delivering) }
            throw ConversationError.failed("thread/queue/start を断られた: \(message)")
        }
        remember(uuid)
        return Self.sendNowResponse(.delivering)
    }

    private static func sendNowResponse(_ outcome: ConversationSendNow.Outcome) -> ConversationControlResponse {
        ConversationControlResponse(payloadJSON: #"{"send_now":"\#(outcome.rawValue)"}"#)
    }

    /// ［取り消す］・［編集］：待ち行列から消す。消せなかった（もう始まっていた）なら false
    private func cancelQueued(_ uuid: String) async throws -> ConversationControlResponse {
        guard accepted[uuid] == Self.queuedState, let submission = queued[uuid], let threadID else {
            return ConversationControlResponse(payloadJSON: #"{"cancelled":false}"#)
        }
        let deleted = try await call("thread/queue/delete", CodexProtocol.QueueItem(threadId: threadID, queuedSubmissionId: submission.id))
            .result(CodexProtocol.QueueDeleted.self).deleted
        guard deleted, accepted[uuid] == Self.queuedState else { return ConversationControlResponse(payloadJSON: #"{"cancelled":false}"#) }
        queued[uuid] = nil
        publishIfQueuePausedChanged()
        accepted[uuid] = "cancelled"
        emit(.accepted(clientMessageID: uuid, state: "cancelled"))
        return ConversationControlResponse(payloadJSON: #"{"cancelled":true}"#)
    }

    /// 待ち行列に入った。始まった・取り消した発言は戻さない（一覧の読み直しは始まりの知らせより古いことがある）
    private func markQueued(_ uuid: String, _ submission: CodexProtocol.QueuedSubmission) {
        let state = accepted[uuid]
        guard state == nil || state == Self.recorded || state == Self.queuedState else { return }
        queued[uuid] = submission
        publishIfQueuePausedChanged()
        guard state != Self.queuedState else { return }
        if state == nil { updateRecord { $0.remember(message: uuid) } }
        accepted[uuid] = Self.queuedState
        emit(.accepted(clientMessageID: uuid, state: Self.queuedState))
    }

    /// 待ち行列を読み直す。重ねて頼まれたら、読み終えてからもう 1 回読む
    private func refreshQueueSoon() {
        guard threadID != nil, child.acceptsInput, replayed else { return }
        guard !queueRefreshing else {
            queueRefreshAgain = true
            return
        }
        queueRefreshing = true
        let target = generation
        Task {
            repeat {
                self.queueRefreshAgain = false
                guard self.generation == target else { break }
                do {
                    try await self.refreshQueue()
                } catch {
                    self.context.logger.warning("codex queue unknown", metadata: ["conversation": .string(self.id), "error": "\(error)"])
                }
            } while self.queueRefreshAgain
            self.queueRefreshing = false
        }
    }

    /// 一覧にある発言を待っている印にする。読む前に待っていて一覧から消えたものは、codex が始めた（ほかの端末が消したものも、もう待っていない）
    private func refreshQueue() async throws {
        guard let threadID else { return }
        let known = Set(queued.keys)
        var listed: [CodexProtocol.QueuedSubmission] = []
        var cursor: String?
        for _ in 0..<Self.pageLimit {
            let page = try await call("thread/queue/list", CodexProtocol.QueueList(threadId: threadID, cursor: cursor)).result(CodexProtocol.QueuePage.self)
            listed += page.data
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        for submission in listed { markQueued(submission.clientUserMessageId.lowercased(), submission) }
        let remaining = Set(listed.map { $0.clientUserMessageId.lowercased() })
        for uuid in known.subtracting(remaining) where queued[uuid] != nil { remember(uuid) }
    }

    /// 権限のモードが plan なら Plan、ほかは default。モデルが分からなければ載せない（settings の model は必須）
    private func collaborationMode() -> CodexProtocol.CollaborationMode? {
        guard !collaborationUnsupported, let model = record.model ?? stats?.model else { return nil }
        return CodexProtocol.CollaborationMode(mode: record.permissionMode == "plan" ? "plan" : "default", model: model, effort: record.effort ?? openedEffort)
    }

    func answer(_ request: ConversationAnswerRequest) async throws {
        guard !retired else { throw ConversationError.removed(id) }
        guard let entry = pending[request.requestID], answering.insert(request.requestID).inserted else { throw ConversationError.notWaiting(request.requestID) }
        defer { answering.remove(request.requestID) }
        if let elicitation = entry.request.elicitation {
            guard let action = request.action else { throw ConversationError.invalid("action（accept・decline・cancel）が要る") }
            do {
                try elicitation.check(action, content: request.content)
            } catch {
                throw ConversationError.invalid(error.description)
            }
            lastActive = context.now()
            let result = CodexProtocol.ElicitResult(action: action.rawValue, content: action == .accept ? request.content : nil)
            try await context.host.write(key: id, try CodexRPC.reply(to: entry.rpcID, result: result))
            finishAnswer(request.requestID)
            return
        }
        if entry.request.kind == .question {
            let answers = try Self.userInputAnswers(entry.request, given: request.answers)
            lastActive = context.now()
            try await context.host.write(key: id, try CodexRPC.reply(to: entry.rpcID, result: answers))
            finishAnswer(request.requestID)
            return
        }
        let decision: ConversationDecision
        if let chosen = request.decision {
            // 選択肢の無い要求（ファイルの変更・古い codex）は許可か拒否だけ
            guard chosen != .unknown, (entry.request.decisions ?? [.accept, .decline]).contains(chosen) else {
                throw ConversationError.invalid("この確認では \(chosen.rawValue) を選べない")
            }
            decision = chosen
        } else {
            guard let allow = request.allow else { throw ConversationError.invalid("許可か拒否を選ぶ") }
            decision = allow ? .accept : .decline
        }
        lastActive = context.now()
        let data = try CodexRPC.reply(to: entry.rpcID, result: CodexProtocol.Decision(decision: decision.rawValue))
        try await context.host.write(key: id, data)
        finishAnswer(request.requestID)
    }

    private func finishAnswer(_ requestID: String) {
        removePending(requestID)
        setPhase(pending.isEmpty ? (activeTurn == nil ? .idle : .running) : .waiting)
    }

    func control(_ request: ConversationControlRequest) async throws -> ConversationControlResponse {
        guard Conversation.Engine.codex.supports(request.kind) else { throw ConversationError.controlUnsupported(request.kind.rawValue, engine: .codex) }
        switch request.kind {
        case .interrupt:
            lastActive = context.now()
            guard let threadID, let turn = activeTurn else { return ConversationControlResponse(payloadJSON: nil) }
            _ = try await call("turn/interrupt", CodexProtocol.ThreadTurn(threadId: threadID, turnId: turn))
            return ConversationControlResponse(payloadJSON: nil)
        case .setNotifyParent:
            return try setNotifyParent(request)
        case .elicitationURL:
            // 開く先の全文は要求した端末への応答にだけ載せる
            guard let requestID = request.value, let entry = pending[requestID], entry.request.kind == .elicitation else {
                throw ConversationError.notWaiting(request.value ?? "")
            }
            guard let url = entry.url.flatMap({ OAuthLinks.openable($0.absoluteString) }) else { throw ConversationError.invalid("開ける URL が無い") }
            let body = try WireJSON.encoder().encode(ElicitationURLResponse(url: url.absoluteString))
            return ConversationControlResponse(payloadJSON: String(decoding: body, as: UTF8.self))
        case .cancelQueued:
            guard let uuid = request.value.flatMap(UUID.init(uuidString:)) else { throw ConversationError.invalid("取り消す発言の uuid が無い") }
            lastActive = context.now()
            return try await cancelQueued(uuid.uuidString.lowercased())
        case .sendNow:
            guard let uuid = request.value.flatMap(UUID.init(uuidString:)) else { throw ConversationError.invalid("今すぐ送る発言の uuid が無い") }
            lastActive = context.now()
            return try await sendQueuedNow(uuid.uuidString.lowercased())
        case .setModel:
            guard let model = request.value, ConversationInput.acceptsCodexName(model) else { throw ConversationError.invalid("model が違う") }
            let response = setting { $0.model = model }
            await applySettings(model: model, effort: nil)
            return response
        case .setEffort:
            guard let effort = request.value, ConversationInput.acceptsCodexName(effort) else { throw ConversationError.invalid("effort が違う") }
            let response = setting { $0.effort = effort }
            await applySettings(model: nil, effort: effort)
            return response
        case .setPermissionMode:
            guard let mode = request.value, ConversationInput.acceptedPermissionModes.contains(mode) else { throw ConversationError.invalid("permission_mode が違う") }
            let sandbox = CodexPermissions(mode: mode).sandbox
            if sandbox != CodexPermissions(mode: record.permissionMode).sandbox { pendingSandbox = sandbox }
            return setting { $0.permissionMode = mode }
        case .rename:
            try await setCustomTitle(ConversationInput.customTitle(request.value))
            return ConversationControlResponse(payloadJSON: nil)
        case .cancelLimitResume:
            clearResumeWaits()
            return ConversationControlResponse(payloadJSON: nil)
        case .compact:
            // 圧縮は codex の turn として動き、様子は contextCompaction の item で出る
            let thread = try liveThread()
            guard activeTurn == nil else { throw ConversationError.busy(id, "生成中") }
            lastActive = context.now()
            _ = try await call("thread/compact/start", CodexProtocol.ThreadOnly(threadId: thread))
            return ConversationControlResponse(payloadJSON: nil)
        case .review:
            // レビューは codex の turn として動き、始まりと終わりは enteredReviewMode・exitedReviewMode の item で出る
            let thread = try liveThread()
            guard activeTurn == nil else { throw ConversationError.busy(id, "生成中") }
            lastActive = context.now()
            let instructions = request.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            _ = try await call(
                "review/start", CodexProtocol.ReviewStart(threadId: thread, target: instructions.isEmpty ? .uncommittedChanges : .custom(instructions)))
            return ConversationControlResponse(payloadJSON: nil)
        case .newThread:
            try await startNewThread()
            return ConversationControlResponse(payloadJSON: nil)
        case .contextUsage:
            return ConversationControlResponse(payloadJSON: contextPercent.map { #"{"percentage":\#($0)}"# })
        case .contextBreakdown:
            guard let threadID, let current = stats, current.agentSessionID == threadID, let tokens = current.contextTokens, let window = current.contextWindow
            else { throw ConversationError.failed("コンテキストの値がまだ無い") }
            // codex は内訳を返さない（使った量と窓の大きさだけ）
            let breakdown = ConversationContextBreakdown(
                agentSessionID: threadID,
                categories: [.init(name: "Messages", tokens: tokens, kind: .used), .init(name: "Free space", tokens: max(0, window - tokens), kind: .free)],
                totalTokens: tokens, maxTokens: window, autoCompactThreshold: nil)
            return ConversationControlResponse(payloadJSON: (try? WireJSON.encoder().encode(breakdown)).map { String(decoding: $0, as: UTF8.self) })
        case .exportConversation:
            return try encoded(try await export(), "thread/items/list")
        case .listBackgroundTasks:
            return try encoded(ConversationBackgroundTasks(tasks: try await backgroundTerminals()), "thread/backgroundTerminals/list")
        case .taskOutput:
            let process = try taskID(request)
            if terminalItems[process] == nil { _ = try await backgroundTerminals() }
            guard let item = terminalItems[process] else { throw ConversationError.invalid("裏のタスク \(process) が無い") }
            return try encoded((outputs[item] ?? CodexControls.OutputTail()).output, "task_output")
        case .stopTask:
            // 終わっていた（terminated が false）ときも、止まっているので成功にする
            _ = try await call(
                "thread/backgroundTerminals/terminate", CodexProtocol.TerminalTerminate(threadId: try liveThread(), processId: try taskID(request)))
            return ConversationControlResponse(payloadJSON: nil)
        case .permissionRules:
            var session = threadSettings
            // daemon が起き直した後は開いた応答を見ていないので、taskboard が渡している値で埋める
            if session.sandbox == nil {
                let permissions = CodexPermissions(mode: record.permissionMode)
                session.approvalPolicy = session.approvalPolicy ?? permissions.approvalPolicy
                session.sandbox = permissions.sandbox
            }
            let config = CodexControls.result(try await call("config/read", CodexProtocol.ConfigRead(cwd: record.cwd)))
            return try encoded(CodexControls.permissionRules(config: config, session: session, cwd: record.cwd), "config/read")
        case .hooks:
            let listing = CodexControls.result(try await call("hooks/list", CodexProtocol.Cwds(cwds: [record.cwd])))
            // 書き換えられるかは、書き込みと同じくユーザーの config.toml（user の層のファイル）で決める。読めなければ載せない
            let layer = try? await call("config/read", CodexProtocol.ConfigRead(cwd: record.cwd, includeLayers: true))
            let userConfig = layer.flatMap { CodexSettingsEdits.userLayer(CodexControls.result($0))?.file }
            return try encoded(CodexControls.hooks(listing, userConfig: userConfig), "hooks/list")
        case .mcpStatus:
            let thread = try liveThread()
            let config = CodexControls.result(try await call("config/read", CodexProtocol.ConfigRead(cwd: record.cwd, includeLayers: true)))
            // codex は呼ばれるたびに繋がらない server を試し直し、1 つでもあると 30 秒かかる（実測）。アプリの要求が切れる前（60 秒）に
            // 返すため、全部の頁で期限（timing.mcpStatus）を 1 つにし、各頁には残りの時間を渡す。過ぎたら設定だけ（有効・無効と層）で返す（実行中の状態は pending）
            var statuses: [[String: Any]] = []
            var cursor: String?
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: context.timing.mcpStatus)
            do {
                for _ in 0..<Self.pageLimit {
                    let remaining = clock.now.duration(to: deadline)
                    guard remaining > .zero else { throw ConversationError.failed("mcpServerStatus/list の期限を過ぎた") }
                    var params: [String: Any] = ["threadId": thread]
                    if let cursor { params["cursor"] = cursor }
                    let page = CodexControls.result(try await call("mcpServerStatus/list", CodexProtocol.JSONValue(value: params), timeout: remaining))
                    statuses += page?["data"] as? [[String: Any]] ?? []
                    cursor = page?["nextCursor"] as? String
                    if cursor == nil { break }
                }
            } catch let error as ConversationError where error.code != .conversationStopped {
                context.logger.warning("codex mcp status unavailable", metadata: ["conversation": .string(id)])
                statuses = []
            }
            return try encoded(CodexControls.mcpStatus(config: config, statuses: statuses), "mcp_status")
        case .mcpToggle:
            _ = try liveThread()
            guard let enabled = request.enabled else { throw ConversationError.invalid("server の名前と enabled が要る") }
            _ = try await editSettings(.mcpServer(name: try connectorName(request), enabled: enabled))
            return ConversationControlResponse(payloadJSON: nil)
        case .mcpReconnect:
            // codex は server ごとに繋ぎ直せない。全部を読み直す
            _ = try liveThread()
            _ = try connectorName(request)
            lastActive = context.now()
            _ = try await settingsRead("config/mcpServer/reload", CodexProtocol.Empty())
            return ConversationControlResponse(payloadJSON: nil)
        case .mcpAuthenticate:
            return try await authenticateConnector(try connectorName(request))
        case .mcpOAuthCallback:
            try await deliverConnectorCallback(try connectorName(request), url: request.callbackURL)
            return ConversationControlResponse(payloadJSON: nil)
        case .mcpClearAuth:
            try await clearConnectorAuth(try connectorName(request))
            return ConversationControlResponse(payloadJSON: nil)
        case .memory:
            _ = try liveThread()
            guard let sources = threadSettings.instructionSources else { throw ConversationError.failed("読み込んだ指示のファイルが分からない（会話を開き直すと分かる）") }
            return try encoded(CodexControls.memory(sources: sources, codexHome: codexHome), "memory")
        case .skills:
            return try encoded(CodexControls.skills(CodexControls.result(try await call("skills/list", CodexProtocol.Cwds(cwds: [record.cwd])))), "skills/list")
        case .setCwd:
            let thread = try liveThread()
            let directory: String
            switch CodexControls.directory(try requestedDirectory(request), home: NSHomeDirectory()) {
            case .refused(let refused): return try encoded(refused, "set_cwd")
            case .found(let resolved): directory = resolved
            }
            _ = try await call("thread/settings/update", CodexProtocol.ThreadCwd(threadId: thread, cwd: directory))
            // 次に thread を戻すとき、codex は替えた作業フォルダで戻す（実測）。記録は差分・シェル・端末で開くときに使う
            if directory != record.cwd {
                try writeRecord { $0.cwd = directory }
                publishState()
                refreshDiffSoon()
            }
            return try encoded(ConversationCwdChange(outcome: .moved, directory: directory), "set_cwd")
        case .login:
            return try await login()
        case .editSettings:
            return try encoded(try await editSettings(request.edit), "edit_settings")
        case .plugins:
            _ = try liveThread()
            return try encoded(CodexPlugins.plugins(try await pluginList(), query: request.value), "plugin/list")
        default:
            throw ConversationError.controlUnsupported(request.kind.rawValue, engine: .codex)
        }
    }

    /// 設定を書く。skill は skill の口、plugin と marketplace は plugin の口、ほかはユーザーの `config.toml`
    private func editSettings(_ edit: ConversationSettingsEdit?) async throws -> ConversationSettingsEditResult {
        _ = try liveThread()
        guard let edit else { throw ConversationError.invalid("書く設定（edit）が無い") }
        guard Conversation.Engine.codex.supports(edit: edit.target) else {
            throw ConversationError.controlUnsupported("edit_settings.\(edit.target.rawValue)", engine: .codex)
        }
        lastActive = context.now()
        switch edit {
        case .plugin, .marketplace: return try await editPlugins(edit)
        default: break
        }
        if case .skill(let name, let path, let state) = edit {
            let enabled = try CodexSettingsEdits.skillEnabled(state)
            let found = try CodexSettingsEdits.skillPath(try await settingsRead("skills/list", CodexProtocol.Cwds(cwds: [record.cwd])), name: name, path: path)
            let line = try await call("skills/config/write", CodexProtocol.SkillsConfigWrite(enabled: enabled, path: found), returningFailure: true)
            try rejectIfFailed(line, edit)
            // skills/config/write だけでは動いている thread に届かない（次に開く thread から）。中身の無い書き込みで読み直させる（実測）
            _ = try await settingsRead("config/batchWrite", CodexProtocol.ConfigBatchWrite(edits: []))
            context.logger.info("conversation settings written", metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue)])
            return ConversationSettingsEditResult()
        }
        return try await writeConfig(edit)
    }

    /// ユーザーの `config.toml` に書く。今の中身（user の層）から書き直す値を作り、版つきで書いて、読み込んである thread に読み直させる。
    /// 書いている間に人がファイルを直していたら（版の衝突）、1 回だけ読み直して作り直す
    private func writeConfig(_ edit: ConversationSettingsEdit) async throws -> ConversationSettingsEditResult {
        for attempt in 0..<2 {
            let read = try await settingsRead("config/read", CodexProtocol.ConfigRead(cwd: record.cwd, includeLayers: true))
            guard let layer = CodexSettingsEdits.userLayer(read) else { throw ConversationError.failed("ユーザーの設定の層を読めない") }
            let write = try await settingsWrite(edit, layer: layer, config: read?["config"] as? [String: Any])
            let line = try await call(
                "config/batchWrite",
                CodexProtocol.ConfigBatchWrite(edits: write.edits.map { CodexProtocol.JSONValue(value: $0) }, expectedVersion: layer.version),
                returningFailure: true)
            if case .failure = line.kind, CodexSettingsEdits.reason(line) == "conflict", attempt == 0 { continue }
            try rejectIfFailed(line, edit)
            // MCP の server は、設定を読み直しただけでは起こし直さない
            if case .mcpServer = edit { _ = try await settingsRead("config/mcpServer/reload", CodexProtocol.Empty()) }
            context.logger.info("conversation settings written", metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue)])
            return CodexSettingsEdits.result(write.effect, response: CodexControls.result(line))
        }
        throw ConversationError.settingsRejected("conflict")
    }

    /// 断られた書き込みは理由の種類で断る。codex の文は書いた値を引用しうるので、応答にもログにも出さない（JSON-RPC の code だけを残す）
    private func rejectIfFailed(_ line: CodexRPCLine, _ edit: ConversationSettingsEdit) throws {
        guard case .failure(_, let code, _) = line.kind else { return }
        let reason = CodexSettingsEdits.reason(line)
        context.logger.warning(
            "conversation settings rejected",
            metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue), "reason": .string(reason), "code": "\(code)"])
        throw ConversationError.settingsRejected(reason)
    }

    /// 設定の書き込みの途中で読む要求。断られたら codex の文を入れずに失敗にする（`call` の失敗は codex の文を含む）
    private func settingsRead(_ method: String, _ params: some Encodable) async throws -> [String: Any]? {
        let line = try await call(method, params, returningFailure: true)
        if case .failure(_, let code, _) = line.kind {
            context.logger.warning("conversation settings read failed", metadata: ["conversation": .string(id), "method": .string(method), "code": "\(code)"])
            throw ConversationError.failed("\(method) を断られた")
        }
        return CodexControls.result(line)
    }

    private func settingsWrite(_ edit: ConversationSettingsEdit, layer: CodexSettingsEdits.UserLayer, config: [String: Any]?) async throws
        -> CodexSettingsEdits.Write
    {
        func hook(_ key: String?) async throws -> CodexSettingsEdits.HookItem {
            guard let key else { throw ConversationError.invalid("hook の鍵（editKey）が無い") }
            let items = CodexSettingsEdits.hookItems(try await settingsRead("hooks/list", CodexProtocol.Cwds(cwds: [record.cwd])))
            guard let item = items.first(where: { $0.editKey == key }) else { throw ConversationError.settingsRejected("not_found") }
            return item
        }
        switch edit {
        case .permissionSetting(let key, let value):
            return try CodexSettingsEdits.permissionSetting(key: key, value: value)
        case .mcpServer(let name, let enabled):
            return try CodexSettingsEdits.mcpServer(name: name, enabled: enabled, layer: layer, config: config)
        case .hook(let op, let scope, let event, let matcher, let body, let key):
            let target = op == .add ? nil : try await hook(key)
            return try CodexSettingsEdits.hook(op: op, scope: scope, event: event, matcher: matcher, body: body, target: target, layer: layer)
        case .hookState(let key, let enabled, let trusted):
            return try CodexSettingsEdits.hookState(target: try await hook(key), enabled: enabled, trusted: trusted, layer: layer)
        case .plugin(let op, let id, _, _, _, _) where op == .enable || op == .disable:
            return CodexPlugins.enabled(id, op == .enable)
        case .permissionRule, .memory, .skill, .sandbox, .plugin, .marketplace:
            throw ConversationError.controlUnsupported("edit_settings.\(edit.target.rawValue)", engine: .codex)
        }
    }

    private func pluginList() async throws -> [String: Any]? {
        try await settingsRead("plugin/list", CodexProtocol.JSONValue(value: ["cwds": [record.cwd]]))
    }

    private func installedEntry(_ id: String) async throws -> CodexPlugins.Entry {
        guard let entry = CodexPlugins.entries(try await pluginList()).first(where: { $0.plugin.id == id }) else {
            throw ConversationError.settingsRejected("not_found")
        }
        return entry
    }

    /// plugin と marketplace を app-server で書く。codex は入れた・外した・切った plugin を、動いている thread の次の turn から使う（実測）。
    /// marketplace を外しても codex はその plugin を外さず、config と cache が残るので、先に plugin を外す
    private func editPlugins(_ edit: ConversationSettingsEdit) async throws -> ConversationSettingsEditResult {
        var wrote = false
        func send(_ method: String, _ params: [String: Any]) async throws -> [String: Any]? {
            wrote = true
            let line = try await call(method, CodexProtocol.JSONValue(value: params), timeout: .seconds(180), returningFailure: true)
            try rejectIfFailed(line, edit)
            return CodexControls.result(line)
        }
        do {
            return try await writePlugins(edit, send)
        } catch {
            // 途中まで書いたかもしれない：今の状態を読み直してから失敗を返す（巻き戻しはしない）
            if wrote, let list = try? await pluginList() {
                context.logger.warning(
                    "conversation plugins partially written",
                    metadata: [
                        "conversation": .string(id), "target": .string(edit.target.rawValue), "installed": "\(CodexPlugins.entries(list).filter(\.plugin.installed).count)",
                    ])
            }
            throw error
        }
    }

    private func writePlugins(_ edit: ConversationSettingsEdit, _ send: (String, [String: Any]) async throws -> [String: Any]?) async throws
        -> ConversationSettingsEditResult
    {
        var result = ConversationSettingsEditResult()
        switch edit {
        case .plugin(let op, let id, let scope, let acceptCommand, _, _):
            guard scope == nil || scope == .user else { throw ConversationError.invalid("codex の plugin はユーザーの設定にだけ入れる") }
            guard acceptCommand == nil else { throw ConversationError.invalid("codex の plugin にコマンドで入れるものは無い") }
            switch op {
            case .install, .update:
                // codex に plugin ごとの更新は無い。入れ直すと新しい版が cache に入る（実測）
                guard let entry = CodexPlugins.entries(try await pluginList()).first(where: { $0.plugin.id == id }) else {
                    throw ConversationError.settingsRejected("not_found")
                }
                if op == .update, !entry.plugin.installed { throw ConversationError.settingsRejected("not_found") }
                result.appsNeedingAuth = CodexPlugins.appsNeedingAuth(try await send("plugin/install", CodexPlugins.installParams(entry)))
            case .uninstall:
                let entry = try await installedEntry(id)
                guard entry.plugin.installed else { throw ConversationError.settingsRejected("not_found") }
                _ = try await send("plugin/uninstall", ["pluginId": id])
            case .purge:
                throw ConversationError.invalid("codex に plugin のデータを消す口は無い（外すとデータは残る）")
            case .enable, .disable:
                guard try await installedEntry(id).plugin.installed else { throw ConversationError.settingsRejected("not_found") }
                return try await writeConfig(edit)
            }
        case .marketplace(let op, let source, let name, let scope, _, _):
            guard scope == nil || scope == .user else { throw ConversationError.invalid("codex の marketplace はユーザーの設定にだけ足す") }
            switch op {
            case .add:
                guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else { throw ConversationError.invalid("marketplace の source が無い") }
                _ = try await send("marketplace/add", ["source": source])
            case .update:
                guard let name, !name.isEmpty else { throw ConversationError.invalid("marketplace の名前が無い") }
                let upgraded = try await send("marketplace/upgrade", ["marketplaceName": name])
                if let errors = upgraded?["errors"] as? [[String: Any]], !errors.isEmpty {
                    context.logger.warning(
                        "conversation settings rejected",
                        metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue), "reason": "other", "errors": "\(errors.count)"])
                    throw ConversationError.settingsRejected("other")
                }
            case .remove:
                guard let name, !name.isEmpty else { throw ConversationError.invalid("marketplace の名前が無い") }
                for pluginID in try CodexPlugins.installedIDsForRemoval(try await pluginList(), marketplace: name) {
                    _ = try await send("plugin/uninstall", ["pluginId": pluginID])
                }
                _ = try await send("marketplace/remove", ["marketplaceName": name])
            }
        default:
            throw ConversationError.invalid("plugin と marketplace のほかは config で書く")
        }
        context.logger.info("conversation settings written", metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue)])
        return result
    }

    private func liveThread() throws -> String {
        guard child.isRunning, let threadID else { throw ConversationError.stopped(id) }
        return threadID
    }

    /// 絶対パスか `~` で始まるパス
    private func requestedDirectory(_ request: ConversationControlRequest) throws -> String {
        guard let path = request.value?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") || path.hasPrefix("~"),
            !path.contains("\0"), path.utf8.count <= 4096
        else { throw ConversationError.invalid("フォルダは絶対パスで渡す") }
        return path
    }

    /// 写した応答を JSON にする。写せない（engine の応答の形が違う）ときは失敗
    private func encoded<Value: Encodable>(_ value: Value?, _ method: String) throws -> ConversationControlResponse {
        guard let value, let data = try? WireJSON.encoder().encode(value) else { throw ConversationError.failed("\(method) の応答を読めない") }
        return ConversationControlResponse(payloadJSON: String(decoding: data, as: UTF8.self))
    }

    /// 裏のターミナルの一覧を全部の頁で読む。processId から出力の item を引けるように控える
    private func backgroundTerminals() async throws -> [ConversationBackgroundTasks.Task] {
        let thread = try liveThread()
        var tasks: [ConversationBackgroundTasks.Task] = []
        var cursor: String?
        for _ in 0..<Self.pageLimit {
            let line = try await call("thread/backgroundTerminals/list", CodexProtocol.TerminalsList(threadId: thread, cursor: cursor))
            guard let page = CodexControls.backgroundTerminals(CodexControls.result(line)) else {
                throw ConversationError.failed("thread/backgroundTerminals/list の応答を読めない")
            }
            tasks += page.tasks
            terminalItems.merge(page.itemIDs) { _, new in new }
            guard let next = page.next else {
                reconcileBackground(listed: Set(tasks.compactMap { terminalItems[$0.id] }))
                return tasks
            }
            cursor = next
        }
        throw ConversationError.failed("裏のターミナルが多すぎて読み切れない")
    }

    /// 書き出し：thread の item を古い順に全部読んで文にする（codex に書き出しの method は無い）
    private func export() async throws -> ConversationExport {
        let thread = try liveThread()
        var items: [CodexItem] = []
        var cursor: String?
        for _ in 0..<Self.pageLimit {
            var params = CodexProtocol.ItemsList(threadId: thread, cursor: cursor, limit: 200)
            params.sortDirection = "asc"
            let page = try await call("thread/items/list", params).result(CodexProtocol.ItemsPage.self)
            items += page.data.map(\.item)
            guard let next = page.nextCursor else {
                let first = items.lazy.compactMap { item -> String? in
                    if case .userMessage(_, _, let text, _) = item, !text.isEmpty { return text }
                    return nil
                }.first
                return ConversationExport(text: CodexControls.export(items), defaultFilename: CodexControls.exportFilename(firstPrompt: first, at: context.now()))
            }
            cursor = next
        }
        throw ConversationError.failed("会話が長すぎて書き出せない")
    }

    /// 一覧に合わせる：一覧にあるのに知らなかった item を足し、一覧に無い今のターンの外の item を外す
    private func reconcileBackground(listed: Set<String>) {
        let before = (backgroundCount, backgroundKnown)
        for item in listed where runningCommands[item] == nil { runningCommands[item] = "" }
        runningCommands = runningCommands.filter { listed.contains($0.key) || $0.value == activeTurn }
        backgroundKnown = true
        if before != (backgroundCount, backgroundKnown) { publishState() }
    }

    /// 終わっていないコマンドのうち、今のターンのものでない数
    private var backgroundCount: Int { runningCommands.values.filter { $0 != activeTurn }.count }

    private func lostBackground() {
        guard backgroundKnown else { return }
        backgroundKnown = false
        publishState()
        refreshBackgroundSoon()
    }

    /// 裏のターミナルの一覧を読み直す（読み直しの途中・子が入力を受けていないときは、次の機会に回す）
    private func refreshBackgroundSoon() {
        guard !backgroundKnown, !backgroundRefreshing, replayed, child.acceptsInput, threadID != nil else { return }
        backgroundRefreshing = true
        let target = generation
        Task {
            if self.generation == target {
                do {
                    _ = try await self.backgroundTerminals()
                } catch {
                    self.context.logger.warning("codex background terminals unknown", metadata: ["conversation": .string(self.id), "error": "\(error)"])
                }
            }
            self.backgroundRefreshing = false
        }
    }

    /// 一覧の頁をたどる上限（200 件の頁で 10 万件）
    static let pageLimit = 500

    private func connectorName(_ request: ConversationControlRequest) throws -> String {
        guard let name = request.value, !name.isEmpty else { throw ConversationError.invalid("server の名前が要る") }
        return name
    }

    /// コネクタの認証を、この会話の app-server で始める（マシンの接続の app-server で認証しても、この会話の app-server は読み直すまで知らない）。
    /// 認証のページは応答にだけ載せ、応答の行は空いていれば host の控えから切る
    private func authenticateConnector(_ name: String) async throws -> ConversationControlResponse {
        _ = try liveThread()
        lastActive = context.now()
        let line = try await call("mcpServer/oauth/login", connectorLogins.params(name: name))
        if pending.isEmpty, activeTurn == nil { await trim(through: appliedSeq) }
        let page: URL
        do {
            (_, page) = try connectorLogins.start(name: name, response: line, at: context.now())
        } catch CodexOAuthLogins.Failure.outdated {
            throw ConversationError(status: 409, code: .codexOutdated, description: "codex の版が古く、認証の照らし合わせ（loginId）を返さない")
        } catch {
            throw ConversationError.failed("認証のページを開けない")
        }
        context.logger.notice("conversation connector login started", metadata: ["conversation": .string(id), "connector": .string(name)])
        let authentication = ConversationMcpAuthentication(authURL: page.absoluteString, requiresUserAction: true, callbackExpected: true)
        return try encoded(authentication, "mcp_authenticate")
    }

    /// ほかの端末で受けた戻り先のアドレスを、このマシンの上で 1 度だけ開き、codex が認証を終えるのを待つ
    private func deliverConnectorCallback(_ name: String, url raw: String?) async throws {
        _ = try liveThread()
        _ = connectorLogins.expire(at: context.now())
        guard let login = connectorLogins.waiting(name: name) else { throw ConversationError.failed("待っている認証が無い") }
        let url: URL
        do {
            url = try connectorLogins.openCallback(loginId: login.loginId, url: raw ?? "")
        } catch CodexOAuthLogins.Failure.callbackMismatch {
            throw ConversationError.invalid("認証の後に開いたページのアドレスが違う")
        } catch {
            throw ConversationError.failed("待っている認証が無い")
        }
        lastActive = context.now()
        do {
            try await context.openCallback(url)
        } catch {
            connectorLogins.callbackFailed(loginId: login.loginId)
            context.logger.notice("conversation connector callback unreachable", metadata: ["conversation": .string(id), "connector": .string(name)])
            throw ConversationError.failed("戻り先のアドレスを開けない")
        }
        if await waitForConnectorLogin(login.loginId, timeout: context.timing.control) == false {
            throw ConversationError.failed("認証できなかった")
        }
    }

    /// `codex mcp logout` で認証を解除し、この会話の app-server に読み直させる（資格情報を覚えているので）。名前は設定にあるものだけ受ける
    private func clearConnectorAuth(_ name: String) async throws {
        _ = try liveThread()
        let config = try await settingsRead("config/read", CodexProtocol.ConfigRead(cwd: record.cwd))
        guard ((config?["config"] as? [String: Any])?["mcp_servers"] as? [String: Any])?[name] != nil else {
            throw ConversationError.invalid("その名前のコネクタが無い")
        }
        lastActive = context.now()
        do {
            try await context.logoutConnector(name)
        } catch {
            context.logger.notice("conversation connector logout failed", metadata: ["conversation": .string(id), "connector": .string(name), "reason": "\(error)"])
            switch error as? CodexMachine.LogoutError {
            case .timedOut: throw ConversationError.failed("codex が認証の解除に時間内に答えなかった")
            case .refused: throw ConversationError.failed("codex が認証の解除を断った")
            default: throw ConversationError.failed("codex を起こせない")
            }
        }
        context.logger.notice("conversation connector logout done", metadata: ["conversation": .string(id), "connector": .string(name)])
        _ = try await settingsRead("config/mcpServer/reload", CodexProtocol.Empty())
    }

    /// `mcpServer/oauthLogin/completed`：待っている認証なら、成否を戻り先を開いた制御に渡す。
    /// 認証の後に動いている server が自分で繋ぎ直すかは確かめていないので、成功したら全部を読み直させてから渡す（行を読む流れの外で送る）
    private func connectorLoginCompleted(_ line: CodexRPCLine) {
        _ = connectorLogins.expire(at: context.now())
        guard let (login, success) = connectorLogins.complete(line) else { return }
        context.logger.notice(
            "conversation connector login completed",
            metadata: ["conversation": .string(id), "connector": .string(login.name), "success": .stringConvertible(success)])
        guard success else { return finishConnectorLogin(login.loginId, success: false) }
        let target = generation
        Task {
            if self.generation == target { _ = try? await self.settingsRead("config/mcpServer/reload", CodexProtocol.Empty()) }
            self.finishConnectorLogin(login.loginId, success: true)
        }
    }

    private func finishConnectorLogin(_ loginId: String, success: Bool?) {
        let waiting = connectorLoginWaiters.removeValue(forKey: loginId) ?? []
        if waiting.isEmpty, let success { connectorLoginResults[loginId] = success }
        for waiter in waiting { waiter.resume(returning: success) }
    }

    /// 認証の成否。時間内に終わらなければ nil
    private func waitForConnectorLogin(_ loginId: String, timeout: Duration) async -> Bool? {
        if let result = connectorLoginResults.removeValue(forKey: loginId) { return result }
        return await withCheckedContinuation { (waiter: CheckedContinuation<Bool?, Never>) in
            connectorLoginWaiters[loginId, default: []].append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.finishConnectorLogin(loginId, success: nil)
            }
        }
    }

    /// `/login`：device code の流れを始める。ページとコードは応答にだけ載せ、応答の行は空いていれば host の控えから切る。
    /// 前の流れが残っていれば取り消してから始める。終わりは `account/login/completed` で知る
    private func login() async throws -> ConversationControlResponse {
        _ = try liveThread()
        if let previous = loginID {
            loginID = nil
            _ = try? await call("account/login/cancel", CodexProtocol.LoginCancel(loginId: previous))
        }
        let line = try await call("account/login/start", CodexProtocol.LoginStart())
        if pending.isEmpty, activeTurn == nil { await trim(through: appliedSeq) }
        let result = CodexControls.result(line)
        guard let (login, started) = CodexControls.login(result) else {
            if let started = result?["loginId"] as? String { _ = try? await call("account/login/cancel", CodexProtocol.LoginCancel(loginId: started)) }
            throw ConversationError.failed("account/login/start の応答を読めない")
        }
        loginID = started
        loginStage = .waiting
        publishState()
        context.logger.info("conversation login started", metadata: ["conversation": .string(id)])
        return try encoded(login, "account/login/start")
    }

    /// モデル・effort・権限は記録だけを替える（次の turn の `turn/start` に入る。権限の sandbox は次に thread を戻したときに入る）
    /// 動いている thread のモデルと effort を替える。記録は書き換えてあり、turn/start は記録の値を毎回渡すので、断られても失敗にしない
    /// （codex が待ち行列から始める turn と、生成中の turn のこの後の手順にだけ効く）
    private func applySettings(model: String?, effort: String?) async {
        guard child.acceptsInput, let threadID else { return }
        do {
            let thread = try await call(
                "thread/settings/update", CodexProtocol.ThreadSettingsUpdate(threadId: threadID, model: model, effort: effort), returningFailure: true)
            if case .failure(_, let code, _) = thread.kind {
                context.logger.warning("codex thread settings not updated", metadata: ["conversation": .string(id), "code": "\(code)"])
            }
            guard let turn = activeTurn else { return }
            let current = try await call(
                "turn/settings/update", CodexProtocol.TurnSettingsUpdate(threadId: threadID, turnId: turn, model: model, effort: effort), returningFailure: true)
            // targetUnavailable（turn が終わっていた）と断り（feature が無い）は、次の turn から効く
            if case .failure(_, let code, let message) = current.kind {
                context.logger.info("codex turn settings not updated", metadata: ["conversation": .string(id), "code": "\(code)", "error": .string(message)])
            }
        } catch {
            context.logger.warning("codex settings not updated", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
    }

    private func setting(_ change: (inout ConversationRecord) -> Void) -> ConversationControlResponse {
        updateRecord(change)
        publishState()
        return ConversationControlResponse(payloadJSON: nil)
    }

    /// 動いている子に要求を 1 つ送る（履歴を読む）。子が入力を受けていなければ nil
    func request(_ method: String, _ params: some Encodable & Sendable) async throws -> CodexRPCLine? {
        guard child.acceptsInput else { return nil }
        return try await call(method, params)
    }

    func sendTitle(_ title: String) async {
        if child.isRunning, let threadID { _ = try? await call("thread/name/set", CodexProtocol.ThreadName(threadId: threadID, name: title)) }
    }

    // MARK: 止める

    func stop(_ cause: ConversationStopCause) async {
        clearResumeWaits()
        guard child.isRunning else { return }
        refuseInput()
        updateRecord { $0.lastExit = $0.lastExit ?? cause.lastExit }
        await finishStopping()
    }

    func stopIfIdle(before cutoff: Date) async -> Bool {
        guard isStoppable(before: cutoff) else { return false }
        refuseInput()
        updateRecord { $0.lastExit = ConversationStopCause.idle.lastExit }
        context.logger.info("stopped idle conversation", metadata: ["conversation": .string(id)])
        await finishStopping()
        return true
    }

    var isResting: Bool {
        child.acceptsInput && phase == .idle && answering.isEmpty && startTask == nil && pending.isEmpty && backgroundKnown
            && backgroundCount == 0
    }

    func stopIfFinished() async -> Bool {
        guard isQuiet else { return false }
        refuseInput()
        updateRecord { $0.lastExit = ConversationStopCause.finished.lastExit }
        context.logger.info("stopped finished scheduled conversation", metadata: ["conversation": .string(id)])
        await finishStopping()
        return true
    }

    /// 利用枠の上限の後の続きは、codex では待たない（codex が自分で待つかを確かめていない）。上限の待ち（`limitResumeAt`）は Claude の会話だけが書くので、
    /// codex の会話には来ない
    func continueAfterLimit() async {}

    /// codex は繋がらない間も turn を終えずに待ち、戻ると同じ turn を続ける（0.162.1 で実測）ので、印を付けず送らない
    func continueAfterNetwork(online: Bool, returned: Bool) async {}

    var noticeState: (busy: Bool, requests: [ConversationRequest]) {
        (child.isRunning && (phase == .running || phase == .starting), pendingOrder.compactMap { pending[$0]?.request })
    }

    var lastActiveAt: Date { lastActive }

    /// 生成中なら turn を止めて終わりを待ち、入力を閉じ（app-server は stdin が閉じると終わる）、終わらなければ TERM・KILL
    private func finishStopping() async {
        let target = generation
        if let threadID, let turn = activeTurn {
            _ = try? await call("turn/interrupt", CodexProtocol.ThreadTurn(threadId: threadID, turnId: turn), timeout: context.timing.stopResult)
            await waitForResult(timeout: context.timing.stopResult)
        }
        guard child.isRunning, generation == target else { return }
        try? await context.host.closeInput(key: id)
        if await waitForExit(timeout: context.timing.stopInput, generation: target) { return }
        await signalIfStill(target, "TERM")
        if await waitForExit(timeout: context.timing.stopTerm, generation: target) { return }
        await signalIfStill(target, "KILL")
        _ = await waitForExit(timeout: context.timing.stopTerm, generation: target)
    }

    // MARK: 様子と出来事

    func snapshot() -> Conversation {
        var conversation = Conversation(record: record, machine: context.machine, rewinding: false)
        conversation.runner = child.isRunning ? .host : .none
        conversation.phase = phase
        conversation.pending = pendingOrder.compactMap { pending[$0]?.request }
        conversation.backgroundTasks = backgroundCount
        conversation.backgroundTasksKnown = backgroundKnown
        conversation.contextPercent = contextPercent
        conversation.diff = diff
        conversation.stats = stats
        conversation.login = loginStage
        conversation.compaction = compaction
        conversation.queuePaused = queuePaused
        return conversation
    }

    private var queuePaused: Bool? { lastTurnInterrupted && activeTurn == nil && !queued.isEmpty ? true : nil }

    /// 待ち行列が増えた・減ったとき、止まりの印が変わる分だけ様子を出し直す
    private func publishIfQueuePausedChanged() {
        if queuePaused != publishedQueuePaused { publishState() }
    }

    var isLive: Bool { child.isRunning }
    var isIdle: Bool { child.isRunning && phase == .idle }
    var lastSeq: Int { log.lastSeq }
    var viewers: Int { log.viewers }

    // MARK: host の行を読む

    func handle(_ notice: AgentHostNotice) async {
        switch notice.event {
        case .output:
            guard let seq = notice.seq, seq > appliedSeq, let line = notice.line else { return }
            appliedSeq = seq
            await handle(line: CodexRPCLine(Data(line.utf8)), seq: seq)
        case .gap:
            if let through = notice.through { appliedSeq = max(appliedSeq, through) }
            lostBackground()
            emit(.gap)
        case .oversize:
            if let seq = notice.seq { appliedSeq = max(appliedSeq, seq) }
            context.logger.warning("conversation line too long", metadata: ["conversation": .string(id), "bytes": .stringConvertible(notice.bytes ?? 0)])
            lostBackground()
            emit(.gap)
        case .exit:
            emitReplayed(replayedStream.release())
            await exited(record.stopCause ?? .unexpected(notice.exit.map(ClaudeConversation.describe) ?? "終わった"), observed: true)
        case .shellOutput, .shellExit:
            return
        }
        if appliedSeq >= replayThrough { emitReplayed(replayedStream.release()) }
        if replayed {
            releaseReplayWaiters()
            if !refuseAfterReplay.isEmpty, child.isRunning {
                let left = refuseAfterReplay.values
                refuseAfterReplay.removeAll()
                for rid in left { await refuse(rid, "taskboard はこの要求に答えられない") }
            }
        }
    }

    private func handle(line: CodexRPCLine?, seq: Int) async {
        guard let line else {
            context.logger.warning("conversation line unreadable", metadata: ["conversation": .string(id), "seq": .stringConvertible(seq)])
            return
        }
        switch line.kind {
        case .response(let rid), .failure(let rid, _, _):
            // 前の daemon・前の子の要求への応答は待っている人がいない
            waiters.removeValue(forKey: rid)?.resume(returning: line)
        case .request(let rid, let method):
            await serverRequest(rid, method: method, line: line)
        case .notification(let method):
            await notification(method, line: line, seq: seq)
        }
    }

    private func serverRequest(_ rid: CodexRequestID, method: String, line: CodexRPCLine) async {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            guard let params = try? line.params(CodexProtocol.Approval.self), params.threadId == threadID else {
                await refuse(rid, "この thread の要求ではない")
                return
            }
            let request = Self.request(rid: rid, method: method, params: params, item: params.itemId.flatMap { items[$0] }, since: context.now())
            let fresh = hold(Pending(rpcID: rid, request: request))
            if fresh, !replaying { leaveNotice(turn: nil) }
        case "item/tool/requestUserInput":
            guard let params = try? line.params(CodexProtocol.RequestUserInput.self), params.threadId == threadID, !params.questions.isEmpty else {
                await refuse(rid, "この thread の要求ではない")
                return
            }
            let fresh = hold(Pending(rpcID: rid, request: Self.request(rid: rid, input: params, since: context.now())))
            if fresh, !replaying {
                context.logger.info("conversation user input", metadata: ["conversation": .string(id), "questions": .stringConvertible(params.questions.count)])
                leaveNotice(turn: nil)
            }
        case "mcpServer/elicitation/request":
            guard let params = try? line.params(CodexProtocol.Elicitation.self), params.threadId == threadID else {
                await refuse(rid, "この thread の要求ではない")
                return
            }
            let schema = ((try? JSONSerialization.jsonObject(with: line.data)) as? [String: Any]).flatMap { ($0["params"] as? [String: Any])?["requestedSchema"] }
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            let asked = ClaudeElicitationRequest(
                serverName: params.serverName, message: params.message, mode: params.mode ?? "form", url: params.url, elicitationID: params.elicitationId,
                schemaJSON: schema, title: nil)
            let (request, url) = ClaudeRequests.make(id: Self.requestID(rid), elicitation: asked, since: context.now())
            let fresh = hold(Pending(rpcID: rid, request: request, url: url))
            if fresh, !replaying {
                context.logger.info("conversation elicitation", metadata: ["conversation": .string(id), "server": .string(params.serverName), "mode": .string(asked.mode)])
                leaveNotice(turn: nil)
            }
        default:
            // 動的なツールなどは、この daemon では答えられない。待たせると turn が止まったままになるので断る
            guard !replaying else {
                refuseAfterReplay[Self.requestID(rid)] = rid
                return
            }
            context.logger.info("codex request refused", metadata: ["conversation": .string(id), "method": .string(method)])
            await refuse(rid, "taskboard はこの要求に答えられない")
            emit(.notice(ConversationScreenText.refusedRequest))
        }
    }

    /// 答えを待つ要求を加えて待ちにする。控えを読み直して同じ要求を見たときは false
    private func hold(_ entry: Pending) -> Bool {
        let fresh = pending[entry.request.id] == nil
        if fresh { pendingOrder.append(entry.request.id) }
        pending[entry.request.id] = entry
        setPhase(.waiting)
        publishState()
        return fresh
    }

    private func refuse(_ rid: CodexRequestID, _ message: String) async {
        guard let data = try? CodexRPC.refuse(rid, code: CodexRPC.methodNotFound, message: message) else { return }
        try? await context.host.write(key: id, data)
    }

    private func notification(_ method: String, line: CodexRPCLine, seq: Int) async {
        // 子の thread（サブエージェント）の通知は、会話の様子に混ぜない
        if let other = (try? line.params(CodexProtocol.AnyThread.self))?.threadId, other != threadID {
            subagentNotification(method, line: line, thread: other)
            return
        }
        if method == "item/started" || method == "item/completed", let item = (try? line.params(CodexProtocol.ItemNotice.self))?.item {
            learnSubagent(item, spawnedIn: nil)
        }
        switch method {
        case "thread/status/changed":
            guard let params = try? line.params(CodexProtocol.ThreadStatusChanged.self) else { return }
            switch params.status.type {
            case "active": setPhase(pending.isEmpty && (params.status.activeFlags ?? []).isEmpty ? .running : .waiting)
            case "idle": setPhase(child.isRunning ? .idle : .stopped)
            default: break
            }
        case "turn/started":
            guard let params = try? line.params(CodexProtocol.TurnNotice.self) else { return }
            activeTurn = params.turn.id
            items.removeAll()
            beginTurn(replaying: replaying)
            setPhase(pending.isEmpty ? .running : .waiting)
            publishIfQueuePausedChanged()
        case "turn/completed":
            guard let params = try? line.params(CodexProtocol.TurnNotice.self) else { return }
            await turnFinished(params.turn, seq: seq)
        case "thread/queue/changed":
            refreshQueueSoon()
        case "thread/compacted":
            // contextCompaction の item の終わりが来なかったときも、圧縮中の様子を残さない
            endCompaction()
        case "item/started":
            guard let params = try? line.params(CodexProtocol.ItemNotice.self), let itemID = params.item.id else { return }
            items[itemID] = params.item
            switch params.item {
            case .agentMessage, .plan:
                startBlock(itemID, .text)
            case .reasoning:
                startBlock(itemID, .thinking)
            case .userMessage(_, let clientID, _, _):
                if let clientID { remember(clientID.lowercased()) }
            case .other(_, let type):
                if type == CodexItems.compactionType, compaction == nil {
                    compaction = ConversationCompaction(startedAt: context.now())
                    publishState()
                }
            case .command:
                runningCommands[itemID] = params.turnId ?? ""
                let raw = ((try? JSONSerialization.jsonObject(with: line.data)) as? [String: Any]).flatMap { ($0["params"] as? [String: Any])?["item"] as? [String: Any] }
                if let process = raw?["processId"] as? String, !process.isEmpty { terminalItems[process] = itemID }
                let messages = CodexItems.messages(params.item, at: context.now())
                if !messages.isEmpty { emit(.messages(messages, apiMessageID: nil)) }
            default:
                let messages = CodexItems.messages(params.item, at: context.now())
                if !messages.isEmpty { emit(.messages(messages, apiMessageID: nil)) }
            }
        case "item/completed":
            guard let params = try? line.params(CodexProtocol.ItemNotice.self), let itemID = params.item.id else { return }
            items[itemID] = params.item
            let messages = CodexItems.messages(params.item, at: context.now())
            switch params.item {
            case .agentMessage, .plan, .reasoning:
                if replaying {
                    replayedStream.finish(messageID: itemID)
                } else {
                    emit(.blockStop(messageID: itemID, index: 0))
                    log.blockStopped(messageID: itemID, index: 0)
                }
                emit(.messages(messages, apiMessageID: itemID))
                log.messageFinished(itemID)
            case .other(_, let type):
                if type == CodexItems.compactionType { endCompaction() }
            case .command, .fileChange:
                if case .command = params.item {
                    outputs.removeValue(forKey: itemID)
                    terminalItems = terminalItems.filter { $0.value != itemID }
                    let wasBackground = runningCommands.removeValue(forKey: itemID).map { $0 != activeTurn } ?? false
                    if wasBackground { publishState() }
                }
                if !messages.isEmpty { emit(.messages(messages, apiMessageID: nil)) }
                if !replaying { refreshDiffSoon() }
            default:
                if !messages.isEmpty { emit(.messages(messages, apiMessageID: nil)) }
            }
        case "item/commandExecution/outputDelta":
            // 裏のターミナルの出力はターンの後も届く。動いている間は item の一覧に出ないので、ここで末尾を貯める
            guard let params = try? line.params(CodexProtocol.OutputDelta.self) else { return }
            outputs[params.itemId, default: CodexControls.OutputTail()].append(params.delta)
        case "thread/settings/updated":
            guard let settings = ((try? JSONSerialization.jsonObject(with: line.data)) as? [String: Any])
                .flatMap({ ($0["params"] as? [String: Any])?["threadSettings"] as? [String: Any] })
            else { return }
            threadSettings.applyUpdated(settings)
        case "mcpServer/oauthLogin/completed":
            connectorLoginCompleted(line)
        case "account/login/completed":
            guard let params = try? line.params(CodexProtocol.LoginCompleted.self), let loginID, params.loginId == loginID else { return }
            self.loginID = nil
            loginStage = params.success ? .succeeded : .failed
            if !replaying { context.logger.info("conversation login finished", metadata: ["conversation": .string(id), "success": "\(params.success)"]) }
            publishState()
        case "item/agentMessage/delta", "item/plan/delta":
            guard let params = try? line.params(CodexProtocol.Delta.self) else { return }
            delta(params.itemId, .text, params.delta)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let params = try? line.params(CodexProtocol.Delta.self) else { return }
            delta(params.itemId, .thinking, params.delta)
        case "serverRequest/resolved":
            guard let params = try? line.params(CodexProtocol.Resolved.self) else { return }
            refuseAfterReplay.removeValue(forKey: Self.requestID(params.requestId))
            removePending(Self.requestID(params.requestId))
            if child.isRunning, phase == .waiting, pending.isEmpty { setPhase(activeTurn == nil ? .idle : .running) }
        case "thread/tokenUsage/updated":
            guard let params = try? line.params(CodexProtocol.TokenUsageUpdated.self) else { return }
            let usage = params.tokenUsage
            updateStats(for: params.threadId) {
                // input は cached を含む（10-20 に実測）。cacheWrite も input の内数として扱う（実測では 0 しか見ていない）
                let cacheWrite = usage.total.cacheWriteInputTokens ?? 0
                $0.tokens = ConversationStats.Tokens(
                    input: max(0, usage.total.inputTokens - usage.total.cachedInputTokens - cacheWrite), output: usage.total.outputTokens,
                    cacheRead: usage.total.cachedInputTokens, cacheWrite: cacheWrite)
                $0.contextTokens = usage.last.totalTokens
                $0.contextWindow = usage.modelContextWindow ?? $0.contextWindow
            }
            if let window = usage.modelContextWindow, window > 0 {
                let percent = min(100, max(0, Int((Double(usage.last.totalTokens) / Double(window) * 100).rounded())))
                if percent != contextPercent {
                    contextPercent = percent
                    publishState()
                }
            }
        case "thread/name/updated":
            var reported = record
            guard let params = try? line.params(CodexProtocol.ThreadNameUpdated.self), let name = params.threadName, !name.isEmpty, reported.takeReportedTitle(name)
            else { return }
            updateRecord { $0.title = reported.title }
            publishState()
        default:
            break
        }
    }

    /// ターンの終わり：費用を取り直し、起こした側への知らせを残し、その行まで host の控えを捨てる
    private func turnFinished(_ turn: CodexProtocol.Turn, seq: Int) async {
        activeTurn = nil
        lastTurnInterrupted = turn.status == "interrupted"
        endCompaction()
        let failed = turn.status == "failed"
        if failed, record.purposeValue == .schedule, !replaying {
            try? context.store.markScheduleRunFailed(conversationID: id, reason: "実行がエラーで終わりました" + (turn.error?.message.map { "（\($0)）" } ?? ""))
        }
        if record.notifyParent, seq > record.parentNoticeSeq { leaveNotice(turn: seq) }
        if failed {
            // codex の誤りの文は英語で中身も内部の話なので画面に出さず、ログに残す
            if !replaying {
                context.logger.warning(
                    "codex turn failed", metadata: ["conversation": .string(id), "turn": .string(turn.id), "error": .string(turn.error?.message ?? "")])
            }
            emit(.messages([ChatMessage(id: "\(turn.id)#failed", role: .user, kind: .notice, text: Self.turnFailedNotice, at: context.now())], apiMessageID: nil))
        }
        emit(
            .turn(
                ConversationTurn(
                    isError: failed, stopReason: turn.status == "completed" ? nil : turn.status, durationMs: turn.durationMs, ttftMs: nil, costUSD: nil,
                    outputTokens: nil)))
        endTurn(replaying: replaying)
        log.compactTurn()
        replayedStream.clear()
        items.removeAll()
        for waiter in resultWaiters { waiter.resume() }
        resultWaiters.removeAll()
        if !replaying {
            refreshCostSoon()
            refreshDiffSoon()
        }
        if pending.isEmpty, !replaying { await trim(through: seq) }
        if child.isRunning, pending.isEmpty { setPhase(.idle) }
        publishIfQueuePausedChanged()
    }

    static let turnFailedNotice = "応答できませんでした。時間をおいて、やり直してください。"

    /// 費用は通知が無いので、ターンの後に `account/usage/read{threadId}` で取る（thread の累計）
    private func refreshCostSoon() {
        guard let threadID else { return }
        let target = generation
        Task {
            guard self.child.acceptsInput, self.generation == target,
                let response = try? await self.call("account/usage/read", CodexProtocol.ThreadOnly(threadId: threadID)),
                let usage = try? response.result(CodexProtocol.UsageRead.self), let micros = usage.threadUsage?.estimatedUsageUsdMicros
            else { return }
            self.updateStats(for: threadID) { $0.costUSD = Double(micros) / 1_000_000 }
        }
    }

    /// この会話の子と分かった thread の終わった item だけを、起こした行の下に写す（id は thread で分ける）。知らない thread は捨てる
    private func subagentNotification(_ method: String, line: CodexRPCLine, thread: String) {
        guard let parent = subagentTools[thread] else {
            context.logger.debug("codex notification of unknown thread dropped", metadata: ["conversation": .string(id), "thread": .string(thread), "method": .string(method)])
            return
        }
        guard method == "item/started" || method == "item/completed", let item = (try? line.params(CodexProtocol.ItemNotice.self))?.item else { return }
        learnSubagent(item, spawnedIn: thread)
        guard method == "item/completed" else { return }
        let messages = CodexItems.subagentMessages(item, at: context.now(), thread: thread, parentToolID: parent)
        if !messages.isEmpty { emit(.messages(messages, apiMessageID: nil)) }
    }

    /// `subAgentActivity` の started で、子の thread を起こした行に結ぶ（`spawner` は起こした thread。nil は本筋）
    private func learnSubagent(_ item: CodexItem, spawnedIn spawner: String?) {
        guard case .subagent(_, "started", let child, _) = item, child != threadID, subagentTools[child] == nil else { return }
        subagentTools[child] = CodexItems.subagentParent(child, spawnedIn: spawner)
    }

    private func exited(_ cause: ConversationStopCause, observed: Bool = false) async {
        let wasLive = child.isRunning
        setChild(observed ? .exited : .none)
        flushDelta()
        activeTurn = nil
        pending.removeAll()
        pendingOrder.removeAll()
        items.removeAll()
        outputs.removeAll()
        terminalItems.removeAll()
        runningCommands.removeAll()
        backgroundKnown = true
        threadSettings = CodexThreadSettings()
        compaction = nil
        lastTurnInterrupted = false
        subagentTools.removeAll()
        loginStage = nil
        loginID = nil
        connectorLogins.removeAll()
        connectorLoginResults.removeAll()
        for waiter in connectorLoginWaiters.values.flatMap({ $0 }) { waiter.resume(returning: nil) }
        connectorLoginWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resume(throwing: ConversationError.stopped(id)) }
        waiters.removeAll()
        for waiter in resultWaiters + exitWaiters { waiter.resume() }
        resultWaiters.removeAll()
        exitWaiters.removeAll()
        context.reservations.release(owner: id)
        updateRecord {
            $0.runner = Conversation.Runner.none.rawValue
            $0.lastExit = cause.lastExit
        }
        setPhase(.stopped)
        publishState()
        if wasLive { emit(.notice(cause.notice(engine: .codex))) }
    }

    private func terminate(reason: String) async {
        let target = generation
        updateRecord { $0.lastExit = reason }
        refuseInput()
        try? await context.host.closeInput(key: id)
        let grace = context.timing.stopTerm
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.signalIfStill(target, "TERM")
        }
    }

    // MARK: 内部

    private func wake() async throws {
        guard !retired else { throw ConversationError.removed(id) }
        if child == .running(acceptsInput: false), await !waitForExit(timeout: context.timing.stopInput + context.timing.stopTerm * 2) {
            throw ConversationError.failed("前のプロセスが終わらない")
        }
        try await start(resume: true, withinSoft: false)
    }

    /// 送った発言を受けた。最初に受けたときに記録に書く（daemon が起き直しても 2 回入れない）
    private func remember(_ uuid: String) {
        queued[uuid] = nil
        publishIfQueuePausedChanged()
        guard accepted[uuid] == nil || accepted[uuid] == Self.recorded || accepted[uuid] == Self.queuedState else { return }
        let first = accepted[uuid] == nil
        accepted[uuid] = "started"
        if first { updateRecord { $0.remember(message: uuid) } }
        emit(.accepted(clientMessageID: uuid, state: "started"))
    }

    private func removePending(_ requestID: String) {
        guard pending.removeValue(forKey: requestID) != nil else { return }
        pendingOrder.removeAll { $0 == requestID }
        publishState()
    }

    func publishState() {
        let current = snapshot()
        publishedQueuePaused = current.queuePaused
        context.publish(current)
        log.publish(current, at: context.now())
    }

    private func setPhase(_ next: Conversation.Phase) {
        guard phase != next else { return }
        phase = next
        lastActive = context.now()
        publishState()
        guard next == .idle, child.isRunning, !replaying else { return }
        let conversationID = id
        let becameIdle = context.becameIdle
        Task { await becameIdle(conversationID) }
    }

    /// 要求を送り、応答を待つ。断られたら `ConversationError.failed`
    @discardableResult
    /// `returningFailure` なら断られた行も返す（誤りの `data` を読むとき）
    private func call(_ method: String, _ params: some Encodable, timeout: Duration? = nil, returningFailure: Bool = false) async throws -> CodexRPCLine {
        guard child.isRunning else { throw ConversationError.stopped(id) }
        let rid = ids.next()
        let data = try CodexRPC.request(id: rid, method: method, params: params)
        let limit = timeout ?? context.timing.control
        let line = try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<CodexRPCLine, any Error>) in
            waiters[rid] = waiter
            Task {
                do {
                    try await self.context.host.write(key: self.id, data)
                } catch {
                    self.failCall(rid, ConversationError.failed("\(method) を送れない: \(error)"))
                }
                try? await Task.sleep(for: limit)
                self.failCall(rid, ConversationError.failed("\(method) の応答が無い"))
            }
        }
        if !returningFailure, case .failure(_, _, let message) = line.kind { throw ConversationError.failed("\(method) を断られた: \(message)") }
        return line
    }

    private func failCall(_ rid: CodexRequestID, _ error: any Error) {
        waiters.removeValue(forKey: rid)?.resume(throwing: error)
    }

    private func waitForResult(timeout: Duration) async {
        guard child.isRunning, activeTurn != nil else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            resultWaiters.append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.releaseResultWaiters()
            }
        }
    }

    // MARK: 組み立て

    /// 問いの id。server の要求の id は子ごとに 0 から振られ、子が終わると問いも消えるので、そのまま使う
    static func requestID(_ rid: CodexRequestID) -> String {
        switch rid {
        case .number(let number): "codex-\(number)"
        case .string(let string): "codex-\(string)"
        }
    }

    static func request(rid: CodexRequestID, method: String, params: CodexProtocol.Approval, item: CodexItem?, since: Date) -> ConversationRequest {
        let id = requestID(rid)
        let tool: String
        let summary: String
        var decisions: [ConversationDecision]?
        switch method {
        case "item/commandExecution/requestApproval":
            tool = CodexItems.commandTool
            summary = params.command.map(Self.unwrapShell) ?? params.reason ?? ""
            // 選択肢を出すのはコマンドの要求だけ（codex の experimental の欄。ファイルの変更の要求には無い）。この版が知らない答えは落とす
            decisions = params.availableDecisions?.compactMap(ConversationDecision.init(rawValue:)).filter { $0 != .unknown }
            if decisions?.isEmpty == true { decisions = nil }
        case "item/fileChange/requestApproval":
            tool = CodexItems.fileTool
            if case .fileChange(_, let changes, _) = item {
                summary = changes.map(\.path).joined(separator: "\n")
            } else {
                summary = params.reason ?? ""
            }
        default:
            tool = "Permissions"
            summary = params.reason ?? ""
        }
        return ConversationRequest(
            id: id, kind: .permission, toolName: tool, toolUseID: params.itemId,
            waiting: RequestWaiting(id: id, since: since, permission: .init(tool: tool, summary: summary, detail: params.reason)), decisions: decisions)
    }

    static func request(rid: CodexRequestID, input: CodexProtocol.RequestUserInput, since: Date) -> ConversationRequest {
        let id = requestID(rid)
        let questions = input.questions.map { question in
            AskQuestion(
                id: question.id, question: question.question, header: question.header.flatMap { $0.isEmpty ? nil : $0 },
                options: (question.options ?? []).map { AskOption(label: $0.label, description: $0.description.flatMap { $0.isEmpty ? nil : $0 }) },
                isSecret: question.isSecret ?? false)
        }
        return ConversationRequest(
            id: id, kind: .question, toolName: "request_user_input", toolUseID: input.itemId, waiting: RequestWaiting(id: id, since: since, questions: questions))
    }

    /// 問いへの答えを選択肢に照らして確かめ、codex の答えの形（選んだ label の後ろに自由記述）にする。答えた問いだけを載せる
    static func userInputAnswers(_ request: ConversationRequest, given: [AskAnswer]?) throws -> CodexProtocol.UserInputAnswers {
        var answers: [String: CodexProtocol.UserInputAnswers.Answer] = [:]
        for answer in given ?? [] {
            guard let question = request.waiting.questions?.first(where: { $0.id == answer.questionID }) else { continue }
            if let mismatch = question.mismatch(answer) { throw ConversationError.invalid(AskAnswerMismatch.describe(mismatch, question)) }
            guard answer.isAnswered else { continue }
            let note = answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            answers[question.id] = .init(answers: answer.selected + (note.isEmpty ? [] : [note]))
        }
        guard !answers.isEmpty else {
            throw ConversationError(status: 400, code: .askUnanswered, params: ["count": "\(request.waiting.questions?.count ?? 0)"], description: "答えが無い")
        }
        return CodexProtocol.UserInputAnswers(answers: answers)
    }

    /// `/bin/zsh -lc 'touch a.txt'` の中のコマンド（codex はコマンドをログインシェルに包んで送る）
    static func unwrapShell(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(prefix) {
            var inner = String(command.dropFirst(prefix.count))
            if inner.hasPrefix("'"), inner.hasSuffix("'"), inner.count >= 2 { inner = String(inner.dropFirst().dropLast()) }
            return inner
        }
        return command
    }

    /// 会話の codex の環境。settings の hook と MCP は、これがあれば host の会話の中として振る舞う
    static func environment(_ base: [String: String], conversationID: String) -> [String: String] {
        var env = base
        env["TASKBOARD_CONVERSATION_ID"] = conversationID
        return env
    }
}

/// taskboard の権限のモードを、codex の承認の方針と sandbox に読み替える（Claude の名前をそのまま使い、画面の欄を共有する）
struct CodexPermissions: Equatable {
    var approvalPolicy: String
    var sandbox: String

    init(mode: String?) {
        switch mode ?? ConversationInput.defaultPermissionMode {
        case "bypassPermissions", "dontAsk": (approvalPolicy, sandbox) = ("never", "danger-full-access")
        case "plan": (approvalPolicy, sandbox) = ("on-request", "read-only")
        case "manual": (approvalPolicy, sandbox) = ("untrusted", "workspace-write")
        default: (approvalPolicy, sandbox) = ("on-request", "workspace-write")
        }
    }
}

extension CodexConversation: LiveConversation, ConversationShell {
    var isAnswering: Bool { !answering.isEmpty }
    var shared: ConversationContext { context.shared }
}
