import Foundation
import TaskboardKit

/// daemon がアプリに見せる現在像と、その変化の配信。ボードとタスクは `Store` から、会話は `ConversationService` から入る。
public actor DaemonState {
    private var machine: MachineInfo
    private var boards: [String: Board] = [:]
    private var tasks: [Int: BoardTask] = [:]
    private var workItems: [Int64: WorkItem] = [:]
    private var documents: [Int64: Document] = [:]
    private var asks: [Int64: Ask] = [:]
    private var reviewRequests: [Int: ReviewRequest] = [:]
    private var prs: PRSnapshot?
    private var usage = UsageSnapshot()
    /// セッションごとの最後の枠。アカウントの枠はここから `UsageWindow.resolve` で決める
    private var claudeReports: [String: ClaudeSessionUsage] = [:]
    /// セッションの報告のアカウント（nil はマシンのログイン）
    private var claudeReportAccounts: [String: String?] = [:]
    private var schedules: [Int64: Schedule] = [:]
    private var wakes: [Int64: Wake] = [:]
    private var watches: [Int64: Watch] = [:]
    /// 会話が登録した概況（部品のあるタスクだけ）
    private var panels: [Int: OverviewPanel] = [:]
    /// URL → 状態。タスクに付いているリンクだけを持つ
    private var links: [String: LinkStatus] = [:]
    private var subscribers: [UUID: AsyncStream<DaemonEvent>.Continuation] = [:]
    private var settings: MachineSettings?
    /// 最後に配ったオーケストレーターの状態
    private var orchestrator: OrchestratorInfo?
    /// 受信箱で消した項目の記録（Store の `inboxDismissal` 表の写し）
    private var inboxDismissals: [InboxDismissal] = []
    /// host の会話の様子（`ConversationService` が入れる）。発言と差分は会話を購読した接続にだけ流れる
    private var conversations: [String: Conversation] = [:]
    /// ツールを使っている会話の、使っているツールの名前（会話の id → 名前）
    private var toolActivities: [String: String] = [:]
    /// daemon の起動ごとの印。`/v1/stream` の番号と会話の seq は起動ごとに数え直すので、アプリはこれが変わったら続きを求めない
    public nonisolated let epoch: String
    private var journal: StreamJournal
    private var streams: [UUID: StreamOutbox] = [:]
    private let streamEncoder = WireJSON.encoder()
    private let clock: @Sendable () -> Date

    public init(machine: MachineInfo, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(machine: machine, journal: StreamJournal(), clock: clock)
    }

    init(machine: MachineInfo, journal: StreamJournal, epoch: String = UUID().uuidString.lowercased(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.machine = machine
        self.journal = journal
        self.epoch = epoch
        self.clock = clock
    }

    public func snapshot() -> StateSnapshot {
        var snapshot = StateSnapshot(
            machine: machine,
            boards: boards.values.sorted { $0.position < $1.position },
            tasks: tasks.values.sorted { $0.number < $1.number },
            workItems: workItems.values.sorted { ($0.taskNumber, $0.position, $0.itemID) < ($1.taskNumber, $1.position, $1.itemID) },
            documents: documents.values.sorted { $0.updatedAt > $1.updatedAt },
            asks: asks.values.sorted { $0.createdAt < $1.createdAt },
            reviewRequests: reviewRequests.values.sorted { $0.requestedAt < $1.requestedAt },
            prs: prs,
            usage: usage.claude == nil && usage.claudeAccounts == nil && usage.codex == nil && usage.contexts.isEmpty ? nil : usage,
            schedules: schedules.values.sorted { $0.scheduleID < $1.scheduleID },
            links: linkStatuses(),
            settings: settings,
            orchestrator: orchestrator,
            generatedAt: Date())
        snapshot.inboxDismissals = inboxDismissals
        snapshot.conversations = conversations.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        snapshot.conversationActivities = toolActivities.sorted { $0.key < $1.key }.map {
            ConversationToolActivity(conversation: ConversationKey(machine: machine.id, id: $0.key), toolName: $0.value)
        }
        snapshot.wakes = wakes.values.sorted { ($0.at, $0.wakeID) < ($1.at, $1.wakeID) }
        snapshot.watches = watches.values.sorted { $0.watchID < $1.watchID }
        snapshot.panels = panels.values.sorted { $0.taskNumber < $1.taskNumber }
        return snapshot
    }

    public func machineInfo() -> MachineInfo { machine }

    func setCLIStatus(_ status: CLIVersionStatus, engine: AgentKind) {
        switch engine {
        case .claude:
            guard machine.claudeCLI != status else { return }
            machine.claudeCLI = status
        case .codex:
            guard machine.codexCLI != status else { return }
            machine.codexCLI = status
        }
        broadcast(.machineUpdated(machine))
    }

    func setAgentHost(_ info: AgentHostInfo) {
        guard machine.agentHost != info else { return }
        machine.agentHost = info
        broadcast(.machineUpdated(machine))
    }

    // MARK: ボードとタスク（Store）

    /// 起動時に Store の中身を載せる。配信はしない（購読者はまだいない）。
    public func load(
        boards newBoards: [Board], tasks newTasks: [BoardTask], workItems newItems: [WorkItem] = [],
        documents newDocuments: [Document] = [], asks newAsks: [Ask] = [], reviewRequests newRequests: [ReviewRequest] = []
    ) {
        boards = Dictionary(uniqueKeysWithValues: newBoards.map { ($0.id, $0) })
        tasks = Dictionary(uniqueKeysWithValues: newTasks.map { ($0.number, $0) })
        workItems = Dictionary(uniqueKeysWithValues: newItems.map { ($0.itemID, $0) })
        documents = Dictionary(uniqueKeysWithValues: newDocuments.map { ($0.docID, $0) })
        asks = Dictionary(uniqueKeysWithValues: newAsks.map { ($0.askID, $0) })
        reviewRequests = Dictionary(uniqueKeysWithValues: newRequests.map { ($0.taskNumber, $0) })
    }

    // MARK: 文書・質問・レビュー依頼

    public func upsert(_ document: Document) {
        documents[document.docID] = document
        broadcast(.docUpdated(document))
    }

    public func removeDocument(id: Int64) {
        guard let removed = documents.removeValue(forKey: id) else { return }
        for ask in asks.values where ask.docID == id { asks.removeValue(forKey: ask.askID) }
        broadcast(.docRemoved(removed.id))
    }

    /// 配る。受領済みと取り下げは一覧から落とす（配信はする。アプリ側も同じ規則で落とす）
    public func upsert(_ ask: Ask) {
        if ask.status == .cancelled || ask.deliveredAt != nil {
            asks.removeValue(forKey: ask.askID)
        } else {
            asks[ask.askID] = ask
        }
        broadcast(.askUpdated(ask))
    }

    public func setPullRequests(_ snapshot: PRSnapshot) {
        guard snapshot != prs else { return }
        prs = snapshot
        broadcast(.prsUpdated(snapshot))
    }

    public func pullRequests() -> PRSnapshot? { prs }

    // MARK: 定期起動

    /// 変わっていなければ配らない（スケジューラが tick ごとに全件を入れ直す）
    public func upsert(_ schedule: Schedule) {
        guard schedules[schedule.scheduleID] != schedule else { return }
        schedules[schedule.scheduleID] = schedule
        broadcast(.scheduleUpdated(schedule))
    }

    public func removeSchedule(id: Int64) {
        guard let removed = schedules.removeValue(forKey: id) else { return }
        broadcast(.scheduleRemoved(removed.id))
    }

    // MARK: 起こす予定

    public func upsert(_ wake: Wake) {
        guard wakes[wake.wakeID] != wake else { return }
        wakes[wake.wakeID] = wake
        broadcast(.wakeUpdated(wake))
    }

    public func removeWake(id: Int64) {
        guard let removed = wakes.removeValue(forKey: id) else { return }
        broadcast(.wakeRemoved(removed.id))
    }

    // MARK: 見張り

    public func upsert(_ panel: OverviewPanel) {
        guard panels[panel.taskNumber] != panel else { return }
        panels[panel.taskNumber] = panel
        broadcast(.panelUpdated(panel))
    }

    public func removePanel(task number: Int) {
        guard let removed = panels.removeValue(forKey: number) else { return }
        broadcast(.panelRemoved(removed.id))
    }

    public func upsert(_ watch: Watch) {
        guard watches[watch.watchID] != watch else { return }
        watches[watch.watchID] = watch
        broadcast(.watchUpdated(watch))
    }

    public func removeWatch(id: Int64) {
        guard let removed = watches.removeValue(forKey: id) else { return }
        broadcast(.watchRemoved(removed.id))
    }

    // MARK: 利用枠（statusline）

    /// statusline は 10 秒ごとに届く。時刻以外が変わらなければ配らない。枠は報告のアカウント（nil はマシンのログイン）の枠に入れる
    public func record(_ report: ClaudeUsageReport, now: Date = Date()) {
        var next = usage
        let session = report.context.agentSessionID
        claudeReports = claudeReports.filter { now.timeIntervalSince($0.value.at) <= Self.contextTTL }
        claudeReportAccounts = claudeReportAccounts.filter { claudeReports[$0.key] != nil }
        if report.fiveHour != nil || report.sevenDay != nil {
            claudeReports[session] = ClaudeSessionUsage.next(claudeReports[session], report, now: now)
            claudeReportAccounts[session] = report.context.account
            let account = report.context.account
            let reports = claudeReports.filter { claudeReportAccounts[$0.key] == account }.map(\.value)
            let current = usage.claudeUsage(account: account)
            let resolved = ClaudeUsage(
                fiveHour: UsageWindow.resolve(
                    reports.compactMap { r in r.fiveHour.map { ReportedUsageWindow(window: $0, changedAt: r.changedAt) } }, current: current?.fiveHour, now: now),
                sevenDay: UsageWindow.resolve(
                    reports.compactMap { r in r.sevenDay.map { ReportedUsageWindow(window: $0, changedAt: r.changedAt) } }, current: current?.sevenDay, now: now),
                at: report.context.at)
            if let account {
                // 設定から消えたアカウントの報告は載せない（一覧は `setClaudeAccounts` が決める）
                if let index = next.claudeAccounts?.firstIndex(where: { $0.name == account }) { next.claudeAccounts?[index].usage = resolved }
            } else {
                next.claude = resolved
            }
        }
        // mod の報告は model と effort を運ばないので、statusline が前に送った値を残す
        let previous = next.contexts.first { $0.agentSessionID == report.context.agentSessionID }
        var context = report.context
        context.model = context.model ?? previous?.model
        context.effort = context.effort ?? previous?.effort
        context.account = context.account ?? previous?.account
        next.contexts.removeAll { $0.agentSessionID == report.context.agentSessionID || now.timeIntervalSince($0.at) > Self.contextTTL }
        next.contexts.append(context)
        next.contexts.sort { $0.agentSessionID < $1.agentSessionID }
        publish(next)
    }

    /// 別のマシンで受けた同じ名前のアカウントの枠。手元より新しいときだけ採る（無いアカウントは入れない）
    public func adopt(_ relay: ClaudeAccountUsageRelay) {
        guard let index = usage.claudeAccounts?.firstIndex(where: { $0.name == relay.account }) else { return }
        if let current = usage.claudeAccounts?[index].usage, current.at >= relay.usage.at { return }
        var next = usage
        next.claudeAccounts?[index].usage = relay.usage
        publish(next)
    }

    /// `claude-accounts.json` のアカウントと既定のアカウント。前から知っているアカウントの枠は残す。無ければ nil（前の版の daemon と同じ形）
    public func setClaudeAccounts(_ accounts: [ClaudeAccount], defaultAccount: String? = nil) {
        var next = usage
        next.claudeDefaultAccount = accounts.isEmpty ? nil : defaultAccount
        next.claudeAccounts = accounts.isEmpty ? nil : accounts.map { account in
            var account = account
            account.usage = usage.claudeAccounts?.first { $0.name == account.name }?.usage
            return account
        }
        publish(next)
    }

    /// 前に起きていた daemon が最後に知っていた枠（`ClaudeUsageFile`）を入れる。もう報告が届いた枠と、今の一覧に無いアカウントの枠は入れない
    public func restoreClaudeUsage(_ saved: ClaudeUsageFile.Contents) {
        var next = usage
        if next.claude == nil { next.claude = saved.login }
        if let accounts = next.claudeAccounts {
            next.claudeAccounts = accounts.map { account in
                var account = account
                if account.usage == nil { account.usage = saved.accounts[account.name] }
                return account
            }
        }
        publish(next)
    }

    public func setClaudeForecast(_ forecast: UsageForecast.Result?) {
        var next = usage
        next.claudeForecast = forecast
        publish(next)
    }

    public func setCodex(_ codex: CodexUsage?) {
        var next = usage
        next.codex = codex
        publish(next)
    }

    public func usageSnapshot() -> UsageSnapshot { usage }

    static let contextTTL = SessionContext.liveFor

    private func publish(_ next: UsageSnapshot) {
        let changed = Self.withoutTimes(next) != Self.withoutTimes(usage)
        usage = next
        if changed { broadcast(.usageUpdated(next)) }
    }

    private static func withoutTimes(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        var copy = snapshot
        copy.claude?.at = .distantPast
        copy.claudeAccounts = copy.claudeAccounts?.map { var a = $0; a.usage?.at = .distantPast; return a }
        copy.contexts = copy.contexts.map { var c = $0; c.at = .distantPast; return c }
        return copy
    }

    // MARK: リンクの状態（PR・Jira）

    /// 1 回の取得の結果。失敗は前回の値を残して `error` だけを替える
    public enum LinkFetch: Sendable, Equatable {
        case pullRequest(PullRequestLinkState)
        case jira(JiraLinkState)
        case devin(DevinLinkState)
        case failed(String)
    }

    /// まとめて入れて、取得の時刻以外が変わったときだけ 1 回配る。タスクに付いていない URL は捨てる（取得中にリンクが外れたとき）
    public func record(links results: [String: LinkFetch], at now: Date = Date()) {
        let urls = linkedURLs()
        var next = links
        for (url, fetch) in results where urls.contains(url) {
            var status = next[url] ?? LinkStatus(url: url, fetchedAt: now)
            switch fetch {
            case .pullRequest(let pr):
                status.pullRequest = pr
                status.error = nil
                status.fetchedAt = now
            case .jira(let issue):
                status.jira = issue
                status.error = nil
                status.fetchedAt = now
            case .devin(let session):
                status.devin = session
                status.error = nil
                status.fetchedAt = now
            case .failed(let reason):
                status.error = reason
            }
            next[url] = status
        }
        publish(links: next)
    }

    public func linkStatuses() -> [LinkStatus] { links.values.sorted { $0.url < $1.url } }

    /// 起動のときに控えを戻す。タスクに付いていない URL と、もう取り直した URL は入れない
    public func restore(links cached: [LinkStatus]) {
        let urls = linkedURLs()
        var next = links
        for status in cached where urls.contains(status.url) && next[status.url] == nil { next[status.url] = status }
        publish(links: next)
    }

    private func linkedURLs() -> Set<String> { Set(tasks.values.flatMap { $0.links.map(\.url) }) }

    /// タスクから外れたリンクを落とす
    private func pruneLinks() {
        let urls = linkedURLs()
        publish(links: links.filter { urls.contains($0.key) })
    }

    private func publish(links next: [String: LinkStatus]) {
        let changed = next.mapValues(Self.withoutTime) != links.mapValues(Self.withoutTime)
        links = next
        if changed { broadcast(.linksUpdated(linkStatuses())) }
    }

    private static func withoutTime(_ status: LinkStatus) -> LinkStatus {
        var copy = status
        copy.fetchedAt = .distantPast
        return copy
    }

    public func upsert(_ request: ReviewRequest) {
        reviewRequests[request.taskNumber] = request
        broadcast(.reviewRequestUpdated(request))
    }

    public func removeReviewRequest(task number: Int) {
        guard let removed = reviewRequests.removeValue(forKey: number) else { return }
        broadcast(.reviewRequestRemoved(removed.id))
    }

    public func document(id: Int64) -> Document? { documents[id] }

    // MARK: 起動

    /// 段階が進むたびに配る。`done` は配ってから一覧から消す（失敗は見せ続ける）。
    public func upsert(_ item: WorkItem) {
        workItems[item.itemID] = item
        broadcast(.workUpdated(item))
    }

    public func upsert(workItems updated: [WorkItem]) {
        for item in updated { upsert(item) }
    }

    /// タスクの作業項目を `items` にする（`StatePublisher`）。変わった項目だけを配り、無くなった項目は外す
    func replaceWorkItems(task number: Int, with items: [WorkItem]) {
        let kept = Set(items.map(\.itemID))
        for item in workItems.values where item.taskNumber == number && !kept.contains(item.itemID) { removeWorkItem(id: item.itemID) }
        for item in items where workItems[item.itemID] != item { upsert(item) }
    }

    public func removeWorkItem(id: Int64) {
        guard let removed = workItems.removeValue(forKey: id) else { return }
        broadcast(.workRemoved(removed.id))
    }

    public func task(number: Int) -> BoardTask? { tasks[number] }
    public func allTasks() -> [BoardTask] { tasks.values.sorted { $0.number < $1.number } }
    public func allBoards() -> [Board] { boards.values.sorted { $0.position < $1.position } }

    /// 起動の文のタスクの欄（`{{id}}`・`{{title}}` など）を埋める（端末の起動と会話の起動で同じ）。タスクが無ければそのまま
    func renderedPrompt(_ template: String, task number: Int?) -> String {
        guard let number, let task = tasks[number] else { return template }
        return PromptTemplate.render(template, task: task, board: boards[task.boardID])
    }

    public func upsert(_ board: Board) {
        boards[board.id] = board
        broadcast(.boardUpdated(board))
    }

    public func removeBoard(id: String) {
        boards.removeValue(forKey: id)
        broadcast(.boardRemoved(id))
    }

    public func upsert(_ task: BoardTask) {
        tasks[task.number] = task
        broadcast(.taskUpdated(task))
        pruneLinks()
    }

    public func upsert(tasks updated: [BoardTask]) {
        for task in updated { upsert(task) }
    }

    public func removeTask(number: Int) {
        guard let removed = tasks.removeValue(forKey: number) else { return }
        for item in workItems.values where item.taskNumber == number {
            workItems.removeValue(forKey: item.itemID)
        }
        for doc in documents.values where doc.taskNumber == number { documents.removeValue(forKey: doc.docID) }
        for ask in asks.values where ask.taskNumber == number { asks.removeValue(forKey: ask.askID) }
        // 予定と見張りの行はタスクと一緒に cascade で消える
        for wake in wakes.values where wake.taskNumber == number { wakes.removeValue(forKey: wake.wakeID) }
        for watch in watches.values where watch.taskNumber == number { watches.removeValue(forKey: watch.watchID) }
        panels.removeValue(forKey: number)
        reviewRequests.removeValue(forKey: number)
        broadcast(.taskRemoved(removed.id))
        pruneLinks()
    }

    // MARK: マシンの設定・オーケストレーター

    /// 変わったときだけ配る
    public func setSettings(_ next: MachineSettings) {
        guard next != settings else { return }
        settings = next
        broadcast(.settingsUpdated(next))
    }

    public func setOrchestrator(_ next: OrchestratorInfo) {
        guard next != orchestrator else { return }
        orchestrator = next
        broadcast(.orchestratorUpdated(next))
    }

    public func orchestratorInfo() -> OrchestratorInfo? { orchestrator }


    // MARK: 受信箱で消した項目

    /// 起動時は購読者がいないので、配っても誰にも届かない
    public func setInboxDismissals(_ records: [InboxDismissal]) {
        guard records != inboxDismissals else { return }
        inboxDismissals = records
        broadcast(.inboxDismissalsUpdated(records))
    }

    /// Store への書き込みと配信を actor の中で続けて行う。2 台の端末が同時に書いても、後に書いた側の記録が最後に配られる
    public func updateInboxDismissals(_ write: @Sendable () throws -> [InboxDismissal]) throws -> [InboxDismissal] {
        let records = try write()
        setInboxDismissals(records)
        return records
    }

    // MARK: host の会話

    /// 変わったときだけ配る
    public func upsert(_ conversation: Conversation) {
        guard conversations[conversation.id] != conversation else { return }
        conversations[conversation.id] = conversation
        broadcast(.conversationUpdated(conversation))
        // ターンの途中でプロセスが終わると、ツールの終わりは届かない
        if conversation.phase != .running && conversation.phase != .waiting { setToolActivity(id: conversation.id, toolName: nil) }
    }

    public func removeConversation(id: String) {
        toolActivities.removeValue(forKey: id)
        guard let removed = conversations.removeValue(forKey: id) else { return }
        broadcast(.conversationRemoved(removed.key))
    }

    /// 会話が使っているツール。変わったときだけ配る。載っていない会話の分は持たない
    public func setToolActivity(id: String, toolName: String?) {
        guard toolActivities[id] != toolName, toolName == nil || conversations[id] != nil else { return }
        toolActivities[id] = toolName
        broadcast(.conversationActivity(ConversationToolActivity(conversation: ConversationKey(machine: machine.id, id: id), toolName: toolName)))
    }

    public func allConversations() -> [Conversation] { conversations.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } }

    // MARK: ペアリングした端末

    /// `StateSnapshot` には載せない（設定画面が開いたときに `GET /v1/devices` で取る）
    public func publishDevices(_ devices: [DeviceInfo]) {
        broadcast(.devicesUpdated(devices.map { var d = $0; d.current = false; return d }))
    }

    /// 端末の設定の写し。これも `StateSnapshot` には載せない（アプリは自分の報告の応答と、この出来事で受ける）
    public func publishClientPrefs(_ prefs: ClientPrefs) {
        broadcast(.clientPrefsUpdated(prefs))
    }

    // MARK: 購読

    /// 変化の購読。返ってきた stream は、呼び出し側が終えたら `unsubscribe` する。
    public func subscribe() -> (UUID, AsyncStream<DaemonEvent>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DaemonEvent>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        subscribers[id] = continuation
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    var subscriberCount: Int { subscribers.count }

    /// `/v1/stream` を繋いだ。最初の 1 通（`hello` の番号の続きか、状態の全体）を `outbox` に積んでから登録する。
    /// 積むのと登録が同じ turn なので、以後の出来事は全部この後に積まれ、それより前の出来事は積まれない
    func openStream(epoch clientEpoch: String?, after: Int?, outbox: StreamOutbox) -> UUID {
        let id = UUID()
        if clientEpoch == epoch, let after, let frames = journal.frames(after: after),
            let resume = try? streamEncoder.encode(StreamServerFrame.resume(epoch: epoch, rev: after))
        {
            outbox.push(resume)
            for frame in frames where !outbox.push(frame) { break }
        } else if let state = try? streamEncoder.encode(StreamServerFrame.state(epoch: epoch, rev: journal.rev, snapshot: snapshot())) {
            outbox.push(state)
        } else {
            outbox.finish()
        }
        streams[id] = outbox
        return id
    }

    func closeStream(_ id: UUID) { streams.removeValue(forKey: id) }

    var streamCount: Int { streams.count }

    private func broadcast(_ event: DaemonEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
        let rev = journal.nextRev()
        if case .stateSnapshot(let snapshot) = event {
            // 状態の全体は控えに入れず、番号を振った `state` として送る。以後の続きはこの番号から
            journal.reset()
            guard !streams.isEmpty, let frame = try? streamEncoder.encode(StreamServerFrame.state(epoch: epoch, rev: rev, snapshot: snapshot)) else { return }
            push(frame)
            return
        }
        guard let frame = try? streamEncoder.encode(StreamServerFrame.event(rev: rev, event: event)) else { return }
        journal.append(frame)
        push(frame)
    }

    private func push(_ frame: Data) {
        for (id, outbox) in streams where !outbox.push(frame) {
            streams.removeValue(forKey: id)
        }
    }
}
