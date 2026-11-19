import Foundation

/// Cloudflare Access の service token。リモートの daemon（tunnel 越し）に繋ぐときだけ使う
public struct AccessCredential: Codable, Hashable, Sendable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

/// daemon の接続先。同一 Mac なら `http://127.0.0.1:5780` と token ファイルの中身。
public struct DaemonEndpoint: Hashable, Sendable {
    public var baseURL: URL
    public var token: String
    public var access: AccessCredential?

    public init(baseURL: URL, token: String, access: AccessCredential? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.access = access
    }

    public static let defaultPort = 5780

    public static func local(port: Int = defaultPort, token: String) -> DaemonEndpoint {
        DaemonEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token)
    }
}

/// 会話を起こした daemon の port と support ディレクトリ。daemon は起こす会話の環境に入れ、会話の中の `taskboard mcp`・`taskboard hook` はこれで同じ daemon に繋ぐ
/// （入れないと、一時の support ディレクトリの daemon が起こした会話も既定の 5780 の daemon に繋ぐ）
public struct DaemonLocation: Equatable, Sendable {
    public static let portVariable = "TASKBOARD_DAEMON_PORT"
    public static let supportDirectoryVariable = "TASKBOARD_SUPPORT_DIR"

    public var port: Int
    public var supportDirectory: String

    public init(port: Int, supportDirectory: String) {
        self.port = port
        self.supportDirectory = supportDirectory
    }

    /// 環境に両方そろっていて port が数のときだけ
    public init?(environment: [String: String]) {
        guard let port = environment[Self.portVariable].flatMap(Int.init), (1...65535).contains(port),
            let directory = environment[Self.supportDirectoryVariable], !directory.isEmpty
        else { return nil }
        self.init(port: port, supportDirectory: directory)
    }

    public var environment: [String: String] {
        [Self.portVariable: String(port), Self.supportDirectoryVariable: supportDirectory]
    }
}

/// daemon の HTTP + WebSocket クライアント。
public final class DaemonClient: SessionSource, DaemonWriter, UsageHistorySource, ConversationSearchSource, Sendable {
    public let endpoint: DaemonEndpoint
    let session: URLSession

    /// Cookie を持たない。Access の `CF_Authorization` が共有されると、取り消したサービストークンや
    /// 別の接続先の偽のトークンでも Cookie が切れるまで通ってしまう。サービストークンは毎回ヘッダで送る
    public static let cookieless: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    public init(endpoint: DaemonEndpoint, session: URLSession = DaemonClient.cookieless) {
        self.endpoint = endpoint
        self.session = session
    }

    public func snapshot() async throws -> StateSnapshot {
        try await get("/v1/state")
    }

    public func health() async throws -> HealthInfo {
        try await get("/v1/health", authorized: false)
    }

    /// `/v1/stream` の 1 本の接続
    public func openStream() -> DaemonStreamConnection {
        DaemonStreamConnection(task: session.webSocketTask(with: request(for: "/v1/stream", websocket: true))) { [self] task in
            if let failure = upgradeError(task) { return failure }
            if let http = task.response as? HTTPURLResponse, http.statusCode != 101 { return SessionSourceError.httpStatus(http.statusCode) }
            return nil
        }
    }

    public func openTerminal(pane: PaneID, cols: Int, rows: Int) -> TerminalConnection {
        let req = request(
            for: "/v1/terminal/\(pane.rawValue)", websocket: true,
            query: [URLQueryItem(name: "cols", value: String(cols)), URLQueryItem(name: "rows", value: String(rows))])
        return TerminalConnection(task: session.webSocketTask(with: req))
    }


    public func boards() async throws -> [Board] {
        try await get("/v1/boards")
    }

    public func createBoard(_ body: BoardCreateRequest) async throws -> Board {
        try await send("POST", "/v1/boards", body)
    }

    public func createTask(_ body: TaskCreateRequest) async throws -> BoardTask {
        try await send("POST", "/v1/tasks", body)
    }

    public func updateTask(number: Int, _ body: TaskUpdateRequest) async throws -> BoardTask {
        try await send("PATCH", "/v1/tasks/\(number)", body)
    }

    public func deleteTask(number: Int) async throws {
        try await delete("/v1/tasks/\(number)")
    }

    public func workItems(task: Int) async throws -> [WorkItem] {
        try await get("/v1/tasks/\(task)/work")
    }

    public func createWorkItem(task: Int, _ body: WorkItemCreateRequest) async throws -> WorkItem {
        try await send("POST", "/v1/tasks/\(task)/work", body)
    }

    public func updateWorkItem(id: Int64, _ body: WorkItemUpdateRequest) async throws -> WorkItem {
        try await send("PATCH", "/v1/work/\(id)", body)
    }

    public func deleteWorkItem(id: Int64) async throws {
        try await delete("/v1/work/\(id)")
    }

    public func finishManualWork(id: Int64) async throws {
        try await postNoContent("/v1/work/\(id)/finish", EmptyBody())
    }

    /// タスクの概況と、紐づけた部品の今の値
    public func panel(task: Int) async throws -> PanelReadResult {
        try await get("/v1/tasks/\(task)/panel")
    }

    public func setPanel(task: Int, _ body: PanelSetRequest) async throws -> PanelWriteResult {
        try await send("PUT", "/v1/tasks/\(task)/panel", body)
    }

    public func updatePanelPart(task: Int, _ body: PanelUpdateRequest) async throws -> PanelWriteResult {
        try await send("POST", "/v1/tasks/\(task)/panel/parts", body)
    }

    /// 送る文面の［承認］。承認と本文は登録した会話に届く
    public func approvePanelDraft(task: Int, part: String, body: String) async throws -> OverviewPanel {
        let id = part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? part
        return try await send("POST", "/v1/tasks/\(task)/panel/parts/\(id)/approve", PanelDraftApproveRequest(body: body))
    }

    /// 文書の送る文面の［承認］。承認と本文は publish した会話に届く
    public func approveDocDraft(doc: Int64, draft: String, body: String) async throws -> Document {
        let id = draft.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? draft
        return try await send("POST", "/v1/docs/\(doc)/drafts/\(id)/approve", PanelDraftApproveRequest(body: body))
    }

    public func workingDirectories() async throws -> WorkingDirectories {
        try await get("/v1/workdirs")
    }

    public func completeWorkingDirectory(_ prefix: String) async throws -> [String] {
        let (data, response) = try await session.data(for: request(for: "/v1/workdirs/complete", query: [URLQueryItem(name: "prefix", value: prefix)]))
        return try decode(data, response)
    }

    public func slashCommands(cwd: String?) async throws -> [SlashCommand] {
        let (data, response) = try await session.data(for: request(for: "/v1/commands", query: cwd.map { [URLQueryItem(name: "cwd", value: $0)] } ?? []))
        return try decode(data, response)
    }

    public func addWorkdirBookmark(path: String) async throws -> WorkdirBookmark {
        try await send("POST", "/v1/workdirs/bookmarks", WorkdirBookmarkRequest(path: path))
    }

    public func deleteWorkdirBookmark(id: Int64) async throws {
        try await delete("/v1/workdirs/bookmarks/\(id)")
    }

    public func worktrees() async throws -> [WorktreeInfo] {
        let response: WorktreeListResponse = try await get("/v1/worktrees")
        return response.worktrees
    }

    public func removeWorktrees(paths: [String]) async throws -> [WorktreeRemoveResult] {
        let response: WorktreeRemoveResponse = try await send("POST", "/v1/worktrees/remove", WorktreeRemoveRequest(paths: paths))
        return response.results
    }

    public func inboxDismissals() async throws -> [InboxDismissal] {
        try await get("/v1/inbox/dismissals")
    }

    public func dismissInbox(_ items: [InboxDismissRequest.Item]) async throws -> [InboxDismissal] {
        try await send("POST", "/v1/inbox/dismiss", InboxDismissRequest(items: items))
    }

    public func restoreInbox(itemIDs: [String]) async throws -> [InboxDismissal] {
        try await send("POST", "/v1/inbox/restore", InboxRestoreRequest(itemIDs: itemIDs))
    }

    public func schedules() async throws -> [Schedule] {
        try await get("/v1/schedules")
    }

    public func createSchedule(_ body: ScheduleCreateRequest) async throws -> Schedule {
        try await send("POST", "/v1/schedules", body)
    }

    public func updateSchedule(id: Int64, _ body: ScheduleUpdateRequest) async throws -> Schedule {
        try await send("PATCH", "/v1/schedules/\(id)", body)
    }

    public func deleteSchedule(id: Int64) async throws {
        try await delete("/v1/schedules/\(id)")
    }

    public func scheduleRuns(id: Int64) async throws -> [ScheduleRun] {
        try await get("/v1/schedules/\(id)/runs")
    }

    /// 「今すぐ実行」
    public func runSchedule(id: Int64) async throws -> ScheduleRun {
        try await send("POST", "/v1/schedules/\(id)/run", [String: String]())
    }

    public func wakes() async throws -> [Wake] {
        try await get("/v1/wakes")
    }

    public func createWake(_ body: WakeCreateRequest) async throws -> Wake {
        try await send("POST", "/v1/wakes", body)
    }

    public func cancelWake(id: Int64) async throws -> Wake {
        try await send("POST", "/v1/wakes/\(id)/cancel", [String: String]())
    }

    public func watches() async throws -> [Watch] {
        try await get("/v1/watches")
    }

    public func createWatch(_ body: WatchCreateRequest) async throws -> WatchCreated {
        try await send("POST", "/v1/watches", body)
    }

    public func startDevin(_ body: DevinStartRequest) async throws -> DevinStarted {
        try await send("POST", "/v1/devin/sessions", body)
    }

    public func devinSession(id: String) async throws -> DevinSessionDetail {
        try await get("/v1/devin/sessions/\(id)")
    }

    public func messageDevin(id: String, _ body: DevinMessageRequest) async throws -> DevinMessageSent {
        try await send("POST", "/v1/devin/sessions/\(id)/message", body)
    }

    public func cancelWatch(id: Int64) async throws -> Watch {
        try await send("POST", "/v1/watches/\(id)/cancel", [String: String]())
    }



    public func orchestrator() async throws -> OrchestratorInfo {
        try await get("/v1/orchestrator")
    }

    public func startOrchestrator(_ request: LaunchRequest) async throws -> OrchestratorInfo {
        try await send("POST", "/v1/orchestrator/start", request)
    }

    public func promptOrchestrator(_ text: String) async throws -> OrchestratorInfo {
        try await send("POST", "/v1/orchestrator/prompt", OrchestratorPromptRequest(text: text))
    }

    public func restartOrchestrator() async throws -> OrchestratorInfo {
        try await send("POST", "/v1/orchestrator/restart", OrchestratorRestartRequest())
    }

    // MARK: マシンの設定・セッションの停止と再開

    public func settings() async throws -> MachineSettings {
        try await get("/v1/settings")
    }

    public func updateSettings(_ body: MachineSettingsUpdate) async throws -> MachineSettings {
        try await send("PATCH", "/v1/settings", body)
    }

    /// ペアリングコードを作る（daemon の token だけ。端末の token は 403）
    public func createPairing() async throws -> PairingCode {
        try await send("POST", "/v1/pairings", EmptyBody())
    }

    /// QR・コードで受け取った接続先に、端末の token を発行してもらう。daemon の token は持たないので送らない
    public static func pair(_ body: PairRequest, url: URL, access: AccessCredential?, session: URLSession = DaemonClient.cookieless) async throws -> PairResponse {
        let client = DaemonClient(endpoint: DaemonEndpoint(baseURL: url, token: "", access: access), session: session)
        return try await client.send("POST", "/v1/pair", body, authorized: false)
    }

    public func devices() async throws -> [DeviceInfo] {
        try await get("/v1/devices")
    }

    /// 端末を止める。端末の token で呼べるのは自分だけ
    public func revokeDevice(_ id: String) async throws {
        try await delete("/v1/devices/\(id)")
    }

    /// APNs のトークンと通知の設定を預ける（端末の token だけ）。daemon に鍵が無ければ `delivering` が false
    public func registerPush(_ body: PushRegistration) async throws -> PushRegistrationResponse {
        try await send("PUT", "/v1/devices/current/push", body)
    }

    /// 預けたトークンを消す（端末の token だけ）。以後この端末には送らない
    public func unregisterPush() async throws {
        try await delete("/v1/devices/current/push")
    }

    /// 主スレッドの止まりの記録を daemon のログに残す（端末の token だけ）
    public func sendDiagnostics(_ body: AppDiagnosticsUpload) async throws -> AppDiagnosticsResult {
        try await send("POST", "/v1/devices/current/diagnostics", body)
    }

    /// 登録のある全端末にテストの通知を送る（daemon の token だけ）
    public func testPush() async throws -> [PushTestResult] {
        try await send("POST", "/v1/push/test", EmptyBody())
    }


    /// タスクに紐づく止まったセッションを同じ会話で起こす。進み具合は `launch.progress`
    public func resumeSession(task: Int, _ body: SessionResumeRequest) async throws -> SessionResumeResult {
        try await send("POST", "/v1/tasks/\(task)/sessions/resume", body)
    }

    /// セッション（pane か host の会話）の Claude Code のアカウントを替える（`POST /v1/sessions/account`）
    public func switchAccount(_ body: SessionAccountRequest) async throws -> SessionResumeResult {
        try await send("POST", "/v1/sessions/account", body)
    }


    public func updateBoard(id: String, _ body: BoardUpdateRequest) async throws -> Board {
        try await send("PATCH", "/v1/boards/\(id)", body)
    }

    /// タスクが 0 件で、ほかに使える案件があるときだけ消える（それ以外は 409）
    public func deleteBoard(id: String) async throws {
        try await delete("/v1/boards/\(id)")
    }

    // MARK: Slack

    public func boardSlack(id: String) async throws -> BoardSlack {
        try await get("/v1/boards/\(id)/slack")
    }

    public func updateBoardSlack(id: String, _ body: BoardSlackUpdate) async throws -> BoardSlack {
        try await send("PUT", "/v1/boards/\(id)/slack", body)
    }

    /// token と設定を消して接続を切る
    public func deleteBoardSlack(id: String) async throws {
        try await delete("/v1/boards/\(id)/slack")
    }

    public func slackChannels(board id: String) async throws -> [SlackChannel] {
        try await get("/v1/boards/\(id)/slack/channels")
    }

    /// 受けた依頼の本文・転送されたメッセージ・スレッド（`slack_get`）
    public func slackRequest(_ id: Int64) async throws -> SlackRequestDetail {
        try await get("/v1/slack/requests/\(id)")
    }

    /// 受けた依頼のスレッドに返す（`slack_reply`）
    public func replySlack(request id: Int64, text: String, status: SlackRequestStatus? = nil) async throws -> SlackReplyResult {
        try await send("POST", "/v1/slack/requests/\(id)/reply", SlackReplyRequest(text: text, status: status))
    }

    // MARK: 文書・質問・レビュー

    public func documents(task: Int) async throws -> [Document] {
        try await get("/v1/tasks/\(task)/docs")
    }

    public func publishDocument(task: Int, _ body: DocPublishRequest) async throws -> DocPublishResponse {
        try await send("POST", "/v1/tasks/\(task)/docs", body)
    }

    public func attachQuestions(doc id: Int64, _ body: DocAskRequest) async throws -> DocPublishResponse {
        try await send("POST", "/v1/docs/\(id)/asks", body)
    }

    public func deleteDocument(id: Int64) async throws {
        try await delete("/v1/docs/\(id)")
    }

    public func documentRevisions(id: Int64) async throws -> [DocRevision] {
        try await get("/v1/docs/\(id)/revisions")
    }

    public func documentContent(id: Int64, rev: Int?) async throws -> DocContent {
        let query = rev.map { [URLQueryItem(name: "rev", value: String($0))] } ?? []
        let (data, response) = try await session.data(for: request(for: "/v1/docs/\(id)/content", query: query))
        return try decode(data, response)
    }

    public func documentSourceFile(id: Int64) async throws -> DocSourceFile {
        try await get("/v1/docs/\(id)/source")
    }

    public func comments(doc id: Int64) async throws -> [DocComment] {
        try await get("/v1/docs/\(id)/comments")
    }

    public func createComment(doc id: Int64, _ body: CommentCreateRequest) async throws -> DocComment {
        try await send("POST", "/v1/docs/\(id)/comments", body)
    }

    public func updateComment(id: Int64, _ body: CommentUpdateRequest) async throws -> DocComment {
        try await send("PATCH", "/v1/comments/\(id)", body)
    }

    public func deleteComment(id: Int64) async throws {
        try await delete("/v1/comments/\(id)")
    }

    public func replyComment(id: Int64, _ body: CommentReplyRequest) async throws -> CommentReply {
        try await send("POST", "/v1/comments/\(id)/reply", body)
    }

    public func resolveComment(id: Int64, resolved: Bool) async throws -> DocComment {
        try await send("POST", "/v1/comments/\(id)/\(resolved ? "resolve" : "reopen")", EmptyBody())
    }

    public func sessionHistory(task: Int) async throws -> [SessionHistory] {
        try await get("/v1/tasks/\(task)/sessions/history")
    }

    public func reviewDraft(task: Int) async throws -> ReviewDraft {
        try await get("/v1/tasks/\(task)/review")
    }

    public func setReviewSummary(task: Int, _ body: ReviewSummaryRequest) async throws -> Review {
        try await send("PATCH", "/v1/tasks/\(task)/review", body)
    }

    public func submitReview(task: Int) async throws -> Review {
        try await send("POST", "/v1/tasks/\(task)/review/submit", EmptyBody())
    }

    public func requestReview(task: Int, _ body: ReviewRequestCreate) async throws -> ReviewRequestResult {
        try await send("POST", "/v1/tasks/\(task)/review-request", body)
    }

    public func asks(task: Int) async throws -> [Ask] {
        try await get("/v1/tasks/\(task)/asks")
    }

    /// リンクの知らせ：届けていない数と、新しい 20 件
    public func linkNotices(task: Int) async throws -> LinkNoticeList {
        try await get("/v1/tasks/\(task)/link-notices")
    }

    public func answerAsk(id: Int64, _ body: AskAnswerRequest) async throws -> Ask {
        try await send("POST", "/v1/asks/\(id)/answer", body)
    }

    public func pullRequestDetail(url: String) async throws -> PullRequestDetail {
        let (data, response) = try await session.data(for: request(for: "/v1/prs/detail", query: [URLQueryItem(name: "url", value: url)]))
        return try decode(data, response)
    }

    public func refreshPullRequests() async throws -> PRSnapshot {
        var req = request(for: "/v1/prs/refresh")
        req.httpMethod = "POST"
        let (data, response) = try await session.data(for: req)
        return try decode(data, response)
    }

    public func cancelAsk(id: Int64) async throws {
        var req = request(for: "/v1/asks/\(id)/cancel")
        req.httpMethod = "POST"
        let (_, response) = try await session.data(for: req)
        try expectNoContent(response)
    }

    public func claimFeedback(_ body: FeedbackClaimRequest) async throws -> FeedbackClaimResponse {
        try await send("POST", "/v1/feedback/claim", body)
    }

    public func ackFeedback(_ body: FeedbackAckRequest) async throws {
        var req = request(for: "/v1/feedback/ack")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try WireJSON.encoder().encode(body)
        let (_, response) = try await session.data(for: req)
        try expectNoContent(response)
    }

    public func takeFeedback(task: Int) async throws -> FeedbackTakeResponse {
        try await send("POST", "/v1/tasks/\(task)/feedback/take", EmptyBody())
    }

    private struct EmptyBody: Encodable {}

    public func linkSession(_ body: SessionLinkRequest) async throws -> TaskResolution {
        try await send("POST", "/v1/sessions/link", body)
    }

    /// タスクからセッションの紐づけを外す。pane は止めない
    public func unlinkSession(task: Int, sessionID: String) async throws -> BoardTask {
        var req = request(for: "/v1/tasks/\(task)/sessions/\(sessionID)")
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        return try decode(data, response)
    }

    public func codexMachine() async throws -> CodexMachineInfo {
        try await get("/v1/codex")
    }

    public func claudeMachine() async throws -> ClaudeMachineInfo {
        try await get("/v1/claude")
    }

    public func refreshCodexConnectors() async throws -> CodexMachineInfo {
        var req = request(for: "/v1/codex/connectors/refresh")
        req.httpMethod = "POST"
        let (data, response) = try await session.data(for: req)
        return try decode(data, response)
    }

    public func startCodexLogin(name: String) async throws -> CodexConnectorLogin {
        try await send("POST", "/v1/codex/connectors/login", CodexConnectorLoginRequest(name: name))
    }

    public func logoutCodexConnector(name: String) async throws -> CodexMachineInfo {
        try await send("POST", "/v1/codex/connectors/logout", CodexConnectorLogoutRequest(name: name))
    }

    public func sendCodexCallback(_ body: CodexConnectorCallbackRequest) async throws {
        try await postNoContent("/v1/codex/connectors/login/callback", body)
    }

    public func cancelCodexLogin(loginId: String) async throws {
        try await postNoContent("/v1/codex/connectors/login/cancel", CodexConnectorLoginCancel(loginId: loginId))
    }

    public func pullRequests() async throws -> PRSnapshot {
        try await get("/v1/prs")
    }

    public func usage() async throws -> UsageSnapshot {
        try await get("/v1/usage")
    }

    public func usageHistory(_ query: UsageHistoryQuery) async throws -> UsageHistory {
        let (data, response) = try await session.data(for: request(for: UsageHistory.path, query: query.queryItems))
        return try decode(data, response)
    }

    /// pane か session_id からタスクを引く（MCP が `task_id` 省略時に使う）。
    public func resolveTask(pane: PaneID?, agentSessionID: String?) async throws -> TaskResolution {
        var query: [URLQueryItem] = []
        if let pane { query.append(URLQueryItem(name: "pane", value: pane.rawValue)) }
        if let agentSessionID { query.append(URLQueryItem(name: "session", value: agentSessionID)) }
        let (data, response) = try await session.data(for: request(for: "/v1/resolve", query: query))
        return try decode(data, response)
    }

    public func hookStop(_ body: HookStopRequest) async throws -> HookStopResponse {
        try await send("POST", "/v1/hooks/stop", body)
    }

    public func hookPrompt(_ body: HookPromptRequest) async throws -> HookPromptResponse {
        try await send("POST", "/v1/hooks/prompt", body)
    }

    public func reportClaudeUsage(_ body: ClaudeUsageReport) async throws {
        var req = request(for: "/v1/usage/claude")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try WireJSON.encoder().encode(body)
        let (_, response) = try await session.data(for: req)
        try expectNoContent(response)
    }










    /// host の会話の札。生きている発言の札は transcript の位置を持たない（0）ので、`at` を付けずに daemon に探させる
    public func conversationFile(_ id: String, toolID: String, file: ChatFile, part: ChatFile.Part) async throws -> ChatFileContent {
        try await fileContent("/v1/conversations/\(id)/files/\(toolID)", file: file, part: part, offset: file.offset > 0 ? file.offset : nil)
    }


    public func conversationImage(_ id: String, lineID: String, image: ChatImage) async throws -> Data {
        try await imageData("/v1/conversations/\(id)/images/\(lineID)/\(image.index)", image: image)
    }

    /// 生きている発言の画像は transcript の位置を持たない（0）ので、`at` を付けずに daemon に探させる
    private func imageData(_ path: String, image: ChatImage) async throws -> Data {
        let query = image.offset > 0 ? [URLQueryItem(name: "at", value: String(image.offset))] : []
        let (data, response) = try await session.data(for: request(for: path, query: query))
        guard let http = response as? HTTPURLResponse else { throw SessionSourceError.invalidResponse }
        if let failure = authFailure(http) { throw failure }
        guard http.statusCode == 200 else { throw SessionSourceError.from(status: http.statusCode, body: data) }
        return data
    }

    /// 応答の Content-Type で形を決める（文・diff・画像）
    private func fileContent(_ path: String, file: ChatFile, part: ChatFile.Part, offset: UInt64?) async throws -> ChatFileContent {
        var query = offset.map { [URLQueryItem(name: "at", value: String($0))] } ?? []
        if part != .content { query.append(URLQueryItem(name: "part", value: part.rawValue)) }
        if let path = file.path, file.action == .edited { query.append(URLQueryItem(name: "path", value: path)) }
        let (data, response) = try await session.data(for: request(for: path, query: query))
        guard let http = response as? HTTPURLResponse else { throw SessionSourceError.invalidResponse }
        if let failure = authFailure(http) { throw failure }
        guard http.statusCode == 200 else { throw SessionSourceError.from(status: http.statusCode, body: data) }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.hasPrefix("image/") { return .image(data) }
        let text = String(decoding: data, as: UTF8.self)
        return type.hasPrefix("text/x-diff") ? .diff(ChatDiffHunk.parse(unified: text)) : .text(text)
    }


    /// 認証で断られた理由（daemon の 401 と Access の 403 を分ける）。
    /// 失効・取り消し・ポリシー外のサービストークンに Access は 403 でなくログイン画面への 302 を返し、
    /// URLSession はそれを追って別ホストの 200 を返す（WebSocket の upgrade は追わず 302 のまま）
    /// 401 は daemon が付ける `X-Taskboard-Auth` があるときだけ daemon の拒否。Access の内側（`behindAccess`）で印の無い 401 は、
    /// strict な service token の検査で Access が返したもの
    static func authFailure(_ http: HTTPURLResponse, base: URL, behindAccess: Bool = false) -> SessionSourceError? {
        switch http.statusCode {
        case 401:
            if !behindAccess || http.value(forHTTPHeaderField: DaemonAuthHeader.name) != nil { return .unauthorized }
            return .forbidden
        case 403 where http.value(forHTTPHeaderField: DaemonAuthHeader.name) == DaemonAuthHeader.forbidden:
            return .rejected(DaemonRejection(status: 403, message: "この端末ではできない", code: .deviceNotAllowed))  // ui-copy:ignore（message は画面に出ない。アプリは code から文を組む）
        case 403, 301, 302, 303, 307, 308: return .forbidden
        default:
            if let host = http.url?.host(), host != base.host() { return .forbidden }
            return nil
        }
    }

    func upgradeError(_ task: URLSessionWebSocketTask) -> SessionSourceError? {
        // 端末を止めると daemon が 4401 で閉じる。次の HTTP の 401 を待たずに知らせる
        if task.closeCode.rawValue == Int(DaemonAuthHeader.revokedCloseCode) { return .unauthorized }
        return (task.response as? HTTPURLResponse).flatMap { authFailure($0) }
    }

    private func authFailure(_ http: HTTPURLResponse) -> SessionSourceError? {
        Self.authFailure(http, base: endpoint.baseURL, behindAccess: endpoint.access != nil)
    }

    func delete(_ path: String) async throws {
        var req = request(for: path)
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        try expectNoContent(response, data)
    }

    func expectNoContent(_ response: URLResponse, _ data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw SessionSourceError.invalidResponse }
        if let failure = authFailure(http) { throw failure }
        switch http.statusCode {
        case 200, 204: return
        default: throw SessionSourceError.from(status: http.statusCode, body: data)
        }
    }

    // MARK: host の会話

    public func startConversation(_ body: ConversationStartRequest) async throws -> Conversation {
        try await send("POST", "/v1/conversations", body)
    }

    public func conversations() async throws -> [Conversation] {
        try await get("/v1/conversations")
    }

    public func conversation(_ id: String) async throws -> Conversation {
        try await get("/v1/conversations/\(id)")
    }

    public func sendConversation(_ id: String, _ body: ConversationSendRequest) async throws -> ConversationSendResponse {
        try await send("POST", "/v1/conversations/\(id)/messages", body)
    }

    /// 画像を置き、送信の `attachments` に渡す id を返す
    public func uploadConversationAttachment(_ id: String, data: Data) async throws -> AttachmentUploadResponse {
        var req = request(for: "/v1/conversations/\(id)/attachments")
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (body, response) = try await session.data(for: req)
        return try decode(body, response)
    }

    /// 画像でないファイルを daemon のマシンに置き、送信の `files` に渡すパスを返す（別のマシン・iPhone から添付するとき。同じ Mac ならパスをそのまま送る）
    public func uploadConversationFile(_ id: String, data: Data, name: String) async throws -> AttachmentUploadResponse {
        var req = request(for: "/v1/conversations/\(id)/files", query: [URLQueryItem(name: "name", value: name)])
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (body, response) = try await session.data(for: req)
        return try decode(body, response)
    }

    public func answerConversation(_ id: String, _ body: ConversationAnswerRequest) async throws {
        try await postNoContent("/v1/conversations/\(id)/answers", body)
    }

    public func controlConversation(_ id: String, _ body: ConversationControlRequest) async throws -> ConversationControlResponse {
        try await send("POST", "/v1/conversations/\(id)/control", body)
    }

    public func stopConversation(_ id: String) async throws {
        try await postNoContent("/v1/conversations/\(id)/stop", [String: String]())
    }

    /// 終了：動いていれば止め、記録は残す
    public func closeConversation(_ id: String) async throws {
        try await postNoContent("/v1/conversations/\(id)/close", [String: String]())
    }

    /// 今のターンを終えてから終了する（会話が自分を終了する `session_exit`）
    public func closeConversationAfterTurn(_ id: String) async throws {
        try await postNoContent("/v1/conversations/\(id)/close", ConversationCloseRequest(afterTurn: true))
    }

    public func resumeConversation(_ id: String) async throws -> Conversation {
        try await send("POST", "/v1/conversations/\(id)/resume", [String: String]())
    }

    /// transcript を新しい方から 1 ページ。`before` は前のページの `nextCursor`（nil なら末尾から）。`subagents` はページの中の Agent の呼び出しの、サブエージェントの発言も受けるか
    public func conversationHistory(
        _ id: String, before: String? = nil, limit: Int = ConversationHistoryResponse.maxLimit, subagents: Bool = false
    ) async throws -> ConversationHistoryResponse {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        if subagents { query.append(URLQueryItem(name: "subagents", value: "1")) }
        let (data, response) = try await session.data(for: request(for: "/v1/conversations/\(id)/history", query: query))
        return try decode(data, response)
    }

    /// 会話をまたいだ全文検索。会話ごとに一致した最新の発言（前の版の daemon は 404）
    public func searchConversations(query: String, limit: Int = ConversationSearchResponse.defaultLimit) async throws -> ConversationSearchResponse {
        let (data, response) = try await session.data(
            for: request(for: "/v1/conversations/search", query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]))
        return try decode(data, response)
    }

    /// 会話の検索の索引を捨てて、裏で初めから作り直させる（daemon の token だけ）
    public func rebuildConversationSearch() async throws {
        try await postNoContent("/v1/conversations/search/rebuild", [String: String]())
    }

    /// 止まっている会話の記録を消す（動いている会話は 409）
    public func deleteConversation(_ id: String) async throws {
        try await delete("/v1/conversations/\(id)")
    }

    /// `/` で使えるコマンド
    public func conversationCommands(_ id: String) async throws -> ConversationCommandsResponse {
        try await get("/v1/conversations/\(id)/commands")
    }

    /// 作業ディレクトリのファイルから、`query` に合うものを引く（入力欄の `@` の候補）
    public func conversationWorkFiles(_ id: String, query: String, limit: Int = ConversationWorkFilesResponse.defaultLimit) async throws -> ConversationWorkFilesResponse {
        let (data, response) = try await session.data(
            for: request(for: "/v1/conversations/\(id)/workfiles", query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]))
        return try decode(data, response)
    }

    /// 会話をフォークし、新しい会話を返す
    public func forkConversation(_ id: String, _ body: ConversationForkRequest) async throws -> Conversation {
        try await send("POST", "/v1/conversations/\(id)/fork", body)
    }

    public func rewindConversation(_ id: String, _ body: ConversationRewindRequest) async throws -> ConversationRewindResponse {
        try await send("POST", "/v1/conversations/\(id)/rewind", body)
    }

    public func undoRewindConversation(_ id: String, _ body: ConversationSessionGuard) async throws -> Conversation {
        try await send("POST", "/v1/conversations/\(id)/rewind/undo", body)
    }

    public func redoRewindConversation(_ id: String, _ body: ConversationSessionGuard) async throws -> Conversation {
        try await send("POST", "/v1/conversations/\(id)/rewind/redo", body)
    }

    /// 会話の作業フォルダのシェル（生きていれば前と同じ pane）
    public func conversationShell(_ id: String) async throws -> ConversationShellResponse {
        try await send("POST", "/v1/conversations/\(id)/shell", [String: String]())
    }

    /// 会話の作業フォルダのシェルの tab を閉じる（無ければ何もしない）
    public func stopConversationShell(_ id: String) async throws {
        try await delete("/v1/conversations/\(id)/shell")
    }

    public func prewarmConversation(_ body: ConversationPrewarmRequest) async throws {
        try await postNoContent("/v1/conversations/prewarm", body)
    }

    public func startConversationRun(_ id: String, _ body: ConversationRunRequest) async throws -> ConversationRun {
        try await send("POST", "/v1/conversations/\(id)/runs", body)
    }

    public func conversationRun(_ id: String, run: String) async throws -> ConversationRun {
        try await get("/v1/conversations/\(id)/runs/\(run)")
    }

    public func cancelConversationRun(_ id: String, run: String) async throws {
        try await delete("/v1/conversations/\(id)/runs/\(run)")
    }

    /// 会話の Run のシェルを全部閉じる（変数と cd を捨てる）
    public func resetConversationRuns(_ id: String) async throws {
        try await postNoContent("/v1/conversations/\(id)/runs/reset", [String: String]())
    }

    public func conversationDiff(_ id: String, scope: ConversationDiffScope) async throws -> ConversationDiffResponse {
        let (data, response) = try await session.data(
            for: request(for: "/v1/conversations/\(id)/diff", query: [URLQueryItem(name: "scope", value: scope.rawValue)]))
        return try decode(data, response)
    }

    public func conversationFileDiff(_ id: String, path: String, scope: ConversationDiffScope) async throws -> ConversationFileDiffResponse {
        let (data, response) = try await session.data(
            for: request(
                for: "/v1/conversations/\(id)/diff/file",
                query: [URLQueryItem(name: "path", value: path), URLQueryItem(name: "scope", value: scope.rawValue)]))
        return try decode(data, response)
    }

    /// `after` より後の出来事と続き（CLI と確かめ用。アプリは `openStream` で購読する）
    public func conversationEvents(_ id: String, after: Int = 0) -> AsyncThrowingStream<ConversationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ConversationEvent, any Error>.makeStream()
        let task = session.webSocketTask(
            with: request(for: "/v1/conversations/\(id)/events", websocket: true, query: [URLQueryItem(name: "after", value: String(after))]))
        task.maximumMessageSize = 16 << 20
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
                    continuation.yield(try decoder.decode(ConversationEvent.self, from: data))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: self.upgradeError(task) ?? error)
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
        return stream
    }

    private func postNoContent<B: Encodable>(_ path: String, _ body: B) async throws {
        var req = request(for: path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try WireJSON.encoder().encode(body)
        let (data, response) = try await session.data(for: req)
        try expectNoContent(response, data)
    }

    public func importTaskherd(_ body: TaskherdImportRequest) async throws -> TaskherdImportResult {
        try await send("POST", "/v1/import/taskherd", body)
    }

    func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, _ body: B, authorized: Bool = true) async throws -> T {
        var req = request(for: path, authorized: authorized)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try WireJSON.encoder().encode(body)
        let (data, response) = try await session.data(for: req)
        return try decode(data, response)
    }

    func get<T: Decodable>(_ path: String, authorized: Bool = true) async throws -> T {
        let (data, response) = try await session.data(for: request(for: path, authorized: authorized))
        return try decode(data, response)
    }

    func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw SessionSourceError.invalidResponse }
        if let failure = authFailure(http) { throw failure }
        switch http.statusCode {
        case 200: return try WireJSON.decoder().decode(T.self, from: data)
        default: throw SessionSourceError.from(status: http.statusCode, body: data)
        }
    }

    func request(for path: String, authorized: Bool = true, websocket: Bool = false, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        if websocket {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
        }
        var req = URLRequest(url: components.url!)
        if authorized {
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        }
        // health も Access の内側にあるので、認証なしの経路にも付ける
        if let access = endpoint.access {
            req.setValue(access.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(access.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return req
    }
}
