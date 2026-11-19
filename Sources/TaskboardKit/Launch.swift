import Foundation

// MARK: - 起動（タスクからセッションを起こす）

/// 定期起動の回の段階（`ScheduleRun.stage`）。`worktree`・`tab`・`started`・`waited` は前の版の pane の起動の段階。
public enum LaunchStage: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case requested
    /// worktree ができた（要求にあるときだけ）
    case worktree
    /// tab と pane ができた。アプリはここで pane を開く
    case tab
    /// agent が pane で起動した（前の版の herdr の `agent.start`）
    case started
    /// agent が idle になった
    case waited
    /// タスクに紐づけた（session_id）
    case linked
    /// 起動プロンプトを送った（空なら送らずにここへ）
    case prompted
    case done
    case failed

    public static func < (lhs: LaunchStage, rhs: LaunchStage) -> Bool {
        let order = LaunchStage.allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }

    /// 画面に出す段階。daemon の段階は「済んだ手順」なので、次に起きていることを出す
    public var label: String {
        switch self {
        case .requested: String(localized: "起動の準備中")
        case .worktree: String(localized: "ターミナルを準備中")
        case .tab, .started: String(localized: "起動中")
        case .waited: String(localized: "タスクに紐づけ中")
        case .linked: String(localized: "起動プロンプトを送信中")
        case .prompted, .done: String(localized: "起動済み")
        case .failed: String(localized: "起動失敗")
        }
    }

    public var isTerminal: Bool { self == .done || self == .failed }
}

/// 起こす agent の種類（`claude`・`codex`）。
public enum AgentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex

    public var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// `POST /v1/orchestrator/start`。`requestID` はクライアントが作り、再送は同じ id で。
public struct LaunchRequest: Codable, Hashable, Sendable {
    public var requestID: String
    public var cwd: String
    public var kind: AgentKind
    /// agent の実行ファイルに渡す引数（`--model ...` 等）
    public var agentArgs: [String]
    /// 起動プロンプト。`{{id}} {{title}} {{status}} {{note}} {{links}}` を daemon が埋める。空なら送らない
    public var prompt: String
    /// worktree を切るとき。`cwd` はその repo
    public var worktree: WorktreeSpec?
    /// 起動を頼んだ host の会話（同じマシン）
    public var parentConversationID: String?
    /// 同じ会話で起こし直す agent のセッション ID。立っていれば daemon が引数に resume を足し、プロンプトは送らない
    public var resumeAgentSessionID: String?
    /// Claude Code のアカウントの名前（`ClaudeAccount.login` はマシンのログイン）。nil なら daemon が決める（再開は前のアカウント、新しい起動は案件の割り当て。どちらも枠が閾値を越えていれば次）
    public var claudeAccount: String?

    public struct WorktreeSpec: Codable, Hashable, Sendable {
        public var branch: String
        public var base: String?
        public var path: String?

        public init(branch: String, base: String? = nil, path: String? = nil) {
            self.branch = branch
            self.base = base
            self.path = path
        }
    }

    public init(
        requestID: String = "launch-" + UUID().uuidString.lowercased(), cwd: String, kind: AgentKind, agentArgs: [String] = [], prompt: String = "",
        worktree: WorktreeSpec? = nil, parentConversationID: String? = nil, resumeAgentSessionID: String? = nil, claudeAccount: String? = nil
    ) {
        self.claudeAccount = claudeAccount
        self.requestID = requestID
        self.cwd = cwd
        self.kind = kind
        self.agentArgs = agentArgs
        self.prompt = prompt
        self.worktree = worktree
        self.parentConversationID = parentConversationID
        self.resumeAgentSessionID = resumeAgentSessionID
    }
}

/// `POST /v1/orchestrator/prompt`。
public struct OrchestratorPromptRequest: Codable, Hashable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// `POST /v1/orchestrator/restart`。中身は無い（止めて新しく起動する。設定の引数と daemon の起動プロンプトで起こす）
public struct OrchestratorRestartRequest: Codable, Hashable, Sendable {
    public init() {}
}

/// `GET /v1/orchestrator` と `orchestrator.updated`
public struct OrchestratorInfo: Codable, Hashable, Sendable {
    /// 常駐するか（`MachineSettings.orchestrator.enabled` と同じ値）
    public var enabled: Bool
    /// 常駐の見張りが起こせなかった理由。起きたら nil
    public var lastError: String?
    /// 最後の返事（transcript の最後の user の発話より後の assistant の文）。daemon のメモリにだけある
    public var lastReply: OrchestratorReply?
    /// オーケストレーターの会話の id。起きていなければ nil
    public var conversationID: String?

    public init(enabled: Bool = false, lastError: String? = nil, lastReply: OrchestratorReply? = nil, conversationID: String? = nil) {
        self.enabled = enabled
        self.lastError = lastError
        self.lastReply = lastReply
        self.conversationID = conversationID
    }

    private enum CodingKeys: String, CodingKey { case enabled, lastError, lastReply, conversationID }

    /// P6 までの daemon は enabled 以下を返さない
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastReply = try c.decodeIfPresent(OrchestratorReply.self, forKey: .lastReply)
        conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID)
    }
}

public struct OrchestratorReply: Codable, Hashable, Sendable {
    /// 2000 字まで
    public var text: String
    public var at: Date

    public init(text: String, at: Date) {
        self.text = text
        self.at = at
    }
}

/// マシン単位の設定（daemon の `setting` 表）。`GET /v1/settings`・`settings.updated`
public struct MachineSettings: Codable, Hashable, Sendable {
    public struct Orchestrator: Codable, Hashable, Sendable {
        /// 常駐するか。切ると動いているものも止める
        public var enabled: Bool
        /// 起こすときの agent の引数（`LaunchChoice.args`）
        public var agentArgs: [String]

        public init(enabled: Bool, agentArgs: [String]) {
            self.enabled = enabled
            self.agentArgs = agentArgs
        }
    }

    /// Claude の host の会話を、利用枠の上限の前に区切る使用率（%）。ターンの終わりにどちらかの窓がこれ以上なら、その窓が戻るまで待つ
    public struct UsagePause: Codable, Hashable, Sendable {
        public var fiveHourPercent: Int
        public var sevenDayPercent: Int

        public init(fiveHourPercent: Int, sevenDayPercent: Int) {
            self.fiveHourPercent = fiveHourPercent
            self.sevenDayPercent = sevenDayPercent
        }

        /// 入れられる値
        public static let percentRange = 1...100
    }

    public var orchestrator: Orchestrator
    /// idle のセッションを止めるまでの分。0 は止めない
    public var idleStopMinutes: Int
    public var usagePause: UsagePause

    /// `idleStopMinutes` に入れられる値
    public static let idleStopChoices = [0, 30, 60, 120, 240]
    public static let defaults = MachineSettings(
        orchestrator: Orchestrator(enabled: true, agentArgs: LaunchChoice.standard.args), idleStopMinutes: 120,
        usagePause: UsagePause(fiveHourPercent: 90, sevenDayPercent: 99))

    public init(orchestrator: Orchestrator, idleStopMinutes: Int, usagePause: UsagePause = MachineSettings.defaults.usagePause) {
        self.orchestrator = orchestrator
        self.idleStopMinutes = idleStopMinutes
        self.usagePause = usagePause
    }

    private enum CodingKeys: String, CodingKey { case orchestrator, idleStopMinutes, usagePause }

    /// 前の daemon は `usagePause` を返さない
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orchestrator = try c.decode(Orchestrator.self, forKey: .orchestrator)
        idleStopMinutes = try c.decode(Int.self, forKey: .idleStopMinutes)
        usagePause = try c.decodeIfPresent(UsagePause.self, forKey: .usagePause) ?? Self.defaults.usagePause
    }
}

/// `PATCH /v1/settings`。省略した項目は変えない。`idleStopMinutes` が `idleStopChoices` に無いか、区切る使用率が `UsagePause.percentRange` の外なら 400
public struct MachineSettingsUpdate: Codable, Hashable, Sendable {
    public var orchestratorEnabled: Bool?
    public var orchestratorAgentArgs: [String]?
    public var idleStopMinutes: Int?
    public var usagePauseFiveHourPercent: Int?
    public var usagePauseSevenDayPercent: Int?

    public init(
        orchestratorEnabled: Bool? = nil, orchestratorAgentArgs: [String]? = nil, idleStopMinutes: Int? = nil, usagePauseFiveHourPercent: Int? = nil,
        usagePauseSevenDayPercent: Int? = nil
    ) {
        self.orchestratorEnabled = orchestratorEnabled
        self.orchestratorAgentArgs = orchestratorAgentArgs
        self.idleStopMinutes = idleStopMinutes
        self.usagePauseFiveHourPercent = usagePauseFiveHourPercent
        self.usagePauseSevenDayPercent = usagePauseSevenDayPercent
    }
}

/// `POST /v1/tasks/{number}/sessions/resume`。紐づけの記録が無ければ 404、動いているか再開の途中なら 409
public struct SessionResumeRequest: Codable, Hashable, Sendable {
    public var agentSessionID: String
    public var requestID: String
    /// Claude Code のアカウント（`LaunchRequest.claudeAccount`）。省くと前のアカウント
    public var account: String?

    public init(agentSessionID: String, requestID: String = "resume-" + UUID().uuidString.lowercased(), account: String? = nil) {
        self.agentSessionID = agentSessionID
        self.requestID = requestID
        self.account = account
    }
}

/// `POST /v1/sessions/account`: 会話の Claude Code のアカウントを替える。
/// 動いている会話は止めて、同じ会話を新しいアカウントで起こし直す（会話は次に送ったときに起きる）
public struct SessionAccountRequest: Codable, Hashable, Sendable {
    public var conversationID: String?
    /// アカウントの名前か `ClaudeAccount.login`
    public var account: String

    public init(conversationID: String? = nil, account: String) {
        self.conversationID = conversationID
        self.account = account
    }
}

// MARK: - 起動プロンプトのテンプレート

/// `{{id}} {{title}} {{status}} {{note}} {{links}}` を埋める。taskherd の `[session_start]` と同じ置換子。
public enum PromptTemplate {
    public static let placeholders = ["{{id}}", "{{title}}", "{{status}}", "{{note}}", "{{links}}"]

    public static func render(_ template: String, task: BoardTask, board: Board?) -> String {
        let column = board?.columns.first { $0.id == task.columnID }
        let links = task.links.map(\.url).joined(separator: "\n")
        return template
            .replacingOccurrences(of: "{{id}}", with: String(task.number))
            .replacingOccurrences(of: "{{title}}", with: task.title)
            .replacingOccurrences(of: "{{status}}", with: column.map { "\($0.id)（\($0.label)）" } ?? task.columnID)
            .replacingOccurrences(of: "{{note}}", with: task.note)
            .replacingOccurrences(of: "{{links}}", with: links)
    }

    /// 列の上書き → ボードの既定 → 空。
    public static func template(for columnID: String, in board: Board) -> String {
        if let column = board.columns.first(where: { $0.id == columnID }), let own = column.promptTemplate, !own.isEmpty {
            return own
        }
        return board.promptTemplate
    }
}

// MARK: - モデルと effort の選び方

/// `--effort` の段階（`claude --help` で確認）
public enum Effort: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max

    public var id: String { rawValue }
    public var label: String { rawValue }
}

/// 起動の選び方（エージェント、モデル、effort）と、agent に渡す引数の相互変換。
/// 引数がこの形に合わないもの（MCP から作った定期起動など）は `custom` として引数のまま持ち、選び直すまで置き換えない
public struct LaunchChoice: Hashable, Sendable {
    public var kind: AgentKind
    /// Claude Code だけ。`--model` に渡す名前のまま（一覧の名前に揃えるのは選ぶ側。`ClaudeModels.argument(for:)`）。nil は `--model` を渡さない
    public var model: String?
    /// Claude Code だけ。nil は `--effort` を渡さない
    public var effort: Effort?
    /// Codex だけ。codex の `model/list` の id。nil は codex の既定
    public var codexModel: String?
    /// Codex だけ。effort の名前（`model_reasoning_effort`）。nil は codex の既定
    public var codexEffort: String?
    /// 形に合わなかった引数。nil なら `model` と `effort`（Codex は `codexModel` と `codexEffort`）から組む
    public var custom: [String]?

    static let codexEffortKey = "model_reasoning_effort="

    /// Claude Code は確認なしで動かす（ユーザーのシェル関数 cco / ccf / ccs と同じ）
    public static let skipPermissions = "--dangerously-skip-permissions"
    /// 既定（Opus 5.5 / medium）
    public static let standard = LaunchChoice(kind: .claude, model: "claude-opus-5-5[1m]", effort: .medium)

    /// 起こし方を指定されなかったときの選び方（MCP の `session_start`・wake）。案件の起動の既定、無ければ `standard`
    public init(defaults: LaunchDefaults?) {
        self = defaults.map { LaunchChoice(kind: $0.kind, args: $0.agentArgs) } ?? .standard
    }

    public init(kind: AgentKind, model: String? = nil, effort: Effort? = nil) {
        self.kind = kind
        self.model = kind == .claude ? model : nil
        self.effort = kind == .claude ? effort : nil
    }

    /// 保存済みの引数から。`--model` と `--effort`（と確認なしの旗）だけなら構造に戻し、ほかの引数があれば `custom`
    public init(kind: AgentKind, args: [String]) {
        self.kind = kind
        switch kind {
        case .codex:
            var index = 0
            var fits = true
            while index < args.count, index + 1 < args.count {
                let (arg, value) = (args[index], args[index + 1])
                if arg == "--model" || arg == "-m", codexModel == nil, !value.isEmpty {
                    codexModel = value
                } else if arg == "-c", value.hasPrefix(Self.codexEffortKey), codexEffort == nil, value.count > Self.codexEffortKey.count {
                    codexEffort = String(value.dropFirst(Self.codexEffortKey.count))
                } else {
                    fits = false
                    break
                }
                index += 2
            }
            if !fits || index < args.count {
                codexModel = nil
                codexEffort = nil
                custom = args
            }
        case .claude:
            var model: String?
            var effort: Effort?
            var index = 0
            var fits = true
            while index < args.count {
                let arg = args[index]
                if arg == Self.skipPermissions {
                    index += 1
                } else if arg == "--model", index + 1 < args.count, model == nil, !args[index + 1].isEmpty, !args[index + 1].hasPrefix("-") {
                    model = args[index + 1]
                    index += 2
                } else if arg == "--effort", index + 1 < args.count, let parsed = Effort(rawValue: args[index + 1]), effort == nil {
                    effort = parsed
                    index += 2
                } else {
                    fits = false
                    break
                }
            }
            if fits {
                self.model = model
                self.effort = effort
            } else {
                custom = args
            }
        }
    }

    public var isCustom: Bool { custom != nil }

    /// agent に渡す引数
    public var args: [String] {
        if let custom { return custom }
        switch kind {
        case .codex:
            var args: [String] = []
            if let codexModel { args += ["--model", codexModel] }
            if let codexEffort { args += ["-c", Self.codexEffortKey + codexEffort] }
            return args
        case .claude:
            var args = [Self.skipPermissions]
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort.rawValue] }
            return args
        }
    }

    /// モデルか effort を選んだら、カスタムの引数は捨てて構造に戻す。nil は `--model` を渡さない（Claude Code の既定）
    public mutating func select(model: String?) {
        custom = nil
        self.model = model
    }

    public mutating func select(effort: Effort) {
        custom = nil
        self.effort = effort
    }

    /// Codex のモデルか effort を選んだら、カスタムの引数は捨てて構造に戻す。nil は codex の既定
    public mutating func select(codexModel: String?) {
        custom = nil
        self.codexModel = codexModel
    }

    public mutating func select(codexEffort: String?) {
        custom = nil
        self.codexEffort = codexEffort
    }

    /// エージェントを変える。Claude Code に戻すときは既定のモデルと effort
    public mutating func select(kind: AgentKind) {
        guard kind != self.kind else { return }
        self = kind == .claude ? .standard : LaunchChoice(kind: .codex)
    }

    /// 1 行の要約（「Claude Code・Opus 5.5・medium」）。モデルの名前はそのマシンの一覧で引く。カスタムは「カスタム」
    public func summary(_ models: ClaudeModels) -> String {
        var parts = [kind.label]
        if isCustom {
            parts.append(String(localized: "カスタム"))
        } else if kind == .claude {
            if let model { parts.append(models.label(model)) }
            if let effort { parts.append(effort.label) }
        } else {
            if let codexModel { parts.append(codexModel) }
            if let codexEffort { parts.append(codexEffort) }
        }
        return parts.joined(separator: "・")
    }
}
