import Foundation
import Testing

@testable import TaskboardKit

@Suite("定期起動の時刻")
struct ScheduleRuleTests {
    var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test("平日 9:30 は金曜の 10:00 の次が月曜 9:30")
    func weekdays() throws {
        let cron = try #require(CronExpression("30 9 * * 1-5"))
        #expect(cron.next(after: at("2026-10-02T10:00:00+09:00"), calendar: tokyo) == at("2026-10-05T09:30:00+09:00"))
        // ちょうどその時刻の「後」なので同じ時刻は返さない
        #expect(cron.next(after: at("2026-10-05T09:30:00+09:00"), calendar: tokyo) == at("2026-10-06T09:30:00+09:00"))
        // 秒の端数があっても次の分から
        #expect(cron.next(after: at("2026-10-05T09:29:30+09:00"), calendar: tokyo) == at("2026-10-05T09:30:00+09:00"))
    }

    @Test("間隔・リスト・範囲の step")
    func steps() throws {
        #expect(CronExpression("*/15 * * * *")?.next(after: at("2026-10-05T10:07:00+09:00"), calendar: tokyo) == at("2026-10-05T10:15:00+09:00"))
        #expect(CronExpression("0 9-17/4 * * *")?.next(after: at("2026-10-05T13:00:00+09:00"), calendar: tokyo) == at("2026-10-05T17:00:00+09:00"))
        #expect(CronExpression("5/20 * * * *")?.next(after: at("2026-10-05T10:26:00+09:00"), calendar: tokyo) == at("2026-10-05T10:45:00+09:00"))
        #expect(CronExpression("0 0 1,15 * *")?.next(after: at("2026-10-02T00:00:00+09:00"), calendar: tokyo) == at("2026-10-15T00:00:00+09:00"))
        // 7 も日曜
        #expect(CronExpression("0 8 * * 7")?.next(after: at("2026-10-05T00:00:00+09:00"), calendar: tokyo) == at("2026-10-11T08:00:00+09:00"))
    }

    @Test("日と曜日の両方を絞ったら、どちらかに合えば起こす")
    func dayOrWeekday() {
        // 9/29（火）の次: 10/1（木、1 日）が 10/5（月）より先
        #expect(CronExpression("0 9 1 * 1")?.next(after: at("2026-09-29T12:00:00+09:00"), calendar: tokyo) == at("2026-10-01T09:00:00+09:00"))
        #expect(CronExpression("0 9 1 * 1")?.next(after: at("2026-10-01T12:00:00+09:00"), calendar: tokyo) == at("2026-10-05T09:00:00+09:00"))
    }

    @Test("来ない日付は nil、読めない式は作れない")
    func invalid() {
        #expect(CronExpression("0 0 31 2 *")?.next(after: at("2026-10-01T00:00:00+09:00"), calendar: tokyo) == nil)
        for bad in ["60 * * * *", "* 24 * * *", "* * *", "a b c d e", "5-1 * * * *", "*/0 * * * *", "* * 0 * *", "* * * 13 *", "1,,2 * * * *", "1/2/3 * * * *"] {
            #expect(CronExpression(bad) == nil, "\(bad)")
        }
    }

    @Test("間隔は anchor から数える")
    func interval() {
        let anchor = at("2026-10-05T10:00:00+09:00")
        let rule = ScheduleRule.interval(minutes: 90)
        #expect(rule.next(after: anchor, anchor: anchor) == at("2026-10-05T11:30:00+09:00"))
        #expect(rule.next(after: at("2026-10-05T13:00:00+09:00"), anchor: anchor) == at("2026-10-05T14:30:00+09:00"))
        // anchor より前なら anchor
        #expect(rule.next(after: at("2026-10-05T08:00:00+09:00"), anchor: anchor) == anchor)
        #expect(ScheduleRule.interval(minutes: 4).isValid == false)
        #expect(ScheduleRule.interval(minutes: 5).isValid)
    }

    @Test("一覧の文")
    func summary() {
        #expect(ScheduleRule.cron("0 9 * * *").summary == "毎日09:00")
        #expect(ScheduleRule.cron("30 8 * * 1-5").summary == "平日08:30")
        #expect(ScheduleRule.cron("0 10 * * 1,4").summary == "毎週月・木の10:00")
        #expect(ScheduleRule.cron("58 23 * * *").summary == "毎日23:58")
        #expect(ScheduleRule.cron("*/15 * * * *").summary == "cron式「*/15 * * * *」")
        #expect(ScheduleRule.cron("0 9 1 * *").summary == "cron式「0 9 1 * *」")
        #expect(ScheduleRule.interval(minutes: 90).summary == "90分おき")
        #expect(ScheduleRule.interval(minutes: 120).summary == "2時間おき")
        #expect(ScheduleRule.interval(minutes: 5).summary == "5分おき")
    }

    @Test("毎週の曜日は、画面の曜日のボタンと同じく月曜から。日曜は 0 でも 7 でも末尾で、重ねて書いても 1 つ")
    func weeklyOrder() {
        #expect(ScheduleRule.cron("0 9 * * 0,1").summary == "毎週月・日の09:00")
        #expect(ScheduleRule.cron("0 9 * * 7,3,0").summary == "毎週水・日の09:00")
        #expect(ScheduleRule.weekdays("6,5,4,3,2,1,0") == [1, 2, 3, 4, 5, 6, 0])
        #expect(ScheduleRule.weekdays("1-3") == nil)
        #expect(ScheduleRule.weekdays("1,,2") == nil)
        #expect(ScheduleRule.weekdays("8") == nil)
    }

    @Test("各回の結果: スキップ、起動済み、起動失敗、起動中、未起動")
    func runOutcome() {
        let t0 = Date(timeIntervalSince1970: 0)
        func run(skipped: String? = nil, stage: LaunchStage? = nil) -> ScheduleRun {
            ScheduleRun(id: 1, scheduleID: 1, scheduledAt: t0, trigger: .schedule, skipped: skipped, stage: stage, createdAt: t0)
        }
        #expect(run(skipped: "前回の実行が終わっていません").outcome == .skipped)
        #expect(run(stage: .done).outcome == .launched)
        #expect(run(stage: .failed).outcome == .failed)
        #expect(run(stage: .tab).outcome == .launching)
        #expect(run().outcome == .notStarted)
    }

    @Test("JSON は cron か intervalMinutes のどちらか")
    func coding() throws {
        let data = try JSONEncoder().encode([ScheduleRule.cron("0 9 * * *"), .interval(minutes: 30)])
        #expect(String(decoding: data, as: UTF8.self) == #"[{"cron":"0 9 * * *"},{"intervalMinutes":30}]"#)
        #expect(try JSONDecoder().decode([ScheduleRule].self, from: data) == [.cron("0 9 * * *"), .interval(minutes: 30)])
    }
}
