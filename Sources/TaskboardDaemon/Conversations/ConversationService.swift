import Foundation
import Logging
import TaskboardKit

/// host の会話を束ねる。agent host への 1 本の接続から出力を会話ごとに振り分け、繋がるたびに host の `list` と記録を突き合わせる。
/// 会話を起こす・送る・答える・止める入口（API と CLI）もここ
public actor ConversationService {
    struct Environment: Sendable {
        var machine: MachineID
        var store: Store
        var state: DaemonState
        var supportDirectory: URL
        var reservations: SessionReservations
        var hooks: HookService?
        var attachments: AttachmentStore?
        /// Claude Code のアカウント。あれば起こす会話の引数にアカウントの `--settings` を入れる
        var accounts: ClaudeAccounts?
        /// この daemon の port と support ディレクトリ。起こす会話の環境と codex の MCP の env に入れる
        var daemon: DaemonLocation?
        var logger = Logger(label: "uk.whatn.taskboardd.conversations")
        var shell = LoginShell.path ?? "/bin/zsh"
        var timing = ConversationTiming()
        var slots = ConversationSlots.standard()
        var home = FileManager.default.homeDirectoryForCurrentUser.path
        /// `cwd` の repo に worktree を切り、その path を返す
        var createWorktree: @Sendable (_ cwd: String, _ spec: LaunchRequest.WorktreeSpec) async throws -> String = { cwd, spec in
            try await GitWorktrees.create(cwd, spec, home: NSHomeDirectory())
        }
        var runLimits = ConversationRuns.Limits()
        /// 事前起動を捨てるまでの間
        var prewarmLifetime: Duration = .seconds(120)
        /// 動いていない codex の会話の要求（履歴とフォーク）を送る口。nil なら codex app-server を 1 本起こして送る（`CodexOneShot`）
        var codexOneShot: (@Sendable (_ method: String, _ params: any Encodable & Sendable) async throws -> CodexRPCLine)?
        var now: @Sendable () -> Date = { Date() }
        /// 外へ出る経路があり、Mac が完全に起きている（DarkWake の間はネットワークが途切れ途切れなので送らない）
        var networkOnline: @Sendable () -> Bool = { NetworkPath.isSatisfied() && SystemPower.isFullWake() }
        /// 経路が切れてから戻った回数（`NetworkPath.returns`）
        var networkReturns: @Sendable () -> Int = { NetworkPath.returns() }
        /// 音声入力の校正を回す口（確かめた版の Claude Code の起こし方を受ける）。nil なら校正しない
        var polishDictation: (@Sendable (_ launch: EngineLaunch, _ request: DictationPolishRequest) async throws -> String)?
    }

    /// `DaemonState` に載せる会話の様子の変化。会話の actor から順に積み、1 つの Task が順に載せる
    enum StateChange: Sendable {
        case upsert(Conversation)
        case remove(String)
        /// 会話（id）が使っているツールが変わった
        case tool(String, String?)
    }

    let environment: Environment
    let host: any AgentHostTransport
    /// 会話の作業フォルダのシェルと、それを開いている画面
    let shells: ConversationShells
    private let client: AgentHostClient?
    var conversations: [String: any LiveConversation] = [:]
    private var hostStartedAt: Double?
    /// `fromShell` が false なら、シェルから取れずに daemon の環境で代えた値
    var loginEnvironment: (captured: Date, values: [String: String], fromShell: Bool)?
    var loginCapture: Task<[String: String], Never>?
    /// 入力待ち（idle）に入った会話を受ける（回答の配送・起こした側への知らせ・オーケストレーターの返事・定期起動の回を止める）
    private var idleHandlers: [@Sendable (String) async -> Void] = []
    /// 起こした側への知らせが残った会話を受ける（`ConversationNotices`）
    private var noticeHandler: (@Sendable (String) async -> Void)?
    /// 記録を消している途中の会話（起こす・送る・答える・購読を断る）
    private var deleting: Set<String> = []
    /// ターンを終えたら終了する会話（`closeAfterTurn`）。
    /// shortcut: daemon が落ちると印が消え、会話は終了せず入力待ちで残る。自分を終了する会話の取りこぼしが問題になったら記録に持つ
    private var closingAfterTurn: Set<String> = []
    /// 繋がった host の会話を記録と突き合わせ終えた（`connected`）
    private var hostReconciled = false
    /// 作っている途中のシェル（同じ時の 2 回目は同じ pane を待つ）
    private var shellsInFlight: [String: Task<PaneID, Error>] = [:]
    private let runs: ConversationRuns
    /// 音声入力の校正（`Environment.polishDictation` があるときだけ）
    private let dictationPolisher: DictationPolisher?
    /// `@` の候補に引く作業ディレクトリのファイルの一覧（`workFiles`）
    private let workFileIndex = WorkFileIndex()
    /// 事前起動（1 本だけ）
    var prewarm: Prewarm?
    private let changes: AsyncStream<StateChange>.Continuation

    /// 本物の host に繋ぐ
    init(_ environment: Environment) {
        let client = AgentHostClient(
            socketPath: AgentHostServer.socketURL(supportDirectory: environment.supportDirectory).path, logger: environment.logger)
        self.init(environment, host: client, client: client)
    }

    /// テスト：host を差し替える（`run` は呼ばず、`connected`・`route` を直接呼ぶ）
    init(_ environment: Environment, host: any AgentHostTransport) {
        self.init(environment, host: host, client: nil)
    }

    private init(_ environment: Environment, host: any AgentHostTransport, client: AgentHostClient?) {
        self.environment = environment
        self.client = client
        self.host = host
        let fallback = client == nil ? nil : InProcessAgentHost(logDirectory: environment.supportDirectory.appending(path: "logs/shells"), logger: environment.logger)
        shells = ConversationShells(host: host, fallback: fallback, logger: environment.logger)
        let (stream, continuation) = AsyncStream<StateChange>.makeStream()
        changes = continuation
        let runs = ConversationRuns(
            shells: shells, directory: environment.supportDirectory.appending(path: "runs"), loginShell: environment.shell, limits: environment.runLimits,
            logger: environment.logger)
        self.runs = runs
        // 校正は会話と同じ起こし方（`launch`）で Claude Code を起こすので、作り終えた self を後から渡す
        let owner = WeakReference<ConversationService>()
        dictationPolisher = environment.polishDictation.map { polish in
            DictationPolisher { request in
                guard let service = owner.value else { throw DictationPolishError.busy }
                return try await polish(try await service.launch(), request)
            }
        }
        owner.value = self
        let state = environment.state
        Task {
            for await change in stream {
                switch change {
                // 廃止した説明役（purpose briefing）の会話は記録だけが残っているので、会話の一覧・見張り盤・タスクの会話に出さない
                case .upsert(let conversation) where conversation.purpose == .briefing: continue
                case .upsert(let conversation): await state.upsert(conversation)
                case .remove(let id): await state.removeConversation(id: id)
                case .tool(let id, let name): await state.setToolActivity(id: id, toolName: name)
                }
            }
        }
        Task { [weak self] in
            for await event in runs.events { await self?.runEvent(event) }
        }
        // Store が会話をタスクに結び直したら（StoreChange.conversation）、受け手がここへ回す
        environment.store.statePublisher(state: state).onConversation { [weak self] id in await self?.rebound(id) }
    }

    /// Store が会話をタスクに結び直した：actor の記録を読み直して配る。actor の無い（止まっている）会話は記録から配る
    private func rebound(_ id: String) async {
        if let conversation = conversations[id] { return await conversation.reloadRecord() }
        guard !deleting.contains(id), let record = try? environment.store.conversation(id: id) else { return }
        changes.yield(.upsert(Conversation(record: record, machine: environment.machine)))
    }

    private func runEvent(_ event: ConversationRuns.Event) async {
        switch event {
        case .update(let id, let update): await conversations[id]?.emitRun(update)
        case .finished(let run):
            await conversations[run.conversationID]?.refreshDiffSoon()
            await sendRunResult(run)
        }
    }

    /// 終わった Run の出力を会話に送る（生成中ならそのターンの後に）。止まった会話は起動して送る
    private func sendRunResult(_ run: ConversationRun) async {
        guard !deleting.contains(run.conversationID) else { return }
        let text = RunResultText.compose(run, timeout: runs.timeout)
        do {
            _ = try await send(run.conversationID, ConversationSendRequest(text: text, later: true))
        } catch {
            environment.logger.warning("conversation run result not sent", metadata: ["run": .string(run.id), "error": "\(error)"])
        }
    }

    /// 起動時：記録の会話を全部 `DaemonState` に載せる（actor の無い会話は止まっている）
    func publishAll() async {
        for conversation in await list() { changes.yield(.upsert(conversation)) }
    }

    func onIdle(_ handler: @escaping @Sendable (String) async -> Void) { idleHandlers.append(handler) }

    func onNotice(_ handler: @escaping @Sendable (String) async -> Void) { noticeHandler = handler }

    /// host への接続を保ち、出力を会話に振り分ける
    func run() async {
        guard let client else { return }
        // 起きた直後に開かれた会話の履歴を、ログインシェルの起動で待たせない
        if loginEnvironment == nil, loginCapture == nil { _ = startLoginCapture() }
        await environment.state.setAgentHost(AgentHostInfo(connected: false))
        await client.start()
        for await event in client.events {
            switch event {
            case .connected(let hello):
                let restarted = hostStartedAt != nil && hello.startedAt != hostStartedAt
                hostStartedAt = hello.startedAt
                await environment.state.setAgentHost(AgentHostInfo(connected: true))
                await shells.hostConnected(version: hello.protocolVersion)
                // 引き取りは控えの読み直しを待つ。その行はこの流れで振り分けるので、待つのは別の Task で
                Task { await self.connected(restarted: restarted) }
            case .disconnected:
                environment.logger.warning("agent host disconnected")
                await shells.hostDisconnected()
                await environment.state.setAgentHost(AgentHostInfo(connected: false))
            case .draining(let remaining):
                await environment.state.setAgentHost(AgentHostInfo(connected: false, draining: true, remaining: remaining))
            case .notice(let notice):
                route(notice)
            }
        }
    }

    func route(_ notice: AgentHostNotice) {
        if ConversationShells.isShell(notice.key) {
            shells.deliver(notice)
            if notice.event == .shellExit { Task { await self.shellExited(notice.key) } }
        } else if notice.key.hasPrefix(ConversationRuns.keyPrefix) {
            shells.deliver(notice)
        } else if let conversation = conversations[notice.key] {
            conversation.inbox.yield(notice)
        } else if let prewarm, prewarm.id == notice.key {
            prewarm.inbox.yield(notice)
        } else if let id = HelperProcess.rewindConversationID(fromKey: notice.key) {
            (conversations[id] as? any RewindingConversation)?.helperInbox.yield(notice)
        }
    }

    /// host に繋がった：起き直していれば会話を止まったことにし、`list` と記録を突き合わせる
    func connected(restarted: Bool) async {
        if restarted {
            for conversation in conversations.values { await conversation.hostRestarted() }
            // 事前起動も終わったものとして、枠と予約を返す（起こしている途中なら、待っている引き取りは普通の起動に回る）
            await prewarm?.helper.hostGone()
        }
        await runs.hostConnected(restarted: restarted)
        await dropLostShells()
        let processes: [AgentHostProcessInfo]
        do {
            processes = try await host.list()
        } catch {
            environment.logger.warning("agent host list failed", metadata: ["error": "\(error)"])
            return
        }
        var seen: Set<String> = []
        var attaching: [(any LiveConversation, AgentHostProcessInfo)] = []
        for process in processes {
            seen.insert(process.key)
            // 事前起動の子（記録はまだ無い）は止めず、読んだ所の続きから受け直す
            if let prewarm, prewarm.id == process.key {
                await prewarm.helper.resubscribe(alive: process.alive)
                continue
            }
            // 巻き戻しの補助のプロセスは、その会話が受け直すか止める（止め終えるまで、その会話を動かさない）
            if let id = HelperProcess.rewindConversationID(fromKey: process.key) {
                if let conversation = try? conversations[id] ?? environment.store.conversation(id: id).map(make) {
                    await (conversation as? any RewindingConversation)?.adoptHelper(process)
                } else if process.alive {
                    try? await host.signal(key: process.key, "TERM")
                }
                continue
            }
            if let conversation = conversations[process.key], await conversation.resubscribes(to: process) {
                await conversation.resubscribe()
                continue
            }
            let record = try? environment.store.conversation(id: process.key)
            // 新しい版の daemon が起こした engine の子は、止めずに残す（その版に戻したときに引き取る）
            if let record, !Self.runs(record) { continue }
            // 突き合わせの前に記録から作っただけの会話と、起こし直しを断られて止まった扱いの会話も引き取る
            guard let conversation = try? conversations[process.key] ?? record.map(make) else {
                // 記録に無い子（記録を消した会話）は止める
                if process.alive { try? await host.signal(key: process.key, "TERM") }
                continue
            }
            attaching.append((conversation, process))
        }
        // 引き取りはそれぞれ控えの読み直しを待つので、並べて待つ（1 本ずつ待つと、会話の数だけ引き取りが遅れる）
        await withTaskGroup(of: Void.self) { group in
            for (conversation, process) in attaching { group.addTask { await conversation.attach(process: process) } }
        }
        // 控えの読み直しを待つ間に起こした会話は、最初の一覧に無い。一覧を取り直して、まだ無い会話だけを止まったことにする
        let unseen = ((try? environment.store.conversations()) ?? []).filter { $0.runnerValue == .host && !seen.contains($0.id) }
        let present = unseen.isEmpty ? [] : Set(((try? await host.list()) ?? processes).map(\.key))
        for record in unseen where !present.contains(record.id) {
            _ = try? environment.store.updateConversation(id: record.id) {
                $0.runner = Conversation.Runner.none.rawValue
                $0.lastExit = $0.lastExit ?? ConversationStopCause.hostMissing.lastExit
            }
            await conversations[record.id]?.hostRestarted()
        }
        hostReconciled = true
        // 引き取った会話が空いていれば、daemon が止まっている間に届いた回答を入れる
        for (id, conversation) in conversations where await conversation.isIdle { await becameIdle(id) }
    }

    // MARK: 入口

    /// 会話を起こす。`resumeAgentSessionID` があれば、その会話 ID を持つ会話（無ければ TUI の会話を取り込んだ新しい記録）を `--resume` で戻す。
    /// daemon の中で起こす会話（オーケストレーター・定期起動）は `purpose` を、定期起動は回から決めた会話の `id` と最初の発言の uuid を渡す
    /// （同じ回の 2 つ目は会話の表の主キーが断る）
    /// `reservedBy` は、戻す Claude の会話 ID の予約を先に取って渡す持ち主（TUI のオーケストレーターを移す間、ほかの起動に取らせない）
    func start(
        _ request: ConversationStartRequest, purpose: Conversation.Purpose? = nil, id fixedID: String? = nil, firstMessageID: String? = nil,
        reservedBy: String? = nil
    ) async throws -> Conversation {
        var request = request
        // cwd を省いたらホーム。定期起動の cwd は `~` で書いてある
        request.cwd = request.cwd.isEmpty ? environment.home : (request.cwd as NSString).expandingTildeInPath
        request = try validated(request)
        let extraArgs = request.extraArgs ?? []
        guard ConversationArguments.acceptsExtra(extraArgs) else { throw ConversationError.invalid("extra_args に会話へ渡せない引数がある") }
        let parent = try resolveParent(request.parent)
        if request.notifyParent == true, parent == nil { throw ConversationError.invalid("知らせる先（parent）が無い") }
        let title = request.title.flatMap(ConversationInput.title)
        if let title, !ConversationInput.acceptsTitle(title) { throw ConversationError.invalidTitle }
        if request.worktree != nil, request.resumeAgentSessionID != nil { throw ConversationError.invalid("戻す会話には worktree を切れない") }
        if let branch = request.worktree?.branch, branch.trimmingCharacters(in: .whitespaces).isEmpty { throw ConversationError.invalid("worktree の branch が空") }
        let newID = fixedID ?? UUID().uuidString.lowercased()
        if let spec = request.worktree {
            do {
                request.cwd = try await environment.createWorktree(request.cwd, spec)
            } catch let error as ConversationError {
                throw error
            } catch {
                throw ConversationError.failed("worktree を作れない: \(error)")
            }
        }
        let engine: Conversation.Engine = request.engine == .codex ? .codex : .claude
        // 新しい会話のアカウントは事前起動を引き取るかを決める前に決める（事前起動はマシンのログインで起きている）
        var accountArgs: [String]?
        if engine == .claude, request.resumeAgentSessionID == nil {
            accountArgs = try await accountArguments(extraArgs, requested: request.account, task: request.taskNumber, resuming: false)
        }
        let record: ConversationRecord
        let resume: Bool
        if let sessionID = request.resumeAgentSessionID {
            if let existing = try environment.store.conversation(agentSessionID: sessionID) {
                guard existing.engineValue == engine else { throw ConversationError.invalid("会話 ID \(sessionID) はほかの engine の会話") }
                record = existing
            } else {
                // TUI の会話を取り込む。ほかのタスクに結んだ行は外れる
                let linked = try environment.store.task(linkedToSession: sessionID)?.number
                record = try environment.store.createConversation(
                    ConversationRecord(
                        id: newID, taskNumber: request.taskNumber ?? linked, engine: engine, agentSessionId: sessionID, cwd: request.cwd,
                        model: request.model, effort: request.effort, permissionMode: request.permissionMode, runner: .none))
            }
            resume = true
        } else if engine == .claude, (accountArgs ?? extraArgs).isEmpty, request.worktree == nil, purpose == nil, fixedID == nil,
            let adopted = try await adoptPrewarm(request)
        {
            record = adopted
            resume = false
        } else {
            // codex の thread の ID は起こしてから決まる。それまでは会話の id を仮の会話 ID にする（`CodexConversation`）
            record = try environment.store.createConversation(
                ConversationRecord(
                    id: newID, taskNumber: request.taskNumber, engine: engine, agentSessionId: engine == .codex ? newID : UUID().uuidString.lowercased(),
                    cwd: request.cwd, model: request.model, effort: request.effort, permissionMode: request.permissionMode, runner: .none))
            resume = false
        }
        // 戻す会話は、前のアカウント（記録の引数）から決める
        if engine == .claude, resume {
            accountArgs = try await accountArguments(request.extraArgs ?? record.extraArguments, requested: request.account, task: record.taskNumber, resuming: true)
        }
        // 題の無いタスクの会話は端末のセッションと同じ「#番号 題」で出す（Claude Code の側の題は UserPromptSubmit の hook が付ける）
        var taskTitle: String?
        if title == nil, record.title == nil, let number = record.taskNumber, let task = await environment.state.task(number: number) {
            taskTitle = SessionGuidance.title(task: task)
        }
        // 引数・役目・起こした側は起こす前に書く（起こす引数に入る。事前起動を引き取った会話は引数を足していない）
        let written = try environment.store.updateConversation(id: record.id) {
            if let accountArgs {
                $0.extraArguments = accountArgs
            } else if request.extraArgs != nil {
                $0.extraArguments = extraArgs
            }
            if let purpose { $0.purpose = purpose.rawValue }
            if let parent { $0.parentConversationId = parent }
            if let notify = request.notifyParent { $0.notifyParent = notify }
            if let title = title ?? taskTitle { $0.title = title }
        }
        guard !deleting.contains(written.id) else { throw ConversationError.removed(written.id) }
        let conversation = try conversations[written.id] ?? make(written)
        await conversation.reloadRecord()
        if let reservedBy, !environment.reservations.transfer(Self.reservationKey(written), from: reservedBy, to: written.id) {
            throw ConversationError.running(written.agentSessionId)
        }
        do {
            try await conversation.start(resume: resume)
        } catch {
            environment.logger.warning(
                "conversation start failed", metadata: ["conversation": .string(written.id), "resume": .stringConvertible(resume), "error": "\(error)"])
            // 起こせなかった新しい会話の記録は残さない（transcript が無く、開き直す道も無い）。worktree は残す
            if !resume { try? await delete(written.id) }
            throw error
        }
        if let title { try? await conversation.rename(title) }
        if let prompt = request.prompt, !prompt.isEmpty {
            let text = await environment.state.renderedPrompt(prompt, task: written.taskNumber)
            _ = try await conversation.send(ConversationSendRequest(text: text, clientMessageID: firstMessageID ?? UUID().uuidString.lowercased()))
        }
        return await conversation.snapshot()
    }

    /// 起こした側の会話が在ること（呼んだ Claude の会話 ID があれば、その会話のものか）を確かめる
    private func resolveParent(_ parent: ConversationParent?) throws -> String? {
        guard let parent else { return nil }
        guard let id = parent.conversationID else { return nil }
        guard try environment.store.conversation(id: id) != nil else { throw ConversationError.invalid("parent の会話 \(id) が無い") }
        if let session = parent.agentSessionID, try !environment.store.conversation(id, owns: session) {
            throw ConversationError.invalid("parent の会話 \(id) は Claude の会話 \(session) を持たない")
        }
        return id
    }

    /// `messageID` の発言まで（省けば今の末尾まで）を写した新しい会話を、同じタスク・フォルダ・設定で作って起こす。
    /// 同じ `requestID` の 2 回目は、作った会話を返す（応答を受け取れずに送り直したとき）
    func fork(_ id: String, _ request: ConversationForkRequest) async throws -> Conversation {
        guard !request.requestID.isEmpty, request.requestID.utf8.count <= 128 else { throw ConversationError.invalid("requestID が無いか長すぎる") }
        if let prompt = request.prompt, prompt.utf8.count > ConversationInput.textBytes { throw ConversationError.invalid("文は 1MB まで") }
        guard !deleting.contains(id), let source = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        let engine = source.engineValue
        guard engine.supports(.fork) else {
            guard let kind = engine.agentKind else { throw ConversationError.unsupportedEngine(id, source.engine) }
            throw ConversationError.controlUnsupported("fork", engine: kind)
        }
        if engine == .codex { return try await forkCodex(source, request) }
        let lineage = await lineage(source)
        var generating = false
        if let running = conversations[id], await running.isLive { generating = await !running.isIdle }
        // ここから記録を作るまで await しない（同じ requestID の 2 回目が間に入らない）
        if let made = try environment.store.conversation(forkRequestID: request.requestID) { return try await get(made.id) }
        let point = try ConversationFork.point(in: lineage, messageID: request.messageID, generating: generating)
        let record = try environment.store.createConversation(
            ConversationRecord(
                taskNumber: source.taskNumber, agentSessionId: UUID().uuidString.lowercased(), cwd: source.cwd, model: source.model,
                effort: source.effort, permissionMode: source.permissionMode, title: source.title, customTitle: source.customTitle, runner: .none
            ).forked(from: source.id, request: request.requestID, point: point))
        environment.logger.info(
            "conversation forked", metadata: ["conversation": .string(record.id), "source": .string(id), "at": .string(point.uuid)])
        let conversation = try make(record)
        do {
            try await conversation.start(resume: false)
        } catch {
            try? await delete(record.id)
            throw error
        }
        if let prompt = request.prompt, !prompt.isEmpty {
            _ = try await conversation.send(ConversationSendRequest(text: prompt, clientMessageID: UUID().uuidString.lowercased()))
        }
        return await conversation.snapshot()
    }

    /// `messageID` の発言の前まで巻き戻す（`files` ならファイルも）。`dryRun` は何が変わるかだけ
    func rewind(_ id: String, _ request: ConversationRewindRequest) async throws -> ConversationRewindResponse {
        guard !request.messageID.isEmpty, request.messageID.utf8.count <= 256 else { throw ConversationError.invalid("messageID が無いか長すぎる") }
        let conversation = try await rewinding(id)
        return try await conversation.rewind(request, projects: await transcriptProjects())
    }

    func undoRewind(_ id: String, _ request: ConversationSessionGuard) async throws -> Conversation {
        try await rewinding(id).undoRewind(expected: request.expectedAgentSessionID)
    }

    func redoRewind(_ id: String, _ request: ConversationSessionGuard) async throws -> Conversation {
        try await rewinding(id).redoRewind(expected: request.expectedAgentSessionID)
    }

    /// 巻き戻せる会話。engine が巻き戻しを持たなければ断る
    private func rewinding(_ id: String) async throws -> any RewindingConversation {
        let conversation = try find(id)
        guard let rewinding = conversation as? any RewindingConversation else {
            throw ConversationError.controlUnsupported(
                "rewind", engine: await conversation.record.engineValue.agentKind ?? .codex)
        }
        return rewinding
    }

    /// 止まった会話を `--resume` で起こし直す
    func resume(_ id: String) async throws -> Conversation {
        let conversation = try find(id)
        guard await !conversation.isLive else { return await conversation.snapshot() }
        try await conversation.start(resume: true)
        return await conversation.snapshot()
    }

    /// `GET /v1/conversations`。廃止した説明役の会話は出さない
    func list() async -> [Conversation] {
        var result: [Conversation] = []
        for record in (try? environment.store.conversations()) ?? [] where record.purposeValue != .briefing {
            if let live = conversations[record.id] {
                result.append(await live.snapshot())
            } else {
                result.append(Conversation(record: record, machine: environment.machine))
            }
        }
        return result
    }

    func get(_ id: String) async throws -> Conversation {
        if let live = conversations[id] { return await live.snapshot() }
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        return Conversation(record: record, machine: environment.machine)
    }

    func send(_ id: String, _ request: ConversationSendRequest) async throws -> ConversationSendOutcome {
        guard request.text.utf8.count <= ConversationInput.textBytes else { throw ConversationError.invalid("文は 1MB まで") }
        return try await find(id).send(request)
    }

    func answer(_ id: String, _ request: ConversationAnswerRequest) async throws {
        try await find(id).answer(request)
    }

    /// 会話の今の engine の会話の履歴を新しい順に読む（Claude は transcript の `ConversationHistory`、codex は `thread/items/list`）
    func history(_ id: String, before cursor: String?, limit: Int, subagents: Bool = false) async throws -> ConversationHistoryResponse {
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        if record.engineValue == .codex { return try await codexHistory(record, before: cursor, limit: limit, subagents: subagents) }
        return try ConversationHistory.read(lineage: await lineage(record), before: cursor, limit: limit, subagents: subagents)
    }

    /// 発言のファイルの札の中身（`GET /v1/conversations/{id}/files/{tool_id}`）。履歴と同じ transcript の並び（`TranscriptLineage`）を順に探す。codex の会話の札は diff を札に載せていて、中身の口は無い
    func file(_ id: String, toolID: String, at offset: UInt64?, path: String?, part: ChatFile.Part) async throws -> TranscriptFiles.Body {
        try await fromTranscript(id, missing: "\(toolID) の中身が会話の記録に無い") { TranscriptFiles.content(in: $0, toolID: toolID, at: offset, path: path, part: part) }
    }

    /// 人の発言に添えた画像（`GET /v1/conversations/{id}/images/{line_id}/{index}`）。読む transcript は `file` と同じ。
    /// codex の会話の画像は transcript に無く、口は無い
    func image(_ id: String, lineID: String, index: Int, at offset: UInt64?) async throws -> TranscriptFiles.Body {
        try await fromTranscript(id, missing: "\(lineID) の画像 \(index) が会話の記録に無い") { TranscriptFiles.userImage(in: $0, uuid: lineID, index: index, at: offset) }
    }

    private func fromTranscript(_ id: String, missing: String, read: (URL) -> TranscriptFiles.Body?) async throws -> TranscriptFiles.Body {
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        let notFound = ConversationError(status: 404, code: .notFound, params: ["kind": DaemonErrorCode.Kind.file.rawValue], description: missing)
        guard record.engineValue == .claude else { throw notFound }
        for segment in await lineage(record).segments {
            if let body = read(segment.url) { return body }
        }
        throw notFound
    }

    /// 全文検索の索引に読む transcript の並び（履歴と同じ）
    func transcriptSegments(_ record: ConversationRecord) async -> [TranscriptLineage.Segment] {
        await lineage(record).segments
    }

    /// 会話の履歴を読む transcript の並び（記録した写し元をたどる）
    private func lineage(_ record: ConversationRecord) async -> TranscriptLineage {
        let store = environment.store
        return TranscriptLineage(record: record, projects: await transcriptProjects()) { (try? store.transcriptSource(of: $0)) ?? nil }
    }

    /// transcript の置き場（CLI に渡す環境の `CLAUDE_CONFIG_DIR`。無ければ `~/.claude`）。daemon は起動時に TUI の分もこれで決める
    func transcriptProjects() async -> URL {
        ClaudeConfigDirectory.projects(environment: await loginShellEnvironment())
    }

    func control(_ id: String, _ request: ConversationControlRequest) async throws -> ConversationControlResponse {
        try await find(id).control(request)
    }

    /// `/` で使えるコマンド。プロセスから受けた一覧が無ければ（daemon が起き直した後の止まった会話）、`.claude` の skill と command だけ
    func commands(_ id: String) async throws -> ConversationCommandsResponse {
        let conversation = try find(id)
        if let commands = await conversation.commands { return ConversationCommandsResponse(commands: commands, source: .session) }
        // .claude の skill と command は Claude Code のもの
        guard await conversation.record.engineValue == .claude else { return ConversationCommandsResponse(commands: [], source: .catalog) }
        let catalog = SlashCommandCatalog.list(cwd: await conversation.record.cwd, home: environment.home, builtins: [])
        return ConversationCommandsResponse(commands: catalog.map { ConversationCommand(name: $0.name, description: $0.description) }, source: .catalog)
    }

    /// 会話の作業フォルダの差分。すべての変更の要約は会話の状態にも載せる
    func diff(_ id: String, scope: ConversationDiffScope = .all) async throws -> ConversationDiffResponse {
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        let response: ConversationDiffResponse
        do {
            response = ConversationDiff.response(try await ConversationDiff.read(cwd: record.cwd, scope: scope), scope: scope)
        } catch {
            throw ConversationError.failed("差分を取れない: \(error)")
        }
        if scope == .all { await conversations[id]?.setDiff(response.summary) }
        return response
    }

    /// 会話の作業ディレクトリのファイルから、`query` に合うものを `limit` 件まで（入力欄の `@` の候補）
    func workFiles(_ id: String, query: String, limit: Int) async throws -> ConversationWorkFilesResponse {
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        let result = await workFileIndex.search(cwd: record.cwd, query: query, limit: limit)
        return ConversationWorkFilesResponse(files: result.files, truncated: result.truncated)
    }

    /// 1 ファイルの diff。`path` は `scope` の今の差分に出た path だけを受ける
    func fileDiff(_ id: String, path: String, scope: ConversationDiffScope = .all) async throws -> ConversationFileDiffResponse {
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        do {
            return try await ConversationDiff.file(cwd: record.cwd, path: path, scope: scope)
        } catch let failure as ConversationDiff.Failure {
            throw ConversationError.invalid(failure.description)
        } catch {
            throw ConversationError.failed("差分を取れない: \(error)")
        }
    }

    /// 会話の作業フォルダのシェル（agent host の擬似端末）。前に開いたシェルが生きていればそれを返す
    func shell(_ id: String) async throws -> PaneID {
        if let running = shellsInFlight[id] { return try await running.value }
        guard !deleting.contains(id), let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        let key = ConversationShells.key(conversation: id)
        let shellPath = environment.shell
        // 記録は Task の中で書く。待っている `stopShell` が再開するより前に書き終え、止めた後に書き戻さない
        let task = Task<PaneID, Error> {
            if let old = record.shellId, old != key { await self.closeShell(PaneID(rawValue: old)) }
            var env = await self.loginShellEnvironment(forLaunch: true)
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            do {
                try await self.shells.open(key: key, argv: [shellPath, "-l"], env: env, cwd: record.cwd)
            } catch {
                throw ConversationError.failed("シェルを開けない: \(error)")
            }
            let pane = PaneID(rawValue: key)
            if record.shellId != key { try await self.recordShell(pane, of: id) }
            return pane
        }
        shellsInFlight[id] = task
        defer { shellsInFlight[id] = nil }
        return try await task.value
    }

    /// シェルが終わった（exit した、host が閉じた）：会話の記録から外す
    private func shellExited(_ key: String) {
        let id = String(key.dropFirst(ConversationShells.keyPrefix.count))
        guard let record = try? environment.store.conversation(id: id), record.shellId == key else { return }
        _ = try? environment.store.updateConversation(id: id, at: record.updatedAt) { $0.shellId = nil }
    }

    /// 起き直した host は前のシェルを持たず、終わりも知らせない。host に無いシェルを記録から外す
    private func dropLostShells() async {
        let live: Set<String>
        do {
            guard let keys = try await shells.liveKeys() else { return }
            live = keys
        } catch {
            environment.logger.warning("agent host shell list failed", metadata: ["error": "\(error)"])
            return
        }
        for record in (try? environment.store.conversations()) ?? [] {
            guard let pane = record.shellId, ConversationShells.isShell(pane), !live.contains(pane) else { continue }
            shellExited(pane)
        }
    }

    private func recordShell(_ pane: PaneID, of id: String) async throws {
        // 作っている間に会話を消した：シェルも閉じる
        guard !deleting.contains(id), (try? environment.store.updateConversation(id: id) { $0.shellId = pane.rawValue }) != nil else {
            await closeShell(pane)
            throw ConversationError.removed(id)
        }
        environment.logger.info("conversation shell opened", metadata: ["conversation": .string(id), "pane": .string(pane.rawValue)])
    }

    /// 会話のシェルの tab を閉じて記録から外す（アプリが端末の欄を閉じたとき）。作っている途中なら、できたシェルを閉じる。シェルが無ければ何もしない
    func stopShell(_ id: String) async throws {
        // 作っている途中の `shell` が記録に書くのは、この await の後になることがある。記録でなく、できた pane を閉じる
        let opening = try? await shellsInFlight[id]?.value
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        if record.shellId != nil {
            // 会話の並び（最近の順）を動かさない
            _ = try environment.store.updateConversation(id: id, at: record.updatedAt) { $0.shellId = nil }
        }
        for pane in Set([opening?.rawValue, record.shellId].compactMap(\.self)) {
            await closeShell(PaneID(rawValue: pane))
        }
        environment.logger.info("conversation shell stopped", metadata: ["conversation": .string(id)])
    }

    // MARK: コードブロックの Run

    func startRun(_ id: String, _ request: ConversationRunRequest) async throws -> ConversationRun {
        guard !deleting.contains(id), let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        let environment = await loginShellEnvironment(forLaunch: true)
        // 出来事を流す先（購読している画面が無ければ作るだけ）
        _ = try find(id)
        return try await runs.start(conversationID: id, cwd: record.cwd, environment: environment, request)
    }

    func run(_ id: String, _ runID: String) async throws -> ConversationRun {
        guard let run = await runs.get(conversationID: id, runID) else { throw Self.runNotFound(runID) }
        return run
    }

    func cancelRun(_ id: String, _ runID: String) async throws {
        guard await runs.cancel(conversationID: id, runID) else { throw Self.runNotFound(runID) }
    }

    /// Run のシェルを全部閉じる（次の Run は新しいシェルで動く）
    func resetRuns(_ id: String) async throws {
        guard !deleting.contains(id), try environment.store.conversation(id: id) != nil else { throw Self.notFound(id) }
        await runs.reset(conversationID: id)
    }

    /// daemon が普通に終わる：動いている Run を止める
    func shutdown() async {
        await runs.shutdown()
    }

    static func runNotFound(_ id: String) -> ConversationError {
        ConversationError(status: 404, code: .notFound, params: ["kind": DaemonErrorCode.Kind.run.rawValue], description: "Run \(id) が無い")
    }

    // MARK: 止める・終了・消す

    /// 前の版の herdr の pane のシェル（`shell-` で始まらない）は herdr と一緒に無くなっているので、閉じるものが無い
    private func closeShell(_ pane: PaneID) async {
        if ConversationShells.isShell(pane.rawValue) { await shells.close(pane.rawValue) }
    }

    /// 止める（止まった会話でも、利用枠の上限の後の続きを取り消す）。止めた会話のうち、止めると記録が消える会話（`Conversation.removedOnStop`）は
    /// 記録も消す。止まっていた会話は記録を残す。人の停止は、常駐が入っているオーケストレーターの会話を断る（常駐が起こし直すので 409）
    func stop(_ id: String, cause: ConversationStopCause) async throws {
        let conversation = try find(id)
        let before = await conversation.snapshot()
        if cause == .person {
            try refuseResident(before)
            // 人が止めた会話は、後で再開して入力待ちに入っても終了しない
            closingAfterTurn.remove(id)
        }
        await conversation.stop(cause)
        if before.phase != .stopped, before.removedOnStop { try await delete(id) }
    }

    private func refuseResident(_ conversation: Conversation) throws {
        if conversation.purpose == .orchestrator, try environment.store.settings().orchestrator.enabled { throw ConversationError.orchestratorResident }
    }

    /// 終了：動いていれば止め、記録は残して終了の印を付ける（`Conversation.isClosed`）。シェルの tab を閉じる。
    /// オーケストレーターの会話は記録を消す（1 台に 1 つで、次に起こすときに記録を引くので、印を残すと終えた会話を起こし直す）。
    /// 終了した会話の委譲先は、空いていれば止める（生成中・問いの待ち・裏のタスクのあるものは動かしたまま）
    func close(_ id: String) async throws {
        let conversation = try find(id)
        let before = await conversation.snapshot()
        try refuseResident(before)
        closingAfterTurn.remove(id)
        await conversation.stop(.closed)
        if before.purpose == .orchestrator { return try await delete(id) }
        var shell: String?
        _ = try environment.store.updateConversation(id: id) {
            shell = $0.shellId
            $0.lastExit = ConversationStopCause.closed.lastExit
            $0.shellId = nil
        }
        await conversation.reloadRecord()
        environment.logger.info("conversation closed", metadata: ["conversation": .string(id)])
        if let shell { await closeShell(PaneID(rawValue: shell)) }
        await runs.reset(conversationID: id)
        for record in (try? environment.store.conversations()) ?? [] where record.parentConversationId == id {
            await conversations[record.id]?.stopIfResting()
        }
    }

    /// 会話が自分を終了する（`session_exit`）。静かな会話・止まった会話はすぐ終了し、ターンの途中なら入力待ちに入ってから終了する。
    /// 印は確かめる前に付ける（確かめている間に入力待ちに入っても取りこぼさない）。終了すると `close` が印を外す
    func closeAfterTurn(_ id: String) async throws {
        let conversation = try find(id)
        try refuseResident(await conversation.snapshot())
        guard await conversation.isLive else { return try await close(id) }
        closingAfterTurn.insert(id)
        _ = await closeIfResting(id)
    }

    /// 動いていて静かな（`LiveConversation.isResting`）会話を終了する。終了したら true。
    /// ターンの途中に頼まれた終了（`wake_create` の close）を、そのターンを終えてから行う
    func closeIfResting(_ id: String) async -> Bool {
        guard !deleting.contains(id), let conversation = conversations[id], await conversation.isLive, await conversation.isResting else { return false }
        do {
            try await close(id)
            return true
        } catch {
            environment.logger.warning("conversation not closed after turn", metadata: ["conversation": .string(id), "error": "\(error)"])
            return false
        }
    }

    /// 止まっている会話の記録を消す。消している途中は起こす・送る・答えるを断り、動いていれば 409。
    /// タスクとの結び（`taskSession`）と、回答を頼んだ会話の記録は残す（タスクの履歴から会話で開き直せる）
    func delete(_ id: String) async throws {
        guard !deleting.contains(id) else { throw ConversationError.removed(id) }
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        deleting.insert(id)
        defer { deleting.remove(id) }
        closingAfterTurn.remove(id)
        let conversation = conversations[id]
        try await conversation?.retire()
        do {
            try environment.store.deleteConversation(id: id)
        } catch {
            await conversation?.unretire()
            throw error
        }
        conversations.removeValue(forKey: id)
        changes.yield(.remove(id))
        environment.logger.info("conversation deleted", metadata: ["conversation": .string(id)])
        if let pane = record.shellId { await closeShell(PaneID(rawValue: pane)) }
        await runs.remove(conversationID: id)
    }

    // MARK: 購読（`/v1/stream`）

    /// 会話の出来事の購読を始める。会話が無ければ `unsubscribed {missing}` を積んで false。
    /// 止まった会話は、目安まで空きがあれば起こす（開いてから送るまでに起動を待たせない）
    func subscribe(_ id: String, key: UUID, epoch: String?, after: Int, subagents: Bool = false, outbox: StreamOutbox) async -> Bool {
        guard !deleting.contains(id), let conversation = try? find(id) else {
            outbox.pushUnsubscribed(conversation: id, reason: StreamServerFrame.missing)
            return false
        }
        guard await conversation.subscribe(outbox, key: key, epoch: epoch, after: after, subagents: subagents) else { return false }
        if await conversation.wakesForViewer {
            let logger = environment.logger
            Task {
                do {
                    try await conversation.start(resume: true, withinSoft: true)
                } catch {
                    logger.debug("conversation not woken for viewer", metadata: ["conversation": .string(id), "error": .string("\(error)")])
                }
            }
        }
        return true
    }

    func unsubscribe(_ id: String, key: UUID) async {
        await conversations[id]?.unsubscribe(key: key)
    }

    // MARK: 止める方針

    /// 自動停止：`cutoff` より後に使っていない会話を止める（`IdleReaper`）。止めた会話の id
    func stopIdle(before cutoff: Date) async -> [String] {
        var stopped: [String] = []
        for (id, conversation) in conversations where await conversation.stopIfIdle(before: cutoff) { stopped.append(id) }
        return stopped
    }

    /// 目安の上限を超えて起こした：止めてよい会話のうち、最後に使ったのが古いものを 1 つ止める
    func makeRoom(except id: String) async {
        let now = environment.now()
        var candidates: [(id: String, at: Date, conversation: any LiveConversation)] = []
        for (key, conversation) in conversations where key != id && !deleting.contains(key) {
            guard await conversation.isStoppable(before: now) else { continue }
            candidates.append((key, await conversation.lastActiveAt, conversation))
        }
        for candidate in candidates.sorted(by: { $0.at < $1.at }) where await candidate.conversation.stopIfIdle(before: now) {
            environment.logger.info("stopped conversation to make room", metadata: ["conversation": .string(candidate.id), "for": .string(id)])
            return
        }
    }

    // MARK: 引く・題の付け直し

    func events(_ id: String, after: Int) async throws -> AsyncStream<ConversationEvent> {
        try await find(id).events(after: after)
    }

    /// タスクの題が変わった：そのタスクの会話の題を、hook で結んだセッションと同じ規則（`SessionGuidance.retitle`）で付け直す。人が付けた題は残す。
    /// 止まっている会話も記録の題を書き換える（CLI には動いている子にだけ送る。`sendTitle`）
    func taskRetitled(_ task: BoardTask) async {
        for record in (try? environment.store.conversations()) ?? [] where record.taskNumber == task.number && !deleting.contains(record.id) {
            guard let title = SessionGuidance.retitle(current: record.title, task: task), let conversation = try? find(record.id) else { continue }
            try? await conversation.rename(title)
        }
    }

    // MARK: 届け口（回答・レビューは FeedbackService、知らせは ConversationNotices・LinkNotices）

    func conversationID(owning agentSessionID: String) async -> String? {
        (try? environment.store.conversation(agentSessionID: agentSessionID))??.id
    }

    func idleConversations() async -> [(id: String, task: Int)] {
        var result: [(id: String, task: Int)] = []
        for (id, conversation) in conversations where await conversation.isIdle {
            if let task = (try? environment.store.conversation(id: id))??.taskNumber { result.append((id, task)) }
        }
        return result
    }

    /// 回答・レビュー・知らせを発言として入れる。止まっている会話は `kind.wake` が起こすなら起こしてから入れ（起こせなければ nil。未受領のまま残る）、
    /// 起こさないなら `busy`
    func deliver(conversationID: String, text: String, uuid: String, kind: DeliveryKind) async -> ConversationDeliveryOutcome? {
        guard !deleting.contains(conversationID), let conversation = try? find(conversationID) else { return nil }
        do {
            return try await conversation.deliver(text: text, uuid: uuid, wake: kind.wake)
        } catch {
            environment.logger.warning("feedback delivery to conversation failed", metadata: ["conversation": .string(conversationID), "error": "\(error)"])
            return nil
        }
    }

    /// 止まった TUI の lead を、届けるために会話で戻す（`kind.resumesStoppedTerminal` のものだけ）。同じ Claude の会話は 5 分に 1 回まで
    /// （戻している間に起こし直さない）。戻した会話が入力待ちに入ったら、届ける側がそこへ入れる
    func resumeStoppedLead(task number: Int, agentSessionID: String, for kind: DeliveryKind) async {
        await resumeStoppedLead(task: number, agentSessionID: agentSessionID, for: kind, now: environment.now())
    }

    /// 止まった TUI の lead を会話で戻した時刻（Claude の会話 ID ごと）
    private var leadResumes: [String: Date] = [:]
    static let leadResumeCooldown: TimeInterval = 300

    func resumeStoppedLead(task number: Int, agentSessionID: String, for kind: DeliveryKind, now: Date) async {
        guard kind.resumesStoppedTerminal, leadResumes[agentSessionID].map({ now.timeIntervalSince($0) >= Self.leadResumeCooldown }) ?? true else { return }
        leadResumes[agentSessionID] = now
        let metadata: Logger.Metadata = ["task": .stringConvertible(number), "kind": .string("\(kind)")]
        do {
            let conversation = try await resumeSession(task: number, agentSessionID: agentSessionID)
            environment.logger.info("stopped lead resumed for delivery", metadata: metadata.merging(["conversation": .string(conversation.id)]) { $1 })
        } catch {
            environment.logger.warning("stopped lead not resumed for delivery", metadata: metadata.merging(["error": "\(error)"]) { $1 })
        }
    }

    // MARK: 枠

    /// 会話の枠（`ClaudeVersionWatcher` の確かめも 1 つ使う）
    nonisolated var slots: ConversationSlots { environment.slots }

    // MARK: TUI のセッションを会話で戻す・移す

    /// タスクに結んだ止まったセッションを戻す（`POST /v1/tasks/{n}/sessions/resume`）。その会話 ID を持つ会話の記録があればそれを起こし、
    /// 無ければ紐づけの記録の起動の引数で会話を起こす。起動の引数を会話の項目に読み替えられなければ断る
    func resume(task number: Int, _ body: SessionResumeRequest) async throws -> SessionResumeResult {
        SessionResumeResult(conversation: try await resumeSession(task: number, agentSessionID: body.agentSessionID, account: body.account))
    }

    /// タスクに結んだ止まったセッションを、会話で戻す（回答・リンクの知らせの配送もこれを呼ぶ）
    func resumeSession(task number: Int, agentSessionID: String, account: String? = nil) async throws -> Conversation {
        guard let task = await environment.state.task(number: number), let ref = task.sessions.last(where: { $0.sessionID == agentSessionID }) else {
            throw ConversationError(
                status: 404, code: .notFound, params: ["kind": DaemonErrorCode.Kind.session.rawValue],
                description: "タスク #\(number) に紐づくセッション \(agentSessionID) が無い")
        }
        guard let kind = AgentKind(rawValue: ref.agent) else { throw ConversationError.invalid("\(ref.agent) の会話は起こせない") }
        var request = try launchRequest(kind: kind, agentArgs: ref.launchArgs, cwd: ref.cwd, taskNumber: number)
        request.resumeAgentSessionID = agentSessionID
        request.account = account
        return try await start(request)
    }

    /// 会話の Claude Code のアカウントを替える（`POST /v1/sessions/account`）。動いていれば止め、次に送ったときに新しいアカウントで起こす
    func switchAccount(_ id: String, account: String) async throws -> Conversation {
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        guard record.engineValue == .claude else { throw ConversationError.invalid("Claude Code の会話ではない") }
        guard let arguments = try await accountArguments(record.extraArguments, requested: account, task: record.taskNumber, resuming: true) else {
            return try await get(id)
        }
        guard let conversation = try find(id) as? ClaudeConversation else { throw ConversationError.invalid("Claude Code の会話ではない") }
        try await conversation.switchAccount(arguments: arguments)
        return await conversation.snapshot()
    }

    /// 会話の引数を、決めたアカウントの `--settings` にしたもの。アカウントの設定が無ければ nil（引数を替えない）
    private func accountArguments(_ args: [String], requested: String?, task number: Int?, resuming: Bool) async throws -> [String]? {
        guard let accounts = environment.accounts else {
            if let requested, requested != ClaudeAccount.login { throw ConversationError.invalid(ClaudeAccountError.unknown(requested, []).message) }
            return nil
        }
        var keys: Set<String> = []
        if let number, let task = await environment.state.task(number: number) { keys = try environment.store.boards().keys(of: task.boardID) }
        let pause = ((try? environment.store.settings()) ?? .defaults).usagePause
        do {
            return try await accounts.apply(to: args, requested: requested, boardKeys: keys, resuming: resuming, settings: pause, now: environment.now()).args
        } catch {
            throw ConversationError.invalid(error.message)
        }
    }

    // MARK: daemon が起こし方を決める口の決まり

    /// daemon が自分で起こす口（定期起動・wake・オーケストレーター・止まったセッションの再開）の会話の起こし方。起動の引数を、その engine の
    /// 会話の項目に読み替える。読み替えられなければ、読めなかった引数の名前を添えて断る（捨てると、人が付けた指定が効かないまま動く）
    func launchRequest(kind: AgentKind, agentArgs: [String], cwd: String, taskNumber: Int?) throws -> ConversationStartRequest {
        switch kind {
        case .claude:
            guard let converted = ConversationArguments.convert(agentArgs, models: claudeModels()) else {
                throw ConversationError.invalid("会話に渡せない引数がある: \(Self.optionNames(agentArgs))")
            }
            return ConversationStartRequest(
                cwd: cwd, taskNumber: taskNumber, model: converted.model, effort: converted.effort, permissionMode: converted.permissionMode,
                extraArgs: converted.extraArgs.isEmpty ? nil : converted.extraArgs)
        case .codex:
            let choice = LaunchChoice(kind: .codex, args: agentArgs)
            guard choice.custom == nil else { throw ConversationError.invalid("codex の会話に渡せない引数がある: \(Self.optionNames(agentArgs))") }
            return ConversationStartRequest(cwd: cwd, taskNumber: taskNumber, model: choice.codexModel, effort: choice.codexEffort, engine: .codex)
        }
    }

    /// 値（ヘッダ・token を含みうる）は出さず、オプションの名前だけ
    private static func optionNames(_ args: [String]) -> String {
        args.filter { $0.hasPrefix("-") }.map { String($0.prefix { $0 != "=" }) }.joined(separator: " ")
    }

    // MARK: daemon が自分で起こす会話（オーケストレーター・定期起動）

    /// オーケストレーターの会話の記録（1 台に 1 つ）
    func orchestratorRecord() -> ConversationRecord? {
        ((try? environment.store.conversations()) ?? []).first { $0.purposeValue == .orchestrator }
    }

    func isLive(_ id: String) async -> Bool {
        guard let conversation = conversations[id] else { return false }
        return await conversation.isLive
    }

    /// 前に送った uuid の今の状態（定期起動の回の最初の発言を受けたか）
    func deliveryState(_ id: String, uuid: String) async -> ConversationDeliveryOutcome? {
        guard !deleting.contains(id), let conversation = try? find(id) else { return nil }
        return await conversation.deliveryState(uuid)
    }

    /// 前に送った uuid の発言を受けたか（daemon が起き直した後の定期起動の回の確かめ）。会話が無ければ false
    func received(_ id: String, uuid: String) async -> Bool {
        guard !deleting.contains(id), let conversation = try? find(id) else { return false }
        return await conversation.received(uuid)
    }

    /// 定期起動の回の会話を、最初の発言を受けてターンを終え、静かになったら止める（`ScheduledRunCloser`）
    func stopIfFinished(_ id: String, firstMessageID: String) async -> Bool {
        guard !deleting.contains(id), let conversation = conversations[id], await conversation.isLive else { return false }
        guard await conversation.deliveryState(firstMessageID) == .delivered else { return false }
        return await conversation.stopIfFinished()
    }

    /// 定期起動の回の会話を止める（起こす途中で daemon が止まった回）。記録は残す
    func stopQuietly(_ id: String) async {
        await conversations[id]?.stop(.taskboard)
    }

    /// 会話の transcript（オーケストレーターの返事と、知らせに載せる最後の返事を読む）
    func transcriptURL(_ id: String) async -> URL? {
        guard let record = try? environment.store.conversation(id: id), record.engineValue == .claude else { return nil }
        let projects = await transcriptProjects().standardizedFileURL.resolvingSymlinksInPath()
        return TranscriptTail.locate(record.agentSessionId, in: projects)
    }

    /// 委譲先の知らせに載せる、会話の最後の返事（上限 `OrchestratorReplyReader.limit` 字）。読めなければ nil
    func latestReply(_ id: String) async -> String? {
        guard let record = try? environment.store.conversation(id: id) else { return nil }
        if record.engineValue == .codex { return await codexLatestReply(record) }
        guard let url = await transcriptURL(id) else { return nil }
        return OrchestratorReplyReader.latest(inTranscript: url).map { String($0.last.prefix(OrchestratorReplyReader.limit)) }
    }

    // MARK: 起こした側への知らせ

    /// 起こした側への知らせを組む材料：記録と、生成中か・答えを待っている問い
    func noticeState(_ id: String) async -> (record: ConversationRecord, busy: Bool, requests: [ConversationRequest])? {
        guard !deleting.contains(id), let record = try? environment.store.conversation(id: id) else { return nil }
        // host の会話を引き取る前は、記録だけの会話が生成中かもしれない
        guard let conversation = conversations[id] else { return (record, !hostReconciled, Conversation(record: record, machine: environment.machine).requests) }
        let state = await conversation.noticeState
        return (await conversation.record, state.busy, state.requests)
    }

    func noticeDelivered(_ id: String, at: Date) async {
        if let conversation = try? find(id) { await conversation.noticeDelivered(at: at) }
    }

    func noticeCancelled(_ id: String, at: Date) async {
        if let conversation = try? find(id) { await conversation.noticeCancelled(at: at) }
    }

    /// 知らせを残した会話（起き直したときと見回りで、届けていない分を探す）
    func pendingNotices() -> [String] {
        ((try? environment.store.conversations()) ?? []).filter { $0.notifyParent && $0.parentNoticeAt != nil }.map(\.id)
    }

    /// 起こした側を替える。`fromConversation` の子を `to` の会話の子にする
    func reparent(fromConversation: String, to target: String) async {
        let moved = (try? environment.store.reparentConversations(fromConversation: fromConversation, to: target)) ?? []
        for id in moved { await conversations[id]?.reloadRecord() }
        if !moved.isEmpty { environment.logger.info("conversations reparented", metadata: ["to": .string(target), "count": .stringConvertible(moved.count)]) }
    }

    private func noticeChanged(_ id: String) async {
        await noticeHandler?(id)
    }

    // MARK: 利用枠の上限の後の続き

    /// 利用枠の上限で待っている会話に、時刻を過ぎたら続きを送る（30 秒ごと）
    func runUsageLimitResumes(interval: Duration = .seconds(30)) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            await resumeAfterUsageLimits(now: environment.now())
            await refreshIdleUsage()
        }
    }

    /// 空いている Claude の会話に利用枠を取り直させる。引くのはアカウントごとに `usageRefreshInterval` に 1 回まで
    func refreshIdleUsage() async {
        for (id, conversation) in conversations where !deleting.contains(id) {
            guard let claude = conversation as? ClaudeConversation else { continue }
            await claude.refreshUsage()
        }
    }

    /// 利用枠の上限で待っている・区切って待っている Claude の会話があるか（定期起動を後へ回す）
    func waitsForUsage(now: Date) -> Bool {
        ((try? environment.store.conversations()) ?? []).contains { record in
            record.engineValue == .claude && (record.limitResumeAt.map { $0 > now } ?? false)
        }
    }

    /// 戻る時刻を過ぎた会話に続きを送る。まだ待っている Claude の会話は、枠の残っている別のアカウントがあれば替えてすぐ続ける
    func resumeAfterUsageLimits(now: Date) async {
        for record in (try? environment.store.conversations()) ?? [] {
            guard let at = record.limitResumeAt, !deleting.contains(record.id), let conversation = try? find(record.id) else { continue }
            if at <= now {
                await conversation.continueAfterLimit()
            } else if record.engineValue == .claude, let claude = conversation as? ClaudeConversation,
                let arguments = try? await accountArguments(record.extraArguments, requested: nil, task: record.taskNumber, resuming: true)
            {
                await claude.continueOnAccount(arguments: arguments)
            }
        }
    }

    // MARK: ネットワークが戻った後の続き

    /// ネットワークに繋がらずに止まった会話に、繋がっていれば続きを送る（30 秒ごと）。経路が戻った回数を見回りのたびに比べる
    func runNetworkResumes(interval: Duration = .seconds(30)) async {
        var seen = environment.networkReturns()
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            let returns = environment.networkReturns()
            await resumeAfterNetwork(online: environment.networkOnline(), returned: returns != seen)
            seen = returns
        }
    }

    func resumeAfterNetwork(online: Bool, returned: Bool) async {
        for record in (try? environment.store.conversations()) ?? [] {
            guard record.networkResumeAt != nil, !deleting.contains(record.id), let conversation = try? find(record.id) else { continue }
            await conversation.continueAfterNetwork(online: online, returned: returned)
        }
    }

    // MARK: 空いた会話の圧縮

    /// 返事の後にしばらく空いた会話を圧縮する（1 分ごと）。止まった会話は起こさない（起こすとキャッシュを書き直すことになる）
    func runIdleCompactions(interval: Duration = .seconds(60)) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            await compactIdleConversations()
        }
    }

    func compactIdleConversations() async {
        for (id, conversation) in conversations where !deleting.contains(id) { await conversation.compactIfIdle() }
    }

    // MARK: 内部

    private func find(_ id: String) throws -> any LiveConversation {
        guard !deleting.contains(id) else { throw ConversationError.removed(id) }
        if let conversation = conversations[id] { return conversation }
        guard let record = try environment.store.conversation(id: id) else { throw Self.notFound(id) }
        return try make(record)
    }

    /// 記録から会話の actor を作る。この版が知らない engine の記録（新しい版の daemon が書いたもの）は動かせないので断る
    func make(_ record: ConversationRecord) throws -> any LiveConversation {
        let conversation: any LiveConversation
        switch record.engineValue {
        case .claude: conversation = ClaudeConversation(record: record, context: context())
        case .codex: conversation = CodexConversation(record: record, context: codexContext())
        case .unknown: throw ConversationError.unsupportedEngine(record.id, record.engine)
        }
        conversations[record.id] = conversation
        return conversation
    }

    /// この版の daemon が動かせる engine の記録か
    static func runs(_ record: ConversationRecord) -> Bool {
        switch record.engineValue {
        case .claude, .codex: true
        case .unknown: false
        }
    }

    /// 記録の engine の会話 ID の予約の key
    static func reservationKey(_ record: ConversationRecord) -> String {
        SessionReservations.key(record.engineValue.agentKind ?? .claude, record.agentSessionId)
    }

    /// 2 つの engine の会話が共に使う daemon の部品
    private func sharedContext(launch: @escaping @Sendable () async throws -> EngineLaunch) -> ConversationContext {
        let state = environment.state
        let logger = environment.logger
        var context = ConversationContext(
            machine: environment.machine, store: environment.store, host: host, launch: launch, attachments: environment.attachments,
            guide: { number in
                guard let task = await state.task(number: number) else { return nil }
                return SessionGuidance.text(task: task, board: await state.allBoards().first { $0.id == task.boardID }, machineName: "この Mac")
            },
            becameIdle: { [weak self] id in await self?.becameIdle(id) }, logger: logger)
        context.reservations = environment.reservations
        context.timing = environment.timing
        context.now = environment.now
        context.epoch = environment.state.epoch
        let changes = changes
        context.publish = { changes.yield(.upsert($0)) }
        context.publishTool = { changes.yield(.tool($0, $1)) }
        context.slots = environment.slots
        context.makeRoom = { [weak self] id in await self?.makeRoom(except: id) }
        context.noticeChanged = { [weak self] id in await self?.noticeChanged(id) }
        context.diff = { cwd in
            do {
                return ConversationDiff.response(try await ConversationDiff.read(cwd: cwd)).summary
            } catch {
                logger.debug("conversation diff failed", metadata: ["cwd": .string(cwd), "error": "\(error)"])
                return nil
            }
        }
        return context
    }

    private func codexContext() -> CodexConversation.Context {
        var context = CodexConversation.Context(
            shared: sharedContext(
                launch: { [weak self] in
                    guard let self else { throw ConversationError.failed("daemon が止まる") }
                    return try await self.codexLaunch()
                }))
        context.logoutConnector = CodexConnectors.logout(install: { [weak self] in
            guard let self else { throw ConversationError.failed("daemon が止まる") }
            let launch = try await self.codexLaunch()
            return CodexInstall(executable: URL(filePath: launch.executable), environment: launch.environment)
        })
        let taskboard = environment.home + "/.local/bin/taskboard"
        if FileManager.default.isExecutableFile(atPath: taskboard) { context.taskboardMCP = .init(command: taskboard, args: ["mcp"], env: environment.daemon?.environment ?? [:]) }
        return context
    }

    private func context() -> ClaudeConversation.Context {
        let state = environment.state
        let hooks = environment.hooks
        let store = environment.store
        let logger = environment.logger
        var context = ClaudeConversation.Context(
            shared: sharedContext(
                launch: { [weak self] in
                    guard let self else { throw ConversationError.failed("daemon が止まる") }
                    return try await self.launch()
                }),
            stopHook: { conversationID, call in
                guard let hooks, let record = try? store.conversation(id: conversationID) else { return nil }
                let turn = call.transcriptPath.flatMap { TranscriptTurn.read(URL(fileURLWithPath: $0)) }
                do {
                    return try await hooks.stopConversation(
                        HookStopRequest(
                            paneID: nil, agent: "claude", agentSessionID: call.sessionID ?? record.agentSessionId, cwd: call.cwd ?? record.cwd,
                            turnStartedAt: turn?.startedAt, turnUsedTools: turn?.usedTools))
                } catch {
                    logger.warning("conversation stop hook failed", metadata: ["conversation": .string(conversationID), "error": "\(error)"])
                    return nil
                }
            })
        let supportDirectory = environment.supportDirectory
        context.modelsListed = { Self.recordModels($0, version: $1, supportDirectory: supportDirectory, logger: logger) }
        context.models = { ClaudeModelRecord.models(supportDirectory: supportDirectory) }
        context.hasTranscript = { ClaudeConversation.transcriptExists($0, environment: $1) }
        context.transcriptSource = { ClaudeConversation.transcriptSource(fork: $0, source: $1, environment: $2) }
        context.answeredInTranscript = { ClaudeConversation.transcriptAnswered($0, toolUseID: $1, environment: $2) }
        context.taskList = { ClaudeTaskList.read($0, environment: $1) }
        let home = environment.home
        context.continuesAtUsageLimit = { record, environment in UsageLimitSetting.continues(record: record, environment: environment, home: home) }
        context.reportUsage = { report in await state.record(report, now: report.context.at) }
        context.usagePause = { ((try? store.settings()) ?? .defaults).usagePause }
        context.claimUsageRefresh = { [weak self] account in await self?.claimUsageRefresh(account: account) ?? false }
        context.launchArguments = { [weak self] record, resume in
            guard record.engineValue == .claude else { return nil }
            return try? await self?.accountArguments(record.extraArguments, requested: nil, task: record.taskNumber, resuming: resume) ?? nil
        }
        return context
    }

    /// 会話の CLI の `get_usage` を最後に引いた時刻。どの会話からでも、アカウント（nil はマシンのログイン）ごとに `usageRefreshInterval` に 1 回まで
    private var lastUsageRefresh: [String: Date] = [:]
    static let usageRefreshInterval: TimeInterval = 300

    private func claimUsageRefresh(account: String?) -> Bool {
        let now = environment.now()
        let key = account ?? ClaudeAccount.login
        if let last = lastUsageRefresh[key], now.timeIntervalSince(last) < Self.usageRefreshInterval { return false }
        lastUsageRefresh[key] = now
        return true
    }

    /// 受け手を回してから、ターンの後の終了を待つ会話を終了する（受け手が回答を入れて動き出したら、次に入力待ちに入るまで待つ）
    private func becameIdle(_ id: String) async {
        for handler in idleHandlers { await handler(id) }
        if closingAfterTurn.contains(id) { _ = await closeIfResting(id) }
    }

    /// `POST /v1/dictation/polish`。校正できなければ 409（確かめた版が無い）・503（校正の口が無い・混んでいる）・502（校正が失敗した）
    func polishDictation(_ request: DictationPolishRequest) async throws -> DictationPolishResponse {
        guard let dictationPolisher else { throw ConversationError(status: 503, code: .unavailable, description: "音声入力の校正が無い") }
        do {
            return DictationPolishResponse(text: try await dictationPolisher.polish(request))
        } catch let error as ConversationError {
            throw error
        } catch DictationPolishError.busy {
            throw ConversationError(status: 503, code: .unavailable, description: "音声入力の校正が混んでいる")
        } catch {
            environment.logger.warning("dictation polish failed", metadata: ["error": "\(error)"])
            throw ConversationError(status: 502, code: .unavailable, description: "音声入力の校正に失敗した")
        }
    }

    /// 確かめた版の CLI とログインシェルの環境。確かめた版が無ければ起こさない
    func launch() async throws -> EngineLaunch {
        guard let entry = VerifiedCLI.load(.claude, supportDirectory: environment.supportDirectory)?.newest(requiring: ClaudeConversation.requiredCapabilities)
        else {
            throw ConversationError(status: 409, code: .claudeUnverified, description: "確かめた版の Claude Code が無い（taskboard conversation check）")
        }
        return EngineLaunch(executable: entry.path, environment: await launchEnvironment())
    }

    /// このマシンの Claude Code のモデルの一覧（`GET /v1/claude`）。まだ CLI から受けていなければ一覧は nil
    func claudeMachine() -> ClaudeMachineInfo {
        ClaudeModelRecord.load(supportDirectory: environment.supportDirectory)
    }

    /// model を確かめる一覧（受けた一覧が無ければ控え）
    private func claudeModels() -> ClaudeModels {
        ClaudeModelRecord.models(supportDirectory: environment.supportDirectory)
    }

    /// 受けた一覧を記録する（同じなら書かない）
    nonisolated static func recordModels(_ models: [ClaudeMachineInfo.Model], version: String?, supportDirectory: URL, logger: Logger) {
        do {
            try ClaudeModelRecord.record(models, version: version, supportDirectory: supportDirectory)
        } catch {
            logger.warning("claude models not recorded", metadata: ["error": "\(error)"])
        }
    }

    /// 確かめて、モデルを `ClaudeModels.argument` の名前にそろえた要求を返す
    func validated(_ request: ConversationStartRequest) throws -> ConversationStartRequest {
        var request = request
        var isDirectory: ObjCBool = false
        guard request.cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: request.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConversationError.invalid("cwd は在るディレクトリの絶対パス")
        }
        if request.engine == .codex {
            if let model = request.model, !ConversationInput.acceptsCodexName(model) { throw ConversationError.invalid("model が違う") }
            if let effort = request.effort, !ConversationInput.acceptsCodexName(effort) { throw ConversationError.invalid("effort が違う") }
            if request.extraArgs?.isEmpty == false { throw ConversationError.invalid("codex の会話には extra_args を渡せない") }
        } else {
            if let model = request.model {
                let models = claudeModels()
                guard let canonical = models.argument(for: model) else { throw ConversationError.invalid(models.rejection(model)) }
                request.model = canonical
            }
            if let effort = request.effort, Effort(rawValue: effort) == nil { throw ConversationError.invalid("effort が違う") }
        }
        if let mode = request.permissionMode, !ConversationInput.acceptedPermissionModes.contains(mode) { throw ConversationError.invalid("permission_mode が違う") }
        if let prompt = request.prompt, prompt.utf8.count > ConversationInput.textBytes { throw ConversationError.invalid("文は 1MB まで") }
        if let id = request.resumeAgentSessionID, UUID(uuidString: id) == nil { throw ConversationError.invalid("戻す会話 ID は UUID") }
        return request
    }

    static func notFound(_ id: String) -> ConversationError {
        ConversationError(status: 404, code: .notFound, params: ["kind": DaemonErrorCode.Kind.conversation.rawValue], description: "会話 \(id) が無い")
    }

}

extension Conversation {
    /// 記録から組む会話の様子（止まった会話の形）。動いている会話は `ClaudeConversation.snapshot` が子の様子を重ねる。
    /// 巻き戻している途中の `rewindFilesPending` は、まだ結果を待っているだけ
    init(record: ConversationRecord, machine: MachineID, rewinding: Bool = false) {
        self.init(
            id: record.id, machine: machine, taskNumber: record.taskNumber, engine: record.engineValue,
            agentSessionID: record.agentSessionId, cwd: record.cwd, model: record.model, effort: record.effort, permissionMode: record.permissionMode,
            title: record.displayTitle, runner: .none, phase: .stopped, pending: [], deferred: record.deferredQuestion?.request, lastExit: record.lastExit,
            stats: record.statsValue, createdAt: record.createdAt, updatedAt: record.updatedAt)
        customTitle = record.customTitle
        account = ClaudeAccount.name(inArguments: record.extraArguments)
        forkSource = record.forkSourceId
        forkAt = record.forkAt
        forkPending = record.pendingForkSessionId != nil
        canUndoRewind = record.previousSessionId != nil
        canRedoRewind = record.redoSessionId != nil
        rewindIncomplete = record.rewindFilesPending && !rewinding
        purpose = record.purposeValue
        parentConversationID = record.parentConversationId
        parentNoticePending = record.parentNoticeAt != nil
        limitResumeAt = record.limitResumeAt
        limitPaused = record.limitPaused
        networkResume = record.networkResumeAt != nil ? true : nil
        if let text = record.lastReply, let at = record.lastReplyAt { lastReply = ConversationReply(text: text, at: at) }
        turnStartedAt = record.turnStartedAt
    }
}

extension ConversationService: FeedbackConversations {}

/// 仕事が `limit` までに終わらなければ、仕事を取り消して `Deadline.Expired` を投げる。
/// 取り消しに応えない仕事（共有の Task の待ちなど）の終わりは待たずに返す
enum Deadline {
    struct Expired: Error, CustomStringConvertible {
        var description: String { "時間切れ" }
    }

    static func run<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation
            gate.tasks = [
                Task {
                    do {
                        gate.finish(.success(try await work()))
                    } catch {
                        gate.finish(.failure(error))
                    }
                },
                Task {
                    try? await Task.sleep(for: limit)
                    gate.finish(.failure(Expired()))
                },
            ]
        }
    }

    /// 最初に終わった方の結果で continuation を 1 度だけ再開し、残りを取り消す
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var _continuation: CheckedContinuation<T, any Error>?
        private var _tasks: [Task<Void, Never>] = []

        var continuation: CheckedContinuation<T, any Error>? {
            get { lock.withLock { _continuation } }
            set { lock.withLock { _continuation = newValue } }
        }

        /// 仕事が `finish` の後に登録されても取り消す
        var tasks: [Task<Void, Never>] {
            get { lock.withLock { _tasks } }
            set {
                let late = lock.withLock { () -> Bool in
                    _tasks = newValue
                    return finished
                }
                if late { newValue.forEach { $0.cancel() } }
            }
        }

        func finish(_ result: Result<T, any Error>) {
            let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
                guard !finished else { return (nil, []) }
                finished = true
                return (_continuation, _tasks)
            }
            continuation?.resume(with: result)
            tasks.forEach { $0.cancel() }
        }
    }
}

/// 作り終える前に渡す口から、作り終えた actor を弱く引く
final class WeakReference<Value: AnyObject & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
