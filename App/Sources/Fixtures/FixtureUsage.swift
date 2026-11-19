import Foundation
import TaskboardKit

extension FixtureSource: UsageHistorySource {
    func usageHistory(_ query: UsageHistoryQuery) async throws -> UsageHistory {
        FixtureUsage.history(query, seed: initial.machine.name)
    }
}

/// fixtures の利用状況。実機の 2 日分の記録（応答 1 万回ほど、1 応答あたりキャッシュ読み込み 8 万トークン前後）に近い量を、
/// 昼に多く夜に少ない形で作る。同じ問い合わせと種からは同じ値を返す（snapshot test が同じ絵を撮るため）
enum FixtureUsage {
    static let skills = [
        "writing-code", "commit", "ukwhatn-writing", "yomiyasu", "taskboard", "writing-ui-text", "designing-ui", "findmem", "create-draft-pr",
        "pr-comment", "self-review", "systematic-debugging", "herdr", "dataviz", "handoff", "humanizer", "pr-review", "update-inst",
    ]
    static let workdirs = ["taskboard", "dotfiles", "blog", "wikidot-tools", "scp-jp-site", "8_tools"]

    static func history(_ query: UsageHistoryQuery, seed: String) -> UsageHistory {
        var random = SeededRandom(seed: seed)
        let bucket = TimeInterval(query.bucketSeconds)
        let tokenBucket = max(bucket, TimeInterval(UsageHistory.tokenSeconds))
        let start = query.from.timeIntervalSince1970
        let end = query.to.timeIntervalSince1970
        let days = (end - start) / 86_400

        var samples: [UsageHistory.Sample] = []
        // Mac ごとにアカウントの使い方と窓の切り替わる時刻を変える
        let scale = 0.5 + random.next() * 0.5
        let fiveHourShift = random.next() * 18_000, sevenDayShift = random.next() * 604_800
        var at = start
        while at < end {
            let busy = activity(at, seconds: bucket, peak: true)
            // 窓の中で経った割合に沿って増え、窓が替わると 0 に戻る
            let fiveHour = min(100, (at + fiveHourShift).truncatingRemainder(dividingBy: 18_000) / 18_000 * 90 * scale * (0.4 + busy * 0.6) + random.next() * 5)
            let sevenDay = min(100, (at + sevenDayShift).truncatingRemainder(dividingBy: 604_800) / 604_800 * 95 * scale + random.next() * 2)
            samples.append(
                UsageHistory.Sample(
                    at: Date(timeIntervalSince1970: at), claudeFiveHour: min(fiveHour, 100), claudeSevenDay: min(sevenDay, 100),
                    codexPrimary: min(busy * 30 * random.next(), 100), codexPrimaryWindow: 18_000, codexSecondary: min(sevenDay * 0.4, 100),
                    codexSecondaryWindow: 604_800, claudeActive: Int((busy * 7 * random.next()).rounded()), codexActive: Int((busy * 2 * random.next()).rounded())))
            at += bucket
        }

        var tokens: [UsageHistory.TokenBucket] = []
        at = (start / tokenBucket).rounded(.down) * tokenBucket
        let models: [(AgentKind, String, Double)] = [(.claude, "claude-opus-5-5", 0.7), (.claude, "claude-sonnet-5-5", 0.2), (.codex, "gpt-5.5-codex", 0.1)]
        while at < end {
            let responses = activity(at, seconds: tokenBucket, peak: false) * 400 * tokenBucket / 3600
            for (engine, model, share) in models {
                let requests = Int((responses * share * (0.6 + random.next() * 0.8)).rounded())
                guard requests > 0 else { continue }
                tokens.append(
                    UsageHistory.TokenBucket(
                        at: Date(timeIntervalSince1970: at), engine: engine, model: model, requests: requests,
                        tokens: TokenCounts(input: requests * 40, cacheWrite: requests * 2_800, cacheRead: requests * 82_000, output: requests * 520)))
            }
            at += tokenBucket
        }

        let lastAt = query.to.addingTimeInterval(-3600)
        let skillCounts = skills.enumerated().flatMap { index, name -> [UsageHistory.SkillCount] in
            let scale = days * 30 / Double(index + 1)
            let model = Int((scale * (0.5 + random.next())).rounded())
            let command = index % 3 == 1 ? Int((scale * 0.3).rounded()) : 0
            return [
                UsageHistory.SkillCount(engine: index % 5 == 4 ? .codex : .claude, name: name, source: .model, count: model, lastAt: lastAt),
                UsageHistory.SkillCount(engine: .claude, name: name, source: .command, count: command, lastAt: lastAt),
            ].filter { $0.count > 0 }
        }

        let compactions = (0..<Int(days * 14)).map { index -> UsageHistory.Compaction in
            let time = start + (end - start) * random.next()
            let trigger: UsageHistory.Compaction.Trigger? = index % 9 == 0 ? .manual : index % 7 == 0 ? nil : .auto
            let before = trigger == .auto ? 155_000 + Int(random.next() * 20_000) : 40_000 + Int(random.next() * 110_000)
            return UsageHistory.Compaction(
                at: Date(timeIntervalSince1970: time), engine: trigger == nil ? .codex : .claude, session: "s\(index % 40)", trigger: trigger, before: before,
                after: before / 8)
        }.sorted { $0.at < $1.at }

        let sessionCount = Int(days * 45)
        let sessions = (0..<min(sessionCount, UsageHistory.sessionLimit)).map { index -> UsageHistory.SessionTotal in
            let requests = Int(900 / Double(index + 1).squareRoot() * (0.7 + random.next() * 0.6) * min(days, 3))
            return UsageHistory.SessionTotal(
                engine: index % 6 == 5 ? .codex : .claude, session: String(format: "%08x-fixture", index * 7919 + 1),
                cwd: "/Users/me/dev/" + workdirs[index % workdirs.count], title: index % 3 == 0 ? "線\(index + 20)の実装" : nil, requests: requests,
                tokens: TokenCounts(input: requests * 40, cacheWrite: requests * 2_800, cacheRead: requests * 82_000, output: requests * 520),
                maxContext: 60_000 + Int(random.next() * 110_000), compactions: Int(random.next() * 4), lastAt: lastAt)
        }

        return UsageHistory(
            from: query.from, to: query.to, bucketSeconds: query.bucketSeconds, recordingSince: query.from.addingTimeInterval(-86_400 * 60), samples: samples,
            tokens: tokens, skills: skillCounts, compactions: compactions, sessions: sessions, sessionCount: sessionCount)
    }

    /// 区切り（`at` から `seconds`）の中の動き具合を 1 時間ごとに見て、最大（`peak`）か平均を返す
    private static func activity(_ at: TimeInterval, seconds: TimeInterval, peak: Bool) -> Double {
        let hours = stride(from: at, to: at + seconds, by: 3600).map(activity)
        return peak ? hours.max() ?? 0 : hours.reduce(0, +) / Double(max(hours.count, 1))
    }

    /// 0（深夜）〜1（昼）。日本時間の 10 時〜翌 1 時を動いている時間にする
    private static func activity(_ at: TimeInterval) -> Double {
        let hour = (at + 9 * 3600).truncatingRemainder(dividingBy: 86_400) / 3600
        let awake = hour >= 10 || hour < 1
        return awake ? 0.55 + 0.45 * sin((hour >= 10 ? hour - 10 : hour + 14) / 15 * .pi) : 0.05
    }
}

/// 種で決まる乱数（SplitMix64）。`String.hashValue` はプロセスごとに変わるので、種の文字列から自分で作る
private struct SeededRandom {
    private var state: UInt64

    init(seed: String) {
        state = seed.utf8.reduce(1_469_598_103_934_665_603) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    /// 0 以上 1 未満
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
