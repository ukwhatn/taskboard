import Foundation
import Logging
import TaskboardKit

/// 会話の操作を断った理由。API はこの `code` と `status` で応答する
struct ConversationError: Error, CustomStringConvertible, Equatable {
    var status: Int
    var code: DaemonErrorCode
    var params: [String: String] = [:]
    var description: String

    static func stopped(_ id: String) -> ConversationError { .init(status: 409, code: .conversationStopped, description: "会話 \(id) は止まっている") }
    static func notWaiting(_ request: String) -> ConversationError { .init(status: 409, code: .notWaiting, description: "問い \(request) は答えを待っていない") }
    static func invalid(_ message: String) -> ConversationError { .init(status: 400, code: .invalidRequest, description: message) }
    static func failed(_ message: String) -> ConversationError { .init(status: 502, code: .sessionCommandFailed, description: message) }
    static func running(_ agentSessionID: String) -> ConversationError {
        .init(status: 409, code: .sessionRunning, description: "engine の会話 \(agentSessionID) はほかで動いている")
    }
    static func controlUnsupported(_ operation: String, engine: AgentKind) -> ConversationError {
        .init(status: 409, code: .engineUnsupported, params: ["engine": engine.rawValue], description: "\(engine.label) の会話では \(operation) を使えない")
    }
    /// 断られた設定の書き込み。理由の種類を params の `reason` に入れ、engine の英語の文は入れない
    static func settingsRejected(_ reason: String) -> ConversationError {
        var error = ConversationError(status: 409, code: .sessionCommandFailed, description: "設定を書けなかった（\(reason)）")
        error.params = ["reason": reason]
        return error
    }
    static func live(_ id: String) -> ConversationError { .init(status: 409, code: .conversationRunning, description: "会話 \(id) は動いている（止めてから消す）") }
    static func removed(_ id: String) -> ConversationError {
        .init(status: 404, code: .notFound, params: ["kind": DaemonErrorCode.Kind.conversation.rawValue], description: "会話 \(id) は消した")
    }
    static func busy(_ id: String, _ reason: String) -> ConversationError {
        .init(status: 409, code: .conversationBusy, description: "会話 \(id) は\(reason)")
    }
    static func notSent(_ id: String) -> ConversationError {
        .init(status: 409, code: .conversationNotSent, description: "会話 \(id) にはまだ履歴が無い（フォーク・巻き戻しの後、まだ送っていない）")
    }
    static func messageNotFound(_ uuid: String) -> ConversationError {
        .init(
            status: 404, code: .notFound, params: ["kind": DaemonErrorCode.Kind.message.rawValue],
            description: "発言 \(uuid) が履歴の末尾 \(ConversationHistory.readLimit >> 20)MB に無い")
    }
    static func changed(_ id: String) -> ConversationError {
        .init(status: 409, code: .conversationChanged, description: "会話 \(id) の Claude の会話 ID が替わった（開き直してからやり直す）")
    }
    static func unsupportedEngine(_ id: String, _ engine: String) -> ConversationError {
        .init(status: 409, code: .invalidRequest, description: "会話 \(id) の engine「\(engine)」は、この版の daemon では動かせない")
    }
    static func questionPending(_ id: String) -> ConversationError {
        .init(status: 409, code: .questionPending, description: "会話 \(id) は問いの答えを待っている")
    }
    static func limit(_ limit: Int) -> ConversationError {
        .init(status: 409, code: .conversationLimit, params: ["limit": "\(limit)"], description: "動いている会話が上限の \(limit) 件")
    }
    static let invalidTitle = ConversationError.invalid("題は改行なしの \(ConversationInput.titleLimit) 字まで")
    static let orchestratorResident = ConversationError(status: 409, code: .orchestratorResident, description: "常駐を切ってから止める")
}

extension ConversationInput {
    /// 会話に人が付ける名前（`.rename` の値）。前後の空白を落とし、空か nil なら名前を外す（nil を返す）。改行を含むか上限を超えると断る
    static func customTitle(_ value: String?) throws -> String? {
        guard let name = value.flatMap(title) else { return nil }
        guard acceptsTitle(name) else { throw ConversationError.invalidTitle }
        return name
    }
}

/// agent host で動く 1 つの Claude の会話（stream-json の CLI）。host の出力を 1 行ずつ順に読み、問い・発言の受付・ターンの終わりを持ち、
/// 出来事を会話ごとの番号つきで配る。daemon が起き直したときと控えから行が落ちたときは、控えを読み直してから initialize を送り直し、
/// 答えを待っている問いを CLI から取り直す（控えに残った問いには答え済みのものがある）
actor ClaudeConversation {
    @dynamicMemberLookup
    struct Context: Sendable {
        var shared: ConversationContext

        subscript<Value>(dynamicMember keyPath: WritableKeyPath<ConversationContext, Value>) -> Value {
            get { shared[keyPath: keyPath] }
            set { shared[keyPath: keyPath] = newValue }
        }

        /// Stop の hook（PR の確かめと待ちの見直し、`HookService.stop`）。返した文があれば、モデルにそのターンを続けさせる
        var stopHook: @Sendable (_ conversationID: String, _ call: ClaudeHookCall) async -> String? = { _, _ in nil }
        /// initialize の答えでモデルの一覧を受けた（`ClaudeModelRecord` に書く）
        var modelsListed: @Sendable (_ models: [ClaudeMachineInfo.Model], _ version: String?) -> Void = { _, _ in }
        /// モデルを切り替えるときに引く一覧
        var models: @Sendable () -> ClaudeModels = { ClaudeModels(nil) }
        /// その会話 ID の transcript があるか（CLI に渡す環境の `CLAUDE_CONFIG_DIR` で引く）。無い会話は `--resume` できない
        var hasTranscript: @Sendable (_ agentSessionID: String, _ environment: [String: String]) -> Bool = { _, _ in true }
        /// フォーク・巻き戻しで CLI が写した transcript の写し元（`TranscriptSource.find`）。要約の後だけを写したときにある
        var transcriptSource: @Sendable (_ fork: String, _ source: String, _ environment: [String: String]) -> TranscriptSource? = { _, _, _ in nil }
        /// その会話の transcript に、その tool_use の tool_result（defer で終えた問いの答え）があるか
        var answeredInTranscript: @Sendable (_ agentSessionID: String, _ toolUseID: String, _ environment: [String: String]) -> Bool = { _, _, _ in false }
        /// その会話の計画（`ClaudeTaskList`）
        var taskList: @Sendable (_ agentSessionID: String, _ environment: [String: String]) -> [ConversationPlanItem]? = { _, _ in nil }
        /// 設定を書く CLI のサブコマンド（`claude edit-* --json`）を、stdin に `input` を渡して起こす
        var settingsCLI: @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String], _ input: Data, _ cwd: String) async throws
            -> Subprocess.Outcome = { executable, arguments, environment, input, cwd in
                try await Subprocess.capture(
                    URL(fileURLWithPath: executable), arguments, cwd: URL(fileURLWithPath: cwd), environment: environment, timeout: .seconds(30),
                    outputLimit: 1 << 20, input: input)
            }
        /// `claude plugin` のサブコマンドを起こす。入れるときは git や npm から取ってくるので長めに待ち、一覧は公式の目録（数千件）を含むので大きく受ける
        var pluginCLI: @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String], _ cwd: String) async throws -> Subprocess.Outcome = {
            executable, arguments, environment, cwd in
            try await Subprocess.capture(
                URL(fileURLWithPath: executable), arguments, cwd: URL(fileURLWithPath: cwd), environment: environment, timeout: .seconds(180),
                outputLimit: 16 << 20)
        }
        /// 設定のファイルを読む（無ければ nil）。marketplace の宣言の層を確かめるのに使う
        var readFile: @Sendable (_ url: URL) -> Data? = { try? Data(contentsOf: $0) }
        /// 利用枠の上限で止まったときに、戻ったら自分で続きを送るか（CLI の設定の `autoContinueAtUsageLimit`。`--settings` のファイルが先）
        var continuesAtUsageLimit: @Sendable (_ record: ConversationRecord, _ environment: [String: String]) -> Bool = { _, _ in false }
        /// 利用枠の上限の前に区切る使用率（マシンの設定）。nil なら区切らない
        var usagePause: @Sendable () -> MachineSettings.UsagePause? = { nil }
        /// 利用枠の窓とコンテキストをマシンの利用枠に入れる（`DaemonState.record`。会話も statusline の 1 セッションと同じに数える）
        var reportUsage: @Sendable (ClaudeUsageReport) async -> Void = { _ in }
        /// `get_usage` を引いてよいか（マシンで間をあける。引いてよければ印を付けて true）
        var claimUsageRefresh: @Sendable (_ account: String?) async -> Bool = { _ in false }
        /// 起こす直前に決め直したアカウントの引数（`ClaudeAccounts.apply`）。nil なら記録の引数のまま起こす
        var launchArguments: @Sendable (_ record: ConversationRecord, _ resume: Bool) async -> [String]? = { _, _ in nil }
    }

    /// AskUserQuestion・ExitPlanMode を defer で終えるか。`auto` は会話を購読している接続（画面に出ている）が無いときだけ
    enum DeferMode: String, Sendable {
        case auto, on, off
    }

    static let preToolHook = "tb_pre"
    /// ［今すぐ送る］と途中送りで裏に回す tool（Desktop と同じ）
    static let detachableToolNames: Set<String> = ["Bash", "PowerShell", "Agent", "Task"]
    /// 途中送りの裏回しで、1 つの発言のために回す tool の数の上限（Desktop と同じ）
    static let steerDetachLimit = 2
    static let bypassMode = "bypassPermissions"
    static let promptHook = "tb_prompt"
    static let stopHookID = "tb_stop"
    static let hookedTools = "AskUserQuestion|ExitPlanMode"
    /// 止める手順（待ち行列の取り消し）と発言の受付で使う
    static let requiredCapabilities = ["interrupt_cancel_queued_v1", "msg_lifecycle_v1"]

    private struct Pending {
        var request: ConversationRequest
        var inputJSON: String
        /// 答えで選べる CLI の候補（`permission_suggestions`）
        var suggestionsJSON: String? = nil
        /// 控えの読み直しで得た（前の daemon が答えたかもしれない）
        var fromReplay = false
        /// MCP の問い（url）の開く先の全文。ここにだけ持ち、［開く］の応答で渡す
        var url: URL? = nil
    }

    nonisolated let id: String
    private let context: Context
    var record: ConversationRecord
    private var phase: Conversation.Phase
    /// CLI が最後に知らせた状態（`session_state_changed` と initialize の応答）
    private var reportedPhase: ClaudeTurnPhase?
    private var pending: [String: Pending] = [:]
    private var pendingOrder: [String] = []
    private var deferMode = DeferMode.auto
    var child = ConversationChild.none
    /// 子を起こした（引き取った）回の番号。後から走る処理が、起こし直した別の子に手を出さないように比べる
    var generation = 0
    /// 読んだ host の行の番号（host が起き直したら 0）
    var appliedSeq = 0
    /// この番号までは読み直し（前の daemon が答えた hook_callback に答えない）
    private var replayThrough = 0
    /// 控えから行が落ちたか、読み直しの後か。読み終えたら initialize を送り直す
    private var needsReconcile = false
    /// 発言の uuid → `command_lifecycle` の最後の状態。記録の `recentMessageIds` から作ったものは `recorded`（控えに続きが無ければ、待ち行列を出た後）
    var accepted: [String: String] = [:]
    private var acceptWaiters: [String: [(states: Set<String>, waiter: CheckedContinuation<String?, Never>)]] = [:]
    /// 読み直しを待っている（daemon が起き直したとき、同じ key を起こす前に控えを終わりまで読む）
    var replayWaiters: [CheckedContinuation<Void, Never>] = []
    private var controlWaiters: [String: CheckedContinuation<ClaudeControlResponse, any Error>] = [:]
    private var controlCounter = 0
    /// `/login` の流れ。URL とコードは持たない。`loginState` は貼ったコードを照らし合わせるためだけに持ち、ログに出さない
    private var loginStage: Conversation.LoginStage?
    /// 圧縮している間の様子と、字数を様子に流した時刻（字数は要約を書くたびに届くので、流すのは 1 秒に 1 回まで）
    var compaction: ConversationCompaction?
    var turnActivity = ConversationTurnActivity()
    private var compactionPublishedAt = Date.distantPast
    /// 止まりの見張り：最後に CLI から行が来た時刻、止まっていると見たときのその時刻、主の流れの結果の来ていないツールの呼び出し（実行中のツールの間は数えない）
    private var lastLineAt = Date.distantPast
    private var stalledSince: Date?
    /// API に届かず CLI が送り直している間の様子
    private var apiRetry: ConversationAPIRetry?
    private var openTools: Set<String> = []
    /// 主の流れの前景で結果を待っている Bash・subagent の task（tool_use の id → task の id）。［今すぐ送る］が `background_tasks` で裏に回す
    private var foregroundTasks: [String: String] = [:]
    /// 主の流れの `detachableToolNames` の tool_use のうち、結果も task_started もまだ来ていないもの（Bash は tool_use から 3〜4 秒で task になる。2.1.304）
    private var toolsAwaitingTask: Set<String> = []
    private var foregroundWaiters: [CheckedContinuation<Void, Never>] = []
    /// 最後に出した様子の `detachableTools`（数が変わったときだけ出し直す）
    private var publishedDetachableTools = 0
    /// 主の流れの `detachableToolNames` の tool_use を受けた時刻（結果が来たら外す）。途中送りの裏回し（`steer`）が動いている時間を見る
    private var detachableSince: [String: ContinuousClock.Instant] = [:]
    /// 途中送りの裏回しを始めた、待ち行列の発言
    private var steering: Set<String> = []
    /// 後で送る（priority "later"）で書いて、まだ待ち行列にある発言の元の uuid。途中送りの裏回しをしない
    private var laterMessages: Set<String> = []
    /// 後で送る発言を今すぐ送るために取り下げた、CLI に書いた uuid。その `cancelled` は発言の取り消しにしない（送り直した uuid で続く）
    private var withdrawn: Set<String> = []
    private var stallWatch: Task<Void, Never>?
    /// 受けた result の数（中断の後にターンが終わったか見る）
    private var resultCount = 0
    /// 待ち行列にある人の発言の、書いた行（応えない CLI を起こし直したときに入れ直す）。受け付けが進むか取り消されたら捨てる
    private var queuedLines: [(uuid: String, line: Data)] = []
    /// 最近書いた人の発言の行（hook の時間切れで CLI が捨てた発言を送り直す）。`sentLineLimit` 件まで
    private var sentLines: [(uuid: String, line: Data)] = []
    /// 最後に `started` になった発言の、CLI に書いた uuid（捨てられた知らせに uuid が載らないので、これで決める）
    private var lastStarted: String?
    /// 送り直した発言の、CLI に書いた uuid → 元の uuid。受付と写しは元の uuid で出す（アプリと送り手は元の uuid で待つ）
    private var resentFrom: [String: String] = [:]
    /// 元の uuid → 最後に送り直した uuid（今すぐ送信と取り消しで CLI に渡す）
    private var resentAs: [String: String] = [:]
    /// taskboard が CLI を止めて起こし直している（応えない CLI・確認なしへの切り替え）。終わったときに待ち行列の発言を取り消さず、止まった知らせを出さない
    private var restarting = false
    private var loginState: String?
    /// 終わりを待っている `claude_oauth_wait_for_completion` の request id。時間で切らない（遅れて届いた応答の行も控えから切るため）。
    /// ほかの制御要求と別の形の id にする（前の daemon の待ちの応答が、起き直した daemon の同じ番号の要求に入らないように）
    private var loginWaitRequest: String?
    /// この流れのコードを CLI に渡した。2 回目の `claude_oauth_callback` は送らない
    private var loginCodeSent = false
    private var guidePending = false
    /// `compact_boundary` の後、要約の本文の行をまだ受けていない
    private var awaitsCompactSummary = false
    /// 題の無い会話で最初に人が送った発言。ターンの終わりに CLI に題を作らせる（1 プロセスで 1 回）
    private var titlePrompt: String?
    private var titleRequested = false
    /// defer で終えた問いの答え。`--resume` で起こした後、同じ tool_use の PreToolUse に返す
    private var resuming: (question: DeferredQuestion, decision: ClaudeRequests.Decision)?
    /// 答えの tool_result を見た defer の問い（tool_use の id）。後から同じ問いの `deferred_tool_use` の result が届いても記録に戻さない
    private var answeredDeferred: Set<String> = []
    var resultWaiters: [CheckedContinuation<Void, Never>] = []
    var exitWaiters: [CheckedContinuation<Void, Never>] = []
    var log: ConversationEventLog
    var deltaFlush: Task<Void, Never>?
    /// 制御の応答の中身（`ConversationControlResponse.payloadJSON`）を組む
    private let encoder = WireJSON.encoder()
    /// 最後の assistant の message の tool_use の数。2 つ以上なら defer しない（1 ターンに 2 つ以上のツールを呼ぶと defer が効かない）
    private var toolUses: (messageID: String, count: Int)?
    /// 控えの読み直しの間に受けた block（読み直しの差分は流さない）
    private var replayedStream = ReplayedStream()
    /// 動いている裏のタスク（`task_started` で足し、終わりの知らせで外す。始めた順）
    private var backgroundTasks: [ConversationBackgroundTasks.Task] = []
    /// 裏のタスクの数が分かっているか。host の控えから行が落ちたら分からない（プロセスが終わるまで）
    private var backgroundTasksKnown = true
    /// 裏に回っていて終わったタスクの終わり方（終わった順。新しい `endedBackgroundTaskLimit` 件まで）。ツールの行は残るので、プロセスが終わっても残す
    private var endedBackgroundTasks: [ConversationBackgroundTaskState] = []
    static let endedBackgroundTaskLimit = 100
    /// 最後に動いた・操作された時刻（自動停止と、目安の上限で止める会話の選び方）
    var lastActive: Date
    /// 最後に返事を終えた時刻。空いた会話の圧縮はここから数え、見回りが 1 度見たら消す（1 つの空きで 1 回まで）
    private var answeredAt: Date?
    /// 次のターンの終わりは、空いた会話の圧縮か利用枠で区切る前の圧縮で送った /compact のもの（その終わりからは数えず、区切るかも見ない）
    private var compactingIdle = false
    /// 利用枠で区切った：入力待ちに入ったら /compact を送る
    private var pauseCompactPending = false
    /// 最後に受けた `rate_limit_event` の窓（`five_hour`・`seven_day`。ターンの終わりに区切るかを見る）
    private var usageWindows: [String: UsageWindow] = [:]
    /// 答えている途中の問い（id → 答えの中身と、同じ答えで待っている呼び出し）
    private var answering: [String: (request: ConversationAnswerRequest, waiters: [CheckedContinuation<Result<Void, ConversationError>, Never>])] = [:]
    /// 記録を消した（以後は起こさない・送らない・購読させない）
    var retired = false
    var startTask: Task<Void, any Error>?
    private(set) var info: ClaudeSessionInfo?
    /// `/` で使えるコマンド（`initialize` の応答と `system/commands_changed`）。プロセスが終わっても最後に受けた分を残す
    private(set) var commands: [ConversationCommand]?
    /// コンテキストの使用率（ターンの終わりに `get_context_usage` で取る）
    private var contextPercent: Int?
    /// 今の Claude の会話の値（記録に残し、止まった会話でも出す）
    var stats: ConversationStats?
    /// 作業フォルダの差分の要約（メモリだけ）と、取り直しを待っているか
    var diff: ConversationDiffSummary?
    var diffScheduled = false
    /// 差分の要約を取り直すツール（ファイルを書くもの）の、結果を待っている tool_use の id
    private var writingTools: Set<String> = []
    /// 結果を待っている計画の tool（TaskCreate・TaskUpdate）
    private var planTools: Set<String> = []
    private var plan: [ConversationPlanItem]?
    /// `plan` を読んだ会話 ID。`/clear`・フォークで替わったら読み直す
    private var planSession: String?
    static let writingToolNames: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Bash"]
    static let planToolNames: Set<String> = ["TaskCreate", "TaskUpdate"]
    /// 巻き戻し・元に戻す・端末へ移すの途中（送る・答える・起こすを断る）
    private var operation: Operation?
    private var rewinding: Bool { operation == .rewind }
    /// 最後に起こしたときの CLI の環境（transcript の置き場を引く）
    private var launchEnvironment: [String: String] = [:]
    /// 巻き戻しでファイルを戻している補助のプロセス（daemon が起き直した後に見つけて止めている途中のものも）。終わるまで送る・起こす・巻き戻すを断る
    private var helper: HelperProcess?
    /// 最後に受けた `rate_limit_event` の状態（ターンが error で終わったときに、上限で断られたかを見る）
    private var rateLimit: ClaudeRateLimit?
    /// 補助のプロセスの host の行（`ConversationService.route` が `-rewind` の key の知らせを入れる）
    nonisolated let helperInbox: AsyncStream<AgentHostNotice>.Continuation
    private let helperStream: AsyncStream<AgentHostNotice>
    private var helperReader: Task<Void, Never>?

    enum Operation: Equatable, Sendable {
        case rewind, undo, redo, account
    }

    nonisolated let inbox: AsyncStream<AgentHostNotice>.Continuation
    let inboxStream: AsyncStream<AgentHostNotice>
    var reader: Task<Void, Never>?

    init(record: ConversationRecord, context: Context) {
        id = record.id
        self.record = record
        self.context = context
        log = ConversationEventLog(conversationID: record.id, epoch: context.epoch, logger: context.logger)
        phase = .stopped
        lastActive = context.now()
        (inboxStream, inbox) = AsyncStream<AgentHostNotice>.makeStream()
        (helperStream, helperInbox) = AsyncStream<AgentHostNotice>.makeStream()
        for uuid in record.recentMessages { accepted[uuid] = Self.recorded }
        stats = record.statsValue
    }

    static let recorded = "recorded"
    static let anyLifecycle: Set<String> = ["queued", "started", "completed", "cancelled", "discarded", "refused"]
    /// CLI が取り込まずに捨てた発言の状態。取り消しと同じに扱い（待ち行列から外し、アプリは入力欄に戻す）、理由は知らせで言う
    static let notTaken: [String: String] = ["discarded": ConversationScreenText.promptDiscarded, "refused": ConversationScreenText.promptRefused]
    static let reachedModel: Set<String> = ["started", "completed"]

    // MARK: 起こす・引き取る・止まる

    /// プロセスを起こす。`resume` なら `--resume`（記録の Claude の会話 ID）、でなければ `--session-id`
    /// 同時に動かす枠を予約してから起こす（起こす道は全部ここを通る）。起こしている途中にもう一度呼ばれたら、その結果を待つ。
    /// `withinSoft` なら目安の内側でだけ起こす（ほかの会話を止めない）
    func start(resume: Bool, withinSoft: Bool = false) async throws {
        guard !child.isRunning else { return }
        guard !retired else { throw ConversationError.removed(id) }
        if let startTask { return try await startTask.value }
        guard operation == nil, helper == nil else { throw ConversationError.busy(id, "巻き戻しの途中") }
        let task = Task { try await self.startNow(resume: resume, withinSoft: withinSoft) }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    /// 画面に出たときに起こしてよい：止まっていて、起こす・巻き戻す途中でない。人が止めた会話（送ると起こす）・defer で終えた問い（答えると起こす）・
    /// 戻せたか分からない巻き戻しのある会話は、人が操作するまで起こさない
    var wakesForViewer: Bool {
        !child.isRunning && !retired && startTask == nil && operation == nil && helper == nil && record.stopCause?.keepsStopped != true && record.deferred == nil
            && !record.rewindFilesPending
    }

    private func startNow(resume: Bool, withinSoft: Bool) async throws {
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
        let sessionID = record.agentSessionId
        guard context.reservations.reserve(Self.reservationKey(sessionID), owner: id) else { throw ConversationError.running(sessionID) }
        do {
            try await launch(resume: resume, sessionID: sessionID)
        } catch {
            if !child.isRunning { context.reservations.release(owner: id) }
            throw error
        }
    }

    /// 操作の前に閉じた入力を元に戻す（その間に子が終わっていれば何もしない）
    private func restoreInput(_ accepted: Bool) {
        if child.isRunning { child = .running(acceptsInput: accepted) }
    }

    static func reservationKey(_ agentSessionID: String) -> String { SessionReservations.key(.claude, agentSessionID) }

    private func launch(resume: Bool, sessionID: String) async throws {
        // 送る・答える・開く・ネットワークの回復など、どの経路で起こしても、マシンのログインの期限切れや設定の変更に追随する
        if let arguments = await context.launchArguments(record, resume), arguments != record.extraArguments {
            try writeRecord { $0.extraArguments = arguments }
        }
        let launch = try await context.launch()
        launchEnvironment = launch.environment
        startReading()
        let hasTranscript = context.hasTranscript(sessionID, launch.environment)
        // フォーク・巻き戻しの後、まだ transcript が無ければ元から写す（発言を送らずに止まると transcript はできない）
        var fork: Fork?
        if let source = record.pendingForkSessionId {
            if hasTranscript {
                clearPendingFork()
            } else {
                fork = Fork(source: source, at: record.pendingForkAt)
            }
        }
        // 起こしてすぐ止まった会話は transcript がまだ無く、`--resume` は「No conversation found」で終わる。同じ ID で始め直す
        let argv = Self.arguments(record: record, executable: launch.executable, resume: resume && hasTranscript, fork: fork)
        let env = Self.environment(launch.environment, conversationID: id)
        replayThrough = appliedSeq
        setChild(.none)
        reportedPhase = nil
        // 記録は起こす前に書く（起こした後に書けないと、子と予約だけが残る）
        do {
            // 前のプロセスの行（ここまで）は、新しいプロセスの裏のタスクの数に関わらない
            let through = appliedSeq
            try writeRecord { $0.startProcess(through: through) }
        } catch {
            throw ConversationError.failed("会話の記録を書けない: \(error)")
        }
        do {
            _ = try await context.host.spawn(key: id, argv: argv, env: env, cwd: record.cwd)
        } catch {
            updateRecord {
                $0.runner = Conversation.Runner.none.rawValue
                $0.lastExit = ConversationStopCause.startFailed.lastExit
            }
            throw ConversationError.failed("会話を起こせない: \(error)")
        }
        generation += 1
        setChild(.running(acceptsInput: true))
        guidePending = true
        endRunningBackgroundTasks()
        backgroundTasksKnown = true
        clearForegroundTasks()
        setPhase(.starting)
        // 起こした後に失敗したら子を終わらせる（起こせなかったと返したのに、子と起動の予約が残らないように）。予約は子が終わったときに外れる。
        // host は子の終わりを購読している接続にしか送らないので、購読できずに失敗したときは、繋ぎ直しの `resubscribe` で入力を閉じ直す
        do {
            try await context.host.subscribe(key: id, after: appliedSeq)
            let response = try await control("initialize", Self.initialize)
            guard response.isSuccess else { throw ConversationError.failed("initialize を断られた: \(response.error ?? "")") }
            received(initialize: response)
        } catch {
            await terminate(reason: "起こした後に失敗した: \(error)")
            throw error as? ConversationError ?? ConversationError.failed("会話を起こせない: \(error)")
        }
        if phase == .starting { setPhase(.idle) }
        refreshDiffSoon()
    }

    /// daemon が起き直したとき：host にある key（生死にかかわらず）を引き取る。控えを終わりまで読み（defer で終えた問いなどを記録に書き）、
    /// 生きていれば initialize を送り直す。読み終えるか `ConversationTiming.replay` まで返らないので、返るまで同じ key を起こさない
    func attach(process: AgentHostProcessInfo, prewarmed: Bool) async {
        startReading()
        // 事前起動のプロセスは、まだ発言を受けていない（最初の発言に案内を入れる）
        if prewarmed { guidePending = true }
        generation += 1
        setChild(process.alive ? .running(acceptsInput: true) : .none)
        endRunningBackgroundTasks()
        // 控えの頭が自分で捨てた所より先なら、捨てていない行が落ちている（裏のタスクを数え直せない）
        backgroundTasksKnown = process.firstSeq - 1 <= record.trimmedThrough
        replayThrough = process.lastSeq
        needsReconcile = process.alive
        if process.alive { _ = context.reservations.reserve(Self.reservationKey(record.agentSessionId), owner: id) }
        // 起こし直しを host に断られて止まった扱いになった記録は、生きている子に合わせる
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
        if process.lastSeq == 0, process.alive { await reconcileSoon() }
        await waitForReplay(alive: process.alive, timeout: context.timing.replay)
        // 答えた後の行が控えから捨てられていると、読み直しでは答えを見ない
        if let toolUseID = deferredQuestion?.request.toolUseID, context.answeredInTranscript(record.agentSessionId, toolUseID, launchEnvironment) {
            clearDeferred(answered: toolUseID)
        } else if process.alive {
            // defer で終えた子は生きていない。生きている子は問いを捨てて先へ進んでいる
            clearDeferred(answered: nil)
        }
        if process.alive { refreshDiffSoon() }
    }

    private var replayed: Bool { appliedSeq >= replayThrough && child != .none }

    private func waitForReplay(alive: Bool, timeout: Duration) async {
        guard !replayed else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            replayWaiters.append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.releaseReplayWaiters()
            }
        }
    }

    /// host が起き直した（前の host の子は止まっている）。番号は 1 から振り直される
    func hostRestarted() async {
        appliedSeq = 0
        replayThrough = 0
        await helper?.hostGone()
        guard child.isRunning else { return }
        await exited(.hostRestarted)
    }

    // MARK: 送る・答える・制御

    /// 発言を送る。画像は添付の id。同じ `clientMessageID` は 2 回入れない
    func send(_ request: ConversationSendRequest) async throws -> ConversationSendOutcome {
        try await send(request, clearingResumeWaits: true)
    }

    /// `clearingResumeWaits` が false なら利用枠の待ちを残す（区切った待ちの前の圧縮）
    private func send(_ request: ConversationSendRequest, clearingResumeWaits: Bool) async throws -> ConversationSendOutcome {
        guard UUID(uuidString: request.clientMessageID) != nil else { throw ConversationError.invalid("client_message_id は UUID") }
        let uuid = request.clientMessageID.lowercased()
        if accepted[uuid] != nil { return .duplicate }
        let images = try request.attachments.map { attachment -> ClaudeStreamInput.Image in
            guard let url = context.attachments?.file(id: attachment), let data = try? Data(contentsOf: url),
                let type = ChatAttachment.ImageType(sniffing: data)
            else { throw ConversationError(status: 404, code: .attachmentMissing, description: "添付 \(attachment) が無い") }
            return ClaudeStreamInput.Image(mediaType: "image/\(type.rawValue)", base64: data.base64EncodedString())
        }
        let text = try ConversationSendText.compose(request, engine: .claude)
        // 人や agent が送った：taskboard が送る続き（利用枠の上限の後・ネットワークが戻った後）は送らない。最初の await より前に消す（書き込みを待つ間に見回りが続きを送らない）。
        // 起こせない・書けないで送れなくても戻さない（戻すと、その間に人が止めて消した待ちまで戻る。送れなかったことは送った側に返る）
        if clearingResumeWaits { clearResumeWaits() }
        if !child.acceptsInput {
            // 止まっている会話は起こしてから送る
            try await wake()
            if accepted[uuid] != nil { return .duplicate }
            guard child.acceptsInput else { throw ConversationError.stopped(id) }
        }
        lastActive = context.now()
        let line = ClaudeStreamInput.user(text: text, images: images, uuid: uuid, later: request.isLater)
        queuedLines.append((uuid, line))
        if request.isLater { laterMessages.insert(uuid) }
        do {
            try await writeUser(uuid, line)
        } catch {
            queuedLines.removeAll { $0.uuid == uuid }
            laterMessages.remove(uuid)
            throw error
        }
        let prompt = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if titlePrompt == nil, record.title == nil, record.customTitle == nil, !prompt.isEmpty, !prompt.hasPrefix("/") { titlePrompt = prompt }
        // 巻き戻しでファイルを戻せたか分からないままでも、人が先へ進めた（帯を消す）
        if record.rewindFilesPending {
            updateRecord { $0.rewindFilesPending = false }
            publishState()
        }
        return await waitForLifecycle(uuid, states: Self.anyLifecycle) != nil ? .accepted : .unknown
    }

    /// 回答・レビュー・知らせを発言として入れる。uuid は届けるものの id と回数から決める。モデルに渡ったら `delivered`。
    /// 待ち行列に入ったまま interrupt で取り消されると届かないので、空いている会話にだけ入れ、`queued` では届いたことにしない。
    /// 止まっている会話を `wake` が起こさないなら `busy`
    func deliver(text: String, uuid: String, wake: ConversationWakePolicy) async throws -> ConversationDeliveryOutcome {
        try await deliver(text: text, uuid: uuid, resume: nil, wake: wake)
    }

    /// taskboard が送る続き（利用枠の上限の後・ネットワークが戻った後）と、送る前に残っているかを見直す待ちの時刻
    private enum ResumeWait: Equatable {
        case limit(Date)
        case network(Date)
    }

    /// その続きの待ちがまだ残っている（人が送った・止めた・取り消したら消えている）
    private func waiting(_ wait: ResumeWait) -> Bool {
        switch wait {
        case .limit(let at): record.limitResumeAt == at
        case .network(let at): record.networkResumeAt == at
        }
    }

    /// `resume` は taskboard が送る続き（送る直前に、その待ちが残っているかを見直す）。
    /// 利用枠の上限の後の続きでない発言は、上限の待ちの間は入れない（入れても上限で断られて終わる）
    private func deliver(text: String, uuid: String, resume: ResumeWait?, wake policy: ConversationWakePolicy) async throws -> ConversationDeliveryOutcome {
        if let state = accepted[uuid] { return await deliveryOutcome(uuid, known: state) }
        if case .limit = resume {} else if let at = record.limitResumeAt, at > context.now() { return .busy }
        if let resume, !waiting(resume) { return .cancelled }
        // 答えて起こした問いを CLI が PreToolUse で受け取る前に発言を入れると、CLI は問いを捨ててその発言に答える
        if resuming != nil { return .busy }
        if !child.acceptsInput {
            // defer で終えた問いは、答えるまで起こしても CLI が同じ問いで終わる
            guard record.deferred == nil else { return .busy }
            switch policy {
            case .always: break
            case .unlessStoppedByPerson: guard record.stopCause?.keepsStopped != true else { return .busy }
            case .never: return .busy
            }
            // 止まっている会話は起こしてから入れる
            try await wake()
            if let state = accepted[uuid] { return await deliveryOutcome(uuid, known: state) }
            guard child.acceptsInput else { throw ConversationError.stopped(id) }
        }
        guard phase == .idle else { return .busy }
        if let resume, !waiting(resume) { return .cancelled }
        // 待ちに回答・知らせが先に入った：その発言で会話が動くので、続きは送らない（人が送ったときと同じ）
        if resume == nil { clearResumeWaits() }
        lastActive = context.now()
        try await writeUser(uuid, ClaudeStreamInput.user(text: text, uuid: uuid))
        return Self.outcome(await waitForLifecycle(uuid, states: Self.reachedModel))
    }

    /// 前に届けた uuid の今の状態（daemon が起き直した後の受け取りの確かめ）
    func deliveryState(_ uuid: String) async -> ConversationDeliveryOutcome {
        guard let state = accepted[uuid] else { return .unknown }
        return await deliveryOutcome(uuid, known: state)
    }

    private func deliveryOutcome(_ uuid: String, known state: String) async -> ConversationDeliveryOutcome {
        switch state {
        // 控えは `queued` の発言より先を捨てないので、記録にあって控えに続きが無ければ待ち行列を出ている
        case Self.recorded: return .delivered
        case "queued": return Self.outcome(await waitForLifecycle(uuid, states: Self.reachedModel))
        default: return Self.outcome(state)
        }
    }

    private static func outcome(_ state: String?) -> ConversationDeliveryOutcome {
        switch state {
        case .some(let value) where reachedModel.contains(value) || value == recorded: .delivered
        case "cancelled": .cancelled
        default: .unknown
        }
    }

    /// 問いに答える。動いている間の `can_use_tool` は応答を返し、defer で終えた問いは `--resume` で起こして返す。
    /// 最初の await より前に問いを「答えている途中」に移す。途中に来た同じ答えは同じ結果を待ち、違う答えは 409（`notWaiting`）
    func answer(_ request: ConversationAnswerRequest) async throws {
        if let inflight = answering[request.requestID] {
            guard inflight.request == request else { throw ConversationError.notWaiting(request.requestID) }
            let result = await withCheckedContinuation { (waiter: CheckedContinuation<Result<Void, ConversationError>, Never>) in
                answering[request.requestID]?.waiters.append(waiter)
            }
            return try result.get()
        }
        guard !retired else { throw ConversationError.removed(id) }
        guard pending[request.requestID] != nil || deferredQuestion?.request.id == request.requestID else { throw ConversationError.notWaiting(request.requestID) }
        answering[request.requestID] = (request, [])
        lastActive = context.now()
        let result: Result<Void, ConversationError>
        do {
            try await answerNow(request)
            result = .success(())
        } catch {
            result = .failure(error as? ConversationError ?? .failed("答えを書けない: \(error)"))
        }
        for waiter in answering.removeValue(forKey: request.requestID)?.waiters ?? [] { waiter.resume(returning: result) }
        try result.get()
    }

    private func answerNow(_ request: ConversationAnswerRequest) async throws {
        if let entry = pending[request.requestID], entry.request.kind == .elicitation {
            let response = try elicitationResponse(entry.request, answer: request)
            do {
                try await context.host.write(key: id, ClaudeStreamInput.success(id: request.requestID, response))
            } catch {
                needsReconcile = true
                throw error
            }
            removePending(request.requestID)
            setPhase(phaseAfterAnswered)
            return
        }
        if let entry = pending[request.requestID] {
            let decision = try decision(entry.request, inputJSON: entry.inputJSON, suggestionsJSON: entry.suggestionsJSON, answer: request)
            // 書けてから問いを消す。書けたか分からないまま消すと、CLI は答えを待ち続けるのに、画面からは問いが消えて答え直せない。
            // 書けていたのに応答だけ切れて答え直しても、CLI は同じ request の 2 回目を読み捨てる（2.1.302 で実測）
            do {
                try await context.host.write(key: id, ClaudeStreamInput.success(id: request.requestID, ClaudeRequests.permissionResponse(decision)))
            } catch {
                // 書けていたなら CLI は先へ進んでいる。次に行を読んだら、CLI が待っている問いと照らし直す
                needsReconcile = true
                throw error
            }
            removePending(request.requestID)
            if case .allow(_, let remember?) = decision, remember.suggestion.kind == .mode { rememberMode(remember.suggestion.subject) }
            setPhase(phaseAfterAnswered)
            return
        }
        guard let deferred = deferredQuestion, deferred.request.id == request.requestID else { throw ConversationError.notWaiting(request.requestID) }
        let decision = try decision(deferred.request, inputJSON: deferred.inputJSON, answer: request)
        // defer の後は入力を閉じてある。プロセスが終わりきる前に答えが来たら、終わるのを待ってから起こし直す
        if child.isRunning, await !waitForExit(timeout: context.timing.stopInput) { throw ConversationError.failed("前のプロセスが終わらない") }
        resuming = (deferred, decision)
        do {
            try await start(resume: true)
        } catch {
            resuming = nil
            throw error
        }
    }

    func control(_ request: ConversationControlRequest) async throws -> ConversationControlResponse {
        switch request.kind {
        case .compact, .newThread, .review:
            throw ConversationError.controlUnsupported(request.kind.rawValue, engine: .claude)
        case .deferQuestions:
            switch request.value {
            case "on", "true": deferMode = .on
            case "off", "false": deferMode = .off
            case "auto", nil: deferMode = .auto
            default: throw ConversationError.invalid("defer_questions は on・off・auto")
            }
            return ConversationControlResponse(payloadJSON: ClaudeStreamParser.json(["defer": deferMode.rawValue]))
        case .setNotifyParent:
            return try setNotifyParent(request)
        case .interrupt:
            lastActive = context.now()
            return try await interrupt()
        case .sendNow:
            guard let uuid = request.value.flatMap(UUID.init(uuidString:)) else { throw ConversationError.invalid("今すぐ送る発言の uuid が無い") }
            guard info?.capabilities.contains("interrupt_send_now_v1") == true else { throw ConversationError.controlUnsupported(request.kind.rawValue, engine: .claude) }
            lastActive = context.now()
            let messageID = uuid.uuidString.lowercased()
            if laterMessages.contains(messageID) { try await sooner(messageID) }
            if try await moveForegroundToBackground(for: messageID) {
                return ConversationControlResponse(
                    payloadJSON: ClaudeStreamParser.json(["send_now": ConversationSendNow.Outcome.delivering.rawValue, "backgrounded": true]))
            }
            return try await response(control("interrupt", ["send_now": true, "message_uuid": resentAs[messageID] ?? messageID]))
        case .cancelQueued:
            guard let uuid = request.value.flatMap(UUID.init(uuidString:)) else { throw ConversationError.invalid("取り消す発言の uuid が無い") }
            lastActive = context.now()
            let messageID = uuid.uuidString.lowercased()
            return try await response(control("cancel_async_message", ["message_uuid": resentAs[messageID] ?? messageID]))
        case .setModel:
            let models = context.models()
            guard let value = request.value, let model = models.argument(for: value) else {
                throw ConversationError.invalid(request.value.map { models.rejection($0) } ?? "model が無い")
            }
            return try await setting("set_model", ["model": model]) { $0.model = model }
        case .setEffort:
            guard let effort = request.value, Effort(rawValue: effort) != nil else { throw ConversationError.invalid("effort が違う") }
            return try await setting("apply_flag_settings", ["settings": ["effortLevel": effort]]) { $0.effort = effort }
        case .setPermissionMode:
            guard let mode = request.value, ConversationInput.acceptedPermissionModes.contains(mode) else { throw ConversationError.invalid("permission_mode が違う") }
            if mode == Self.bypassMode { return try await switchToBypass() }
            return try await setting("set_permission_mode", ["mode": mode]) { $0.permissionMode = mode }
        case .mcpStatus:
            // CLI の応答の config（stdio の env・HTTP の headers）と error（server が返した文）は外に出さない
            let raw = try await control("mcp_status")
            guard raw.isSuccess else { throw ConversationError.failed(raw.error ?? "断られた") }
            let status = ClaudeControls.mcpStatus(payload: raw.payloadJSON)
            return ConversationControlResponse(payloadJSON: (try? encoder.encode(status)).map { String(decoding: $0, as: UTF8.self) })
        case .mcpReconnect:
            return try await response(control("mcp_reconnect", ["serverName": try serverName(request)]))
        case .mcpToggle:
            guard let name = request.value, !name.isEmpty, let enabled = request.enabled else { throw ConversationError.invalid("server の名前と enabled が要る") }
            return try await response(control("mcp_toggle", ["serverName": name, "enabled": enabled]))
        case .contextUsage:
            let session = record.agentSessionId
            let response = try await response(control("get_context_usage", ["detail": "summary"]))
            applyContext(response.payloadJSON, session: session)
            return response
        case .contextBreakdown:
            let session = record.agentSessionId
            let response = try await response(control("get_context_usage", ["detail": "summary"]))
            applyContext(response.payloadJSON, session: session)
            guard let breakdown = ClaudeControls.contextBreakdown(payload: response.payloadJSON, agentSessionID: session) else {
                throw ConversationError.failed("コンテキストの内訳を読めない")
            }
            return ConversationControlResponse(payloadJSON: (try? encoder.encode(breakdown)).map { String(decoding: $0, as: UTF8.self) })
        case .usage: return try await response(control("get_usage"))
        case .rename:
            try await setCustomTitle(ConversationInput.customTitle(request.value))
            return ConversationControlResponse(payloadJSON: nil)
        case .cancelLimitResume:
            clearResumeWaits()
            return ConversationControlResponse(payloadJSON: nil)
        case .elicitationURL:
            // 開く先の全文は要求した端末への応答にだけ載せる
            guard let requestID = request.value, let entry = pending[requestID], entry.request.kind == .elicitation else {
                throw ConversationError.notWaiting(request.value ?? "")
            }
            guard let url = entry.url.flatMap({ OAuthLinks.openable($0.absoluteString) }) else { throw ConversationError.invalid("開ける URL が無い") }
            return ConversationControlResponse(payloadJSON: (try? encoder.encode(ElicitationURLResponse(url: url.absoluteString))).map { String(decoding: $0, as: UTF8.self) })
        case .mcpAuthenticate:
            let raw = try await control("mcp_authenticate", ["serverName": try serverName(request)])
            // 応答の行に認証の URL がある。空いていればその行まで控えを切り、生成中ならターンの終わりの trim に任せる
            if phase == .idle, trimmable { await trim(through: raw.seq) }
            guard raw.isSuccess else { throw ConversationError.failed(raw.error ?? "断られた") }
            guard let authentication = ClaudeControls.mcpAuthentication(payload: raw.payloadJSON) else {
                throw ConversationError.failed("mcp_authenticate の応答を読めない")
            }
            return ConversationControlResponse(payloadJSON: (try? encoder.encode(authentication)).map { String(decoding: $0, as: UTF8.self) })
        case .mcpOAuthCallback:
            let name = try serverName(request)
            guard let url = request.callbackURL.flatMap(OAuthLinks.callback) else { throw ConversationError.invalid("認証の後に開いたページのアドレスが違う") }
            do {
                _ = try response(await control("mcp_oauth_callback_url", ["serverName": name, "callbackUrl": url.absoluteString]))
                return try response(await control("mcp_reconnect", ["serverName": name]))
            } catch {
                // 応答だけが失われてアプリが送り直すと、CLI は 2 回目の callback を断る。繋がっていれば済んでいる
                if await isConnected(name) { return ConversationControlResponse(payloadJSON: nil) }
                throw error
            }
        case .mcpClearAuth:
            return try await response(control("mcp_clear_auth", ["serverName": try serverName(request)]))
        case .exportConversation:
            return try encoded(ClaudeControls.export(payload: try response(await control("export_conversation")).payloadJSON), "export_conversation")
        case .sandbox:
            return try encoded(ClaudeControls.sandbox(payload: try response(await control("get_sandbox_dialog")).payloadJSON), "get_sandbox_dialog")
        case .editSettings:
            return try encoded(try await editSettings(request.edit), "edit_settings")
        case .plugins:
            guard child.isRunning else { throw ConversationError.stopped(id) }
            let list = try await pluginRun(ClaudePlugins.list)
            let marketplaces = try await pluginRun(ClaudePlugins.marketplaces)
            guard list.status == 0, !list.timedOut, !list.overflowed else { throw ConversationError.failed("plugin の一覧を読めない") }
            return try encoded(ClaudePlugins.plugins(list: list.stdout, marketplaces: marketplaces.stdout, query: request.value), "plugins")
        case .listBackgroundTasks:
            return try encoded(ConversationBackgroundTasks(tasks: backgroundTasks, known: backgroundTasksKnown), "list_background_tasks")
        case .taskOutput:
            let output = try response(await control("get_task_output", ["task_id": try taskID(request)]))
            return try encoded(ClaudeControls.taskOutput(payload: output.payloadJSON), "get_task_output")
        case .stopTask:
            _ = try response(await control("stop_task", ["task_id": try taskID(request)]))
            return ConversationControlResponse(payloadJSON: nil)
        case .permissionRules:
            return try encoded(ClaudeControls.permissionRules(payload: try response(await control("list_permission_rules")).payloadJSON), "list_permission_rules")
        case .hooks:
            return try encoded(ClaudeControls.hooks(payload: try response(await control("get_hooks_listing")).payloadJSON), "get_hooks_listing")
        case .memory:
            return try encoded(ClaudeControls.memory(payload: try response(await control("get_memory_dialog")).payloadJSON), "get_memory_dialog")
        case .skills:
            return try encoded(ClaudeControls.skills(payload: try response(await control("get_skills_dialog")).payloadJSON), "get_skills_dialog")
        case .sideQuestion:
            guard let question = request.value?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
                throw ConversationError.invalid("質問が空")
            }
            guard question.utf8.count <= ConversationInput.textBytes else { throw ConversationError.invalid("質問は 1MB まで") }
            // 答えはモデルが書くので、ほかの制御要求より長く待つ
            let answer = try response(await control("side_question", ["question": question], timeout: context.timing.sideQuestion))
            return try encoded(ClaudeControls.sideAnswer(payload: answer.payloadJSON), "side_question")
        case .addDirectory:
            let added = try response(await control("register_repo_root", ["directory": try directory(request)]))
            return try encoded(ClaudeControls.directoryAdded(payload: added.payloadJSON), "register_repo_root")
        case .login:
            let raw = try await control("claude_authenticate", ["loginWithClaudeAi": true])
            // 応答の行にログインの URL がある。空いていればその行まで控えを切り、生成中ならターンの終わりの trim に任せる
            if phase == .idle, trimmable { await trim(through: raw.seq) }
            guard raw.isSuccess else { throw ConversationError.failed(raw.error ?? "断られた") }
            // 貼ったコードを照らし合わせられないページでは始めない
            guard let login = ClaudeControls.login(payload: raw.payloadJSON), let state = ClaudeControls.loginState(login) else {
                throw ConversationError.failed("claude_authenticate の応答を読めない")
            }
            // 2 回目の claude_authenticate は同じ流れのページを返すので、待ちも 1 本のまま
            loginState = state
            loginCodeSent = false
            try await waitForLogin()
            return try encoded(login, "claude_authenticate")
        case .loginCode:
            guard let (code, state) = ClaudeControls.loginCode(request.code) else { throw ConversationError.invalid("ログインのページに出たコードを貼る") }
            guard loginStage == .waiting, let loginState else { throw ConversationError.invalid("待っているログインが無い") }
            guard state == loginState else { throw ConversationError.invalid("このログインのコードではない") }
            guard !loginCodeSent else { throw ConversationError.invalid("このログインのコードはもう渡した") }
            // claude_oauth_callback は流れが終わるまで答えないので待たない。終わりは claude_oauth_wait_for_completion で知る
            loginCodeSent = true
            do {
                try await send("claude_oauth_callback", ["authorizationCode": code, "state": state])
            } catch {
                loginCodeSent = false
                throw error
            }
            return ConversationControlResponse(payloadJSON: nil)
        case .setCwd:
            let raw = try response(await control("set_cwd", ["path": try directory(request)]))
            guard let change = ClaudeControls.cwdChange(payload: raw.payloadJSON) else { throw ConversationError.failed("set_cwd の応答を読めない") }
            // 替えたと答えたときだけ記録の作業フォルダを替える（次に起こすとき・差分・シェルが新しいフォルダを使う）
            if change.outcome == .moved, let cwd = change.directory, cwd != record.cwd {
                try writeRecord { $0.cwd = cwd }
                publishState()
                refreshDiffSoon()
            }
            return try encoded(change, "set_cwd")
        }
    }

    /// 設定を書く：CLI のサブコマンドを会話の作業フォルダで起こす（会話のプロセスには送らない。動いている CLI は書いたファイルを自分で読み直す）。
    /// 断られたら理由の種類だけを返し、CLI の文はログに残す
    private func editSettings(_ edit: ConversationSettingsEdit?) async throws -> ConversationSettingsEditResult {
        guard child.isRunning else { throw ConversationError.stopped(id) }
        guard let edit else { throw ConversationError.invalid("書く設定（edit）が無い") }
        switch edit {
        case .plugin, .marketplace: return try await editPlugins(edit)
        default: break
        }
        var target: ClaudeSettingsEdits.HookTarget?
        if case .hook(let op, _, _, _, _, let key) = edit, op != .add {
            // 鍵は中身のハッシュなので、今の一覧から中身を引く（一覧を開いた後に変わっていれば見つからない）
            guard let key else { throw ConversationError.invalid("書き換える hook の鍵（editKey）が無い") }
            // 一覧の失敗の文は CLI のもの（hook の中身を引用しうる）なので、応答に入れない
            guard let listing = try? response(await control("get_hooks_listing")).payloadJSON else {
                throw ConversationError.failed("hook の一覧を読めない")
            }
            guard let found = ClaudeSettingsEdits.hookTargets(listing: listing).first(where: { $0.key == key }) else {
                throw ConversationError.settingsRejected("not_found")
            }
            target = found.target
        }
        let invocation = try ClaudeSettingsEdits.invocation(edit, target: target)
        let launch = try await context.launch()
        lastActive = context.now()
        let outcome: Subprocess.Outcome
        do {
            outcome = try await context.settingsCLI(
                launch.executable, [invocation.subcommand, "--json"], ClaudeSettingsEdits.environment(launch.environment), invocation.input, record.cwd)
        } catch {
            throw ConversationError.failed("設定を書く CLI を起こせない: \(error)")
        }
        switch try ClaudeSettingsEdits.answer(outcome) {
        case .written(let result, let warnings):
            context.logger.info(
                "conversation settings written", metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue), "warnings": "\(warnings)"])
            return result
        case .rejected(let reason, let status):
            context.logger.warning(
                "conversation settings rejected",
                metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue), "reason": .string(reason), "status": "\(status)"])
            throw ConversationError.settingsRejected(reason)
        }
    }

    private func pluginRun(_ arguments: [String]) async throws -> Subprocess.Outcome {
        let launch = try await context.launch()
        lastActive = context.now()
        do {
            return try await context.pluginCLI(launch.executable, arguments, ClaudeSettingsEdits.environment(launch.environment), record.cwd)
        } catch {
            throw ConversationError.failed("plugin の CLI を起こせない: \(error)")
        }
    }

    /// plugin の書き込みを 1 つ通す。断られたら理由の種類で断る（CLI の文は書いた値を引用しうるので、ログにも残さない）
    private func pluginWrite(_ arguments: [String], _ edit: ConversationSettingsEdit) async throws -> ClaudePlugins.Reply {
        let outcome = try await pluginRun(arguments)
        let reply = try ClaudePlugins.reply(outcome)
        if case .rejected(let reason, let status) = reply {
            context.logger.warning(
                "conversation settings rejected",
                metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue), "reason": .string(reason), "status": "\(status)"])
            throw ConversationError.settingsRejected(reason)
        }
        return reply
    }

    /// 入れた plugin の一覧（`plugin list --json`）。外す対象を決めるのに使うので、読めない・形が違うときは失敗にする
    private func installedPlugins() async throws -> [ConversationPlugins.Plugin] {
        let outcome = try await pluginRun(ClaudePlugins.installed)
        guard outcome.status == 0, !outcome.timedOut, !outcome.overflowed else { throw ConversationError.failed("入れた plugin の一覧を読めない") }
        return try ClaudePlugins.installedPluginsForRemoval(outcome.stdout)
    }

    /// 値を保存してある設定の名前。保存する設定の無い plugin は CLI に聞かない
    private func savedOptions(_ plugin: ConversationPlugins.Plugin) async throws -> [String] {
        plugin.hasOptions == false ? [] : try ClaudePlugins.configuredOptions(try await pluginRun(ClaudePlugins.configure(plugin.id)))
    }

    /// plugin と marketplace を `claude plugin` で書き、動いている CLI に `reload_plugins` で読み直させる（CLI は自分では読み直さない。実測）。
    /// 外すと消えて戻せないもの（データの置き場・保存した設定）があるときは、書かずに `confirmation` を返す。送り直しの `confirmDigest` が
    /// 今の対象から作り直した digest と合うときだけ書く（人が見た後に対象が替わっていれば、確かめ直す）。確かめた状態は daemon に持たない
    private func editPlugins(_ edit: ConversationSettingsEdit) async throws -> ConversationSettingsEditResult {
        func confirmed(_ confirmation: ConversationSettingsEditResult.Confirmation, _ confirm: Bool?, _ digest: String?) -> Bool {
            confirm == true && digest == confirmation.digest
        }
        // 書く CLI を 1 つでも起こしたか（途中で失敗したら読み直す）
        var wrote = false
        do {
            switch edit {
            case .plugin(let op, let rawID, let scope, let acceptCommand, let confirm, let digest):
                let id = try ClaudePlugins.token(rawID, "plugin の id ")
                let accept = try acceptCommand.map { try ClaudePlugins.token($0, "コマンドの sha256 ") }
                switch op {
                case .install, .update:
                    let arguments = op == .install
                        ? ClaudePlugins.install(id, scope: scope, acceptCommand: accept) : ClaudePlugins.update(id, scope: scope, acceptCommand: accept)
                    wrote = true
                    if case .shown(let command) = try await pluginWrite(arguments, edit) {
                        // 見せただけで何も書いていない
                        wrote = false
                        return ConversationSettingsEditResult(shownCommand: command)
                    }
                case .uninstall, .purge:
                    // 層を省いたら入れた層で外す（CLI の既定は user で、ほかの層の plugin は見つからない）
                    guard let plugin = try await installedPlugins().first(where: { $0.id == id && (scope == nil || $0.scope == scope.map(ClaudePlugins.scope)) })
                    else { throw ConversationError.settingsRejected("not_found") }
                    let options = try await savedOptions(plugin)
                    if op == .purge || !options.isEmpty {
                        let confirmation = ClaudePlugins.confirmation(op == .purge ? .data : .options, plugins: [.init(id: id, scope: plugin.scope)], options: options)
                        if !confirmed(confirmation, confirm, digest) { return ConversationSettingsEditResult(confirmation: confirmation) }
                    }
                    wrote = true
                    _ = try await pluginWrite(ClaudePlugins.uninstall(id, scope: plugin.scope, keepData: op == .uninstall), edit)
                case .enable, .disable:
                    wrote = true
                    _ = try await pluginWrite(ClaudePlugins.toggle(id, enabled: op == .enable, scope: scope), edit)
                }
            case .marketplace(let op, let source, let rawName, let scope, let confirm, let digest):
                switch op {
                case .add:
                    let arguments = ClaudePlugins.marketplaceAdd(try ClaudePlugins.token(source, "marketplace の source ", allowsSpaces: true), scope: scope)
                    wrote = true
                    _ = try await pluginWrite(arguments, edit)
                case .update:
                    let arguments = ClaudePlugins.marketplaceUpdate(try ClaudePlugins.token(rawName, "marketplace の名前 "))
                    wrote = true
                    _ = try await pluginWrite(arguments, edit)
                case .remove:
                    // CLI はその marketplace の plugin をデータごと外すので、先に plugin をデータを残して外す（実測）。層を付けたらその層の plugin だけ
                    let name = try ClaudePlugins.token(rawName, "marketplace の名前 ")
                    // 層を付けたのにその層が宣言していなければ、CLI は plugin を外した後で断る（実測）ので、何も外さずに断る
                    if let scope {
                        let file = ClaudePlugins.settingsFile(scope, environment: try await context.launch().environment, cwd: record.cwd)
                        guard try ClaudePlugins.declares(context.readFile(file), marketplace: name) else { throw ConversationError.settingsRejected("not_found") }
                    }
                    let targets = try await installedPlugins().filter { $0.marketplace == name && (scope == nil || $0.scope == scope.map(ClaudePlugins.scope)) }
                    var options: [String] = []
                    for plugin in targets { options += try await savedOptions(plugin) }
                    if !options.isEmpty {
                        let confirmation = ClaudePlugins.confirmation(.options, plugins: targets.map { .init(id: $0.id, scope: $0.scope) }, options: options)
                        if !confirmed(confirmation, confirm, digest) { return ConversationSettingsEditResult(confirmation: confirmation) }
                    }
                    for plugin in targets {
                        wrote = true
                        _ = try await pluginWrite(ClaudePlugins.uninstall(plugin.id, scope: plugin.scope, keepData: true), edit)
                    }
                    wrote = true
                    _ = try await pluginWrite(ClaudePlugins.marketplaceRemove(name, scope: scope), edit)
                }
            default:
                throw ConversationError.invalid("plugin と marketplace のほかは edit_settings の CLI で書く")
            }
        } catch {
            // 途中まで書いたかもしれない：今の状態を読み直し、動いている CLI にも読み直させてから失敗を返す（巻き戻しはしない）
            if wrote { await refreshPlugins(edit, failed: true) }
            throw error
        }
        context.logger.info("conversation settings written", metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue)])
        await refreshPlugins(edit, failed: false)
        return ConversationSettingsEditResult()
    }

    /// 書いた後の読み直し。動いている CLI に `reload_plugins` を送る。失敗したときは入れた plugin の一覧も読み直し、残った数をログに残す
    private func refreshPlugins(_ edit: ConversationSettingsEdit, failed: Bool) async {
        if failed, let installed = try? await installedPlugins() {
            context.logger.warning(
                "conversation plugins partially written", metadata: ["conversation": .string(id), "target": .string(edit.target.rawValue), "installed": "\(installed.count)"])
        }
        if child.isRunning, (try? response(await control("reload_plugins"))) == nil {
            context.logger.warning("conversation plugins reload failed", metadata: ["conversation": .string(id)])
        }
    }

    /// `/login` の終わりを HTTP の要求から切り離して待つ。CLI は流れが終わるまで答えないので、応答は行を読む所で受ける（`loginFinished`）
    private func waitForLogin() async throws {
        loginStage = .waiting
        publishState()
        guard loginWaitRequest == nil, child.isRunning else { return }
        let requestID = "tb_login_\(UUID().uuidString)"
        loginWaitRequest = requestID
        do {
            try await context.host.write(key: id, ClaudeStreamInput.request(id: requestID, subtype: "claude_oauth_wait_for_completion", [:]))
        } catch {
            loginWaitRequest = nil
            loginStage = nil
            publishState()
            throw error
        }
    }

    private func loginFinished(_ response: ClaudeControlResponse) async {
        loginWaitRequest = nil
        loginState = nil
        loginCodeSent = false
        // 認証情報が書かれたかは、応答のアカウントで決める
        loginStage = response.isSuccess && ClaudeControls.loginAccount(payload: response.payloadJSON) ? .succeeded : .failed
        // 応答の行にアカウントがある
        if phase == .idle, trimmable { await trim(through: response.seq) }
        publishState()
    }

    /// 絶対パスか `~` で始まるパス（CLI が `~` を開いて実体のパスにする）
    private func directory(_ request: ConversationControlRequest) throws -> String {
        guard let path = request.value?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") || path.hasPrefix("~"),
            !path.contains("\0"), path.utf8.count <= 4096
        else { throw ConversationError.invalid("フォルダは絶対パスで渡す") }
        return path
    }

    /// 写した応答を JSON にする。写せない（engine の応答の形が違う）ときは失敗
    private func encoded<Value: Encodable>(_ value: Value?, _ subtype: String) throws -> ConversationControlResponse {
        guard let value, let data = try? encoder.encode(value) else { throw ConversationError.failed("\(subtype) の応答を読めない") }
        return ConversationControlResponse(payloadJSON: String(decoding: data, as: UTF8.self))
    }

    private func serverName(_ request: ConversationControlRequest) throws -> String {
        guard let name = request.value, !name.isEmpty else { throw ConversationError.invalid("server の名前が空") }
        return name
    }

    private func isConnected(_ server: String) async -> Bool {
        guard let raw = try? await control("mcp_status"), raw.isSuccess else { return false }
        return ClaudeControls.mcpStatus(payload: raw.payloadJSON).mcpServers.contains { $0.name == server && $0.status == "connected" }
    }

    /// モデル・effort・権限を替える。動いていれば CLI に送ってから記録を書き換え、止まっていれば記録だけ（次に起こすときの引数に入る）。
    /// 起こしている途中なら、起き終えてから CLI に送る（起こす引数に替える前の値が入っていることがある）
    private func setting(_ subtype: String, _ fields: [String: Any], _ change: (inout ConversationRecord) -> Void) async throws -> ConversationControlResponse {
        if let startTask { _ = try? await startTask.value }
        var result = ConversationControlResponse(payloadJSON: nil)
        if child.isRunning { result = try response(await control(subtype, fields)) }
        try writeRecord(change)
        publishState()
        return result
    }

    /// 「今後は聞かない」候補でモードが替わった（CLI は応答を受けて替える）ので、記録も揃える
    private func rememberMode(_ mode: String) {
        // 答えはもう CLI に届いている。記録を書けなくても答えは失敗にしない
        do {
            try writeRecord { $0.permissionMode = mode }
            publishState()
        } catch {
            context.logger.warning("conversation permission mode not recorded", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
    }

    /// 確認なし（bypassPermissions）に替える。`--allow-dangerously-skip-permissions` を付けずに起こした CLI（その引数を足す前の版の daemon が
    /// 起こした子。agent host は daemon を入れ替えても子を起こし直さない）は断るので、空いていれば記録を替えて止め、`--resume` で起こし直す
    /// （起こす引数に付く）。空いていなければ断る
    private func switchToBypass() async throws -> ConversationControlResponse {
        if let startTask { _ = try? await startTask.value }
        guard child.isRunning else { return try await setting("set_permission_mode", ["mode": Self.bypassMode]) { $0.permissionMode = Self.bypassMode } }
        let answer = try await control("set_permission_mode", ["mode": Self.bypassMode])
        guard !answer.isSuccess else {
            try writeRecord { $0.permissionMode = Self.bypassMode }
            publishState()
            return ConversationControlResponse(payloadJSON: answer.payloadJSON)
        }
        guard isResting else { throw ConversationError.busy(id, "確認なしへの切り替えに再起動が要るが、生成中・問いの待ち・裏のタスクがあって再起動できない") }
        context.logger.info("conversation restarting for bypass", metadata: ["conversation": .string(id), "error": .string(answer.error ?? "")])
        try writeRecord { $0.permissionMode = Self.bypassMode }
        restarting = true
        defer { restarting = false }
        await stop(.taskboard)
        try await wake()
        emit(.notice(ConversationScreenText.restartedForBypass))
        return ConversationControlResponse(payloadJSON: ClaudeStreamParser.json(["restarted": true]))
    }

    /// `rename_session` は応答を返さないので待たない
    func sendTitle(_ title: String) async throws {
        guard child.isRunning else { return }
        controlCounter += 1
        try await context.host.write(key: id, ClaudeStreamInput.request(id: "tb_\(controlCounter)", subtype: "rename_session", ["title": title]))
    }

    /// 止める：送るのを断り、生成中なら待ち行列ごと中断して result を待ち、入力を閉じ、終わらなければ TERM・KILL
    func stop(_ cause: ConversationStopCause) async {
        // 止まった会話でも、taskboard が送る続き（利用枠の上限の後・ネットワークが戻った後）を取り消す
        clearResumeWaits()
        guard child.isRunning else { return }
        refuseInput()
        // 割り込んで終わると CLI は 0 以外で終わる。止めたことを理由に残す
        updateRecord { $0.lastExit = $0.lastExit ?? cause.lastExit }
        await finishStopping()
    }

    /// しばらく使っていない会話を止める（自動停止と、目安の上限を超えたとき）。確かめてから入力を断るまでに await を挟まないので、
    /// 同じ時に来た送る・答えるは、止める前に入るか、止めた後に起こし直して入る
    func stopIfIdle(before cutoff: Date) async -> Bool {
        guard isStoppable(before: cutoff) else { return false }
        refuseInput()
        updateRecord { $0.lastExit = ConversationStopCause.idle.lastExit }
        context.logger.info("stopped idle conversation", metadata: ["conversation": .string(id)])
        await finishStopping()
        return true
    }

    /// `isQuiet` の、画面に出ているかを問わない分
    var isResting: Bool {
        child.acceptsInput && phase == .idle && backgroundTasksKnown && backgroundTasks.isEmpty && answering.isEmpty && startTask == nil
            && pending.isEmpty && record.limitResumeAt == nil && record.networkResumeAt == nil
    }

    /// 定期起動の回の会話を、ターンを終えて静かになったら止める（`ScheduledRunCloser`。最初の発言を受けたかは呼ぶ側が見る）
    func stopIfFinished() async -> Bool {
        guard isQuiet else { return false }
        refuseInput()
        updateRecord { $0.lastExit = ConversationStopCause.finished.lastExit }
        context.logger.info("stopped finished scheduled conversation", metadata: ["conversation": .string(id)])
        await finishStopping()
        return true
    }

    /// 利用枠が戻った：止まったところから続ける発言を送る（`ConversationService` の見回り）。送れたら待ちを消す
    func continueAfterLimit() async {
        guard !retired, let at = record.limitResumeAt, at <= context.now() else { return }
        // 区切った待ち：上限で切れたターンは無いので続きは送らず、溜まった回答・知らせを入れる
        if record.limitPaused {
            clearResumeWaits()
            context.logger.info("usage pause ended", metadata: ["conversation": .string(id)])
            let conversationID = id
            let becameIdle = context.becameIdle
            Task { await becameIdle(conversationID) }
            return
        }
        let uuid = StableUUID.make("taskboard-limit:\(id):\(Int(at.timeIntervalSince1970))")
        let outcome: ConversationDeliveryOutcome
        do {
            outcome = try await deliver(text: Self.limitResumeText, uuid: uuid, resume: .limit(at), wake: DeliveryKind.limitResume.wake)
        } catch {
            context.logger.warning("conversation not continued after usage limit", metadata: ["conversation": .string(id), "error": "\(error)"])
            return
        }
        switch outcome {
        case .delivered:
            context.logger.info("conversation continued after usage limit", metadata: ["conversation": .string(id)])
            if record.limitResumeAt == at { clearResumeWaits() }
        case .cancelled where record.limitResumeAt == at:
            // 待ち行列で取り消された：1 分後に別の uuid で送り直す
            updateRecord { $0.limitResumeAt = Store.storedDate(self.context.now().addingTimeInterval(60)) }
            publishState()
        case .cancelled, .busy, .unknown:
            break
        }
    }

    /// 利用枠の上限で待っている会話を、枠の残っている別のアカウントに替えて（`arguments` はその `--settings` にした引数）、すぐに続ける
    func continueOnAccount(arguments: [String]) async {
        guard !retired, record.limitResumeAt != nil, arguments != record.extraArguments else { return }
        do {
            try await switchAccount(arguments: arguments)
        } catch {
            context.logger.warning("conversation not moved to another account", metadata: ["conversation": .string(id), "error": "\(error)"])
            return
        }
        context.logger.info("conversation moved to another account at usage limit", metadata: ["conversation": .string(id)])
        updateRecord { $0.limitResumeAt = Store.storedDate(self.context.now()) }
        publishState()
        await continueAfterLimit()
    }

    static let limitResumeText = TaskboardNotice.limitResumePrompt

    /// ネットワークに繋がらずに止まった会話に、繋がっていれば続きを送る（`ConversationService` の見回り）。`returned` は前の見回りから経路が戻った。
    /// 送れたら印を消して数を足す（その続きもまた繋がらずに終われば、`NetworkResumeRule` の間で印を付け直す）
    func continueAfterNetwork(online: Bool, returned: Bool) async {
        guard !retired, record.networkResumeAt != nil else { return }
        if returned {
            updateRecord {
                $0.networkResumeTries = 0
                $0.networkResumeAt = Store.storedDate(self.context.now())
            }
        }
        let tries = record.networkResumeTries
        guard online, let at = record.networkResumeAt, at <= context.now(), !NetworkResumeRule.exhausted(tries: tries) else { return }
        let uuid = StableUUID.make("taskboard-network:\(id):\(Int(at.timeIntervalSince1970 * 1000))")
        let outcome: ConversationDeliveryOutcome
        do {
            outcome = try await deliver(text: Self.networkResumeText, uuid: uuid, resume: .network(at), wake: .always)
        } catch {
            context.logger.warning("conversation not continued after network", metadata: ["conversation": .string(id), "error": "\(error)"])
            return
        }
        switch outcome {
        case .delivered where record.networkResumeAt == at:
            context.logger.info("conversation continued after network", metadata: ["conversation": .string(id), "tries": .stringConvertible(tries + 1)])
            updateRecord {
                $0.networkResumeAt = nil
                $0.networkResumeTries = tries + 1
            }
            publishState()
        case .cancelled where record.networkResumeAt == at:
            // 待ち行列で取り消された：1 分後に別の uuid で送り直す
            updateRecord { $0.networkResumeAt = Store.storedDate(self.context.now().addingTimeInterval(60)) }
            publishState()
        case .delivered, .cancelled, .busy, .unknown:
            break
        }
    }

    static let networkResumeText = TaskboardNotice.networkResumePrompt

    /// ターンがネットワークに繋がらずに終わった：接続があれば続きを送る印を付ける。続きを送った後の失敗なら間を広げる
    private func waitForNetwork() {
        let tries = record.networkResumeTries
        updateRecord { $0.networkResumeAt = Store.storedDate(NetworkResumeRule.nextAttempt(tries: tries, now: self.context.now())) }
        context.logger.info(
            "conversation waits for network",
            metadata: ["conversation": .string(id), "tries": .stringConvertible(tries), "exhausted": .stringConvertible(NetworkResumeRule.exhausted(tries: tries))])
        publishState()
    }

    /// 定期起動の回が利用枠の上限で断られた（`schedule_runs` の失敗の理由）
    static let scheduleRunLimitedReason = "利用枠の上限で止まりました"

    /// 利用枠が閾値を越えたターンの終わり：戻る時刻の 1 分後まで待つ。戻るまで prompt cache より長ければ、入力待ちに入ってから圧縮する
    private func pauseForUsage(until resets: Date) {
        let compacts = UsagePauseRule.compacts(resetsAt: resets, now: context.now())
        updateRecord {
            $0.limitResumeAt = Store.storedDate(resets.addingTimeInterval(60))
            $0.limitPaused = true
        }
        context.logger.info("conversation paused for usage", metadata: ["conversation": .string(id), "resetsAt": .stringConvertible(resets), "compacts": .stringConvertible(compacts)])
        publishState()
        guard compacts else { return }
        pauseCompactPending = true
        compactForPauseIfIdle()
    }

    private func compactForPauseIfIdle() {
        guard pauseCompactPending, phase == .idle else { return }
        pauseCompactPending = false
        Task { await self.compactForPause() }
    }

    /// 区切った待ちが残っている間だけ送る。人が送った・取り消した・止めたら待ちごと消えている
    private func compactForPause() async {
        guard record.limitPaused, record.limitResumeAt != nil, child.acceptsInput, phase == .idle else { return }
        compactingIdle = true
        do {
            _ = try await send(ConversationSendRequest(text: "/compact"), clearingResumeWaits: false)
            context.logger.info("usage pause compaction sent", metadata: ["conversation": .string(id)])
        } catch {
            compactingIdle = false
            context.logger.warning("usage pause compaction not sent", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
    }

    /// これより小さい会話は空いても圧縮しない（`/context` の Messages の行。圧縮で縮むのはこの分だけ）
    static let idleCompactMinMessageTokens = 30_000

    func compactIfIdle() async {
        guard let at = answeredAt, isResting else { return }
        let idle = context.now().timeIntervalSince(at)
        guard idle >= context.timing.idleCompact else { return }
        answeredAt = nil
        guard idle <= context.timing.idleCompactCutoff else {
            context.logger.info("idle compaction skipped: past cutoff", metadata: ["conversation": .string(id), "idleMinutes": .stringConvertible(Int(idle / 60))])
            return
        }
        let session = record.agentSessionId
        guard let usage = try? await response(control("get_context_usage", ["detail": "summary"])) else { return }
        applyContext(usage.payloadJSON, session: session)
        let messages = ClaudeControls.contextBreakdown(payload: usage.payloadJSON, agentSessionID: session)?
            .categories.first { $0.kind == .used && $0.name == "Messages" }?.tokens
        guard let messages, messages >= Self.idleCompactMinMessageTokens else {
            context.logger.info("idle compaction skipped: small", metadata: ["conversation": .string(id), "messageTokens": .stringConvertible(messages ?? -1)])
            return
        }
        // 内訳を待つ間に人が送った
        guard isResting, answeredAt == nil else { return }
        compactingIdle = true
        do {
            _ = try await send(ConversationSendRequest(text: "/compact"))
            context.logger.info("idle compaction sent", metadata: ["conversation": .string(id), "messageTokens": .stringConvertible(messages)])
        } catch {
            compactingIdle = false
            context.logger.warning("idle compaction not sent", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
    }

    /// 知らせを組むのに使う今の様子：動いていて生成中か（届けない）、答えを待っている問い
    var noticeState: (busy: Bool, requests: [ConversationRequest]) {
        let busy = child.isRunning && (phase == .running || phase == .starting)
        return (busy, pendingOrder.compactMap { pending[$0]?.request } + (deferredQuestion.map { [$0.request] } ?? []))
    }

    var lastActiveAt: Date { lastActive }

    private func finishStopping() async {
        // 最初の await より前に取る（止める途中で子が終わり、送る・答えるで起こし直された新しい子には触らない）
        let target = generation
        if phase == .running || phase == .waiting || phase == .starting {
            _ = try? await control("interrupt", ["cancel_queued": true], timeout: context.timing.stopResult)
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
        var conversation = Conversation(record: record, machine: context.machine, rewinding: rewinding)
        conversation.runner = child.isRunning ? .host : .none
        conversation.phase = phase
        conversation.pending = pendingOrder.compactMap { pending[$0]?.request }
        conversation.backgroundTasks = backgroundTasks.count
        conversation.backgroundTasksKnown = backgroundTasksKnown
        conversation.backgroundTaskStates =
            backgroundTasks.filter(\.isBackground).map { ConversationBackgroundTaskState(id: $0.id, status: .running) } + endedBackgroundTasks
        conversation.contextPercent = contextPercent
        conversation.diff = diff
        conversation.stats = stats
        conversation.login = loginStage
        conversation.compaction = compaction
        conversation.stalledSince = stalledSince
        conversation.apiRetry = apiRetry
        conversation.detachableTools = detachableTools > 0 ? detachableTools : nil
        if planSession != record.agentSessionId { reloadPlan() }
        conversation.plan = plan
        return conversation
    }

    /// 変わったら true
    @discardableResult
    private func reloadPlan() -> Bool {
        planSession = record.agentSessionId
        let items = context.taskList(record.agentSessionId, launchEnvironment)
        guard items != plan else { return false }
        plan = items
        return true
    }

    /// ［今すぐ送信］で裏に回せる tool の数（task になったものと、task になるのを待っているもの）
    private var detachableTools: Int { foregroundTasks.count + toolsAwaitingTask.count }

    var isLive: Bool { child.isRunning }
    var isIdle: Bool { child.isRunning && phase == .idle }
    var lastSeq: Int { log.lastSeq }
    /// 購読している接続の数（画面に出ているか）
    var viewers: Int { log.viewers }

    /// フォーク・巻き戻しの後の transcript ができた（以後は `--resume <今の ID>`）。CLI が要約の後だけを写していたら、写し元を記録に残す
    private func clearPendingFork() {
        if let source = record.pendingForkSessionId, let found = context.transcriptSource(record.agentSessionId, source, launchEnvironment) {
            do {
                try context.store.setTranscriptSource(of: record.agentSessionId, found)
            } catch {
                context.logger.error("conversation transcript source not recorded", metadata: ["conversation": .string(id), "error": "\(error)"])
            }
        }
        updateRecord {
            $0.pendingForkSessionId = nil
            $0.pendingForkAt = nil
        }
        publishState()
    }

    private func setCommands(_ list: [ConversationCommand]) {
        guard list != commands else { return }
        commands = list
        emit(.commands(list))
    }

    private func setContextPercent(_ percent: Int) {
        guard percent != contextPercent else { return }
        contextPercent = percent
        publishState()
    }

    /// 動いているプロセスに `rewind_files` を送る（`userMessageID` は人が送った発言の行の uuid）。CLI が断ったら `canRewind: false` を返す
    func rewindFiles(userMessageID: String, dryRun: Bool) async throws -> ConversationRewindResponse {
        var fields: [String: Any] = ["user_message_id": userMessageID]
        if dryRun { fields["dry_run"] = true }
        let response = try await control("rewind_files", fields)
        guard response.isSuccess else { return ConversationRewindResponse(canRewind: false, error: response.error) }
        guard let result = ClaudeControls.rewind(payload: response.payloadJSON) else { throw ConversationError.failed("rewind_files の応答を読めない") }
        return result
    }

    // MARK: 巻き戻し・元に戻す

    /// 巻き戻しと元に戻すの確かめ。最初の await より前に呼び、通ったら同じ turn のうちに `operation` を立てる
    private func checkOperable(expected: String) throws {
        guard !retired else { throw ConversationError.removed(id) }
        guard record.agentSessionId == expected else { throw ConversationError.changed(id) }
        guard operation == nil, helper == nil, startTask == nil, answering.isEmpty else { throw ConversationError.busy(id, "ほかの操作の途中") }
        guard pending.isEmpty, record.deferred == nil else { throw ConversationError.questionPending(id) }
        guard !child.isRunning || (child.acceptsInput && phase == .idle) else { throw ConversationError.busy(id, "生成中") }
        // 裏の Bash がファイルを書いている間に戻さない
        guard backgroundTasksKnown, backgroundTasks.isEmpty else { throw ConversationError.busy(id, "裏のタスクが動いている") }
    }

    /// `messageID`（人が送った発言）の前まで会話を戻す。`files` ならファイルも戻す。`dryRun` は何が変わるかだけを返し、会話は変えない。
    /// 会話を止めてから記録を新しい Claude の会話 ID に替え、ファイルは後で補助のプロセスで戻す（ファイルだけが戻って会話が戻らない状態を作らない）
    func rewind(_ request: ConversationRewindRequest, projects: URL) async throws -> ConversationRewindResponse {
        try checkOperable(expected: request.expectedAgentSessionID)
        let projects = projects.standardizedFileURL.resolvingSymlinksInPath()
        guard let url = TranscriptTail.locate(record.agentSessionId, in: projects) else { throw ConversationError.notSent(id) }
        let uuid = ConversationFork.lineUUID(request.messageID)
        guard !uuid.isEmpty, let line = TranscriptLines.find(uuid, in: url) else { throw ConversationError.messageNotFound(uuid) }
        guard let prompt = line.prompt else { throw ConversationError.invalid("人が送った発言ではない") }
        // 戻せるのは最後の要約より後だけ（要約より前の発言は読むだけ。画面も巻き戻しの操作を出さない）
        guard !TranscriptLines.hasBoundary(in: url, after: line.end) else { throw ConversationError.invalid("要約より前の発言には戻せない") }
        let helperKey = HelperProcess.rewindKey(id)
        let previous = record.agentSessionId
        let reservation = Self.reservationKey(previous)
        if request.dryRun {
            guard request.files else { return ConversationRewindResponse(canRewind: true) }
            if child.isRunning { return try await rewindFiles(userMessageID: line.uuid, dryRun: true) }
            operation = .rewind
            defer { operation = nil }
            guard context.reservations.reserve(reservation, owner: helperKey) else { throw ConversationError.running(previous) }
            defer { context.reservations.release(owner: helperKey) }
            switch await runHelper(session: previous, userMessageID: line.uuid, dryRun: true) {
            case .result(let result): return result
            case .refused(let message): throw ConversationError.failed("ファイルを戻せるか確かめられない: \(message)")
            case .unknown: throw ConversationError.failed("ファイルを戻せるか確かめられない")
            }
        }

        operation = .rewind
        let wasAccepting = child.acceptsInput
        refuseInput()
        // ファイルを戻す間は、今の ID の予約を補助の key で持つ（会話のプロセスが終わっても外れず、その間に TUI で同じ会話を起こせない）
        if request.files, !context.reservations.transfer(reservation, from: id, to: helperKey) {
            operation = nil
            restoreInput(wasAccepting)
            throw ConversationError.running(previous)
        }
        do {
            if child.isRunning { try await stopForOperation() }
        } catch {
            if child.isRunning {
                _ = context.reservations.transfer(reservation, from: helperKey, to: id)
            } else {
                context.reservations.release(owner: helperKey)
            }
            operation = nil
            publishState()
            throw error
        }

        let before = RewindBefore(record)
        let next = UUID().uuidString.lowercased()
        do {
            record = try context.store.switchConversationSession(id: id, agentSessionID: next, at: context.now()) {
                $0.previousSessionId = previous
                $0.clearRedo()
                // 最初の発言（親が無い）まで戻すなら、新しい会話として始める
                $0.pendingForkSessionId = line.parentUUID == nil ? nil : previous
                $0.pendingForkAt = line.parentUUID
                $0.rewindFilesPending = request.files
            }
        } catch {
            context.reservations.release(owner: helperKey)
            operation = nil
            publishState()
            throw ConversationError.failed("会話の記録を書けない: \(error)")
        }

        var response = ConversationRewindResponse(canRewind: true)
        if request.files {
            let outcome = await runHelper(session: previous, userMessageID: line.uuid, dryRun: false)
            context.reservations.release(owner: helperKey)
            switch outcome {
            case .result(let result) where result.canRewind == true:
                response = result
                updateRecord { $0.rewindFilesPending = false }
            case .result(let result):
                await abandonRewind(to: previous, discarding: next, before: before)
                throw ConversationError.failed("ファイルを戻せない: \(result.error ?? "")")
            case .refused(let message):
                await abandonRewind(to: previous, discarding: next, before: before)
                throw ConversationError.failed("ファイルを戻せない: \(message)")
            case .unknown:
                // CLI がファイルを戻した後で応答だけが届かなかったのかもしれない。記録を戻すとファイルだけが戻った状態になりうるので、巻き戻したまま
                // `rewindIncomplete` を出す
                context.logger.warning("rewind files result unknown", metadata: ["conversation": .string(id)])
            }
            // 作業フォルダが変わっても、ツールの結果もターンの終わりも来ない
            refreshDiffSoon()
        }
        operation = nil
        contextPercent = nil
        resetFeed()
        publishState()
        context.logger.info("conversation rewound", metadata: ["conversation": .string(id), "at": .string(line.uuid), "files": .stringConvertible(request.files)])
        response.draft = prompt
        response.conversation = snapshot()
        return response
    }

    /// CLI がファイルを戻すのをはっきり断った：記録を巻き戻す前に戻す（ファイルは変わっていない）。戻せなければ `rewindFilesPending` が残る
    private func abandonRewind(
        to previous: String, discarding next: String, before: RewindBefore
    ) async {
        do {
            record = try context.store.switchConversationSession(id: id, agentSessionID: previous, discarding: next, at: context.now()) { before.restore(&$0) }
        } catch {
            context.logger.error("conversation rewind not restored", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
        operation = nil
        publishState()
    }

    /// 直前の巻き戻しを取り消して、巻き戻す前の Claude の会話 ID に戻す（会話だけ。ファイルは戻らない）。巻き戻した先はやり直すために取っておく
    func undoRewind(expected: String) async throws -> Conversation {
        try checkOperable(expected: expected)
        guard let previous = record.previousSessionId else { throw ConversationError.changed(id) }
        let rewound = (session: record.agentSessionId, fork: record.pendingForkSessionId, at: record.pendingForkAt)
        try await switchRewind(to: previous, operation: .undo) {
            $0.previousSessionId = nil
            $0.pendingForkSessionId = nil
            $0.pendingForkAt = nil
            $0.redoSessionId = rewound.session
            $0.redoForkSessionId = rewound.fork
            $0.redoForkAt = rewound.at
        }
        context.logger.info("conversation rewind undone", metadata: ["conversation": .string(id)])
        return snapshot()
    }

    /// 元に戻した巻き戻しをやり直す（巻き戻した先の Claude の会話 ID と、まだ送っていなければフォークの印に戻す。ファイルは戻さない）
    func redoRewind(expected: String) async throws -> Conversation {
        try checkOperable(expected: expected)
        guard let rewound = record.redoSessionId else { throw ConversationError.changed(id) }
        let current = record.agentSessionId
        let fork = (session: record.redoForkSessionId, at: record.redoForkAt)
        try await switchRewind(to: rewound, operation: .redo) {
            $0.previousSessionId = current
            $0.pendingForkSessionId = fork.session
            $0.pendingForkAt = fork.at
            $0.clearRedo()
        }
        context.logger.info("conversation rewind redone", metadata: ["conversation": .string(id)])
        return snapshot()
    }

    /// 巻き戻す前の記録の巻き戻しの欄（CLI がファイルを戻すのを断ったら戻す）
    private struct RewindBefore {
        var previous: String?
        var fork: String?
        var at: String?
        var files: Bool
        var redo: (session: String?, fork: String?, at: String?)

        init(_ record: ConversationRecord) {
            previous = record.previousSessionId
            fork = record.pendingForkSessionId
            at = record.pendingForkAt
            files = record.rewindFilesPending
            redo = (record.redoSessionId, record.redoForkSessionId, record.redoForkAt)
        }

        func restore(_ record: inout ConversationRecord) {
            record.previousSessionId = previous
            record.pendingForkSessionId = fork
            record.pendingForkAt = at
            record.rewindFilesPending = files
            (record.redoSessionId, record.redoForkSessionId, record.redoForkAt) = redo
        }
    }

    /// 会話を止めて、記録を `session` に替える（元に戻す・やり直す）
    private func switchRewind(to session: String, operation kind: Operation, _ change: (inout ConversationRecord) -> Void) async throws {
        operation = kind
        let wasAccepting = child.acceptsInput
        refuseInput()
        do {
            if let owner = context.reservations.owner(of: Self.reservationKey(session)), owner != id { throw ConversationError.running(session) }
            if child.isRunning { try await stopForOperation() }
            record = try context.store.switchConversationSession(id: id, agentSessionID: session, at: context.now()) {
                change(&$0)
                $0.rewindFilesPending = false
            }
        } catch {
            restoreInput(wasAccepting)
            operation = nil
            publishState()
            throw error as? ConversationError ?? ConversationError.failed("会話の記録を書けない: \(error)")
        }
        operation = nil
        contextPercent = nil
        resetFeed()
        publishState()
    }

    /// Claude Code のアカウントを替える（`arguments` はアカウントの `--settings` を入れ替えた引数）。動いていればプロセスを止める。
    /// 次に送ったときに、新しいアカウントで同じ会話を `--resume` で起こす
    func switchAccount(arguments: [String]) async throws {
        try checkOperable(expected: record.agentSessionId)
        guard arguments != record.extraArguments else { return }
        operation = .account
        defer { operation = nil }
        let wasAccepting = child.acceptsInput
        refuseInput()
        do {
            if child.isRunning { try await stopForOperation() }
            try writeRecord { $0.extraArguments = arguments }
        } catch {
            restoreInput(wasAccepting)
            publishState()
            throw error as? ConversationError ?? ConversationError.failed("会話の記録を書けない: \(error)")
        }
        publishState()
    }

    /// 巻き戻し・元に戻す・端末で開くの前に会話のプロセスを止める（入力は呼ぶ側が閉じている）
    private func stopForOperation() async throws {
        updateRecord { $0.lastExit = ConversationStopCause.suspended.lastExit }
        await finishStopping()
        guard !child.isRunning else { throw ConversationError.failed("前のプロセスが終わらない") }
    }

    /// 会話の中身を替えた：控えを捨てて `reset` を流す（購読している画面は手元の発言を捨てて履歴を取り直す）
    private func resetFeed() {
        replayedStream.clear()
        flushDelta()
        log.reset(at: context.now())
    }

    private enum HelperOutcome {
        /// CLI が答えた。`canRewind` が false ならファイルは変わっていない
        case result(ConversationRewindResponse)
        /// `rewind_files` を送る前に止まった（ファイルは変わっていない）
        case refused(String)
        /// `rewind_files` を送った後に応答が無い（ファイルを戻したかは分からない）
        case unknown
    }

    /// 補助のプロセスを起こして `rewind_files` を送り、終わるのを確かめてから返す。今の ID の予約は呼ぶ側が持ち、枠は補助の key で取る
    private func runHelper(session: String, userMessageID: String, dryRun: Bool) async -> HelperOutcome {
        let key = HelperProcess.rewindKey(id)
        guard context.slots.reserve(key) else { return .refused("動いている会話が上限の \(context.slots.hard) 件") }
        defer { context.slots.release(key) }
        let launch: EngineLaunch
        do {
            launch = try await context.launch()
        } catch {
            return .refused("\(error)")
        }
        var env = launch.environment
        env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1"
        // settings.json の hook に何もさせない（`/clear` の扱いで会話の ID を前の ID に替えさせない）
        env["TASKBOARD_CONVERSATION_ID"] = id
        let helper = HelperProcess(key: key, host: context.host)
        self.helper = helper
        defer { self.helper = nil }
        startHelperReading()
        do {
            try await helper.spawn(
                argv: HelperProcess.rewindArguments(executable: launch.executable, agentSessionID: session, permissionMode: record.permissionMode), env: env,
                cwd: record.cwd)
        } catch {
            _ = await helper.kill(context.timing)
            return .refused("補助のプロセスを起こせない: \(error)")
        }
        let outcome: HelperOutcome
        do {
            let initialized = try await helper.control("initialize", timeout: context.timing.control)
            if !initialized.isSuccess {
                outcome = .refused("initialize を断られた: \(initialized.error ?? "")")
            } else {
                var fields: [String: Any] = ["user_message_id": userMessageID]
                if dryRun { fields["dry_run"] = true }
                do {
                    let response = try await helper.control("rewind_files", fields, timeout: context.timing.control)
                    if !response.isSuccess {
                        outcome = .result(ConversationRewindResponse(canRewind: false, error: response.error))
                    } else if let result = ClaudeControls.rewind(payload: response.payloadJSON) {
                        outcome = .result(result)
                    } else {
                        outcome = .unknown
                    }
                } catch {
                    outcome = .unknown
                }
            }
        } catch {
            outcome = .refused("initialize の応答が無い: \(error)")
        }
        if await !helper.finish(context.timing) {
            context.logger.warning("rewind helper did not exit", metadata: ["conversation": .string(id)])
        }
        return outcome
    }

    private func startHelperReading() {
        guard helperReader == nil else { return }
        helperReader = Task { [helperStream] in
            for await notice in helperStream { await self.helper?.receive(notice) }
        }
    }

    /// 繋ぎ直したときに host にあった補助のプロセス。この daemon が起こしたもの（host に繋ぎ直しただけ）なら受け直す。
    /// 前の daemon のものなら止める。止め終えるまでは送る・起こす・巻き戻すを断る（ファイルを戻している途中に会話を動かさない）
    func adoptHelper(_ process: AgentHostProcessInfo) async {
        if let helper {
            await helper.resubscribe(alive: process.alive)
            return
        }
        guard process.alive else { return }
        let key = HelperProcess.rewindKey(id)
        let helper = HelperProcess(key: key, host: context.host)
        self.helper = helper
        startHelperReading()
        // 戻している途中の ID（巻き戻す前の ID）を、止め終えるまで Launcher に起こさせない
        _ = context.reservations.reserve(Self.reservationKey(record.previousSessionId ?? record.agentSessionId), owner: key)
        context.logger.warning("stopping orphaned rewind helper", metadata: ["conversation": .string(id)])
        Task {
            await helper.resubscribe(alive: true)
            if await !helper.kill(self.context.timing) {
                self.context.logger.error("orphaned rewind helper did not exit", metadata: ["conversation": .string(self.id)])
            }
            self.context.reservations.release(owner: key)
            if self.helper === helper { self.helper = nil }
            self.publishState()
        }
    }

    /// 題の無い会話に、人の最初の発言から CLI に題を作らせる。題は `.titleChanged` と同じく人の名前を上書きしない。作れなければ次のターンで作り直させる
    private func generateTitleSoon() {
        guard !titleRequested, let prompt = titlePrompt, record.title == nil, record.customTitle == nil else { return }
        titleRequested = true
        let target = generation
        Task {
            guard self.child.acceptsInput, self.generation == target,
                let response = try? await self.control("generate_session_title", ["description": prompt, "persist": true]), response.isSuccess,
                let title = ClaudeControls.sessionTitle(payload: response.payloadJSON)
            else {
                self.titleRequested = false
                return
            }
            var reported = self.record
            guard reported.title == nil, reported.takeReportedTitle(title) else { return }
            self.record = (try? self.context.store.updateConversation(id: self.id, at: self.context.now()) { $0.title = reported.title }) ?? self.record
            self.publishState()
        }
    }

    /// ターンの終わりにコンテキストの使用率と、間をあけて利用枠を取り直す。応答は host の行で届くので、行を読む流れの外で待つ
    private func refreshContextSoon() {
        let target = generation
        let session = record.agentSessionId
        Task {
            // 止めている途中（入力を閉じる前後）には書かない
            guard self.child.acceptsInput, self.generation == target,
                let response = try? await self.control("get_context_usage", ["detail": "summary"]), response.isSuccess
            else { return }
            self.applyContext(response.payloadJSON, session: session)
            guard self.child.isRunning, self.generation == target else { return }
            await self.pollUsage()
        }
    }

    /// 空いている会話の利用枠を取り直す（`ConversationService.refreshIdleUsage` の見回り）。ターンを終える会話が無くても、起き直した daemon が枠を知るため
    func refreshUsage() async {
        guard child.acceptsInput, phase == .idle else { return }
        await pollUsage()
    }

    /// 推論専用の token のアカウントは枠を返さない（`rate_limits` が null）
    private func pollUsage() async {
        guard await context.claimUsageRefresh(ClaudeAccount.name(inArguments: record.extraArguments)),
            let usage = try? await control("get_usage"), usage.isSuccess
        else { return }
        let windows = ClaudeControls.usageWindows(payload: usage.payloadJSON)
        if windows.fiveHour != nil || windows.sevenDay != nil { await reportUsage(fiveHour: windows.fiveHour, sevenDay: windows.sevenDay) }
    }

    /// `get_context_usage` の応答を使用率と値に入れる。取っている間に Claude の会話が替わっていれば値には入れない
    private func applyContext(_ payload: String?, session: String) {
        if let percent = ClaudeControls.contextPercent(payload: payload) { setContextPercent(percent) }
        guard let fill = ClaudeControls.contextFill(payload: payload) else { return }
        updateStats(for: session) {
            $0.contextTokens = fill.tokens
            $0.contextWindow = fill.window
        }
    }

    /// 利用枠の窓をマシンの枠に入れる。コンテキストも一緒に送る（statusline の 1 セッションの報告と同じ形）
    private func reportUsage(fiveHour: UsageWindow?, sevenDay: UsageWindow?) async {
        let current = stats?.agentSessionID == record.agentSessionId ? stats : nil
        let session = SessionContext(
            agentSessionID: record.agentSessionId, model: current?.model, effort: record.effort, usedPercent: contextPercent.map(Double.init),
            inputTokens: current?.contextTokens, windowSize: current?.contextWindow, account: ClaudeAccount.name(inArguments: record.extraArguments),
            at: context.now())
        await context.reportUsage(ClaudeUsageReport(context: session, fiveHour: fiveHour, sevenDay: sevenDay))
    }

    /// 会話の様子を `DaemonState` に載せ、E1 の購読にも流す（控えには入れない）
    func publishState() {
        let current = snapshot()
        publishedDetachableTools = current.detachableTools ?? 0
        context.publish(current)
        log.publish(current, at: context.now())
    }

    private func publishIfDetachableToolsChanged() {
        if detachableTools != publishedDetachableTools { publishState() }
    }

    /// idle に入ったら、回答とレビューの配送を呼ぶ（`result` の時点ではまだ running で、配送は idle の会話にしか入れないため。
    /// `session_state_changed` の idle は `result` の後の行で来る）
    private func setPhase(_ next: Conversation.Phase) {
        guard phase != next else { return }
        // Claude Code はターンの始まりを別の行で知らせないので、入力待ちから生成中・問いの待ちに入った所を始まりにする
        let began = (next == .running || next == .waiting) && (phase == .idle || phase == .starting || phase == .stopped)
        phase = next
        lastActive = context.now()
        if began { beginTurn(replaying: replaying) }
        if next == .running { watchStall() } else { stalledSince = nil; apiRetry = nil }
        publishState()
        guard next == .idle, child.isRunning, !replaying else { return }
        compactForPauseIfIdle()
        let conversationID = id
        let becameIdle = context.becameIdle
        Task { await becameIdle(conversationID) }
    }

    // MARK: host の行を読む

    func handle(_ notice: AgentHostNotice) async {
        switch notice.event {
        case .output:
            guard let seq = notice.seq, seq > appliedSeq, let line = notice.line else { return }
            appliedSeq = seq
            noteLine()
            await handle(line: ClaudeStreamParser.parse(Data(line.utf8), index: seq), seq: seq)
        case .gap:
            if let through = notice.through { appliedSeq = max(appliedSeq, through) }
            needsReconcile = true
            // 自分で捨てた所までの欠けなら、裏のタスクは数え直せる
            if (notice.through ?? .max) > record.trimmedThrough { loseBackgroundTasks() }
            emit(.gap)
        case .oversize:
            if let seq = notice.seq { appliedSeq = max(appliedSeq, seq) }
            context.logger.warning("conversation line too long", metadata: ["conversation": .string(id), "bytes": .stringConvertible(notice.bytes ?? 0)])
            needsReconcile = true
            loseBackgroundTasks()
            emit(.gap)
        case .exit:
            emitReplayed(replayedStream.release())
            await exited(record.stopCause ?? .unexpected(notice.exit.map(Self.describe) ?? "終わった"), observed: true)
            if replayed { releaseReplayWaiters() }
            return
        case .shellOutput, .shellExit:
            return
        }
        if appliedSeq >= replayThrough { emitReplayed(replayedStream.release()) }
        if needsReconcile, child.isRunning, appliedSeq >= replayThrough { await reconcileSoon() }
        if replayed { releaseReplayWaiters() }
    }

    private var replaying: Bool { appliedSeq <= replayThrough }

    private func holdReplayed(_ kind: ClaudeStreamEvent.Kind, messageID: String) {
        switch kind {
        case .blockStart(let index, .text): replayedStream.start(messageID: messageID, index: index, block: .text)
        case .blockStart(let index, .thinking): replayedStream.start(messageID: messageID, index: index, block: .thinking)
        case .blockStart(let index, .toolUse(_, let name)): replayedStream.start(messageID: messageID, index: index, block: .toolInput, toolName: name)
        case .textDelta(let index, let text), .thinkingDelta(let index, let text), .toolInputDelta(let index, let text):
            replayedStream.append(messageID: messageID, index: index, text: text)
        case .blockStop(let index): replayedStream.stop(messageID: messageID, index: index)
        default: break
        }
    }

    private func handle(line: ClaudeStreamLine, seq: Int) async {
        switch line {
        case .initialized(let info):
            self.info = info
            let missing = Self.requiredCapabilities.filter { !info.capabilities.contains($0) }
            if !missing.isEmpty {
                context.logger.error("claude lacks capabilities", metadata: ["conversation": .string(id), "missing": .string(missing.joined(separator: ","))])
                await terminate(reason: "Claude Code \(info.version ?? "?") に \(missing.joined(separator: "・")) が無い")
                return
            }
            if info.sessionID != record.agentSessionId { await changeSession(info.sessionID) }
            updateStats(for: info.sessionID) {
                $0.model = info.model ?? $0.model
                $0.engineVersion = info.version ?? $0.engineVersion
            }
        case .phase(let state):
            reportedPhase = state
            switch state {
            case .running: setPhase(pending.isEmpty ? .running : .waiting)
            case .requiresAction: setPhase(.waiting)
            case .idle: setPhase(child.isRunning ? .idle : .stopped)
            }
        case .titleChanged(let title):
            var reported = record
            guard reported.takeReportedTitle(title) else { return }
            updateRecord { $0.title = reported.title }
            publishState()
        case .commandsChanged(let list):
            setCommands(list)
        case .conversationReset(let sessionID):
            await changeSession(sessionID)
            guidePending = true
            // /clear の前の発言を控えに残すと、開き直した画面が新しい会話の履歴の前後に前の会話の発言を混ぜる
            resetFeed()
        case .compacted(let divider):
            guidePending = true
            endCompaction()
            emit(.messages([divider], apiMessageID: nil))
            awaitsCompactSummary = true
        case .compacting(let chars):
            let now = context.now()
            if compaction == nil {
                compaction = ConversationCompaction(startedAt: now, outputChars: chars)
            } else {
                guard compaction?.outputChars != chars else { return }
                compaction?.outputChars = chars
                guard now.timeIntervalSince(compactionPublishedAt) >= 1 else { return }
            }
            compactionPublishedAt = now
            publishState()
        case .statusCleared(let failed, let error):
            endCompaction()
            if failed, !replaying {
                context.logger.warning("conversation compaction failed", metadata: ["conversation": .string(id), "error": .string(error ?? "")])
                emit(.notice(ConversationScreenText.compactFailed))
            }
        case .apiRetry(let attempt, let maxRetries, let delayMs, let status, let kind):
            // 控えの読み直しの分は古い送り直しなので載せない
            guard !replaying else { return }
            apiRetry = ConversationAPIRetry(
                attempt: attempt, maxRetries: maxRetries, retryAt: context.now().addingTimeInterval(Double(delayMs) / 1000), status: status, kind: kind)
            publishState()
        case .accepted(let written, let reported):
            if reported == "cancelled", withdrawn.remove(written) != nil { return }
            let notice = Self.notTaken[reported]
            let state = notice == nil ? reported : "cancelled"
            if state == "started" { lastStarted = written }
            let uuid = resentFrom[written] ?? written
            remember(uuid, state: state)
            emit(.accepted(clientMessageID: uuid, state: state))
            if let notice, !replaying {
                context.logger.warning("conversation message not taken", metadata: ["conversation": .string(id), "message": .string(uuid), "state": .string(reported)])
                emit(.notice(notice))
            }
            if state != "queued" { laterMessages.remove(uuid) }
            if state == "queued", !replaying, !laterMessages.contains(uuid), steering.insert(uuid).inserted { Task { await self.steer(uuid) } }
        case .promptDropped(let reason):
            guard !replaying, let dropped = lastStarted else { return }
            lastStarted = nil
            await resend(dropped, reason: reason)
        case .stream(let event):
            // サブエージェントの生成中の差分は出さない（終わった発言だけを `messages` で送る）
            guard let messageID = event.messageID, event.parentToolUseID == nil else { return }
            endAPIRetry()
            if case .blockStart(_, .toolUse) = event.kind {
                toolUses = toolUses?.messageID == messageID ? (messageID, (toolUses?.count ?? 0) + 1) : (messageID, 1)
            }
            if replaying {
                holdReplayed(event.kind, messageID: messageID)
                return
            }
            if case .blockStart(let index, _) = event.kind { log.blockStarted(messageID: messageID, index: index) }
            switch event.kind {
            case .blockStart(let index, .text): emit(.blockStart(messageID: messageID, index: index, block: .text, toolName: nil))
            case .blockStart(let index, .thinking): emit(.blockStart(messageID: messageID, index: index, block: .thinking, toolName: nil))
            case .blockStart(let index, .toolUse(_, let name)):
                emit(.blockStart(messageID: messageID, index: index, block: .toolInput, toolName: name))
            case .textDelta(let index, let text): emitDelta(messageID: messageID, index: index, block: .text, text: text)
            case .thinkingDelta(let index, let text): emitDelta(messageID: messageID, index: index, block: .thinking, text: text)
            case .toolInputDelta(let index, let text): emitDelta(messageID: messageID, index: index, block: .toolInput, text: text)
            case .blockStop(let index):
                emit(.blockStop(messageID: messageID, index: index))
                log.blockStopped(messageID: messageID, index: index)
            default: break
            }
        case .messages(let written, let parent, let apiMessageID):
            // 区切りの直後の要約の本文（stream-json では isSynthetic の user の行）。transcript でも区切りだけを出す
            if awaitsCompactSummary, parent == nil, !written.isEmpty {
                awaitsCompactSummary = false
                if written.allSatisfy({ $0.role == .user && $0.isInjected }) { break }
            }
            let messages = resentFrom.isEmpty ? written : written.map(originalLine)
            if let parent {
                // サブエージェントの発言は差分を出していないので、置き換える message の id を付けない
                if !messages.isEmpty { emit(.messages(messages.map { $0.inSubagent(parent) }, apiMessageID: nil)) }
            } else if !messages.isEmpty {
                endAPIRetry()
                if let apiMessageID, replaying {
                    replayedStream.finish(messageID: apiMessageID)
                }
                emit(.messages(messages, apiMessageID: apiMessageID))
                if let apiMessageID { log.messageFinished(apiMessageID) }
                for message in messages {
                    guard let toolID = message.toolID else { continue }
                    if message.kind == .toolUse {
                        openTools.insert(toolID)
                        if let name = message.toolName, Self.detachableToolNames.contains(name) {
                            toolsAwaitingTask.insert(toolID)
                            detachableSince[toolID] = .now
                        }
                    } else if message.kind == .toolResult {
                        openTools.remove(toolID)
                        detachableSince.removeValue(forKey: toolID)
                        if toolsAwaitingTask.remove(toolID) != nil || foregroundTasks.removeValue(forKey: toolID) != nil { releaseForegroundWaiters() }
                    }
                }
                publishIfDetachableToolsChanged()
            }
            // サブエージェントのツールもファイルを書く
            for message in messages {
                guard let toolID = message.toolID else { continue }
                if message.kind == .toolUse, let name = message.toolName, Self.writingToolNames.contains(name) {
                    writingTools.insert(toolID)
                } else if message.kind == .toolResult, writingTools.remove(toolID) != nil, !replaying {
                    refreshDiffSoon()
                }
                if message.kind == .toolUse, let name = message.toolName, Self.planToolNames.contains(name) {
                    planTools.insert(toolID)
                } else if message.kind == .toolResult, planTools.remove(toolID) != nil, reloadPlan() {
                    publishState()
                }
                if message.kind == .toolResult, parent == nil, deferredQuestion?.request.toolUseID == toolID { clearDeferred(answered: toolID) }
            }
        case .backgroundTask(let taskID, let finished, let type, let description, let toolUseID, let foreground, let backgrounded, let status):
            if finished {
                foregroundTasks = foregroundTasks.filter { $0.value != taskID }
            } else if let toolUseID {
                toolsAwaitingTask.remove(toolUseID)
                if foreground { foregroundTasks[toolUseID] = taskID }
                releaseForegroundWaiters()
            }
            let index = backgroundTasks.firstIndex { $0.id == taskID }
            if finished {
                let task = index.map { backgroundTasks.remove(at: $0) }
                // 知らせなしに一覧から消えて終了にしたものも、後から届いた終わり方に直す
                let remembered = task.map(\.isBackground) ?? endedBackgroundTasks.contains { $0.id == taskID }
                if remembered { rememberEnded(taskID, Self.endStatus(status)) }
                if task != nil || remembered { publishState() }
            } else if index == nil {
                backgroundTasks.append(ConversationBackgroundTasks.Task(id: taskID, type: type, description: description, backgrounded: backgrounded))
                publishState()
            }
            publishIfDetachableToolsChanged()
        case .backgroundTaskList(let tasks):
            // 裏に回ったかは一覧に載らないので、知っている task の印を引き継ぐ
            let next = tasks.map { task in
                var task = task
                task.backgrounded = backgroundTasks.first { $0.id == task.id }?.backgrounded
                return task
            }
            // CLI の一覧そのものなので、控えから行が落ちて分からなくなった数も、これで分かる
            if next != backgroundTasks || !backgroundTasksKnown {
                for task in backgroundTasks where task.isBackground && !next.contains(where: { $0.id == task.id }) { rememberEnded(task.id, .ended) }
                backgroundTasks = next
                backgroundTasksKnown = true
                publishState()
            }
        case .taskBackgrounded(let taskID):
            foregroundTasks = foregroundTasks.filter { $0.value != taskID }
            if let index = backgroundTasks.firstIndex(where: { $0.id == taskID }), backgroundTasks[index].backgrounded != true {
                backgroundTasks[index].backgrounded = true
                publishState()
            }
            publishIfDetachableToolsChanged()
        case .incompatible(let type):
            context.logger.warning("conversation message unreadable", metadata: ["conversation": .string(id), "type": .string(type)])
            emit(.gap)
        case .result(let result):
            endCompaction()
            endAPIRetry()
            resultCount += 1
            openTools.removeAll()
            clearForegroundTasks()
            publishIfDetachableToolsChanged()
            await turnFinished(result, seq: seq)
        case .rateLimits(let windows, let limit):
            if let limit { rateLimit = limit }
            // 控えの読み直しの分は古い窓なので入れない
            if !replaying, !windows.isEmpty {
                usageWindows.merge(windows) { $1 }
                await reportUsage(fiveHour: windows["five_hour"], sevenDay: windows["seven_day"])
            }
        case .request(let request):
            await received(request)
        case .cancelRequest(let requestID):
            removePending(requestID)
            if child.isRunning { setPhase(phaseAfterAnswered) }
        case .response(var response):
            response.seq = seq
            if response.requestID == loginWaitRequest {
                await loginFinished(response)
            } else {
                controlWaiters.removeValue(forKey: response.requestID)?.resume(returning: response)
            }
        case .other(let type, let subtype):
            if type != "keep_alive", type != "system" {
                context.logger.debug("conversation line skipped", metadata: ["type": .string(type), "subtype": .string(subtype ?? "")])
            }
        case .unreadable:
            context.logger.warning("conversation line unreadable", metadata: ["conversation": .string(id), "seq": .stringConvertible(seq)])
        }
    }

    private func received(_ request: ClaudeControlRequest) async {
        switch request.kind {
        case .canUseTool(let permission):
            let suggestionsJSON = permission.suppressAlwaysAllowRule ? nil : permission.suggestionsJSON
            let made = ClaudeRequests.make(
                id: request.requestID, toolName: permission.toolName, toolUseID: permission.toolUseID, inputJSON: permission.inputJSON,
                description: permission.description, suggestionsJSON: suggestionsJSON, since: context.now())
            let fresh = pending[request.requestID] == nil
            if fresh { pendingOrder.append(request.requestID) }
            pending[request.requestID] = Pending(request: made, inputJSON: permission.inputJSON, suggestionsJSON: suggestionsJSON, fromReplay: replaying)
            phase = .waiting
            publishState()
            if fresh, !replaying { leaveNotice(turn: nil) }
        case .elicitation(let elicitation):
            // 問いの行は答えるまで host の控えに残る（trimmable は問いがあると捨てない）。daemon が起き直したら、読み直しで開く先を取り直す
            let (made, url) = ClaudeRequests.make(id: request.requestID, elicitation: elicitation, since: context.now())
            let fresh = pending[request.requestID] == nil
            if fresh { pendingOrder.append(request.requestID) }
            pending[request.requestID] = Pending(request: made, inputJSON: "{}", fromReplay: replaying, url: url)
            if fresh, !replaying {
                context.logger.info(
                    "conversation elicitation", metadata: ["conversation": .string(id), "server": .string(elicitation.serverName), "mode": .string(elicitation.mode)])
            }
            phase = .waiting
            publishState()
            if fresh, !replaying { leaveNotice(turn: nil) }
        case .hookCallback(let call):
            // 読み直しの分は前の daemon が答えている。答えていなかった分は、initialize の送り直しで CLI が自分で解く
            guard !replaying else { return }
            if call.event == "Stop" {
                // 待ちの見直しは state を読むので待つ。その間も行を読む（interrupt の応答などを止めない）
                Task { await self.answerHook(request.requestID, call) }
                return
            }
            await answerHook(request.requestID, call)
        case .other(let subtype):
            guard !replaying else { return }
            try? await context.host.write(key: id, ClaudeStreamInput.failure(id: request.requestID, "Unsupported control request subtype: \(subtype)"))
        }
    }

    private func answerHook(_ requestID: String, _ call: ClaudeHookCall) async {
        let response = await hookResponse(call)
        try? await context.host.write(key: id, ClaudeStreamInput.success(id: requestID, response))
    }

    private func hookResponse(_ call: ClaudeHookCall) async -> [String: Any] {
        switch call.event {
        case "PreToolUse":
            if let resuming, call.toolUseID == resuming.question.request.toolUseID {
                self.resuming = nil
                clearDeferred(answered: resuming.question.request.toolUseID)
                return ClaudeRequests.preToolUseResponse(resuming.decision)
            }
            if let name = call.toolName, shouldDefer(name) {
                return ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "defer"]]
            }
            return [:]
        case "Stop":
            guard call.agentID == nil, let reminder = await context.stopHook(id, call) else { return [:] }
            return ["decision": "block", "reason": reminder]
        case "UserPromptSubmit":
            guard guidePending else { return [:] }
            guidePending = false
            guard let task = currentTask, let text = await context.guide(task) else { return [:] }
            return ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": text]]
        default:
            return [:]
        }
    }

    /// 問いを defer で終えるか。画面に出ていない会話の問いは defer で終え、プロセスを残さない（host の入れ替えが止まらないように）。
    /// 1 つの message で 2 つ以上のツールを呼んでいると defer が効かないので、残して待つ。
    /// 裏のタスクが動いている間も残す（プロセスが終わらず、CLI は裏のタスクの知らせで次のターンを始めて、問いを内部の誤りで埋める）
    private func shouldDefer(_ toolName: String) -> Bool {
        guard Self.hookedTools.split(separator: "|").contains(Substring(toolName)), (toolUses?.count ?? 0) <= 1,
            backgroundTasksKnown, backgroundTasks.isEmpty
        else { return false }
        switch deferMode {
        case .on: return true
        case .off: return false
        case .auto: return log.viewers == 0
        }
    }

    // MARK: 止まりの見張りと中断の段上げ

    private func noteLine() {
        lastLineAt = context.now()
        guard stalledSince != nil else { return }
        stalledSince = nil
        publishState()
    }

    /// 生成中の間、行が `stall` を超えて来ないか見る。生成中でなくなったらやめる
    private func watchStall() {
        guard stallWatch == nil else { return }
        stallWatch = Task { [weak self] in
            while !Task.isCancelled, let wait = await self?.checkStall() {
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// 止まっているか確かめ、次に確かめるまでの間を返す。生成中でなければ nil
    private func checkStall() -> Duration? {
        guard child.isRunning, phase == .running else {
            stallWatch = nil
            return nil
        }
        let limit = Double(context.timing.stall.components.seconds) + Double(context.timing.stall.components.attoseconds) / 1e18
        let quiet = context.now().timeIntervalSince(lastLineAt)
        guard quiet >= limit else { return .milliseconds(Int(max(0.05, limit - quiet) * 1000)) }
        if stalledSince == nil, openTools.isEmpty {
            stalledSince = lastLineAt
            context.logger.warning("conversation stalled", metadata: ["conversation": .string(id), "quietSeconds": "\(Int(quiet))"])
            publishState()
        }
        return context.timing.stall
    }

    /// 中断。CLI が応えないか、応えてもターンが終わらなければ（2.1.303 で、止まった CLI が interrupt にも応えず running のまま残った）、
    /// 止めて `--resume` で起こし直し、待ち行列にあった人の発言を同じ uuid で入れ直す
    private func interrupt() async throws -> ConversationControlResponse {
        let target = generation
        let results = resultCount
        let answer = try? await control("interrupt", ["cancel_queued": true], timeout: context.timing.interruptAnswer)
        if let answer, !answer.isSuccess { throw ConversationError.failed(answer.error ?? "断られた") }
        if answer != nil, resultCount == results, phase == .running { await waitForResult(timeout: context.timing.interruptResult) }
        guard generation == target, child.isRunning, resultCount == results, phase == .running else {
            return ConversationControlResponse(payloadJSON: answer?.payloadJSON)
        }
        try await restartUnresponsive(target)
        return ConversationControlResponse(payloadJSON: ClaudeStreamParser.json(["restarted": true]))
    }

    private func restartUnresponsive(_ target: Int) async throws {
        let requeue = queuedLines
        context.logger.warning("conversation unresponsive, restarting", metadata: ["conversation": .string(id), "requeue": "\(requeue.count)"])
        restarting = true
        defer { restarting = false }
        refuseInput()
        updateRecord { $0.lastExit = ConversationStopCause.taskboard.lastExit }
        // 止まった CLI は入力を閉じても終わらないので、すぐ TERM を送る
        await signalIfStill(target, "TERM")
        if await !waitForExit(timeout: context.timing.stopTerm, generation: target) {
            await signalIfStill(target, "KILL")
            _ = await waitForExit(timeout: context.timing.stopTerm, generation: target)
        }
        try await wake()
        for entry in requeue where accepted[entry.uuid] == "queued" { try await write(entry.line) }
        emit(.notice(ConversationScreenText.restartedUnresponsive))
    }

    private func endAPIRetry() {
        guard apiRetry != nil else { return }
        apiRetry = nil
        publishState()
    }

    /// 動いていた裏のタスクを、終わり方の分からない終了にして控えを空にする（プロセスが替わる・終わる）
    private func endRunningBackgroundTasks() {
        for task in backgroundTasks where task.isBackground { rememberEnded(task.id, .ended) }
        backgroundTasks.removeAll()
    }

    private func rememberEnded(_ taskID: String, _ status: ConversationBackgroundTaskState.Status) {
        if let index = endedBackgroundTasks.firstIndex(where: { $0.id == taskID }) {
            endedBackgroundTasks[index].status = status
            return
        }
        endedBackgroundTasks.append(ConversationBackgroundTaskState(id: taskID, status: status))
        endedBackgroundTasks.removeFirst(max(0, endedBackgroundTasks.count - Self.endedBackgroundTaskLimit))
    }

    /// Claude Code の task の終わりの値（`task_notification` の `status`）
    static func endStatus(_ status: String?) -> ConversationBackgroundTaskState.Status {
        switch status {
        case "completed": .completed
        case "failed": .failed
        case "killed", "stopped": .stopped
        default: .ended
        }
    }

    private func loseBackgroundTasks() {
        guard backgroundTasksKnown else { return }
        backgroundTasksKnown = false
        context.logger.warning("conversation background tasks unknown", metadata: ["conversation": .string(id)])
        publishState()
    }

    /// 止めている途中なら終わるのを待ってから、`--resume` で起こす
    private func wake() async throws {
        guard !retired else { throw ConversationError.removed(id) }
        if operation != nil || helper != nil { throw ConversationError.busy(id, "巻き戻しの途中") }
        if child == .running(acceptsInput: false), await !waitForExit(timeout: context.timing.stopInput + context.timing.stopTerm * 2) {
            throw ConversationError.failed("前のプロセスが終わらない")
        }
        try await start(resume: true)
    }

    /// ターンの終わり：記録に書くもの（defer の問い）を書いてから、その行まで host の控えを捨てる
    private func turnFinished(_ result: ClaudeTurnResult, seq: Int) async {
        let compactTurn = compactingIdle
        if !replaying {
            // 返事の無いターン（誤り・中断）は、キャッシュを最後の返事のときのまま残している
            if !result.isError { answeredAt = compactingIdle ? nil : context.now() }
            compactingIdle = false
        }
        // 費用とトークンは、その Claude の会話の累計（`/clear` の後は 0 から数え直す）
        if let session = result.sessionID {
            updateStats(for: session) {
                if let cost = result.costUSD { $0.costUSD = cost }
                if let tokens = result.tokens { $0.tokens = tokens }
            }
        }
        let deferredTool = result.deferred.flatMap { answeredDeferred.contains($0.toolUseID) ? nil : $0 }
        if deferredTool == nil, !replaying, record.deferred != nil || resuming != nil {
            // 起こし直した CLI が問いに戻らずにターンを終えた：問いは捨てられ、答えても届かない
            resuming = nil
            clearDeferred(answered: nil)
        }
        if let tool = deferredTool {
            let request = ClaudeRequests.make(
                id: tool.toolUseID, toolName: tool.name, toolUseID: tool.toolUseID, inputJSON: tool.inputJSON, description: nil, since: context.now())
            let deferred = DeferredQuestion(request: request, inputJSON: tool.inputJSON)
            updateRecord {
                $0.deferred = String(decoding: (try? JSONEncoder().encode(deferred)) ?? Data(), as: UTF8.self)
                $0.lastExit = ConversationStopCause.deferred.lastExit
            }
        }
        // 利用枠の上限で断られて終わった：戻る時刻の 1 分後に続きを送る（stream-json の CLI は自分で待たない）
        if result.isError, let limit = rateLimit, limit.rejected, let resets = limit.resetsAt, resets > context.now(), record.limitResumeAt == nil,
            record.purposeValue != .schedule, context.continuesAtUsageLimit(record, launchEnvironment)
        {
            updateRecord { $0.limitResumeAt = Store.storedDate(resets.addingTimeInterval(60)) }
            context.logger.info("conversation waits for usage limit", metadata: ["conversation": .string(id), "resetsAt": .stringConvertible(resets)])
            publishState()
        }
        // 利用枠が閾値を越えた：上限で断られる前に区切り、戻るまで待つ。定期起動の回はターンを終えたら閉じるので区切らない
        if !result.isError, !replaying, !compactTurn, record.limitResumeAt == nil, record.purposeValue != .schedule, let pause = context.usagePause(),
            let resets = UsagePauseRule.resetsAt(windows: usageWindows, pause: pause, now: context.now())
        {
            pauseForUsage(until: resets)
        }
        // ネットワークに繋がらずに終わった：接続が戻ったら続きを送る。誤りでなく終われば繋がっているので、印と数を消す。
        // 定期起動の回は失敗にして閉じる（下）ので待たない
        if !replaying, record.purposeValue != .schedule {
            if result.connectionFailed, record.limitResumeAt == nil {
                waitForNetwork()
            } else if !result.isError, record.networkResumeAt != nil || record.networkResumeTries > 0 {
                updateRecord {
                    $0.networkResumeAt = nil
                    $0.networkResumeTries = 0
                }
                publishState()
            }
        }
        // 定期起動の回のターンが error で終わった：回を失敗にする。上限で断られた回も待たない（待つ間、回の会話が残り続ける）
        if result.isError, record.purposeValue == .schedule, record.limitResumeAt == nil, !replaying {
            let reason = rateLimit?.rejected == true ? Self.scheduleRunLimitedReason : "実行がエラーで終わりました" + (result.stopReason.map { "（\($0)）" } ?? "")
            try? context.store.markScheduleRunFailed(conversationID: id, reason: reason)
        }
        // 起こした側への知らせは、控えを捨てる前に記録に残す（捨てた後に daemon が落ちても残る）。読み直しで同じ行を 2 回数えない。
        // 裏のタスクが残っていれば数えない（終わった後のターンの終わりで数える）
        if record.notifyParent, backgroundTasksKnown, backgroundTasks.isEmpty, seq > record.parentNoticeSeq {
            leaveNotice(turn: seq)
        } else if deferredTool != nil, !replaying {
            leaveNotice(turn: nil)
        }
        emit(
            .turn(
                ConversationTurn(
                    isError: result.isError, stopReason: result.stopReason, durationMs: result.durationMs, ttftMs: result.ttftMs, costUSD: result.costUSD,
                    outputTokens: result.outputTokens)))
        endTurn(replaying: replaying)
        // 読み直しで得た MCP の問いがまだあれば、前の daemon が答えている（答えを待つ問いがあると CLI はターンを終えない）
        for requestID in pendingOrder where pending[requestID]?.fromReplay == true && pending[requestID]?.request.kind == .elicitation {
            removePending(requestID)
        }
        log.compactTurn()
        replayedStream.clear()
        toolUses = nil
        if record.pendingForkSessionId != nil, context.hasTranscript(record.agentSessionId, launchEnvironment) { clearPendingFork() }
        for waiter in resultWaiters { waiter.resume() }
        resultWaiters.removeAll()
        if !replaying {
            refreshContextSoon()
            refreshDiffSoon()
            generateTitleSoon()
        }
        if trimmable { await trim(through: seq) }
        if deferredTool != nil, child.isRunning {
            refuseInput()
            try? await context.host.closeInput(key: id)
        }
    }

    /// host の控えを捨ててよい。待ち行列にある発言の受付より先は捨てない（daemon が起き直した後、記録の uuid が待ち行列を出たかを控えで決める）。
    /// 裏のタスクが残っている間も捨てない（daemon が起き直したら、控えの読み直しで数え直す）
    private var trimmable: Bool {
        pending.isEmpty && !needsReconcile && !accepted.values.contains("queued") && backgroundTasksKnown && backgroundTasks.isEmpty && !replaying
    }

    /// 控えを読み直した後と gap の後：initialize を送り直し、CLI が答えを待っている問いを真実源にする。
    /// 応答は host の行で届くので、行を読む流れの外で待つ
    private func reconcileSoon() async {
        needsReconcile = false
        Task { await self.reconcile() }
    }

    private func reconcile() async {
        guard child.isRunning else { return }
        do {
            let response = try await control("initialize", Self.initialize)
            received(initialize: response)
            guard let requests = response.pendingRequests else {
                await terminate(reason: "initialize の応答に待っている問いが無い（古い Claude Code）")
                return
            }
            let state = (ClaudeRequests.object(response.payloadJSON ?? "{}")["session_state"] as? String).flatMap(ClaudeTurnPhase.init(rawValue:))
            if let state { reportedPhase = state }
            var still: Set<String> = []
            for request in requests {
                still.insert(request.requestID)
                if pending[request.requestID] == nil { await received(request) }
            }
            // 一覧に無い問いは答え済み。ただし答えを待っている間は、読み直しで得たもの（前の daemon が答えたかもしれない）だけ消す。
            // SDK の型の説明に、引き継いだ問いが一覧に出ない場合があるとあるので、消すと待っている問いが 1 つも無くなるなら残す
            // MCP の問いは一覧（pending_permission_requests）に出ないので、ここでは消さない（答えるか、CLI の取り消しかターンの終わりで消す）
            let absent = pendingOrder.filter { !still.contains($0) && pending[$0]?.request.kind != .elicitation }
            if state != .requiresAction {
                for requestID in absent { removePending(requestID) }
            } else {
                let replayed = absent.filter { pending[$0]?.fromReplay == true }
                if replayed.count < pendingOrder.count {
                    for requestID in replayed { removePending(requestID) }
                } else if !replayed.isEmpty {
                    context.logger.warning("conversation waits but lists no request", metadata: ["conversation": .string(id)])
                }
            }
            // MCP の問いは一覧で確かめられないので、読み直しで得た印を残す（ターンの終わりで答え済みと分かる）
            for requestID in pendingOrder where pending[requestID]?.request.kind != .elicitation { pending[requestID]?.fromReplay = false }
            switch state {
            case .idle: setPhase(.idle)
            case .running: setPhase(pending.isEmpty ? .running : .waiting)
            case .requiresAction: setPhase(.waiting)
            case nil: if pending.isEmpty, phase == .waiting { setPhase(.running) }
            }
            publishState()
        } catch {
            context.logger.warning("conversation reconcile failed", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
    }

    /// 子が終わった。`observed` は控えの行で終わりを見た（host が起き直したときは見ていない）
    private func exited(_ cause: ConversationStopCause, observed: Bool = false) async {
        let wasLive = child.isRunning
        setChild(observed ? .exited : .none)
        endRunningBackgroundTasks()
        backgroundTasksKnown = true
        flushDelta()
        reportedPhase = nil
        pending.removeAll()
        pendingOrder.removeAll()
        resuming = nil
        for (_, waiter) in controlWaiters { waiter.resume(throwing: ConversationError.stopped(id)) }
        controlWaiters.removeAll()
        // ログインの流れと圧縮と止まりの見張りはプロセスと一緒に終わる
        compaction = nil
        stalledSince = nil
        apiRetry = nil
        openTools.removeAll()
        clearForegroundTasks()
        stallWatch?.cancel()
        stallWatch = nil
        loginStage = nil
        loginState = nil
        loginWaitRequest = nil
        loginCodeSent = false
        // 待ち行列にあった発言は、プロセスが終わると走らない（応えない CLI を起こし直すときは入れ直す）
        if !restarting {
            for (uuid, state) in accepted where state == "queued" { remember(uuid, state: "cancelled") }
            queuedLines.removeAll()
        }
        for (_, waiters) in acceptWaiters { for entry in waiters { entry.waiter.resume(returning: nil) } }
        acceptWaiters.removeAll()
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
        if wasLive, !restarting { emit(.notice(cause.notice(engine: .claude))) }
    }

    /// 続けられない（capabilities が足りない・initialize を断られた）。理由を残して止める
    private func terminate(reason: String) async {
        // 最初の await より前に取る（closeInput の応答を待つ間に、子が終わって起こし直されることがある）
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

    private var currentTask: Int? { (try? context.store.conversation(id: id))?.taskNumber ?? nil }

    private var deferredQuestion: DeferredQuestion? { record.deferredQuestion }

    private func clearDeferred(answered toolUseID: String?) {
        if let toolUseID { answeredDeferred.insert(toolUseID) }
        guard record.deferred != nil else { return }
        updateRecord { $0.deferred = nil }
        publishState()
    }

    private func changeSession(_ sessionID: String) async {
        if child.isRunning, !context.reservations.reserve(Self.reservationKey(sessionID), owner: id) {
            context.logger.error("conversation session reserved elsewhere", metadata: ["conversation": .string(id), "session": .string(sessionID)])
        }
        do {
            record = try context.store.updateConversationSession(id: id, agentSessionID: sessionID, at: context.now())
        } catch {
            context.logger.error("conversation session change refused", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
        publishState()
    }

    /// 問いが減ったときの phase。CLI が空いたと知らせていれば idle に置く（答え直しでは、CLI から次の知らせが来ない）
    private var phaseAfterAnswered: Conversation.Phase {
        if !pending.isEmpty { return .waiting }
        return reportedPhase == .idle ? .idle : .running
    }

    private func removePending(_ requestID: String) {
        guard pending.removeValue(forKey: requestID) != nil else { return }
        pendingOrder.removeAll { $0 == requestID }
        publishState()
    }

    private func decision(
        _ request: ConversationRequest, inputJSON: String, suggestionsJSON: String? = nil, answer: ConversationAnswerRequest
    ) throws -> ClaudeRequests.Decision {
        do {
            return try ClaudeRequests.decide(request, inputJSON: inputJSON, suggestionsJSON: suggestionsJSON, answer: answer)
        } catch ClaudeRequests.AnswerError.unanswered {
            throw ConversationError(status: 400, code: .askUnanswered, params: ["count": "\(request.waiting.questions?.count ?? 0)"], description: "答えが無い")
        } catch ClaudeRequests.AnswerError.mismatch(let question, let mismatch) {
            throw ConversationError.invalid(AskAnswerMismatch.describe(mismatch, question))
        } catch ClaudeRequests.AnswerError.suggestion(let reason) {
            throw ConversationError.invalid(reason)
        } catch {
            throw ConversationError.invalid("許可か拒否を選ぶ")
        }
    }

    private func elicitationResponse(_ request: ConversationRequest, answer: ConversationAnswerRequest) throws -> [String: Any] {
        do {
            return try ClaudeRequests.elicitationResponse(request, answer: answer)
        } catch ClaudeRequests.AnswerError.elicitation(let error) {
            throw ConversationError.invalid(error.description)
        } catch {
            throw ConversationError.invalid("action（accept・decline・cancel）が要る")
        }
    }

    /// 発言を書く。host への書き込みの応答が切れても書き直さない（受けたかは `command_lifecycle` で決める）
    private func write(_ data: Data) async throws {
        do {
            try await context.host.write(key: id, data)
        } catch AgentHostClient.Failure.refused(let message) {
            throw ConversationError.failed("送れない: \(message)")
        } catch {
            context.logger.warning("conversation write unconfirmed", metadata: ["conversation": .string(id), "error": "\(error)"])
        }
    }

    static let sentLineLimit = 8
    /// hook の時間切れで捨てられた発言を送り直す回数
    static let resendLimit = 2

    private func writeUser(_ uuid: String, _ line: Data) async throws {
        sentLines.removeAll { $0.uuid == uuid }
        sentLines.append((uuid, line))
        if sentLines.count > Self.sentLineLimit { sentLines.removeFirst(sentLines.count - Self.sentLineLimit) }
        try await write(line)
        // 元に戻した後に続きを送ったら、巻き戻した先へはやり直さない（送った続きを捨てることになる）
        if record.redoSessionId != nil {
            updateRecord { $0.clearRedo() }
            publishState()
        }
    }

    /// CLI が捨てた発言（`dropped` は CLI に書いた uuid）を、元の uuid から決まる別の uuid で送り直す。
    /// 尽きたか行が残っていなければ、元の uuid を取り消しにして画面に知らせる（アプリから送った発言は入力欄に戻る）
    private func resend(_ dropped: String, reason: String?) async {
        let original = resentFrom[dropped] ?? dropped
        let attempt = resentFrom.values.filter { $0 == original }.count + 1
        let metadata: Logger.Metadata = ["conversation": .string(id), "message": .string(original), "reason": .string(reason ?? ""), "attempt": .stringConvertible(attempt)]
        guard attempt <= Self.resendLimit, let line = sentLines.last(where: { $0.uuid == dropped })?.line,
            case let next = StableUUID.make("taskboard-resend:\(original):\(attempt)"), let reissued = ClaudeStreamInput.reissued(line, uuid: next)
        else {
            context.logger.error("conversation prompt dropped by hook", metadata: metadata)
            remember(original, state: "cancelled")
            emit(.accepted(clientMessageID: original, state: "cancelled"))
            emit(.notice(ConversationScreenText.promptDropped))
            return
        }
        context.logger.warning("conversation prompt dropped by hook, resending", metadata: metadata)
        resentFrom[next] = original
        resentAs[original] = next
        // 応えない CLI を起こし直したときに入れ直す（元の uuid の受付が進めば捨てる）
        queuedLines.append((original, reissued))
        try? await writeUser(next, reissued)
    }

    /// 送り直した発言の写しを、元の uuid の行として出す
    private func originalLine(_ message: ChatMessage) -> ChatMessage {
        guard message.role == .user, let original = resentFrom[message.lineID] else { return message }
        var message = message
        message.id = original + message.id.dropFirst(message.lineID.count)
        return message
    }

    /// 受けた発言の状態を持つ。最初に受けたときに記録に書き（host の控えはターンの終わりに捨てる）、取り消されたら記録から外す
    private func remember(_ uuid: String, state: String) {
        let first = accepted[uuid] == nil
        accepted[uuid] = state
        if state != "queued" { queuedLines.removeAll { $0.uuid == uuid } }
        if state == "cancelled" {
            if record.recentMessages.contains(uuid) {
                updateRecord { $0.forget(message: uuid) }
            }
        } else if first {
            updateRecord { $0.remember(message: uuid) }
        }
        guard var waiters = acceptWaiters[uuid] else { return }
        let reached = waiters.filter { $0.states.contains(state) || state == "cancelled" }
        waiters.removeAll { $0.states.contains(state) || state == "cancelled" }
        acceptWaiters[uuid] = waiters.isEmpty ? nil : waiters
        for entry in reached { entry.waiter.resume(returning: state) }
    }

    /// その uuid が `states` のどれかになるのを待つ。取り消されたら `cancelled`、時間内に来なければ nil
    private func waitForLifecycle(_ uuid: String, states: Set<String>) async -> String? {
        if let state = accepted[uuid], states.contains(state) || state == "cancelled" { return state }
        let timeout = context.timing.accept
        return await withCheckedContinuation { (waiter: CheckedContinuation<String?, Never>) in
            acceptWaiters[uuid, default: []].append((states, waiter))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireLifecycle(uuid)
            }
        }
    }

    private func expireLifecycle(_ uuid: String) {
        for entry in acceptWaiters.removeValue(forKey: uuid) ?? [] { entry.waiter.resume(returning: nil) }
    }

    /// CLI に制御要求を送り、応答を待たない（応答の行は、待つ人がいないので読み捨てる）
    private func send(_ subtype: String, _ fields: [String: Any]) async throws {
        guard child.isRunning else { throw ConversationError.stopped(id) }
        controlCounter += 1
        try await context.host.write(key: id, ClaudeStreamInput.request(id: "tb_\(controlCounter)", subtype: subtype, fields))
    }

    /// CLI に制御要求を送り、応答を待つ
    private func control(_ subtype: String, _ fields: [String: Any] = [:], timeout: Duration? = nil) async throws -> ClaudeControlResponse {
        guard child.isRunning else { throw ConversationError.stopped(id) }
        controlCounter += 1
        let requestID = "tb_\(controlCounter)"
        let data = ClaudeStreamInput.request(id: requestID, subtype: subtype, fields)
        let limit = timeout ?? context.timing.control
        return try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<ClaudeControlResponse, any Error>) in
            controlWaiters[requestID] = waiter
            Task {
                do {
                    try await self.context.host.write(key: self.id, data)
                } catch {
                    self.failControl(requestID, error)
                }
                try? await Task.sleep(for: limit)
                self.failControl(requestID, ConversationError.failed("\(subtype) の応答が無い"))
            }
        }
    }

    private func failControl(_ requestID: String, _ error: any Error) {
        controlWaiters.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func response(_ response: ClaudeControlResponse) throws -> ConversationControlResponse {
        guard response.isSuccess else { throw ConversationError.failed(response.error ?? "断られた") }
        return ConversationControlResponse(payloadJSON: response.payloadJSON)
    }

    /// 後で送る発言を、今のターンの区切りで取り込める発言にする。priority "later" のままでは裏に回しても取り込まれず、send_now はターンを止める（2.1.310 で実測）。
    /// 取り下げてから priority なしで送り直し、元の uuid の発言として続ける。CLI が先に始めていて取り下げられなければ、そのまま
    private func sooner(_ original: String) async throws {
        let written = resentAs[original] ?? original
        guard let line = queuedLines.last(where: { $0.uuid == original })?.line,
            case let next = StableUUID.make("taskboard-sooner:\(original)"), let reissued = ClaudeStreamInput.reissued(line, uuid: next, sooner: true)
        else { return }
        withdrawn.insert(written)
        let answer = try await control("cancel_async_message", ["message_uuid": written])
        guard answer.isSuccess, ClaudeControls.cancelled(payload: answer.payloadJSON) else {
            withdrawn.remove(written)
            return
        }
        laterMessages.remove(original)
        resentFrom[next] = original
        resentAs[original] = next
        queuedLines.removeAll { $0.uuid == original }
        queuedLines.append((original, reissued))
        try await writeUser(next, reissued)
    }

    /// ［今すぐ送る］：発言が待ち行列にあれば、主の流れの前景で待っている Bash・subagent を `background_tasks` で裏に回す。1 つでも回せたら true で、
    /// 発言は tool の結果の後の区切りで CLI が読む。tool がまだ task になっていなければ `detachWait` まで待つ（task の前に送ると CLI は回さない）。
    /// priority "now" は使わない（裏に回した subagent が後で止められる）。回した後に interrupt も送らない（CLI が tool の結果を拒否に書き換える。どちらも 2.1.304 で実測）
    private func moveForegroundToBackground(for messageID: String) async throws -> Bool {
        guard accepted[messageID] == "queued" else { return false }
        if foregroundTasks.isEmpty, !toolsAwaitingTask.isEmpty { await waitForForegroundTask(timeout: context.timing.detachWait) }
        guard accepted[messageID] == "queued" else { return false }
        var moved = false
        for toolUseID in foregroundTasks.keys.sorted() where try await moveToBackground(toolUseID) { moved = true }
        return moved
    }

    /// 生成中に送って待ち行列に入った発言のために、主の流れの前景の task のうち tool_use から `steerDetachAge` 以上たったものを裏に回す
    /// （Desktop が普通に送ったときと同じ規則。1 つの発言で `steerDetachLimit` まで、回せなければ `steerDetachRetry` ごとに試し直し、
    /// 発言が待ち行列を出るか `steerDetachGiveUp` で終える）
    private func steer(_ messageID: String) async {
        defer { steering.remove(messageID) }
        let timing = context.timing
        let deadline = ContinuousClock.now + timing.steerDetachGiveUp
        var moved = 0
        while accepted[messageID] == "queued", child.isRunning {
            let now = ContinuousClock.now
            let due = foregroundTasks.keys.filter { detachableSince[$0].map { now - $0 >= timing.steerDetachAge } ?? false }.sorted()
            for toolUseID in due.prefix(Self.steerDetachLimit - moved) where (try? await moveToBackground(toolUseID)) == true { moved += 1 }
            guard moved < Self.steerDetachLimit, now < deadline else { return }
            try? await Task.sleep(for: timing.steerDetachRetry)
        }
    }

    /// `background_tasks {tool_use_id}`。CLI が裏に回したら true（task になる前と、もう裏にあるものは false）
    private func moveToBackground(_ toolUseID: String) async throws -> Bool {
        let answer = try await control("background_tasks", ["tool_use_id": toolUseID])
        guard answer.isSuccess, ClaudeRequests.object(answer.payloadJSON ?? "{}")["backgrounded"] as? Bool == true else { return false }
        // task_backgrounded の知らせを待たずに前景から外す（待つ間の途中送りの試し直しが、同じ task を回し直して数えていた）
        foregroundTasks.removeValue(forKey: toolUseID)
        publishIfDetachableToolsChanged()
        return true
    }

    /// 前景の task が出るか、待っている tool が無くなるか、期限まで
    private func waitForForegroundTask(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while foregroundTasks.isEmpty, !toolsAwaitingTask.isEmpty, child.isRunning, ContinuousClock.now < deadline {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                foregroundWaiters.append(waiter)
                Task { [weak self] in
                    try? await Task.sleep(until: deadline)
                    await self?.releaseForegroundWaiters()
                }
            }
        }
    }

    private func releaseForegroundWaiters() {
        for waiter in foregroundWaiters { waiter.resume() }
        foregroundWaiters.removeAll()
    }

    private func clearForegroundTasks() {
        foregroundTasks.removeAll()
        toolsAwaitingTask.removeAll()
        detachableSince.removeAll()
        releaseForegroundWaiters()
    }

    private func waitForResult(timeout: Duration) async {
        guard child.isRunning else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            resultWaiters.append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.releaseResultWaiters()
            }
        }
    }

    /// initialize の答えの `/` のコマンドとモデルの一覧
    private func received(initialize response: ClaudeControlResponse) {
        if let list = ClaudeControls.commands(initializePayload: response.payloadJSON) { setCommands(list) }
        if let listed = ClaudeControls.models(initializePayload: response.payloadJSON) { context.modelsListed(listed.models, listed.version) }
    }

    /// 会話の CLI に送る initialize の中身（事前起動の子も同じもの）
    static var initialize: [String: Any] {
        // 宣言しないと、interrupt（生成を停止）が裏の subagent も止める（2.1.304 で実測）。宣言は最初の initialize だけが効く
        ["hooks": hooks, "perTaskStopAffordance": true]
    }

    private static var hooks: [String: Any] {
        [
            "PreToolUse": [["matcher": hookedTools, "hookCallbackIds": [preToolHook]]],
            "UserPromptSubmit": [["hookCallbackIds": [promptHook]]],
            "Stop": [["hookCallbackIds": [stopHookID]]],
        ]
    }

    /// 元の Claude の会話 ID の transcript を `at` の行まで写して、記録の会話 ID で始める（`--resume-session-at` は help に無い引数で、`conversation check` で確かめる）
    struct Fork: Equatable, Sendable {
        var source: String
        var at: String?
    }

    /// 会話の CLI の環境（事前起動も同じもので起こす）
    static func environment(_ base: [String: String], conversationID: String) -> [String: String] {
        var env = base
        // 巻き戻しでファイルも戻せるように、送った発言ごとにファイルの控えを取る
        env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1"
        // settings.json の hook と MCP は、これがあれば host の会話の中として振る舞う（hook は何もしない）
        env["TASKBOARD_CONVERSATION_ID"] = conversationID
        env["CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL"] = "1"
        // 無いと system/session_state_changed が出ず、問いに答えた後やターンの後に空いたことが分からない（2.1.302 で実測）
        env["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] = "1"
        // 端末の Claude Code と同じく TaskCreate・TaskUpdate を使わせる（`-p` では既定で無い。2.1.310 で実測）
        env["CLAUDE_CODE_ENABLE_TODO_TOOLS"] = "1"
        return env
    }

    static func arguments(record: ConversationRecord, executable: String, resume: Bool, fork: Fork? = nil) -> [String] {
        var argv = [
            executable, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--replay-user-messages", "--permission-prompt-tool", "stdio",
        ]
        if let fork {
            argv += ["--resume", fork.source, "--fork-session", "--session-id", record.agentSessionId]
            if let at = fork.at { argv += ["--resume-session-at", at] }
        } else {
            argv += resume ? ["--resume", record.agentSessionId] : ["--session-id", record.agentSessionId]
        }
        if let model = record.model { argv += ["--model", model] }
        if let effort = record.effort { argv += ["--effort", effort] }
        // allow を付けずに起こした CLI は、後から set_permission_mode で bypassPermissions に替えるのを断る（2.1.303 で実測）
        argv += ["--permission-mode", record.permissionMode ?? ConversationInput.defaultPermissionMode, "--allow-dangerously-skip-permissions", "--autocompact", "auto"]
        return argv + record.extraArguments
    }

    static func transcriptExists(_ agentSessionID: String, environment: [String: String]) -> Bool {
        let projects = ClaudeConfigDirectory.projects(environment: environment)
        return TranscriptTail.locate(agentSessionID, in: projects.standardizedFileURL.resolvingSymlinksInPath()) != nil
    }

    static func transcriptSource(fork: String, source: String, environment: [String: String]) -> TranscriptSource? {
        let projects = ClaudeConfigDirectory.projects(environment: environment).standardizedFileURL.resolvingSymlinksInPath()
        guard let own = TranscriptTail.locate(fork, in: projects), let base = TranscriptTail.locate(source, in: projects) else { return nil }
        return TranscriptSource.find(fork: own, source: source, at: base)
    }

    static func transcriptAnswered(_ agentSessionID: String, toolUseID: String, environment: [String: String]) -> Bool {
        let projects = ClaudeConfigDirectory.projects(environment: environment)
        guard let url = TranscriptTail.locate(agentSessionID, in: projects.standardizedFileURL.resolvingSymlinksInPath()),
            let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else { return false }
        return data.range(of: Data(#""tool_use_id":"\#(toolUseID)""#.utf8)) != nil
    }

    static func describe(_ exit: AgentHostExit) -> String {
        if let signal = exit.signal { return "signal \(signal) で終わった" }
        return "終了コード \(exit.status ?? -1) で終わった"
    }
}

extension ClaudeConversation: RewindingConversation, ConversationShell {
    var isAnswering: Bool { !answering.isEmpty }
    var shared: ConversationContext { context.shared }
}

extension ConversationBackgroundTasks.Task {
    /// 裏に回っている（前景で Claude Code が結果を待っていない）。分からないもの（CLI の一覧にだけ載ったもの）は裏と見る
    fileprivate var isBackground: Bool { backgrounded != false }
}
