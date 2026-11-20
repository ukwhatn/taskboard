import Foundation

/// 応答 1 回ぶんのトークン。Claude Code は usage の 4 つ、Codex は input から cached を引いた分を `input` に、cached を `cacheRead` に入れる
public struct TokenCounts: Codable, Hashable, Sendable {
    public var input: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }

    public var total: Int { input + cacheWrite + cacheRead + output }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output)
    }
}

/// `GET /v1/usage/history`。daemon が transcript（Claude Code の `projects`、Codex の `sessions`）と利用枠から貯めた記録を、期間と粒度で集めたもの。
/// 記録は daemon がそのマシンで見たものだけで、過去の分は貯め始めた時（`recordingSince`）から
public struct UsageHistory: Codable, Hashable, Sendable {
    public static let path = "/v1/usage/history"
    /// 遡れる長さ。daemon はこれより古い記録を消す
    public static let retention: TimeInterval = 90 * 86_400
    /// 粒度の下限（利用枠と動いていたセッションは 5 分ごとに貯める）
    public static let sampleSeconds = 300
    /// トークンは 1 時間ごとに貯めるので、粒度がこれより細かくても 1 時間で集める
    public static let tokenSeconds = 3600
    /// 返すセッションの上限（トークンの多い順）
    public static let sessionLimit = 50
    /// 返す圧縮の上限（新しい順）
    public static let compactionLimit = 2000

    /// 5 分ごとの利用枠と、その間に応答したセッションの数。枠はその間の大きいほう
    public struct Sample: Codable, Hashable, Sendable {
        public var at: Date
        public var claudeFiveHour: Double?
        public var claudeSevenDay: Double?
        public var codexPrimary: Double?
        public var codexPrimaryWindow: Int?
        public var codexSecondary: Double?
        public var codexSecondaryWindow: Int?
        public var codexMonthly: Double?
        public var claudeActive: Int
        public var codexActive: Int

        public init(
            at: Date, claudeFiveHour: Double? = nil, claudeSevenDay: Double? = nil, codexPrimary: Double? = nil, codexPrimaryWindow: Int? = nil,
            codexSecondary: Double? = nil, codexSecondaryWindow: Int? = nil, codexMonthly: Double? = nil, claudeActive: Int = 0, codexActive: Int = 0
        ) {
            self.at = at
            self.claudeFiveHour = claudeFiveHour
            self.claudeSevenDay = claudeSevenDay
            self.codexPrimary = codexPrimary
            self.codexPrimaryWindow = codexPrimaryWindow
            self.codexSecondary = codexSecondary
            self.codexSecondaryWindow = codexSecondaryWindow
            self.codexMonthly = codexMonthly
            self.claudeActive = claudeActive
            self.codexActive = codexActive
        }
    }

    public struct TokenBucket: Codable, Hashable, Sendable {
        public var at: Date
        public var engine: AgentKind
        public var model: String
        public var requests: Int
        public var tokens: TokenCounts

        public init(at: Date, engine: AgentKind, model: String, requests: Int, tokens: TokenCounts) {
            self.at = at
            self.engine = engine
            self.model = model
            self.requests = requests
            self.tokens = tokens
        }
    }

    /// skill を誰が呼んだか。モデルが Skill の tool（Codex は SKILL.md を読むコマンド）で呼んだか、人が `/名前` で打ったか
    public enum SkillSource: String, Codable, Hashable, Sendable {
        case model, command
    }

    public struct SkillCount: Codable, Hashable, Sendable {
        public var engine: AgentKind
        public var name: String
        public var source: SkillSource
        public var count: Int
        public var lastAt: Date

        public init(engine: AgentKind, name: String, source: SkillSource, count: Int, lastAt: Date) {
            self.engine = engine
            self.name = name
            self.source = source
            self.count = count
            self.lastAt = lastAt
        }
    }

    /// 会話の圧縮 1 回。`before` は直前のコンテキストのトークン（Claude Code は compact_boundary の preTokens、Codex は直前の応答の入力）
    public struct Compaction: Codable, Hashable, Sendable {
        public enum Trigger: String, Codable, Hashable, Sendable {
            case auto, manual
        }

        public var at: Date
        public var engine: AgentKind
        public var session: String
        /// Codex の記録は自動か手動かを持たないので nil
        public var trigger: Trigger?
        public var before: Int?
        public var after: Int?

        public init(at: Date, engine: AgentKind, session: String, trigger: Trigger?, before: Int?, after: Int?) {
            self.at = at
            self.engine = engine
            self.session = session
            self.trigger = trigger
            self.before = before
            self.after = after
        }
    }

    /// 期間の中の 1 セッションの合計
    public struct SessionTotal: Codable, Hashable, Sendable {
        public var engine: AgentKind
        public var session: String
        public var cwd: String?
        public var title: String?
        public var requests: Int
        public var tokens: TokenCounts
        /// 本筋（サブエージェントを除く）の 1 回の応答の入力の最大。コンテキストの大きさの目安
        public var maxContext: Int?
        public var compactions: Int
        public var lastAt: Date

        public init(
            engine: AgentKind, session: String, cwd: String?, title: String?, requests: Int, tokens: TokenCounts, maxContext: Int?, compactions: Int,
            lastAt: Date
        ) {
            self.engine = engine
            self.session = session
            self.cwd = cwd
            self.title = title
            self.requests = requests
            self.tokens = tokens
            self.maxContext = maxContext
            self.compactions = compactions
            self.lastAt = lastAt
        }
    }

    public var from: Date
    public var to: Date
    public var bucketSeconds: Int
    /// 最も古い記録の時刻。まだ何も貯めていなければ nil
    public var recordingSince: Date?
    public var samples: [Sample]
    public var tokens: [TokenBucket]
    public var skills: [SkillCount]
    public var compactions: [Compaction]
    /// トークンの多い順に `sessionLimit` まで
    public var sessions: [SessionTotal]
    /// 期間の中で応答のあったセッションの数（`sessions` で切る前）
    public var sessionCount: Int

    public init(
        from: Date, to: Date, bucketSeconds: Int, recordingSince: Date?, samples: [Sample] = [], tokens: [TokenBucket] = [], skills: [SkillCount] = [],
        compactions: [Compaction] = [], sessions: [SessionTotal] = [], sessionCount: Int = 0
    ) {
        self.from = from
        self.to = to
        self.bucketSeconds = bucketSeconds
        self.recordingSince = recordingSince
        self.samples = samples
        self.tokens = tokens
        self.skills = skills
        self.compactions = compactions
        self.sessions = sessions
        self.sessionCount = sessionCount
    }
}

/// `GET /v1/usage/history` の問い合わせ（`from`・`to` は UNIX 秒、`bucket` は粒度の秒）
public struct UsageHistoryQuery: Hashable, Sendable {
    public var from: Date
    public var to: Date
    public var bucketSeconds: Int

    public init(from: Date, to: Date, bucketSeconds: Int) {
        self.from = from
        self.to = to
        self.bucketSeconds = bucketSeconds
    }

    /// 遡れる長さと粒度の下限に収めた問い合わせ。逆さの期間・粒度の不正は nil
    public static func validated(from: Date, to: Date, bucketSeconds: Int, now: Date) -> UsageHistoryQuery? {
        guard to > from, bucketSeconds >= UsageHistory.sampleSeconds, bucketSeconds <= 86_400 * 7 else { return nil }
        let earliest = now.addingTimeInterval(-UsageHistory.retention)
        let clampedFrom = max(from, earliest)
        guard to > clampedFrom else { return nil }
        // 点が多すぎると画面もエージェントも読めないので、1 回に 2,000 区切りまで
        guard to.timeIntervalSince(clampedFrom) / Double(bucketSeconds) <= 2000 else { return nil }
        return UsageHistoryQuery(from: clampedFrom, to: to, bucketSeconds: bucketSeconds)
    }

    public var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "from", value: String(Int(from.timeIntervalSince1970))),
            URLQueryItem(name: "to", value: String(Int(to.timeIntervalSince1970))),
            URLQueryItem(name: "bucket", value: String(bucketSeconds)),
        ]
    }
}

/// 利用状況を引ける供給元（daemon と fixtures）
public protocol UsageHistorySource: Sendable {
    func usageHistory(_ query: UsageHistoryQuery) async throws -> UsageHistory
}

/// Claude のアカウント（マシンのログインは `ClaudeAccount.login`）の利用枠を 1 回観測した値。`at` は観測した時刻で、
/// 同じ観測は何度記録しても 1 件になる。使用率はアカウント全体の値なので、同じアカウントを使う他のマシンの消費も含む
public struct UsageAccountSample: Codable, Hashable, Sendable {
    public var account: String
    public var at: Date
    public var fiveHour: Double?
    public var sevenDay: Double?
    public var sevenDayResetsAt: Date?

    public init(account: String, at: Date, fiveHour: Double? = nil, sevenDay: Double? = nil, sevenDayResetsAt: Date? = nil) {
        self.account = account
        self.at = at
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayResetsAt = sevenDayResetsAt
    }

    /// 今の枠のうち、窓の終わりを過ぎていない値の観測（ログインと taskboard のアカウントの全部）
    public static func observations(_ usage: UsageSnapshot, now: Date) -> [UsageAccountSample] {
        func live(_ window: UsageWindow?) -> UsageWindow? { window.flatMap { w in (w.resetsAt.map { $0 > now } ?? true) ? w : nil } }
        let named = [(ClaudeAccount.login, usage.claude)] + (usage.claudeAccounts ?? []).map { ($0.name, $0.usage) }
        return named.compactMap { name, claude in
            guard let claude else { return nil }
            let five = live(claude.fiveHour), week = live(claude.sevenDay)
            guard five != nil || week != nil else { return nil }
            return UsageAccountSample(account: name, at: claude.at, fiveHour: five?.usedPercent, sevenDay: week?.usedPercent, sevenDayResetsAt: week?.resetsAt)
        }
    }
}

