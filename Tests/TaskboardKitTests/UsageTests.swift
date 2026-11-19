import Foundation
import Testing

@testable import TaskboardKit

@Suite("利用枠")
struct UsageTests {
    let now = Date(timeIntervalSince1970: 1_791_100_000)

    @Test("statusline の JSON から context と 5h / 1w を読む")
    func parseStatusline() throws {
        let json = """
            {"session_id":"0b6f9a2e-1111-2222-3333-444455556666","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
             "effort":{"level":"medium"},
             "context_window":{"used_percentage":31.4,"total_input_tokens":155000,"context_window_size":500000},
             "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1791107800},"seven_day":{"used_percentage":57.5,"resets_at":1791500000}}}
            """
        let report = try #require(ClaudeUsageReport.parse(statusline: Data(json.utf8), now: now))
        #expect(report.context.agentSessionID == "0b6f9a2e-1111-2222-3333-444455556666")
        #expect(report.context.model == "Opus 5.5")
        #expect(report.context.effort == "medium")
        #expect(report.context.usedPercent == 31.4)
        #expect(report.context.inputTokens == 155_000)
        #expect(report.context.windowSize == 500_000)
        #expect(report.fiveHour == UsageWindow(usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1_791_107_800), windowSeconds: 18_000))
        #expect(report.sevenDay?.usedPercent == 57.5)
        #expect(report.sevenDay?.windowSeconds == 604_800)
    }

    @Test("rate_limits が無い（API key の契約）なら枠は nil で、context は読む")
    func parseWithoutLimits() throws {
        let json = #"{"session_id":"abcdefgh-1","context_window":{"used_percentage":5}}"#
        let report = try #require(ClaudeUsageReport.parse(statusline: Data(json.utf8), now: now))
        #expect(report.fiveHour == nil && report.sevenDay == nil)
        #expect(report.context.usedPercent == 5)
        #expect(report.context.model == nil)
    }

    @Test("session_id の無い・壊れた入力は捨てる")
    func parseRejects() {
        #expect(ClaudeUsageReport.parse(statusline: Data(), now: now) == nil)
        #expect(ClaudeUsageReport.parse(statusline: Data("not json".utf8), now: now) == nil)
        #expect(ClaudeUsageReport.parse(statusline: Data(#"{"session_id":""}"#.utf8), now: now) == nil)
    }

    @Test("着地は今のペースで窓の終わりまで使ったときの値。経過が短いうちは出さない")
    func projection() {
        // 5h 窓の半分が経って 40% → 80%
        let half = UsageWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(9_000), windowSeconds: 18_000)
        #expect(half.projectedPercent(now: now) == 80)
        // 経過 1,000 秒は窓の 1/10（1,800 秒）未満
        let early = UsageWindow(usedPercent: 3, resetsAt: now.addingTimeInterval(17_000), windowSeconds: 18_000)
        #expect(early.projectedPercent(now: now) == nil)
        // 1w 窓は 6 時間経つまで出さない。ちょうど 6 時間で出る
        let week = UsageWindow(usedPercent: 2, resetsAt: now.addingTimeInterval(604_800 - 21_600), windowSeconds: 604_800)
        #expect(abs((week.projectedPercent(now: now) ?? 0) - 56) < 0.001)
        // 999% で頭打ち、リセット時刻や窓長が無ければ出さない
        let burst = UsageWindow(usedPercent: 90, resetsAt: now.addingTimeInterval(16_000), windowSeconds: 18_000)
        #expect(burst.projectedPercent(now: now) == 810)
        #expect(UsageWindow(usedPercent: 99, resetsAt: now.addingTimeInterval(15_000), windowSeconds: 18_000).projectedPercent(now: now) == 594)
        #expect(UsageWindow(usedPercent: 50, resetsAt: nil, windowSeconds: 18_000).projectedPercent(now: now) == nil)
        #expect(UsageWindow(usedPercent: 50, resetsAt: now, windowSeconds: 0).projectedPercent(now: now) == nil)
    }

}
