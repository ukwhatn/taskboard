import Foundation
import Logging
import TaskboardKit

public struct DaemonConfiguration: Sendable {
    public var port: Int
    public var supportDirectory: URL?
    public var machineName: String?

    public init(port: Int = DaemonEndpoint.defaultPort, supportDirectory: URL? = nil, machineName: String? = nil) {
        self.port = port
        self.supportDirectory = supportDirectory
        self.machineName = machineName
    }
}

public enum Daemon {
    public static let version = "0.1.0"

    /// API と見回りを並走させる。どれかが終わったら全体を止める。
    public static func run(_ config: DaemonConfiguration) async throws {
        let logger = Logger(label: "uk.whatn.taskboardd")
        let paths = try Paths(directory: config.supportDirectory)
        let token = try paths.loadOrCreateToken()
        let machineID = try paths.loadOrCreateMachineID()
        let name = config.machineName ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let state = DaemonState(
            machine: MachineInfo(id: machineID, name: name, daemonVersion: version))
        let store = try Store(databaseURL: paths.databaseFile, backupDirectory: paths.backupDirectory, machineID: machineID)
        await state.load(
            boards: try store.boards(), tasks: try store.tasks(), workItems: try store.workItems(),
            documents: try store.documents(), asks: try store.asks(pending: true), reviewRequests: try store.reviewRequests())
        for schedule in try store.schedules() { await state.upsert(schedule) }
        for wake in try store.wakes() { await state.upsert(wake) }
        for watch in try store.watches() { await state.upsert(watch) }
        for panel in try store.panels() { await state.upsert(panel) }
        await state.setSettings(try store.settings())
        await state.setInboxDismissals(try store.inboxDismissals())
        do { await state.restore(links: try store.cachedLinkStatuses()) } catch {
            logger.warning("link status cache unreadable", metadata: ["error": .string(String(describing: error))])
        }
        // 配った一覧を控えに残す（取得の時刻だけが変わったときは配らないので、書くのは中身が変わったときだけ）
        let (_, linkEvents) = await state.subscribe()
        Task {
            for await event in linkEvents {
                guard case .linksUpdated(let statuses) = event else { continue }
                do { try store.saveLinkStatuses(statuses) } catch {
                    logger.warning("link status cache not saved", metadata: ["error": .string(String(describing: error))])
                }
            }
        }
        // ここから先の Store の書き込みは、この受け手が state に入れる
        _ = store.statePublisher(state: state)
        var dependencies = APIServer.Dependencies()
        dependencies.store = store
        await dependencies.deviceAuth.load(try store.devices())
        let cli = GitHubCLI(accountsFile: paths.githubAccountsFile)
        let github = GitHubSync(store: store, state: state, cli: cli)
        let jira = JiraSync(store: store, state: state, configFile: paths.jiraConfigFile)
        let devin = DevinSync(store: store, state: state, configFile: paths.devinConfigFile)
        dependencies.devin = devin
        let prs = PullRequestSync(store: store, state: state, cli: cli, machine: machineID)
        await prs.loadCache()
        dependencies.prs = prs
        let feedback = FeedbackService(store: store, state: state, markers: FeedbackMarkers(directory: paths.feedbackPendingDirectory))
        dependencies.feedback = feedback
        dependencies.hooks = HookService(store: store, state: state, github: github, feedback: feedback)
        dependencies.github = github
        // 同じ Claude の会話を 2 つの会話で同時に戻さない
        let reservations = SessionReservations()
        let accounts = ClaudeAccounts(supportDirectory: paths.directory, state: state)
        await accounts.reload()
        let usageFile = ClaudeUsageFile(supportDirectory: paths.directory)
        await state.restoreClaudeUsage(usageFile.load(now: Date()))
        let push = PushService(store: store, sender: APNsSender(keys: APNsKeyStore(directory: paths.apnsDirectory)))
        dependencies.push = push
        let attachments = AttachmentStore(directory: paths.attachmentsDirectory)
        attachments.purge()
        dependencies.attachments = attachments
        let conversations = ConversationService(
            .init(
                machine: machineID, store: store, state: state, supportDirectory: paths.directory, reservations: reservations, hooks: dependencies.hooks,
                attachments: attachments, accounts: accounts, daemon: DaemonLocation(port: config.port, supportDirectory: paths.directory.path),
                polishDictation: { launch, request in try await ClaudeDictationPolish.run(launch, request, timeout: .seconds(20)) }))
        dependencies.conversations = conversations
        dependencies.worktrees = .live(store: store, conversations: conversations)
        // transcript は、会話と同じくログインシェルの環境の CLAUDE_CONFIG_DIR で引く
        let transcripts = await conversations.transcriptProjects()
        dependencies.transcripts = transcripts
        await conversations.publishAll()
        let scheduler = Scheduler(store: store, state: state, conversations: conversations, accounts: accounts)
        dependencies.scheduler = scheduler
        let keeper = OrchestratorKeeper(store: store, state: state, conversations: conversations)
        dependencies.orchestrator = keeper
        let notices = ConversationNotices(conversations: conversations, state: state)
        let wakes = WakeService(store: store, state: state, conversations: conversations)
        let slack = SlackBridge(store: store, state: state, settings: SlackSettingsStore(directory: paths.slackDirectory), conversations: conversations)
        dependencies.slack = slack
        let linkNotices = LinkNotices(store: store, state: state, conversations: conversations)
        await github.onNotices { [linkNotices] numbers in await linkNotices.noticesRecorded(numbers) }
        await devin.onNotices { [linkNotices] numbers in await linkNotices.noticesRecorded(numbers) }
        let watchNotices = WatchNotices(store: store, state: state, conversations: conversations)
        await github.onWatchEvents { [watchNotices] ids in await watchNotices.eventsRecorded(ids) }
        let commandWatcher = CommandWatcher(store: store) { await conversations.loginShellEnvironment(forLaunch: true) }
        await commandWatcher.onEvents { [watchNotices] ids in await watchNotices.eventsRecorded(ids) }
        dependencies.commandWatcher = commandWatcher
        let codex = CodexMachine(state: state, launch: CodexAppServerProcess.launcher())
        dependencies.codex = codex
        let versions = AgentKind.allCases.map { CLIVersionWatcher(engine: $0, supportDirectory: paths.directory, slots: conversations.slots, state: state) }
        await feedback.setConversations(conversations)
        await conversations.onIdle { [feedback] id in await feedback.conversationIdle(id) }
        await conversations.onIdle { [notices] id in await notices.conversationIdle(id) }
        await conversations.onIdle { [keeper] id in await keeper.conversationIdle(id) }
        await conversations.onIdle { [linkNotices] id in await linkNotices.conversationIdle(id) }
        await conversations.onIdle { [wakes] id in await wakes.conversationIdle(id) }
        await conversations.onIdle { [watchNotices] id in await watchNotices.conversationIdle(id) }
        await conversations.onIdle { [prs] id in await prs.conversationSettled(id) }
        await conversations.onClose { [prs] id in await prs.conversationSettled(id) }
        // 書いた会話が終われば、その会話が出していた状態は誰も更新しない
        await conversations.onClose { [store] id in _ = try? store.clearStatuses(writtenBy: id) }
        let search = ConversationSearchIndex(
            store: store,
            sources: .init(
                segments: { record in await conversations.transcriptSegments(record) },
                codexHistory: { record, before in try await conversations.history(record.id, before: before, limit: ConversationHistoryResponse.maxLimit) }))
        dependencies.conversationSearch = search
        await conversations.onIdle { [search] id in await search.conversationIdle(id) }
        await conversations.onNotice { [notices] id in await notices.deliver(id) }
        let notifier = PushNotifier(state: state, push: push)
        let usageRecorder = UsageRecorder(store: store, state: state) { [transcripts] in
            let environment = await LoginShellEnvironment.capture(shell: LoginShell.path ?? "/bin/zsh") ?? [:]
            return UsageRecorder.Roots(claudeProjects: transcripts, codexSessions: CodexHome.url(environment: environment).appending(path: "sessions"))
        }
        let reaper = IdleReaper(store: store, conversations: conversations)
        let scheduledCloser = ScheduledRunCloser(store: store, state: state, conversations: conversations)
        if reaper.overrideSeconds != nil {
            logger.notice("idle stop overridden", metadata: ["seconds": .stringConvertible(reaper.overrideSeconds ?? 0), "env": .string(IdleReaper.environmentKey)])
        }
        let app = APIServer.application(state: state, token: token, port: config.port, dependencies: dependencies)
        logger.info(
            "taskboardd starting",
            metadata: [
                "version": .string(version), "machine": .string(machineID.rawValue), "port": .stringConvertible(config.port),
                "database": .string(paths.databaseFile.path),
            ])

        // launchd の停止（SIGTERM）：会話のコードブロックの Run の子を止めてから終わる（既定の動きでは daemon だけが終わり、子が残る）
        // SIG_IGN にすると、daemon が起こす git・gh にも無視が引き継がれる。何もしない handler なら exec で既定に戻る
        signal(SIGTERM) { _ in }
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let shutdown: @Sendable () async -> Void = {
            await conversations.shutdown()
            await codex.shutdown()
            await commandWatcher.shutdown()
        }
        termination.setEventHandler {
            Task {
                logger.notice("taskboardd stopping")
                await shutdown()
                exit(0)
            }
        }
        termination.resume()
        defer { termination.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.runService() }
            group.addTask { await github.run() }
            group.addTask { await jira.run() }
            group.addTask { await devin.run() }
            group.addTask { await slack.run() }
            group.addTask { await prs.run() }
            group.addTask { await codex.run() }
            group.addTask { await scheduler.run() }
            group.addTask { await keeper.run() }
            group.addTask { await reaper.run() }
            group.addTask { await usageRecorder.run() }
            group.addTask { await usageFile.run(state: state) }
            group.addTask { await scheduledCloser.run() }
            group.addTask { await notifier.run() }
            group.addTask { await feedback.run() }
            group.addTask { await conversations.run() }
            group.addTask { await conversations.runUsageLimitResumes() }
            group.addTask { await conversations.runNetworkResumes() }
            group.addTask { await conversations.runIdleCompactions() }
            group.addTask(priority: .background) { await search.run() }
            group.addTask { await notices.run() }
            group.addTask { await linkNotices.run() }
            group.addTask { await wakes.run() }
            group.addTask { await watchNotices.run() }
            group.addTask { await commandWatcher.run() }
            // launchd の外で動かすと見張る先が無く、すぐ戻る。戻った子は daemon を畳むので足さない
            if !LaunchdJobRepair.peerLabels.isEmpty { group.addTask { await LaunchdJobRepair.watch(LaunchdJobRepair.peerLabels, logger: logger) } }
            for watcher in versions { group.addTask { await watcher.run() } }
            _ = try await group.next()
            group.cancelAll()
        }
        await shutdown()
    }

    /// 同一マシンのアプリや CLI が使う接続先（token ファイルから）。
    public static func localEndpoint(port: Int = DaemonEndpoint.defaultPort, supportDirectory: URL? = nil) throws -> DaemonEndpoint {
        let paths = try Paths(directory: supportDirectory)
        return .local(port: port, token: try paths.loadOrCreateToken())
    }
}
