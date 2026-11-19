import Foundation
import Testing
@testable import TaskboardKit

@Suite struct UsageReportTests {
    let t0 = Date(timeIntervalSince1970: 1_792_900_800)

    func history(
        samples: [UsageHistory.Sample] = [], tokens: [UsageHistory.TokenBucket] = [], skills: [UsageHistory.SkillCount] = [],
        compactions: [UsageHistory.Compaction] = [], sessions: [UsageHistory.SessionTotal] = [], sessionCount: Int = 0, since: Date? = nil
    ) -> UsageHistory {
        UsageHistory(
            from: t0, to: t0.addingTimeInterval(86_400), bucketSeconds: 3600, recordingSince: since, samples: samples, tokens: tokens, skills: skills,
            compactions: compactions, sessions: sessions, sessionCount: sessionCount)
    }

    func session(_ id: String, tokens: Int) -> UsageHistory.SessionTotal {
        UsageHistory.SessionTotal(
            engine: .claude, session: id, cwd: nil, title: nil, requests: 1, tokens: TokenCounts(cacheRead: tokens), maxContext: nil, compactions: 0, lastAt: t0)
    }

    @Test("利用枠は Mac ごとの系列のまま、応答したセッションとトークンは同じ時刻で足す")
    func mergesMachines() {
        let studio = history(
            samples: [UsageHistory.Sample(at: t0, claudeFiveHour: 40, claudeActive: 3)],
            tokens: [UsageHistory.TokenBucket(at: t0, engine: .claude, model: "opus", requests: 10, tokens: TokenCounts(input: 1, cacheWrite: 2, cacheRead: 30, output: 4))],
            sessionCount: 2, since: t0.addingTimeInterval(-100))
        let laptop = history(
            samples: [UsageHistory.Sample(at: t0, claudeFiveHour: 70, claudeActive: 2)],
            tokens: [UsageHistory.TokenBucket(at: t0, engine: .claude, model: "opus", requests: 5, tokens: TokenCounts(input: 1, cacheWrite: 0, cacheRead: 10, output: 1))],
            sessionCount: 1, since: t0.addingTimeInterval(-500))
        let report = UsageReport([.init(name: "Studio", history: studio), .init(name: "Air", history: laptop)])

        #expect(report.machines == ["Studio", "Air"])
        #expect(report.windows.map(\.window) == [.claudeFiveHour])
        #expect(report.windows[0].points.map(\.percent) == [40, 70])
        #expect(report.windows[0].points.map(\.machine) == ["Studio", "Air"])
        // Codex の記録が無ければ Codex の系列を出さない
        #expect(report.active == [UsageReport.ActivePoint(at: t0, engine: .claude, count: 5)])
        #expect(report.totalTokens == TokenCounts(input: 2, cacheWrite: 2, cacheRead: 40, output: 5))
        #expect(report.tokens.map(\.tokens) == [2, 2, 40, 5])
        #expect(report.models == [UsageReport.ModelRow(engine: .claude, model: "opus", requests: 15, tokens: TokenCounts(input: 2, cacheWrite: 2, cacheRead: 40, output: 5))])
        #expect(report.sessionCount == 3)
        #expect(report.tokensPerSession == 49 / 3)
        #expect(report.recordingSince == t0.addingTimeInterval(-500))
    }

    @Test("スキルは名前ごとにモデルと /コマンドの回数を合わせ、多い順に並べる")
    func skills() {
        let a = history(skills: [
            .init(engine: .claude, name: "commit", source: .model, count: 3, lastAt: t0),
            .init(engine: .claude, name: "commit", source: .command, count: 2, lastAt: t0.addingTimeInterval(60)),
            .init(engine: .claude, name: "handoff", source: .command, count: 1, lastAt: t0),
        ])
        let b = history(skills: [.init(engine: .codex, name: "yomiyasu", source: .model, count: 7, lastAt: t0)])
        let report = UsageReport([.init(name: "A", history: a), .init(name: "B", history: b)])
        #expect(report.skills.map(\.name) == ["yomiyasu", "commit", "handoff"])
        #expect(report.skills[1] == UsageReport.SkillRow(name: "commit", model: 3, command: 2, lastAt: t0.addingTimeInterval(60)))
    }

    @Test("圧縮は回数を種類ごとに数え、直前の大きさが無いものは点にしない")
    func compactions() {
        let report = UsageReport([.init(name: "A", history: history(compactions: [
            .init(at: t0, engine: .claude, session: "s", trigger: .auto, before: 160_000, after: 20_000),
            .init(at: t0, engine: .claude, session: "s", trigger: .manual, before: nil, after: nil),
            .init(at: t0, engine: .codex, session: "c", trigger: nil, before: 90_000, after: nil),
        ]))])
        #expect(report.compactionCounts == (1, 1, 1))
        #expect(report.compactions.map(\.before) == [160_000, 90_000])
        #expect(!report.isEmpty)
    }

    @Test("セッションは Mac をまたいでトークンの多い順に 20 件まで")
    func sessions() {
        let a = history(sessions: (0..<15).map { session("a\($0)", tokens: 100 + $0) })
        let b = history(sessions: (0..<15).map { session("b\($0)", tokens: 200 + $0) })
        let report = UsageReport([.init(name: "A", history: a), .init(name: "B", history: b)])
        #expect(report.sessions.count == 20)
        #expect(report.sessions.first?.total.session == "b14")
        #expect(report.sessions.first?.machine == "B")
        #expect(report.sessions.last?.total.session == "a10")
    }

    @Test("記録が無ければ空")
    func empty() {
        #expect(UsageReport([]).isEmpty)
        #expect(UsageReport([.init(name: "A", history: history(samples: [UsageHistory.Sample(at: t0)]))]).isEmpty)
        #expect(UsageReport([]).tokensPerSession == nil)
    }
}

@Suite struct UsageHistoryQueryTests {
    let now = Date(timeIntervalSince1970: 1_792_900_800)

    @Test("逆さの期間と、粒度が 5 分より細かい・7 日より粗いものは断る")
    func rejects() {
        #expect(UsageHistoryQuery.validated(from: now, to: now, bucketSeconds: 3600, now: now) == nil)
        #expect(UsageHistoryQuery.validated(from: now, to: now.addingTimeInterval(-1), bucketSeconds: 3600, now: now) == nil)
        #expect(UsageHistoryQuery.validated(from: now.addingTimeInterval(-3600), to: now, bucketSeconds: 299, now: now) == nil)
        #expect(UsageHistoryQuery.validated(from: now.addingTimeInterval(-3600), to: now, bucketSeconds: 7 * 86_400 + 1, now: now) == nil)
    }

    @Test("始まりは 90 日前までに縮め、区切りが 2,000 を超えるものは断る")
    func clamps() {
        let long = UsageHistoryQuery.validated(from: now.addingTimeInterval(-200 * 86_400), to: now, bucketSeconds: 86_400, now: now)
        #expect(long?.from == now.addingTimeInterval(-90 * 86_400))
        #expect(UsageHistoryQuery.validated(from: now.addingTimeInterval(-2000 * 300), to: now, bucketSeconds: 300, now: now) != nil)
        #expect(UsageHistoryQuery.validated(from: now.addingTimeInterval(-2001 * 300), to: now, bucketSeconds: 300, now: now) == nil)
        // 保持より前だけの期間は空になるので断る
        #expect(UsageHistoryQuery.validated(from: now.addingTimeInterval(-200 * 86_400), to: now.addingTimeInterval(-100 * 86_400), bucketSeconds: 86_400, now: now) == nil)
    }

    @Test("問い合わせの欄は UNIX 秒と粒度の秒")
    func items() {
        let query = UsageHistoryQuery(from: now.addingTimeInterval(-3600), to: now, bucketSeconds: 900)
        #expect(query.queryItems.map { "\($0.name)=\($0.value ?? "")" } == ["from=1792897200", "to=1792900800", "bucket=900"])
    }
}
