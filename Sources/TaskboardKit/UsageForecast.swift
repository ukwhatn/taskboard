import Foundation

/// Claude の 7 日の枠を、アカウントを切り替えながら今の速さで使い続けたときの見込み。
/// 使う順は daemon が会話を起動するときと同じ（閾値を越えていないうち、7 日の枠が先に戻るもの。`ClaudeAccounts.choose`）。
/// アカウントの % は同じ契約（同じ上限）として足し引きする
public enum UsageForecast {
    public struct Account: Codable, Hashable, Sendable {
        public var name: String
        public var sevenDay: Double
        public var resetsAt: Date

        public init(name: String, sevenDay: Double, resetsAt: Date) {
            self.name = name
            self.sevenDay = sevenDay
            self.resetsAt = resetsAt
        }
    }

    public struct Result: Codable, Hashable, Sendable {
        /// 見込みに使ったマシン全体の 1 時間あたりの消費（ポイント）
        public var perHour: Double = 0
        /// 「越える」とみた 7 日の使用率（会話を区切る閾値）
        public var threshold: Double = 100
        /// 全アカウントが閾値を越える時刻。越えなければ nil
        public var exhaustedAt: Date?
        /// 越えた後、最も早く枠が戻る時刻
        public var resumesAt: Date?
        /// 越えないとき、どこまで先を見たか（全アカウントが 1 回戻るまで）
        public var horizon: Date
        /// アカウントごとの、次のリセットの時刻の直前の見込みの使用率
        public var atReset: [String: Double]

        public init(perHour: Double, threshold: Double, exhaustedAt: Date?, resumesAt: Date?, horizon: Date, atReset: [String: Double]) {
            self.perHour = perHour
            self.threshold = threshold
            self.exhaustedAt = exhaustedAt
            self.resumesAt = resumesAt
            self.horizon = horizon
            self.atReset = atReset
        }
    }

    static let week: TimeInterval = 604_800

    /// `perHour` はマシン全体の 1 時間あたりの消費（ポイント）。`threshold` は会話を区切る 7 日の閾値（`usagePause`）
    public static func simulate(accounts: [Account], perHour: Double, threshold: Double, now: Date, step: TimeInterval = 600) -> Result? {
        guard !accounts.isEmpty, perHour >= 0, step > 0 else { return nil }
        var used = accounts.map(\.sevenDay)
        var resets = accounts.map(\.resetsAt)
        var atReset: [String: Double] = [:]
        let horizon = accounts.map(\.resetsAt).max() ?? now
        var t = now
        while t <= horizon {
            for index in accounts.indices where t >= resets[index] {
                if atReset[accounts[index].name] == nil { atReset[accounts[index].name] = used[index] }
                used[index] = 0
                resets[index] += week
            }
            let open = accounts.indices.filter { used[$0] < threshold }
            guard let active = open.min(by: { (resets[$0], $0) < (resets[$1], $1) }) else {
                for index in accounts.indices where atReset[accounts[index].name] == nil { atReset[accounts[index].name] = used[index] }
                return Result(perHour: perHour, threshold: threshold, exhaustedAt: t, resumesAt: resets.min(), horizon: horizon, atReset: atReset)
            }
            used[active] += perHour * step / 3600
            t += step
        }
        for index in accounts.indices where atReset[accounts[index].name] == nil { atReset[accounts[index].name] = used[index] }
        return Result(perHour: perHour, threshold: threshold, exhaustedAt: nil, resumesAt: nil, horizon: horizon, atReset: atReset)
    }

    /// 今使っている枠（`UsageSnapshot.claudeInUse`）のうち、7 日の窓が戻る時刻まで分かっているものの見込み。速さが分からなければ nil
    public static func make(_ usage: UsageSnapshot, samples: [UsageAccountSample], threshold: Double, now: Date) -> Result? {
        guard let rate = perHour(samples, now: now) else { return nil }
        let accounts = usage.claudeInUse(now: now).compactMap { name -> Account? in
            guard let week = usage.claudeUsage(account: name)?.sevenDay, let resets = week.resetsAt, resets > now else { return nil }
            return Account(name: name ?? ClaudeAccount.login, sevenDay: week.usedPercent, resetsAt: resets)
        }
        return simulate(accounts: accounts, perHour: rate, threshold: threshold, now: now)
    }

    /// 直近 `window` の観測から、全アカウントの 7 日の使用率が 1 時間あたり何ポイント増えたか。
    /// 同じ窓（リセットの時刻の差が 120 秒以内）の中の増えた分だけを数え、リセットで下がった分は数えない。観測した期間が 1 時間に満たなければ nil
    public static func perHour(_ samples: [UsageAccountSample], now: Date, window: TimeInterval = 86_400) -> Double? {
        let since = now.addingTimeInterval(-window)
        let recent = samples.filter { $0.at >= since && $0.at <= now && $0.sevenDay != nil }
        guard let first = recent.map(\.at).min() else { return nil }
        let hours = now.timeIntervalSince(first) / 3600
        guard hours >= 1 else { return nil }
        var increase = 0.0
        for (_, rows) in Dictionary(grouping: recent, by: \.account) {
            let sorted = rows.sorted { $0.at < $1.at }
            for (previous, next) in zip(sorted, sorted.dropFirst()) {
                guard let a = previous.sevenDay, let b = next.sevenDay, b > a,
                    let ra = previous.sevenDayResetsAt, let rb = next.sevenDayResetsAt, abs(ra.timeIntervalSince(rb)) <= 120
                else { continue }
                increase += b - a
            }
        }
        return increase / hours
    }
}
