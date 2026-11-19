import Foundation

/// daemon が agent host で動かす Claude の会話（stream-json の CLI）。hook で結んだ普段使いの端末のセッション（`TaskSessionRef`）とは別に持つ。
/// `id` は daemon が振る UUID で、`/clear` やフォークで変わる Claude の会話 ID（`agentSessionID`）と分ける。
/// マシンを跨いでは `(machine, id)` で指す
public struct Conversation: Codable, Hashable, Sendable, Identifiable {
    public enum Engine: String, Codable, Sendable {
        case claude
        case codex
        /// この版が知らない engine（新しい daemon が足したもの）。会話は捨てずに一覧に残し、開くと案内だけを出す
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Engine(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// 起こす agent の種類（`claude`・`codex`）。知らない engine は nil
        public var agentKind: AgentKind? { AgentKind(rawValue: rawValue) }
    }

    /// `/login` の流れの段階
    public enum LoginStage: String, Codable, Sendable {
        /// ページを開いてログインを終えるのを待っている
        case waiting
        case succeeded
        /// 断られた・時間が過ぎた
        case failed
        /// この版が知らない段階
        case unknown

        public init(from decoder: any Decoder) throws {
            self = LoginStage(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// 何が CLI のプロセスを動かしているか。`none` は止まっている（`--resume` で戻せる）
    public enum Runner: String, Codable, Sendable {
        case host
        case none
    }

    public enum Phase: String, Codable, Sendable {
        /// プロセスを起こして init を待っている
        case starting
        /// 入力を待っている
        case idle
        /// 生成中
        case running
        /// 権限の確認か質問の答えを待っている
        case waiting
        /// プロセスが無い（止めた・終わった・defer で終えた）
        case stopped
    }

    /// daemon が自分で起こした会話の役目。人や agent が起こした会話は nil
    public enum Purpose: String, Codable, Sendable {
        case orchestrator
        case schedule
        /// 廃止した文書の説明役。記録だけが残っていて、会話の一覧・検索に出さない
        case briefing
    }

    public var id: String
    public var machine: MachineID
    public var taskNumber: Int?
    public var engine: Engine
    public var agentSessionID: String
    public var cwd: String
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    /// 出す題（人が付けた名前があればそれ、無ければ自動の題）
    public var title: String?
    /// 人が付けた名前。付けていなければ nil（前の版の daemon も nil）。空にして外すと `title` は自動の題に戻る
    public var customTitle: String?
    public var runner: Runner
    public var phase: Phase
    /// 答えを待っている問い（プロセスが動いている間の `can_use_tool`）
    public var pending: [ConversationRequest]
    /// defer で終えた問い。答えると `--resume` で戻して入れる
    public var deferred: ConversationRequest?
    /// 最後にプロセスが終わった理由（人が読む文）
    public var lastExit: String?
    /// 動いている裏のタスク（`run_in_background` の Bash など）の数。残っている間は自動で止めない
    public var backgroundTasks: Int
    /// 裏のタスクの数が分かっているか。host の控えから行が落ちた会話は分からない（プロセスが終わるか CLI の task の一覧が届くまで自動で止めない）
    public var backgroundTasksKnown: Bool
    /// 裏に回った（前景で結果を待っていない）タスクの様子。動いているものを始めた順に、続けて終わったものを終わった順に（新しい 100 件まで）。
    /// Claude Code の会話だけ。nil は前の版の daemon と codex
    public var backgroundTaskStates: [ConversationBackgroundTaskState]?
    /// コンテキストの使用率（0〜100）。ターンの後に daemon が取る。止まった会話は最後に取った値
    public var contextPercent: Int?
    /// 作業フォルダの差分の要約。ターンの後・ファイルを書くツールの後・Run の後に daemon が取り直す
    public var diff: ConversationDiffSummary?
    /// フォーク元の会話の id
    public var forkSource: String?
    /// フォークした地点（フォーク元の transcript の行の uuid。codex は発言の id）。末尾から分けた codex の会話は nil
    public var forkAt: String?
    /// フォークか巻き戻しの後で、まだ送っていない（新しい Claude の会話の transcript がまだ無い）。この間は端末で開けない
    public var forkPending: Bool
    /// 巻き戻しを元に戻せる（直前の 1 回だけ）
    public var canUndoRewind: Bool
    /// 元に戻した巻き戻しをやり直せる（元に戻した後、次に送るまで）
    public var canRedoRewind: Bool
    /// 巻き戻しの途中で daemon が終わり、ファイルを戻せたか分からない。次に送るか元に戻すと消える
    public var rewindIncomplete: Bool
    public var purpose: Purpose?

    /// 止めると記録が消えるか。タスクに結ばれていない会話は消える（画面から開き直す道が無い）。オーケストレーター（常駐が同じ会話で起こし直す）と
    /// 定期起動の回（回の行から開き直す）は消えない
    public var removedOnStop: Bool { taskNumber == nil && purpose == nil }

    /// 起こした側（委譲先の会話のとき）。会話か pane のどちらか
    public var parentConversationID: String?
    /// 起こした側にまだ知らせていないことがある
    public var parentNoticePending: Bool
    /// 利用枠の上限で止まり、この時刻に続きを送る。`limitPaused` なら上限の前に taskboard が区切った待ちで、続きは送らずに待ちを解くだけ
    public var limitResumeAt: Date?
    public var limitPaused: Bool
    /// ネットワークに繋がらずにターンが終わり、接続が戻ったら続きを送る（Claude の会話だけ）。印が無ければ載せない（前の版の daemon も載せない）
    public var networkResume: Bool?
    /// engine の会話の値（費用・トークン・解決したモデル・版・コンテキスト）。止まった会話は最後に取った値。出すときは `currentStats`
    public var stats: ConversationStats?
    /// `/login` の流れの段階。流れが無ければ nil。会話が止まると消える（URL・アカウント・コードは載せない）
    public var login: LoginStage?
    /// 会話を圧縮している間だけ。前の版の daemon は載せない
    public var compaction: ConversationCompaction?
    /// ［今すぐ送信］で裏に回せる、主の流れの前景で動いている tool（Claude Code の Bash・PowerShell・Agent・Task）の数。0 なら載せない（前の版の daemon も載せない）
    public var detachableTools: Int?
    /// 生成中なのに engine から何も届かなくなった（daemon の見張り）。値は最後に届いた時刻。届けば nil
    public var stalledSince: Date?
    /// API に届かず CLI が送り直している間だけ。前の版の daemon は載せない
    public var apiRetry: ConversationAPIRetry?
    /// 中断で codex が待ち行列を止めている（次の turn が普通に終わるか、［再開］で始めるまで codex は待ち行列を始めない）。止まっていなければ載せない（前の版の daemon も載せない）
    public var queuePaused: Bool?
    /// engine の計画（Claude Code の TaskCreate・TaskUpdate の一覧）。項目が無ければ載せない（前の版の daemon と codex も載せない）
    public var plan: [ConversationPlanItem]?
    /// Claude Code のアカウント（`ClaudeAccount`）。マシンのログインなら載せない（前の版の daemon も載せない）
    public var account: String?
    /// 最後に応答を書いて終わったターンの、最後の応答の頭。ターンの終わりにだけ変わる。前の版の daemon は載せない
    public var lastReply: ConversationReply?
    /// 最後に始まったターンの時刻（今のターンが終わっても残す）。前の版の daemon は載せない
    public var turnStartedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var key: ConversationKey { ConversationKey(machine: machine, id: id) }

    /// 一覧の並び（作った順。同じ時刻なら id）
    public static func listOrder(_ a: Conversation, _ b: Conversation) -> Bool {
        (a.createdAt, a.id) < (b.createdAt, b.id)
    }

    /// 今の engine の会話の値。`/clear`・フォーク・巻き戻しの前の会話の値は出さない
    public var currentStats: ConversationStats? { stats?.agentSessionID == agentSessionID ? stats : nil }

    /// 動いている裏のタスクの数（下の帯と一覧の印）。`backgroundTasks` は前景で結果を待っているタスクも数えるので、様子が載っていれば裏に回ったものだけを数える。
    /// 数が分からなければ nil
    public var runningBackgroundTasks: Int? {
        guard backgroundTasksKnown else { return nil }
        return backgroundTaskStates.map { $0.count { $0.status == .running } } ?? backgroundTasks
    }

    public init(
        id: String, machine: MachineID, taskNumber: Int?, engine: Engine = .claude, agentSessionID: String, cwd: String, model: String? = nil,
        effort: String? = nil, permissionMode: String? = nil, title: String? = nil, runner: Runner, phase: Phase, pending: [ConversationRequest] = [],
        deferred: ConversationRequest? = nil, lastExit: String? = nil, backgroundTasks: Int = 0, backgroundTasksKnown: Bool = true,
        backgroundTaskStates: [ConversationBackgroundTaskState]? = nil,
        contextPercent: Int? = nil, diff: ConversationDiffSummary? = nil, forkSource: String? = nil, forkPending: Bool = false,
        canUndoRewind: Bool = false, canRedoRewind: Bool = false, rewindIncomplete: Bool = false, purpose: Purpose? = nil,
        parentConversationID: String? = nil, parentNoticePending: Bool = false,
        limitResumeAt: Date? = nil, limitPaused: Bool = false, networkResume: Bool? = nil, stats: ConversationStats? = nil, login: LoginStage? = nil, compaction: ConversationCompaction? = nil, detachableTools: Int? = nil, stalledSince: Date? = nil,
        apiRetry: ConversationAPIRetry? = nil, queuePaused: Bool? = nil, plan: [ConversationPlanItem]? = nil, account: String? = nil, createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.account = account
        self.machine = machine
        self.taskNumber = taskNumber
        self.engine = engine
        self.agentSessionID = agentSessionID
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.title = title
        self.runner = runner
        self.phase = phase
        self.pending = pending
        self.deferred = deferred
        self.lastExit = lastExit
        self.backgroundTasks = backgroundTasks
        self.backgroundTasksKnown = backgroundTasksKnown
        self.backgroundTaskStates = backgroundTaskStates
        self.contextPercent = contextPercent
        self.diff = diff
        self.forkSource = forkSource
        self.forkPending = forkPending
        self.canUndoRewind = canUndoRewind
        self.canRedoRewind = canRedoRewind
        self.rewindIncomplete = rewindIncomplete
        self.purpose = purpose
        self.parentConversationID = parentConversationID
        self.parentNoticePending = parentNoticePending
        self.limitResumeAt = limitResumeAt
        self.limitPaused = limitPaused
        self.networkResume = networkResume
        self.stats = stats
        self.login = login
        self.compaction = compaction
        self.detachableTools = detachableTools
        self.stalledSince = stalledSince
        self.apiRetry = apiRetry
        self.queuePaused = queuePaused
        self.plan = plan
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, machine, taskNumber, engine, agentSessionID, cwd, model, effort, permissionMode, title, customTitle, runner, phase, pending, deferred, lastExit
        case backgroundTasks, backgroundTasksKnown, backgroundTaskStates, contextPercent, diff, forkSource, forkAt, forkPending, canUndoRewind, canRedoRewind, rewindIncomplete
        case purpose, parentConversationID, parentNoticePending, limitResumeAt, limitPaused, networkResume, stats, login, compaction, detachableTools, stalledSince, apiRetry, queuePaused, plan
        case account, lastReply, turnStartedAt, createdAt, updatedAt
    }

    /// E1 の daemon は裏のタスクの数を、E2 の daemon は E3 の項目を、E3 の daemon は E4 の項目を返さない
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        machine = try c.decode(MachineID.self, forKey: .machine)
        taskNumber = try c.decodeIfPresent(Int.self, forKey: .taskNumber)
        engine = try c.decode(Engine.self, forKey: .engine)
        agentSessionID = try c.decode(String.self, forKey: .agentSessionID)
        cwd = try c.decode(String.self, forKey: .cwd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        runner = try c.decode(Runner.self, forKey: .runner)
        phase = try c.decode(Phase.self, forKey: .phase)
        pending = try c.decode([ConversationRequest].self, forKey: .pending)
        deferred = try c.decodeIfPresent(ConversationRequest.self, forKey: .deferred)
        lastExit = try c.decodeIfPresent(String.self, forKey: .lastExit)
        backgroundTasks = try c.decodeIfPresent(Int.self, forKey: .backgroundTasks) ?? 0
        backgroundTasksKnown = try c.decodeIfPresent(Bool.self, forKey: .backgroundTasksKnown) ?? true
        backgroundTaskStates = try c.decodeIfPresent([ConversationBackgroundTaskState].self, forKey: .backgroundTaskStates)
        contextPercent = try c.decodeIfPresent(Int.self, forKey: .contextPercent)
        diff = try c.decodeIfPresent(ConversationDiffSummary.self, forKey: .diff)
        forkSource = try c.decodeIfPresent(String.self, forKey: .forkSource)
        forkAt = try c.decodeIfPresent(String.self, forKey: .forkAt)
        forkPending = try c.decodeIfPresent(Bool.self, forKey: .forkPending) ?? false
        canUndoRewind = try c.decodeIfPresent(Bool.self, forKey: .canUndoRewind) ?? false
        canRedoRewind = try c.decodeIfPresent(Bool.self, forKey: .canRedoRewind) ?? false
        rewindIncomplete = try c.decodeIfPresent(Bool.self, forKey: .rewindIncomplete) ?? false
        // 新しい daemon が足した役目は、役目の無い会話として扱う
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose).flatMap(Purpose.init(rawValue:))
        parentConversationID = try c.decodeIfPresent(String.self, forKey: .parentConversationID)
        parentNoticePending = try c.decodeIfPresent(Bool.self, forKey: .parentNoticePending) ?? false
        limitResumeAt = try c.decodeIfPresent(Date.self, forKey: .limitResumeAt)
        limitPaused = try c.decodeIfPresent(Bool.self, forKey: .limitPaused) ?? false
        networkResume = try? c.decodeIfPresent(Bool.self, forKey: .networkResume)
        // 値が読めなくても会話は読む（値は表示のためだけのもので、欄は engine ごとに増える）
        stats = try? c.decodeIfPresent(ConversationStats.self, forKey: .stats)
        login = try c.decodeIfPresent(LoginStage.self, forKey: .login)
        compaction = try? c.decodeIfPresent(ConversationCompaction.self, forKey: .compaction)
        detachableTools = try c.decodeIfPresent(Int.self, forKey: .detachableTools)
        stalledSince = try? c.decodeIfPresent(Date.self, forKey: .stalledSince)
        apiRetry = try? c.decodeIfPresent(ConversationAPIRetry.self, forKey: .apiRetry)
        queuePaused = try? c.decodeIfPresent(Bool.self, forKey: .queuePaused)
        plan = try? c.decodeIfPresent([ConversationPlanItem].self, forKey: .plan)
        account = try? c.decodeIfPresent(String.self, forKey: .account)
        lastReply = try? c.decodeIfPresent(ConversationReply.self, forKey: .lastReply)
        turnStartedAt = try? c.decodeIfPresent(Date.self, forKey: .turnStartedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// 答えを待っている問い（動いている間の問いが先、defer で終えた問いが後）
    public var requests: [ConversationRequest] { pending + (deferred.map { [$0] } ?? []) }
}

/// 会話の最後の応答（`Conversation.lastReply`）
public struct ConversationReply: Codable, Hashable, Sendable {
    /// 応答の頭（`limit` 字まで）
    public var text: String
    /// ターンが終わった時刻
    public var at: Date

    public static let limit = 200

    public init(text: String, at: Date) {
        self.text = String(text.prefix(Self.limit))
        self.at = at
    }
}

/// 会話が今使っているツール（`conversation.activity` の知らせ）。ツールの始まりと終わりのたびに変わるので、`Conversation` に入れずに別に送る
public struct ConversationToolActivity: Codable, Hashable, Sendable {
    public var conversation: ConversationKey
    /// 最後に始めて、まだ終わっていないツールの名前。nil はツールを使っていない
    public var toolName: String?

    public init(conversation: ConversationKey, toolName: String?) {
        self.conversation = conversation
        self.toolName = toolName
    }
}

/// 会話を圧縮している間の様子（Claude Code の `system/status` の `compacting`、codex の `contextCompaction` の item）
public struct ConversationCompaction: Codable, Hashable, Sendable {
    public var startedAt: Date
    /// これまでに書いた要約の字数。Claude Code の自動の圧縮だけが知らせる（手で送った `/compact` と codex には無い）
    public var outputChars: Int?

    public init(startedAt: Date, outputChars: Int? = nil) {
        self.startedAt = startedAt
        self.outputChars = outputChars
    }
}

/// API に届かず、CLI が送り直している間の様子（Claude Code の `system/api_retry`。利用枠の待ちの間の心拍も同じ形で届く）
public struct ConversationAPIRetry: Codable, Hashable, Sendable {
    /// 今の回（1 から）と上限（CLI が載せなければ nil）
    public var attempt: Int
    public var maxRetries: Int?
    /// 次に送る時刻（受けた時刻 + `retry_delay_ms`）
    public var retryAt: Date
    /// API が返した HTTP の status。つながらないときは nil
    public var status: Int?
    /// CLI の種類の名前（`overloaded`・`rate_limit`・`authentication_failed`・`server_error`・`cloud_credential_error`・`unknown`）。版が増やした名前もそのまま持つ
    public var kind: String

    public init(attempt: Int, maxRetries: Int? = nil, retryAt: Date, status: Int? = nil, kind: String) {
        self.attempt = attempt
        self.maxRetries = maxRetries
        self.retryAt = retryAt
        self.status = status
        self.kind = kind
    }
}

/// 会話をマシンを跨いで一意に指すキー
public struct ConversationKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let machine: MachineID
    public let id: String

    public init(machine: MachineID, id: String) {
        self.machine = machine
        self.id = id
    }

    public var description: String { "\(machine.rawValue)/\(id)" }
}

/// 会話が答えを待っている問い。中身は `RequestWaiting`
public struct ConversationRequest: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// AskUserQuestion
        case question
        /// ExitPlanMode（計画の承認）
        case plan
        /// ツールの権限の確認
        case permission
        /// MCP の server が人に聞く問い（`elicitation` に中身）
        case elicitation
        /// この版が知らない種類（新しい daemon が足したもの）。捨てると CLI が答えを待ったままになるので、カードで端末へ案内する
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// 答えるときに指す id。プロセスが動いている間は CLI の制御要求の id、defer で終えた問いは tool_use の id
    public var id: String
    public var kind: Kind
    public var toolName: String
    public var toolUseID: String?
    public var waiting: RequestWaiting
    /// ExitPlanMode の計画の本文
    public var plan: String?
    /// kind が elicitation のとき
    public var elicitation: Elicitation?
    /// Codex の承認が出した答えの選択肢（要求の `availableDecisions` の順）。nil は［許可］［拒否］の 2 択
    public var decisions: [ConversationDecision]?
    /// Claude の権限の確認で、CLI が出した「今後は聞かない」候補。選ぶと許可に添えて返す。nil か空は候補なし
    public var suggestions: [PermissionSuggestion]?

    public init(
        id: String, kind: Kind, toolName: String, toolUseID: String?, waiting: RequestWaiting, plan: String? = nil, elicitation: Elicitation? = nil,
        decisions: [ConversationDecision]? = nil, suggestions: [PermissionSuggestion]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.waiting = waiting
        self.plan = plan
        self.elicitation = elicitation
        self.decisions = decisions
        self.suggestions = suggestions
    }
}

/// Codex の承認の答え（codex の `CommandExecutionApprovalDecision` の文字列の値）
public enum ConversationDecision: String, Codable, Hashable, Sendable {
    case accept
    /// 同じコマンドは、この会話の間は聞かずに許可する
    case acceptForSession
    /// 拒否して、ターンは続ける
    case decline
    /// 拒否して、ターンを止める
    case cancel
    /// この版が知らない答え（新しい codex が足したもの）。画面に出さず、送らない
    case unknown

    public init(from decoder: any Decoder) throws {
        self = ConversationDecision(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// 許可の側か。答えには `allow` も添える（`decision` を知らない古い daemon が同じ向きで答える）
    public var allows: Bool { self == .accept || self == .acceptForSession }
}

/// `POST /v1/conversations`
public struct ConversationStartRequest: Codable, Hashable, Sendable {
    public var cwd: String
    public var taskNumber: Int?
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    /// 最初に送る発言。空なら起こすだけ
    public var prompt: String?
    /// 前の Claude の会話を戻すとき
    public var resumeAgentSessionID: String?
    /// CLI にそのまま渡す引数（`--settings <絶対パス>`・`--disallowedTools <名前…>`・`--allowedTools <名前…>`・`--add-dir <絶対パス>` だけ）
    public var extraArgs: [String]?
    /// worktree を切ってその中で動かす（`cwd` の repo から）
    public var worktree: LaunchRequest.WorktreeSpec?
    /// 起こした側（委譲先の会話のとき）
    public var parent: ConversationParent?
    /// ターンの終わりと問いを `parent` に知らせる
    public var notifyParent: Bool?
    public var title: String?
    /// 省くと Claude Code
    public var engine: AgentKind?
    /// Claude Code のアカウント（`LaunchRequest.claudeAccount`）
    public var account: String?

    public init(
        cwd: String, taskNumber: Int? = nil, model: String? = nil, effort: String? = nil, permissionMode: String? = nil, prompt: String? = nil,
        resumeAgentSessionID: String? = nil, extraArgs: [String]? = nil, worktree: LaunchRequest.WorktreeSpec? = nil, parent: ConversationParent? = nil,
        notifyParent: Bool? = nil, title: String? = nil, engine: AgentKind? = nil, account: String? = nil
    ) {
        self.cwd = cwd
        self.account = account
        self.taskNumber = taskNumber
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.prompt = prompt
        self.resumeAgentSessionID = resumeAgentSessionID
        self.extraArgs = extraArgs
        self.worktree = worktree
        self.parent = parent
        self.notifyParent = notifyParent
        self.title = title
        self.engine = engine
    }
}

/// 会話を起こした側の host の会話。
/// `agentSessionID` は呼んだ Claude Code の会話 ID（`CLAUDE_CODE_SESSION_ID`）。daemon はその会話が同じ会話 ID を持つかを確かめる
public struct ConversationParent: Codable, Hashable, Sendable {
    public var conversationID: String?
    public var agentSessionID: String?

    public init(conversationID: String? = nil, agentSessionID: String? = nil) {
        self.conversationID = conversationID
        self.agentSessionID = agentSessionID
    }
}

/// 止まったセッションを戻した結果
public struct SessionResumeResult: Codable, Hashable, Sendable {
    public var conversation: Conversation?

    public init(conversation: Conversation? = nil) {
        self.conversation = conversation
    }
}

/// `POST /v1/conversations/{id}/messages`。`clientMessageID` は送る側が振り、同じ id は 2 回入れない
public struct ConversationSendRequest: Codable, Hashable, Sendable {
    public var text: String
    /// `POST /v1/conversations/{id}/attachments` で置いた画像の id
    public var attachments: [String]
    /// 画像でない添付。daemon のマシンの絶対パス（同じ Mac で選んだファイルか、`POST /v1/conversations/{id}/files` で置いたファイル）。
    /// daemon が `MentionedFiles` の形で本文の頭に書く
    public var files: [String]
    public var clientMessageID: String
    /// 生成中なら今のターンに入れず、ターンが終わってから送る（Claude の user 行の priority "later"）。true のときだけ載せる。
    /// codex は生成中の発言をもともとターンの後に回すので読まない
    public var later: Bool?

    public init(text: String, attachments: [String] = [], files: [String] = [], clientMessageID: String = UUID().uuidString.lowercased(), later: Bool = false) {
        self.text = text
        self.attachments = attachments
        self.files = files
        self.clientMessageID = clientMessageID
        self.later = later ? true : nil
    }

    private enum CodingKeys: String, CodingKey {
        case text, attachments, files, clientMessageID, later
    }

    /// `files` と `later` は前の版のアプリが送らない
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decode([String].self, forKey: .attachments)
        files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
        clientMessageID = try container.decode(String.self, forKey: .clientMessageID)
        later = try container.decodeIfPresent(Bool.self, forKey: .later) == true ? true : nil
    }

    public var isLater: Bool { later == true }
}

/// 送信の結果。`accepted` は CLI が受けた、`duplicate` は同じ `clientMessageID` を前に受けている、`unknown` は受けたかを確かめられなかった
public struct ConversationSendResponse: Codable, Hashable, Sendable {
    public var outcome: String

    public init(outcome: String) {
        self.outcome = outcome
    }
}

/// `POST /v1/conversations/{id}/answers`。質問には `answers`、権限の確認と計画には `allow`（拒否の理由は `message`）、
/// MCP の server の問いには `action` と（form を受けるときだけ）`content`
public struct ConversationAnswerRequest: Codable, Hashable, Sendable {
    public var requestID: String
    public var answers: [AskAnswer]?
    public var allow: Bool?
    public var message: String?
    public var action: ElicitationAction?
    public var content: [String: ElicitationValue]?
    /// Codex の承認で選んだ答え（問いの `decisions` のどれか）。省くと `allow` から許可か拒否
    public var decision: ConversationDecision?
    /// Claude の権限の確認で選んだ「今後は聞かない」候補（問いの `suggestions` の id）。`allow` が true のときだけ。古い daemon は読み飛ばして、ただの許可になる
    public var suggestionID: String?

    public init(
        requestID: String, answers: [AskAnswer]? = nil, allow: Bool? = nil, message: String? = nil, action: ElicitationAction? = nil,
        content: [String: ElicitationValue]? = nil, decision: ConversationDecision? = nil, suggestionID: String? = nil
    ) {
        self.requestID = requestID
        self.answers = answers
        self.allow = allow
        self.message = message
        self.action = action
        self.content = content
        self.decision = decision
        self.suggestionID = suggestionID
    }
}

/// `POST /v1/conversations/{id}/close`。`afterTurn` が true なら、今のターンを終えて入力待ちに入ってから終了する（会話が自分を終了するとき。
/// tool の途中で止めると返事が返らない）。静かな会話・止まった会話はすぐ終了する
public struct ConversationCloseRequest: Codable, Hashable, Sendable {
    public var afterTurn: Bool?

    public init(afterTurn: Bool? = nil) {
        self.afterTurn = afterTurn
    }
}

/// `POST /v1/conversations/{id}/control`
public struct ConversationControlRequest: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case interrupt
        case setModel = "set_model"
        case setPermissionMode = "set_permission_mode"
        case mcpStatus = "mcp_status"
        case contextUsage = "context_usage"
        case usage
        case rename
        /// 質問を必ず defer で終える（確かめ用。`off` で戻すと、画面に出ているか（購読の数）で決める）
        case deferQuestions = "defer_questions"
        /// effort を替える（`value` は low・medium・high・xhigh・max）。止まった会話は記録だけを書き換える
        case setEffort = "set_effort"
        /// 起こした側へターンの終わりと回答待ちを知らせるかを替える（`value` は on・off）。止まった会話も記録を書き換える
        case setNotifyParent = "set_notify_parent"
        /// MCP の server に繋ぎ直す（`value` は server の名前）
        case mcpReconnect = "mcp_reconnect"
        /// MCP の server を有効・無効にする（`value` は server の名前、`enabled`）。CLI がそのフォルダの設定に残すので、そのフォルダの Claude Code 全部に効く
        case mcpToggle = "mcp_toggle"
        /// 利用枠の上限の後・ネットワークが戻った後に続きを送る予定を取り消す（会話は止めない）
        case cancelLimitResume = "cancel_limit_resume"
        /// MCP の問い（url）の開く先の全文を、要求した端末にだけ返す（`value` は問いの id、応答は `ElicitationURLResponse`）
        case elicitationURL = "elicitation_url"
        /// コンテキストの区分ごとのトークン（応答は `ConversationContextBreakdown`）
        case contextBreakdown = "context_breakdown"
        /// コネクタの認証を始める（`value` は server の名前。応答は `ConversationMcpAuthentication`）
        case mcpAuthenticate = "mcp_authenticate"
        /// 認証の後に開いたページのアドレス（`callbackURL`）を渡して繋ぐ（`value` は server の名前）
        case mcpOAuthCallback = "mcp_oauth_callback"
        /// コネクタの認証を解除する（`value` は server の名前）
        case mcpClearAuth = "mcp_clear_auth"
        /// 会話を文にした書き出し（`/export`。応答は `ConversationExport`）
        case exportConversation = "export_conversation"
        /// 裏のタスクの一覧（`/tasks`。応答は `ConversationBackgroundTasks`。Claude は daemon が持っている一覧で CLI には聞かない、codex は裏のターミナルの一覧）
        case listBackgroundTasks = "list_background_tasks"
        /// 裏のタスクの出力の末尾（`value` はタスクの id。応答は `ConversationTaskOutput`）
        case taskOutput = "task_output"
        /// 裏のタスクを止める（`value` はタスクの id）
        case stopTask = "stop_task"
        /// 権限の規則と作業フォルダ（`/permissions`。応答は `ConversationPermissionRules`）
        case permissionRules = "permission_rules"
        /// hook の一覧（`/hooks`。応答は `ConversationHooks`）
        case hooks
        /// 読み込んでいるメモリのファイル（`/memory`。応答は `ConversationMemory`）
        case memory
        /// skill の一覧（`/skills`。応答は `ConversationSkills`）
        case skills
        /// 会話の記録に入れない脇の質問（`/btw`。`value` は質問。応答は `ConversationSideAnswer`）
        case sideQuestion = "side_question"
        /// 作業フォルダを足す（`/add-dir`。`value` はパス。今の作業フォルダの下だけ。応答は `ConversationDirectoryAdded`）
        case addDirectory = "add_directory"
        /// 作業フォルダを替える（`/cd`。`value` はパス。応答は `ConversationCwdChange`）
        case setCwd = "set_cwd"
        /// engine のアカウントのログインを始める（`/login`。応答は `ConversationLogin`。終わりは会話の `login` で知る。マシンのすべての会話に効く）
        case login
        /// ほかの端末でログインのページに出たコード（`code`）を渡す
        case loginCode = "login_code"
        /// sandbox の状態（`/sandbox`。応答は `ConversationSandbox`）
        case sandbox
        /// plugin と marketplace の一覧（`/plugin`。`value` は入れられる plugin を絞る文字。応答は `ConversationPlugins`）
        case plugins
        /// 設定を書く（`edit` に中身。応答は `ConversationSettingsEditResult`）。書く先によってはマシンのすべての会話に効く
        case editSettings = "edit_settings"
        /// 生成中に送って待っている発言（`value` は発言の uuid）を今すぐ渡す。動いているシェルとサブエージェントは止めずに裏へ回る。応答は `ConversationSendNow`
        case sendNow = "send_now"
        /// 生成中に送って待っている発言（`value` は発言の uuid）を待ち行列から外す。応答は `ConversationQueuedCancel`。
        /// 外せたら発言の受付は cancelled で終わる（［編集］は外してから直した文を送る）
        case cancelQueued = "cancel_queued"
        /// 会話を圧縮する（codex の `thread/compact/start`。空いているときだけ）。Claude は CLI の `/compact` を文で送る
        case compact
        /// 同じ会話で新しい thread を始める（codex の `/new`・`/clear`。空いているときだけ）。前の thread は会話のタスクに結んだまま残す。
        /// Claude は CLI の `/clear` を文で送る
        case newThread = "new_thread"
        /// コードをレビューさせる（codex の `review/start`。`value` が無ければ未コミットの変更、あれば指示。空いているときだけ）。Claude は CLI の `/review` を文で送る
        case review
    }

    public var kind: Kind
    public var value: String?
    /// `mcp_toggle` で有効にするか
    public var enabled: Bool?
    /// `mcp_oauth_callback` で渡す、認証の後に開いたページのアドレス
    public var callbackURL: String?
    /// `login_code` で渡す、ログインのページに出たコード（`value` に載せない。`value` は CLI の引数やログに出ることがある）
    public var code: String?
    /// `edit_settings` で書く中身
    public var edit: ConversationSettingsEdit?

    public init(
        kind: Kind, value: String? = nil, enabled: Bool? = nil, callbackURL: String? = nil, code: String? = nil, edit: ConversationSettingsEdit? = nil
    ) {
        self.kind = kind
        self.value = value
        self.enabled = enabled
        self.callbackURL = callbackURL
        self.code = code
        self.edit = edit
    }
}

/// 制御要求の結果。`payloadJSON` は応答の中身（`get_context_usage`・`get_usage` は CLI の応答のまま、`mcp_status` は `ConversationMcpStatus`）
public struct ConversationControlResponse: Codable, Hashable, Sendable {
    public var payloadJSON: String?

    public init(payloadJSON: String?) {
        self.payloadJSON = payloadJSON
    }
}

/// `cancel_queued` の結果（CLI の応答のまま）。false は、もう生成に渡った・待ち行列に無かった
public struct ConversationQueuedCancel: Codable, Hashable, Sendable {
    public var cancelled: Bool

    public init(cancelled: Bool) {
        self.cancelled = cancelled
    }
}

/// `send_now` の結果
public struct ConversationSendNow: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// 生成を止めて、すぐ渡した
        case stopped
        /// 次の切れ目で渡す
        case delivering
        /// 待っている発言が無かった（もう渡っていた）
        case nothingWaiting = "nothing_waiting"
    }

    public var outcome: Outcome
    /// daemon が前景の tool を裏に回して渡した（`delivering` のときだけ true。前の版の daemon は送らない）
    public var backgrounded: Bool?

    public init(outcome: Outcome, backgrounded: Bool? = nil) {
        self.outcome = outcome
        self.backgrounded = backgrounded
    }

    private enum CodingKeys: String, CodingKey {
        case outcome = "send_now"
        case backgrounded
    }
}

/// `GET /v1/conversations/{id}/history?before=<cursor>&limit=<1〜50>`。transcript を新しい方から読んだ 1 ページ
public struct ConversationHistoryResponse: Codable, Hashable, Sendable {
    /// 古い順
    public var messages: [ChatMessage]
    /// 次（より古い方）のページの cursor。先頭まで読んだら nil
    public var nextCursor: String?
    /// 読んだ transcript の Claude の会話 ID（`/clear` で変わる。変わったら手元の発言を捨てて取り直す）
    public var agentSessionID: String

    public static let maxLimit = 50

    public init(messages: [ChatMessage], nextCursor: String?, agentSessionID: String) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.agentSessionID = agentSessionID
    }
}

/// 会話の出来事。`seq` は daemon が会話ごとに振る番号で、`GET …/events?after=` で続きから取る
public struct ConversationEvent: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// 会話の記録が変わった（状態・問い・題・モデル）
        case conversation(Conversation)
        /// 生成中の block が始まった。`messageID` は API の message の id、`index` は block の位置。`toolName` はツールの呼び出しの block のとき
        case blockStart(messageID: String, index: Int, block: DeltaBlock, toolName: String?)
        /// 生成中の差分（daemon が 50ms ずつまとめる）
        case delta(messageID: String, index: Int, block: DeltaBlock, text: String)
        /// block が終わった。その block の終わった発言（`messages`）は、これより先に届く（Claude Code 2.1.303 で実測）
        case blockStop(messageID: String, index: Int)
        /// 終わった発言。`apiMessageID` は assistant の発言の API の message の id で、同じ id の生成中の block をこれで置き換える。
        /// 送った発言の写し（`--replay-user-messages`）の id は、送ったときの `clientMessageID` か `<clientMessageID>#<n>`
        case messages([ChatMessage], apiMessageID: String?)
        /// 送った発言を CLI が受けた（`queued`・`started`・`completed`）
        case accepted(clientMessageID: String, state: String)
        /// ターンが終わった
        case turn(ConversationTurn)
        /// 控えから落ちた分がある。続きは transcript から読み直す
        case gap
        /// 人が読む知らせ（読めないメッセージ、プロセスの終わりなど）
        case notice(String)
        /// `/` で使えるコマンドの一覧が変わった
        case commands([ConversationCommand])
        /// コードブロックの Run の出力と状態（100ms ずつまとめる）
        case run(ConversationRunUpdate)
        /// 会話の履歴が替わった（巻き戻し・元に戻す）。手元の発言を捨てて履歴を取り直す
        case reset
        /// この版が知らない種類の出来事か塊（新しい daemon が足したもの）。番号だけ進める（飛ばすと続きから受けられなくなる）
        case unsupported
    }

    public enum DeltaBlock: String, Codable, Hashable, Sendable {
        case text, thinking, toolInput
    }

    public var seq: Int
    public var conversationID: String
    public var at: Date
    public var kind: Kind

    public init(seq: Int, conversationID: String, at: Date, kind: Kind) {
        self.seq = seq
        self.conversationID = conversationID
        self.at = at
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case seq, conversationID, at, kind }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        at = try c.decode(Date.self, forKey: .at)
        do {
            kind = try c.decode(Kind.self, forKey: .kind)
        } catch DecodingError.typeMismatch(_, let context) where context.codingPath.last?.stringValue == CodingKeys.kind.stringValue {
            // 知らない種類（Kind の鍵がどれにも当たらない）
            kind = .unsupported
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.last?.stringValue == "block" {
            kind = .unsupported
        }
    }
}

extension ConversationEvent {
    /// サブエージェントの発言を外した出来事（求めていない購読に送る）。外す発言が無ければ nil
    public var strippedOfSubagents: ConversationEvent? {
        guard case .messages(let messages, let apiMessageID) = kind, messages.contains(where: \.isSubagent) else { return nil }
        var event = self
        event.kind = .messages(messages.filter { !$0.isSubagent }, apiMessageID: apiMessageID)
        return event
    }
}

/// 今の engine の会話（Claude の session ID・codex の thread ID）の値。費用とトークンはその会話の累計で、`/clear`・フォーク・巻き戻しで
/// engine の会話が替わると 0 から数え直す（`--resume` では続く。2.1.303 で実測）
public struct ConversationStats: Codable, Hashable, Sendable {
    public struct Tokens: Codable, Hashable, Sendable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int

        public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    /// 値を取った engine の会話。今の `Conversation.agentSessionID` と違えば古い値
    public var agentSessionID: String
    /// 解決したモデル（既定のモデルで起こしたときも名前が入る）
    public var model: String?
    /// engine の CLI の版
    public var engineVersion: String?
    public var costUSD: Double?
    public var tokens: Tokens?
    /// コンテキストに入っているトークンと、上限
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var at: Date

    public init(
        agentSessionID: String, model: String? = nil, engineVersion: String? = nil, costUSD: Double? = nil, tokens: Tokens? = nil,
        contextTokens: Int? = nil, contextWindow: Int? = nil, at: Date
    ) {
        self.agentSessionID = agentSessionID
        self.model = model
        self.engineVersion = engineVersion
        self.costUSD = costUSD
        self.tokens = tokens
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.at = at
    }
}

/// `context_breakdown` の応答。コンテキストの区分ごとのトークン（codex は区分が無く、合計と上限だけ）
public struct ConversationContextBreakdown: Codable, Hashable, Sendable {
    public struct Category: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// コンテキストに入っている
            case used
            /// 使うときに読み込む（合計に入らない）
            case deferred
            /// 自動の圧縮のために空けてある
            case buffer
            case free
            case other

            public init(from decoder: any Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
            }
        }

        /// engine が付けた名前（Claude Code は英語。画面は知っている名前を訳す）
        public var name: String
        public var tokens: Int
        public var kind: Kind

        public init(name: String, tokens: Int, kind: Kind) {
            self.name = name
            self.tokens = tokens
            self.kind = kind
        }
    }

    /// 取った engine の会話（開いている間に替わったら捨てる）
    public var agentSessionID: String
    public var categories: [Category]
    public var totalTokens: Int
    public var maxTokens: Int
    /// この量に達すると自動で圧縮する
    public var autoCompactThreshold: Int?

    public init(agentSessionID: String, categories: [Category], totalTokens: Int, maxTokens: Int, autoCompactThreshold: Int?) {
        self.agentSessionID = agentSessionID
        self.categories = categories
        self.totalTokens = totalTokens
        self.maxTokens = maxTokens
        self.autoCompactThreshold = autoCompactThreshold
    }
}

public struct ConversationTurn: Codable, Hashable, Sendable {
    public var isError: Bool
    public var stopReason: String?
    public var durationMs: Int?
    public var ttftMs: Int?
    public var costUSD: Double?
    public var outputTokens: Int?

    public init(isError: Bool, stopReason: String?, durationMs: Int?, ttftMs: Int?, costUSD: Double?, outputTokens: Int?) {
        self.isError = isError
        self.stopReason = stopReason
        self.durationMs = durationMs
        self.ttftMs = ttftMs
        self.costUSD = costUSD
        self.outputTokens = outputTokens
    }
}

extension Sequence<Conversation> {
    /// 会話を合わせた、動いている裏のタスクの数（タスクの行とカードの印）。数が分からない会話は数えない
    public var runningBackgroundTasks: Int { reduce(0) { $0 + ($1.runningBackgroundTasks ?? 0) } }
}
