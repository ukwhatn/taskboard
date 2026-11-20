import Foundation

/// 利用枠の 1 窓（Claude の 5h / 1w、Codex の primary / secondary）。
public struct UsageWindow: Codable, Hashable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    /// 窓の長さ。着地の見積に使う
    public var windowSeconds: Int

    public init(usedPercent: Double, resetsAt: Date?, windowSeconds: Int) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    /// 今のペースで窓の終わりまで使ったときの %。経過が短いうちは見積が暴れるので出さない
    /// （statusline-command.sh の `project` と同じ式。1w 窓は 6 時間、それ以外は窓の 1/10 経つまで nil）
    public func projectedPercent(now: Date) -> Double? {
        guard let resetsAt, windowSeconds > 0 else { return nil }
        let remaining = max(0, resetsAt.timeIntervalSince(now))
        let elapsed = Double(windowSeconds) - remaining
        let minimum = windowSeconds >= 604_800 ? 21_600.0 : Double(windowSeconds) / 10
        guard elapsed >= minimum else { return nil }
        return min(999, usedPercent * Double(windowSeconds) / elapsed)
    }

    /// 複数のセッションが送る枠を 1 つにする。statusline の枠はそのセッションの最後の応答の時点の値で、
    /// しばらく動いていないセッションは古い値を送り続ける。同じ窓（終わりが 60 秒以内）の中は使用率が減らないので大きいほうを、
    /// 窓が新しければ新しいほうを残す。報告に窓が無ければ今の値を残す
    public static func merge(_ current: UsageWindow?, _ report: UsageWindow?, now: Date) -> UsageWindow? {
        guard let report else { return current }
        guard let current, let held = current.resetsAt, let reported = report.resetsAt, held > now else { return report }
        if reported.timeIntervalSince(held) > 60 { return report }
        if held.timeIntervalSince(reported) > 60 { return current }
        return report.usedPercent >= current.usedPercent ? report : current
    }

    /// 同じ読みか（使用率が同じで、窓の終わりが 60 秒以内）
    public func sameReading(as other: UsageWindow) -> Bool {
        guard usedPercent == other.usedPercent else { return false }
        switch (resetsAt, other.resetsAt) {
        case (nil, nil): return true
        case (let a?, let b?): return abs(a.timeIntervalSince(b)) <= 60
        default: return false
        }
    }

    /// セッションごとの最後の値からアカウントの枠を決める。報告が変わったセッションがあれば、いちばん最近変わったものを採る
    /// （リセットで使用率が下がっても窓の終わりは変わらないので、大きいほうを残すと、止まっているセッションの古い値が勝ち続ける）。
    /// どれもまだ変わっていなければ（daemon の起動直後）、`merge` で大きいほうを残す
    public static func resolve(_ reports: [ReportedUsageWindow], current: UsageWindow?, now: Date) -> UsageWindow? {
        if let latest = reports.filter({ $0.changedAt != nil }).max(by: { $0.changedAt! < $1.changedAt! }) { return latest.window }
        return reports.reduce(current) { merge($0, $1.window, now: now) }
    }
}

/// アカウントの枠を決めるときの、1 セッションの窓と、そのセッションの報告が最後に変わった時刻（変わったのを見ていなければ nil）
public struct ReportedUsageWindow: Hashable, Sendable {
    public var window: UsageWindow
    public var changedAt: Date?

    public init(window: UsageWindow, changedAt: Date?) {
        self.window = window
        self.changedAt = changedAt
    }
}

/// 1 セッションが最後に送った枠と context。止まっているセッションも同じ中身を送り続けるので、
/// 中身（枠の読みか context）が変わった時刻でどのセッションが新しいかを決める。枠の値は 1% 動くまで時間がかかるが、
/// context は応答のたびに変わる
public struct ClaudeSessionUsage: Hashable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var contextTokens: Int?
    public var contextPercent: Double?
    public var changedAt: Date?
    public var at: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, contextTokens: Int?, contextPercent: Double?, changedAt: Date?, at: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.contextTokens = contextTokens
        self.contextPercent = contextPercent
        self.changedAt = changedAt
        self.at = at
    }

    /// 前の値に今回の報告を重ねる。報告に無い窓は前の値を残す
    public static func next(_ previous: ClaudeSessionUsage?, _ report: ClaudeUsageReport, now: Date) -> ClaudeSessionUsage {
        var next = ClaudeSessionUsage(
            fiveHour: report.fiveHour ?? previous?.fiveHour, sevenDay: report.sevenDay ?? previous?.sevenDay,
            contextTokens: report.context.inputTokens, contextPercent: report.context.usedPercent, changedAt: previous?.changedAt, at: now)
        guard let previous else { return next }
        func differs(_ a: UsageWindow?, _ b: UsageWindow?) -> Bool {
            switch (a, b) {
            case (nil, nil): false
            case (let a?, let b?): !a.sameReading(as: b)
            default: true
            }
        }
        if differs(previous.fiveHour, next.fiveHour) || differs(previous.sevenDay, next.sevenDay)
            || previous.contextTokens != next.contextTokens || previous.contextPercent != next.contextPercent {
            next.changedAt = now
        }
        return next
    }
}

/// Claude Code の statusline が運ぶアカウントの枠。セッションごとの値は `UsageWindow.resolve` で合わせる
public struct ClaudeUsage: Codable, Hashable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var at: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, at: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.at = at
    }
}

/// codex の `account/rateLimits/read` の利用枠。契約で載る欄が変わる（窓のある契約は primary・secondary、従量の契約は monthly）
public struct CodexUsage: Codable, Hashable, Sendable {
    public struct Monthly: Codable, Hashable, Sendable {
        public var usedPercent: Double
        public var used: Double?
        public var limit: Double?
        public var resetsAt: Date?

        public init(usedPercent: Double, used: Double?, limit: Double?, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.used = used
            self.limit = limit
            self.resetsAt = resetsAt
        }
    }

    public var primary: UsageWindow?
    public var secondary: UsageWindow?
    public var monthly: Monthly?
    public var fetchedAt: Date?

    public init(primary: UsageWindow?, secondary: UsageWindow?, monthly: Monthly?, fetchedAt: Date?) {
        self.primary = primary
        self.secondary = secondary
        self.monthly = monthly
        self.fetchedAt = fetchedAt
    }
}

/// 1 セッションの context と model。statusline が 10 秒ごとに送る
public struct SessionContext: Codable, Hashable, Sendable {
    /// statusline が止まったセッション（終了・別の pane へ移った）の context は、これより経ったら動いていないとみる
    public static let liveFor: TimeInterval = 1800

    public var agentSessionID: String
    public var model: String?
    public var effort: String?
    public var usedPercent: Double?
    public var inputTokens: Int?
    public var windowSize: Int?
    /// taskboard の Claude Code のアカウントの名前（`ClaudeAccount`）。nil はマシンのログイン
    public var account: String?
    public var at: Date

    public init(
        agentSessionID: String, model: String?, effort: String?, usedPercent: Double?, inputTokens: Int?, windowSize: Int?,
        account: String? = nil, at: Date
    ) {
        self.agentSessionID = agentSessionID
        self.account = account
        self.model = model
        self.effort = effort
        self.usedPercent = usedPercent
        self.inputTokens = inputTokens
        self.windowSize = windowSize
        self.at = at
    }
}

/// taskboard が起こす Claude Code に使わせるアカウント（`claude-accounts.json`）と、その枠。マシンのログインは含めない
public struct ClaudeAccount: Codable, Hashable, Sendable {
    /// アカウントの settings が Claude Code に入れる、アカウントの名前の変数（hook と statusline の子に渡る。トークンの変数は渡らない）
    public static let environmentName = "TASKBOARD_CLAUDE_ACCOUNT"
    /// アカウントを指すときの、マシンのログインの名前（アカウントには付けられない）
    public static let login = "login"
    /// アカウントの settings のファイルを置くディレクトリの名前（daemon の support ディレクトリの下に `<名前>.json`）
    public static let directoryName = "claude-accounts"

    /// 引数の `--settings` がアカウントの settings を指していれば、そのアカウントの名前（セッションの記録の `launchArgs`、会話の引数）
    public static func name(inArguments args: [String]) -> String? {
        var found: String?
        for (index, arg) in args.enumerated() {
            let path: String
            if arg == "--settings", index + 1 < args.count {
                path = args[index + 1]
            } else if arg.hasPrefix("--settings=") {
                path = String(arg.dropFirst("--settings=".count))
            } else {
                continue
            }
            let url = URL(fileURLWithPath: path)
            if url.pathExtension == "json", url.deletingLastPathComponent().lastPathComponent == directoryName {
                found = url.deletingPathExtension().lastPathComponent
            }
        }
        return found
    }

    public var name: String
    /// 先に使う案件（id か名前）
    public var boards: [String]
    public var usage: ClaudeUsage?

    public init(name: String, boards: [String] = [], usage: ClaudeUsage? = nil) {
        self.name = name
        self.boards = boards
        self.usage = usage
    }
}

/// マシンの枠とセッションの context。`/v1/state` の `usage` と `usage.updated` で丸ごと配る
public struct UsageSnapshot: Codable, Hashable, Sendable {
    /// マシンのログインの枠
    public var claude: ClaudeUsage?
    /// taskboard のアカウントと、その枠（前の版の daemon は送らない）
    public var claudeAccounts: [ClaudeAccount]?
    /// 割り当ての無い会話を起こすアカウント（`claude-accounts.json` の `default`）。nil ならマシンのログインも起こす候補に入る
    public var claudeDefaultAccount: String?
    /// 7 日の枠を、アカウントを切り替えながら今の速さで使い続けたときの見込み（daemon が 5 分ごとに求める）
    public var claudeForecast: UsageForecast.Result?
    public var codex: CodexUsage?
    public var contexts: [SessionContext]

    public init(
        claude: ClaudeUsage? = nil, claudeAccounts: [ClaudeAccount]? = nil, claudeDefaultAccount: String? = nil, claudeForecast: UsageForecast.Result? = nil,
        codex: CodexUsage? = nil, contexts: [SessionContext] = []
    ) {
        self.claude = claude
        self.claudeAccounts = claudeAccounts
        self.claudeDefaultAccount = claudeDefaultAccount
        self.claudeForecast = claudeForecast
        self.codex = codex
        self.contexts = contexts
    }

    /// 今使われている Claude の枠（nil はマシンのログイン）の並び。taskboard のアカウントは全部入れる（起こすたびにどれかへ移る）。
    /// 既定のアカウントがあればマシンのログインで会話を起こさないので、ログインは、ログインで動いている会話（人が端末で起こしたもの）があるときだけ入れる。
    /// 使っていない枠を並べると、会話がそれを今の枠と読んで委譲先を決める
    public func claudeInUse(now: Date) -> [String?] {
        let names = (claudeAccounts ?? []).map { Optional($0.name) }
        guard !names.isEmpty, claudeDefaultAccount != nil else { return [nil] + names }
        let loginRunning = contexts.contains { $0.account == nil && now.timeIntervalSince($0.at) <= SessionContext.liveFor }
        return (loginRunning ? [nil] : []) + names
    }

    /// アカウントの枠。nil はマシンのログイン
    public func claudeUsage(account: String?) -> ClaudeUsage? {
        guard let account else { return claude }
        return claudeAccounts?.first { $0.name == account }?.usage
    }

}

/// `POST /v1/usage/claude`。`taskboard hook statusline` が statusline の JSON から作る
public struct ClaudeUsageReport: Codable, Hashable, Sendable {
    public var context: SessionContext
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?

    public init(context: SessionContext, fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        self.context = context
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// statusline の入力（Claude Code が stdin に渡す JSON）。使う欄だけ読み、無い欄は nil
    public static func parse(statusline data: Data, account: String? = nil, now: Date) -> ClaudeUsageReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionID = root["session_id"] as? String, !sessionID.isEmpty
        else { return nil }
        let context = root["context_window"] as? [String: Any]
        let limits = root["rate_limits"] as? [String: Any]
        func window(_ key: String, seconds: Int) -> UsageWindow? {
            guard let raw = limits?[key] as? [String: Any], let used = number(raw["used_percentage"]) else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: number(raw["resets_at"]).map { Date(timeIntervalSince1970: $0) }, windowSeconds: seconds)
        }
        return ClaudeUsageReport(
            context: SessionContext(
                agentSessionID: sessionID,
                model: (root["model"] as? [String: Any])?["display_name"] as? String,
                effort: (root["effort"] as? [String: Any])?["level"] as? String,
                usedPercent: number(context?["used_percentage"]),
                inputTokens: number(context?["total_input_tokens"]).map { Int($0) },
                windowSize: number(context?["context_window_size"]).map { Int($0) },
                account: account, at: now),
            fiveHour: window("five_hour", seconds: 18_000),
            sevenDay: window("seven_day", seconds: 604_800))
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
