import Foundation

/// 利用状況の画面に出す値。接続先ごとの `UsageHistory` を合わせる。
/// 利用枠はアカウントの値で Mac ごとに違うアカウントのことがあるので Mac ごとの系列にし、数（トークン・セッション・skill・圧縮）は足す
public struct UsageReport: Equatable, Sendable {
    public struct Machine: Sendable {
        public var name: String
        public var history: UsageHistory

        public init(name: String, history: UsageHistory) {
            self.name = name
            self.history = history
        }
    }

    public enum Window: String, CaseIterable, Sendable {
        case claudeFiveHour, claudeSevenDay, codexPrimary, codexSecondary, codexMonthly

        public var engine: AgentKind { self == .claudeFiveHour || self == .claudeSevenDay ? .claude : .codex }
    }

    public struct WindowPoint: Hashable, Sendable {
        public var at: Date
        public var machine: String
        public var percent: Double
    }

    public struct WindowSeries: Equatable, Sendable {
        public var window: Window
        /// Codex の短い窓と長い窓の長さ（ラベルに使う）。Claude と月の枠は nil
        public var windowSeconds: Int?
        public var points: [WindowPoint]
    }

    public struct ActivePoint: Hashable, Sendable {
        public var at: Date
        public var engine: AgentKind
        public var count: Int
    }

    public enum TokenKind: String, CaseIterable, Sendable {
        case input, cacheWrite, cacheRead, output

        public func value(_ counts: TokenCounts) -> Int {
            switch self {
            case .input: counts.input
            case .cacheWrite: counts.cacheWrite
            case .cacheRead: counts.cacheRead
            case .output: counts.output
            }
        }
    }

    public struct TokenPoint: Hashable, Sendable {
        public var at: Date
        public var kind: TokenKind
        public var tokens: Int
    }

    public struct ModelRow: Hashable, Sendable {
        public var engine: AgentKind
        public var model: String
        public var requests: Int
        public var tokens: TokenCounts
    }

    public struct SkillRow: Hashable, Sendable {
        public var name: String
        public var model: Int
        public var command: Int
        public var lastAt: Date

        public var total: Int { model + command }
    }

    public struct CompactionPoint: Hashable, Sendable {
        public var at: Date
        public var machine: String
        public var engine: AgentKind
        public var trigger: UsageHistory.Compaction.Trigger?
        public var before: Int
    }

    public struct SessionRow: Hashable, Sendable {
        public var machine: String
        public var total: UsageHistory.SessionTotal
    }

    /// Mac の名前（渡した順。利用枠の系列の色はこの順に割り当てる）
    public var machines: [String]
    public var windows: [WindowSeries]
    public var active: [ActivePoint]
    public var tokens: [TokenPoint]
    public var totalTokens: TokenCounts
    public var models: [ModelRow]
    public var skills: [SkillRow]
    public var compactions: [CompactionPoint]
    public var compactionCounts: (auto: Int, manual: Int, unknown: Int)
    public var sessions: [SessionRow]
    public var sessionCount: Int
    /// 期間の中で応答のあったセッションの、1 つあたりのトークン（上位で切る前の和は持たないので、全部のトークンをセッションの数で割る）
    public var tokensPerSession: Int?
    public var recordingSince: Date?

    public static let sessionLimit = 20

    public static func == (a: UsageReport, b: UsageReport) -> Bool {
        a.machines == b.machines && a.windows == b.windows && a.active == b.active && a.tokens == b.tokens && a.totalTokens == b.totalTokens && a.models == b.models
            && a.skills == b.skills && a.compactions == b.compactions && a.compactionCounts == b.compactionCounts && a.sessions == b.sessions
            && a.sessionCount == b.sessionCount && a.tokensPerSession == b.tokensPerSession && a.recordingSince == b.recordingSince
    }

    public init(_ machines: [Machine]) {
        self.machines = machines.map(\.name)
        windows = Window.allCases.compactMap { window in
            var seconds: Int?
            let points = machines.flatMap { machine in
                machine.history.samples.compactMap { sample -> WindowPoint? in
                    let value: Double?
                    switch window {
                    case .claudeFiveHour: value = sample.claudeFiveHour
                    case .claudeSevenDay: value = sample.claudeSevenDay
                    case .codexPrimary:
                        value = sample.codexPrimary
                        seconds = sample.codexPrimaryWindow ?? seconds
                    case .codexSecondary:
                        value = sample.codexSecondary
                        seconds = sample.codexSecondaryWindow ?? seconds
                    case .codexMonthly: value = sample.codexMonthly
                    }
                    return value.map { WindowPoint(at: sample.at, machine: machine.name, percent: $0) }
                }
            }
            return points.isEmpty ? nil : WindowSeries(window: window, windowSeconds: seconds, points: points)
        }

        var active: [Date: [AgentKind: Int]] = [:]
        for sample in machines.flatMap(\.history.samples) {
            active[sample.at, default: [:]][.claude, default: 0] += sample.claudeActive
            active[sample.at, default: [:]][.codex, default: 0] += sample.codexActive
        }
        let hasCodex = machines.contains { $0.history.samples.contains { $0.codexActive > 0 } || $0.history.tokens.contains { $0.engine == .codex } }
        self.active = active.keys.sorted().flatMap { at in
            (hasCodex ? AgentKind.allCases : [.claude]).map { ActivePoint(at: at, engine: $0, count: active[at]?[$0] ?? 0) }
        }

        let buckets = machines.flatMap(\.history.tokens)
        var byTime: [Date: TokenCounts] = [:]
        var byModel: [String: ModelRow] = [:]
        for bucket in buckets {
            byTime[bucket.at, default: TokenCounts()] = byTime[bucket.at, default: TokenCounts()] + bucket.tokens
            let key = bucket.engine.rawValue + "\u{0}" + bucket.model
            var row = byModel[key] ?? ModelRow(engine: bucket.engine, model: bucket.model, requests: 0, tokens: TokenCounts())
            row.requests += bucket.requests
            row.tokens = row.tokens + bucket.tokens
            byModel[key] = row
        }
        tokens = byTime.keys.sorted().flatMap { at in TokenKind.allCases.map { TokenPoint(at: at, kind: $0, tokens: $0.value(byTime[at] ?? TokenCounts())) } }
        totalTokens = buckets.reduce(TokenCounts()) { $0 + $1.tokens }
        models = byModel.values.sorted { ($0.tokens.total, $1.model) > ($1.tokens.total, $0.model) }

        var skills: [String: SkillRow] = [:]
        for count in machines.flatMap(\.history.skills) {
            var row = skills[count.name] ?? SkillRow(name: count.name, model: 0, command: 0, lastAt: count.lastAt)
            switch count.source {
            case .model: row.model += count.count
            case .command: row.command += count.count
            }
            row.lastAt = max(row.lastAt, count.lastAt)
            skills[count.name] = row
        }
        self.skills = skills.values.sorted { ($0.total, $1.name) > ($1.total, $0.name) }

        let compactions = machines.flatMap { machine in machine.history.compactions.map { (machine.name, $0) } }
        self.compactions = compactions.compactMap { name, item in
            item.before.map { CompactionPoint(at: item.at, machine: name, engine: item.engine, trigger: item.trigger, before: $0) }
        }.sorted { $0.at < $1.at }
        compactionCounts = (
            compactions.filter { $0.1.trigger == .auto }.count, compactions.filter { $0.1.trigger == .manual }.count,
            compactions.filter { $0.1.trigger == nil }.count
        )

        sessions = Array(
            machines.flatMap { machine in machine.history.sessions.map { SessionRow(machine: machine.name, total: $0) } }
                .sorted { $0.total.tokens.total > $1.total.tokens.total }.prefix(Self.sessionLimit))
        sessionCount = machines.reduce(0) { $0 + $1.history.sessionCount }
        tokensPerSession = sessionCount > 0 ? totalTokens.total / sessionCount : nil
        recordingSince = machines.compactMap(\.history.recordingSince).min()
    }

    public var isEmpty: Bool {
        windows.isEmpty && tokens.isEmpty && skills.isEmpty && compactions.isEmpty && compactionCounts == (0, 0, 0) && !active.contains { $0.count > 0 }
    }
}
