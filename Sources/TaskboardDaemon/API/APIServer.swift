import Foundation
import Hummingbird
import HummingbirdWSCompression
import HummingbirdWebSocket
import Logging
import NIOCore
import TaskboardKit

/// アプリ向けの HTTP + WebSocket API。loopback にだけ bind する。
public enum APIServer {
    public typealias App = Application<RouterResponder<TaskboardRequestContext>>

    public struct Dependencies: Sendable {
        /// nil なら `/v1/boards` `/v1/tasks` は 503。
        public var store: Store?
        /// nil なら `/v1/hooks/*` と `/v1/sessions/link` は 503。
        public var hooks: HookService?
        /// 見張りを作ったときに元の様子を取る
        var github: GitHubSync?
        /// nil なら `/v1/devin/*` は 503
        var devin: DevinSync?
        /// nil なら `/v1/boards/{id}/slack`・`/v1/slack/*` は 503
        var slack: SlackBridge?
        /// nil なら `/v1/feedback/*` は 503。
        public var feedback: FeedbackService?
        /// nil なら `/v1/schedules/*` は 503。
        public var scheduler: Scheduler?
        /// nil なら `/v1/prs/*` は 503。
        public var prs: PullRequestSync?
        /// 設定を変えたときに知らせる（常駐を切る・入れる）。nil なら知らせない
        public var orchestrator: OrchestratorKeeper?
        /// Claude Code の transcript の置き場（`/v1/chat/*` が読む）
        /// daemon は起動時に会話と同じログインシェルの環境で決めて入れる（`ConversationService.transcriptProjects`）
        public var transcripts: URL = ClaudeConfigDirectory.projects(environment: [:])
        /// nil なら APNs に送らない（登録の応答は `delivering: false`、`/v1/push/test` は 503）
        public var push: PushService?
        /// nil なら会話の添付（`/v1/conversations/{id}/attachments`）は 503
        public var attachments: AttachmentStore?
        /// nil なら `/v1/conversations/*` は 503
        public var conversations: ConversationService?
        /// nil なら `/v1/conversations/search` は 503
        var conversationSearch: ConversationSearchIndex?
        /// nil なら `/v1/worktrees*` は 503
        var worktrees: WorktreeCleaner?
        /// nil なら `/v1/codex/*` は 503
        var codex: CodexMachine?
        /// nil なら command の見張りを作れない（503）
        var commandWatcher: CommandWatcher?
        /// 端末の token の認証と、端末の WebSocket の登録。起動時に `device` 表を `load` する
        var deviceAuth = DeviceAuth()
        var pairings = PairingRegistry()
        /// 端末から届いた止まりの記録の重複と上限
        var diagnostics = AppDiagnosticsGate()
        /// テスト用: 端末の WebSocket が `register` を呼ぶ直前（upgrade の判定の後）に呼ぶ
        var socketWillRegister: (@Sendable () async -> Void)?

        public init() {}
    }

    public static func application(
        state: DaemonState, token: String, host: String = "127.0.0.1", port: Int, dependencies: Dependencies
    ) -> App {
        let router = Router(context: TaskboardRequestContext.self)
        let encoder = WireJSON.encoder()
        let logger = {
            var logger = Logger(label: "uk.whatn.taskboardd.api")
            logger.logLevel = .info
            return logger
        }()
        router.get("/v1/health") { _, _ in
            let machine = await state.machineInfo()
            return try json(HealthInfo(ok: true, daemonVersion: machine.daemonVersion, machineID: machine.id), encoder)
        }

        // 認証の外（Access の内側）。一度きりのコードで端末の token を出す
        registerPairRoute(router, state: state, dependencies: dependencies, encoder: encoder, logger: logger)

        let authenticator = Authenticator(token: token, devices: dependencies.deviceAuth, store: dependencies.store, logger: logger)
        let v1 = router.group("v1").add(middleware: authenticator)
        if let store = dependencies.store { v1.add(middleware: StateSettled(publisher: store.statePublisher(state: state))) }
        // 端末の token では 403。アプリが使わない経路（端末を増やす経路は Mac の端末に通すので、ここに置かない）
        let daemonOnly = v1.group().add(middleware: DaemonTokenOnly())
        // 認証に落ちた upgrade も通し、handler が 101 の後に 4401 で閉じる（`Authenticator` の説明）
        var socketAuthenticator = authenticator
        socketAuthenticator.upgradeUnauthenticated = true
        let sockets = router.group("v1").add(middleware: socketAuthenticator)

        registerDeviceRoutes(v1: v1, daemonOnly: daemonOnly, state: state, dependencies: dependencies, encoder: encoder, logger: logger)
        registerPushRoutes(v1: v1, daemonOnly: daemonOnly, state: state, dependencies: dependencies, encoder: encoder, logger: logger)
        registerDiagnosticsRoutes(v1: v1, dependencies: dependencies, encoder: encoder, logger: logger)
        registerInboxRoutes(v1: v1, state: state, dependencies: dependencies, encoder: encoder)
        registerChatFileRoutes(v1: v1, dependencies: dependencies, logger: logger)
        registerSessionLinkRoutes(v1: v1, state: state, dependencies: dependencies, encoder: encoder)
        registerConversationRoutes(v1: v1, daemonOnly: daemonOnly, dependencies: dependencies, encoder: encoder, logger: logger)
        registerConversationSocket(sockets: sockets, dependencies: dependencies, encoder: encoder)

        v1.get("state") { _, _ in
            try json(await state.snapshot(), encoder)
        }

        registerBoardRoutes(v1: v1, daemonOnly: daemonOnly, state: state, dependencies: dependencies, encoder: encoder)
        registerDevinRoutes(v1: v1, dependencies: dependencies, encoder: encoder)
        registerSlackRoutes(v1: v1, daemonOnly: daemonOnly, dependencies: dependencies, encoder: encoder)
        registerClientPrefsRoutes(v1: v1, state: state, dependencies: dependencies, encoder: encoder)
        registerSessionRoutes(v1: v1, state: state, dependencies: dependencies, encoder: encoder)
        registerScheduleRoutes(v1: v1, state: state, dependencies: dependencies, encoder: encoder)
        registerWorkdirRoutes(v1: v1, daemonOnly: daemonOnly, state: state, dependencies: dependencies, encoder: encoder)
        registerPullRequestRoutes(v1: v1, dependencies: dependencies, encoder: encoder)
        registerCodexRoutes(v1: v1, dependencies: dependencies, encoder: encoder)
        registerWorktreeRoutes(v1: v1, dependencies: dependencies, encoder: encoder)
        registerDocumentRoutes(v1: v1, daemonOnly: daemonOnly, state: state, dependencies: dependencies, encoder: encoder)
        registerPanelRoutes(v1: v1, state: state, dependencies: dependencies, encoder: encoder)
        registerPaneRoutes(v1: v1, daemonOnly: daemonOnly, state: state, dependencies: dependencies, encoder: encoder)
        registerSockets(sockets: sockets, state: state, dependencies: dependencies, encoder: encoder, logger: logger)

        return Application(
            router: router,
            // 1 通の上限の既定（16KB）では、端末に 12KB ほどを貼っただけで接続が切れる（base64 と JSON で膨らむ）。
            // 圧縮はアプリ（URLSession）が申し出たときだけ効く。展開した 1 通の上限も 1 通の上限に揃える（既定の 16KB では貼り付けで切れる）
            server: .http1WebSocketUpgrade(
                webSocketRouter: router,
                configuration: .init(
                    ws: .init(
                        maxFrameSize: webSocketFrameLimit,
                        extensions: [.perMessageDeflate(maxDecompressedFrameSize: webSocketFrameLimit, minFrameSizeToCompress: webSocketCompressFrom)]))),
            configuration: .init(address: .hostname(host, port: port), serverName: "taskboardd"),
            logger: logger
        )
    }

    static let webSocketFrameLimit = 1 << 20
    /// これより小さい 1 通は圧縮しない（端末のキー入力とその応答の遅れを増やさない）
    static let webSocketCompressFrom = 512

    static func json<T: Encodable>(_ value: T, _ encoder: JSONEncoder) throws -> Response {
        let data = try encoder.encode(value)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

/// handler が Store に書いた分を state に入れ終えてから応答を返す（アプリには `task.updated` などの知らせが応答より先に届く）
struct StateSettled: RouterMiddleware {
    typealias Context = TaskboardRequestContext

    let publisher: StatePublisher

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            let response = try await next(request, context)
            await publisher.settled()
            return response
        } catch {
            // 書いてから失敗した handler もある
            await publisher.settled()
            throw error
        }
    }
}
