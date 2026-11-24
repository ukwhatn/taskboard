import Foundation

/// ボードとタスクを書け、会話のシェルの端末を開ける供給元。本番は `DaemonClient`。fixtures は読むだけなので準拠しない。
public protocol DaemonWriter: Sendable {
    func openTerminal(pane: PaneID, cols: Int, rows: Int) -> TerminalConnection
    func createBoard(_ request: BoardCreateRequest) async throws -> Board
    func createTask(_ request: TaskCreateRequest) async throws -> BoardTask
    func updateTask(number: Int, _ request: TaskUpdateRequest) async throws -> BoardTask
    func deleteTask(number: Int) async throws
    /// セッションをタスクに紐づける（`taskNumber` を入れて送る）。返った `task` が紐づけた後のタスク
    func linkSession(_ body: SessionLinkRequest) async throws -> TaskResolution
    /// タスクからセッションの紐づけを外す。会話は止めない
    func unlinkSession(task: Int, sessionID: String) async throws -> BoardTask
    func workItems(task: Int) async throws -> [WorkItem]
    func createWorkItem(task: Int, _ request: WorkItemCreateRequest) async throws -> WorkItem
    func updateWorkItem(id: Int64, _ request: WorkItemUpdateRequest) async throws -> WorkItem
    func deleteWorkItem(id: Int64) async throws
    /// 手作業待ちの作業項目を済ませる（作業中に戻し、済んだことを会話へ届ける）。`POST /v1/work/{id}/finish`
    func finishManualWork(id: Int64) async throws
    func approvePanelDraft(task: Int, part: String, body: String) async throws -> OverviewPanel
    func submitDoc(doc: Int64, _ request: DocSubmitRequest) async throws -> Document
    func startDocRun(doc: Int64, _ body: ConversationRunRequest) async throws -> ConversationRun
    func conversationRun(_ id: String, run: String) async throws -> ConversationRun
    func cancelConversationRun(_ id: String, run: String) async throws
    func relayClaudeUsage(_ body: ClaudeAccountUsageRelay) async throws
    func orchestrator() async throws -> OrchestratorInfo
    /// 返るのはオーケストレーターの様子（起こした会話は `conversationID`）
    func startOrchestrator(_ request: LaunchRequest) async throws -> OrchestratorInfo
    func promptOrchestrator(_ text: String) async throws -> OrchestratorInfo
    /// オーケストレーターを止めて（今の会話を破棄して）新しく起動する。`POST /v1/orchestrator/restart`。返るのは `startOrchestrator` と同じ様子
    func restartOrchestrator() async throws -> OrchestratorInfo
    func updateSettings(_ body: MachineSettingsUpdate) async throws -> MachineSettings
    /// 止まったセッションを会話で戻す
    func resumeSession(task: Int, _ body: SessionResumeRequest) async throws -> SessionResumeResult
    /// 会話の Claude Code のアカウントを替える。返るのは替えた後の会話
    func switchAccount(_ body: SessionAccountRequest) async throws -> SessionResumeResult
    /// タスクに紐づいたセッションの会話の題・最後の指示・ブランチ（止まったセッションの一覧）
    func sessionHistory(task: Int) async throws -> [SessionHistory]
    func createPairing() async throws -> PairingCode
    func devices() async throws -> [DeviceInfo]
    func revokeDevice(_ id: String) async throws
    func updateBoard(id: String, _ request: BoardUpdateRequest) async throws -> Board
    func deleteBoard(id: String) async throws
    func boardSlack(id: String) async throws -> BoardSlack
    func updateBoardSlack(id: String, _ request: BoardSlackUpdate) async throws -> BoardSlack
    func deleteBoardSlack(id: String) async throws
    func slackChannels(board id: String) async throws -> [SlackChannel]
    func documents(task: Int) async throws -> [Document]
    func publishDocument(task: Int, _ request: DocPublishRequest) async throws -> DocPublishResponse
    func deleteDocument(id: Int64) async throws
    func documentRevisions(id: Int64) async throws -> [DocRevision]
    func documentContent(id: Int64, rev: Int?) async throws -> DocContent
    /// publish 元のファイルのパス。同じ Mac の daemon にだけ聞ける（端末の token は 403）
    func documentSourceFile(id: Int64) async throws -> DocSourceFile
    func comments(doc id: Int64) async throws -> [DocComment]
    func createComment(doc id: Int64, _ request: CommentCreateRequest) async throws -> DocComment
    func updateComment(id: Int64, _ request: CommentUpdateRequest) async throws -> DocComment
    func deleteComment(id: Int64) async throws
    func replyComment(id: Int64, _ request: CommentReplyRequest) async throws -> CommentReply
    func resolveComment(id: Int64, resolved: Bool) async throws -> DocComment
    func reviewDraft(task: Int) async throws -> ReviewDraft
    func setReviewSummary(task: Int, _ request: ReviewSummaryRequest) async throws -> Review
    func submitReview(task: Int) async throws -> Review
    func asks(task: Int) async throws -> [Ask]
    func answerAsk(id: Int64, _ request: AskAnswerRequest) async throws -> Ask
    func cancelAsk(id: Int64) async throws
    func pullRequestDetail(url: String) async throws -> PullRequestDetail
    /// 今すぐ取り直す（rate limit で止まっているアカウントは飛ばす）
    func refreshPullRequests() async throws -> PRSnapshot
    /// そのマシンの codex のアカウント・モデル・コネクタ（daemon が読んである値。`GET /v1/codex`）
    func codexMachine() async throws -> CodexMachineInfo
    /// そのマシンの Claude Code のモデルの一覧（daemon が CLI から受けた値。`GET /v1/claude`）。口の無い daemon は 404
    func claudeMachine() async throws -> ClaudeMachineInfo
    /// codex のコネクタを読み直した値（前に読んでから 30 秒たっていなければ読み直さない）
    func refreshCodexConnectors() async throws -> CodexMachineInfo
    /// codex のコネクタの認証を始め、開く認証のページを受け取る
    func startCodexLogin(name: String) async throws -> CodexConnectorLogin
    /// codex のコネクタの認証を解除し（`codex mcp logout`）、読み直したコネクタを受け取る
    func logoutCodexConnector(name: String) async throws -> CodexMachineInfo
    /// ほかの端末で受けた戻り先のアドレスを、そのマシンの上で開いてもらう
    func sendCodexCallback(_ body: CodexConnectorCallbackRequest) async throws
    /// 認証の待ちを消す（それより後の戻り先のアドレスを daemon が開かない）
    func cancelCodexLogin(loginId: String) async throws
    func workingDirectories() async throws -> WorkingDirectories
    /// 打ちかけのパス（`~/` か `/` で始まる）の続きになるディレクトリ。そのマシンのパスで、入力と同じ書き方で返る
    func completeWorkingDirectory(_ prefix: String) async throws -> [String]
    /// チャットの入力欄の `/` の候補。`cwd` はセッションの作業ディレクトリ（そこと親の `.claude` も読む）
    func slashCommands(cwd: String?) async throws -> [SlashCommand]
    func addWorkdirBookmark(path: String) async throws -> WorkdirBookmark
    func deleteWorkdirBookmark(id: Int64) async throws
    /// そのマシンの worktree と、消せるかの判定（`GET /v1/worktrees`）。判定は一覧を作った時点のもの
    func worktrees() async throws -> [WorktreeInfo]
    /// 消す。daemon が 1 件ずつ今の状態を読み直して、消せるものだけ消す（`POST /v1/worktrees/remove`）
    func removeWorktrees(paths: [String]) async throws -> [WorktreeRemoveResult]
    func createSchedule(_ body: ScheduleCreateRequest) async throws -> Schedule
    func updateSchedule(id: Int64, _ body: ScheduleUpdateRequest) async throws -> Schedule
    func deleteSchedule(id: Int64) async throws
    func scheduleRuns(id: Int64) async throws -> [ScheduleRun]
    func runSchedule(id: Int64) async throws -> ScheduleRun
    func dismissInbox(_ items: [InboxDismissRequest.Item]) async throws -> [InboxDismissal]
    func restoreInbox(itemIDs: [String]) async throws -> [InboxDismissal]
}

/// `/v1/terminal/{pane_id}` から届くもの。
public enum TerminalIncoming: Sendable {
    /// 端末のバイト列（ANSI）。そのまま端末エミュレータに流す。
    case bytes(Data)
    case message(TerminalServerMessage)
}

/// 1 本の端末 WebSocket。`incoming` が終わったら切れている。再接続は呼び出し側が新しく開く。
public final class TerminalConnection: Sendable {
    public let incoming: AsyncThrowingStream<TerminalIncoming, any Error>
    private let task: URLSessionWebSocketTask
    private let encoder = WireJSON.encoder()

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (stream, continuation) = AsyncThrowingStream<TerminalIncoming, any Error>.makeStream()
        incoming = stream
        task.resume()
        let reader = Task {
            let decoder = WireJSON.decoder()
            do {
                while !Task.isCancelled {
                    switch try await task.receive() {
                    case .data(let data):
                        continuation.yield(.bytes(data))
                    case .string(let text):
                        continuation.yield(.message(try decoder.decode(TerminalServerMessage.self, from: Data(text.utf8))))
                    @unknown default:
                        continue
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    public func send(_ message: TerminalClientMessage) async throws {
        try await task.send(.string(String(decoding: try encoder.encode(message), as: UTF8.self)))
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
