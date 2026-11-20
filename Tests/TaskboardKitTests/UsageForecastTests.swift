import Foundation
import Testing

@testable import TaskboardKit

@Suite("利用枠の見込み")
struct UsageForecastTests {
    // 2026-11-20 14:00（Asia/Tokyo）
    let now = Date(timeIntervalSince1970: 1_795_150_800)
    func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }

    @Test("Studio の 11-20 の形: main は上限で、sub を 1 時間に 3 ポイントで使うと 14 時間ほどで全部が閾値を越え、main が戻る 11-21 14:00 まで止まる")
    func studioExhausts() throws {
        let result = try #require(
            UsageForecast.simulate(
                accounts: [.init(name: "main", sevenDay: 100, resetsAt: hours(24)), .init(name: "sub", sevenDay: 56, resetsAt: hours(150))],
                perHour: 3, threshold: 99, now: now))
        let exhausted = try #require(result.exhaustedAt)
        // 56 → 99 は 43 ポイントで 14.33 時間。10 分刻みなので 1 刻みまでずれる
        #expect(abs(exhausted.timeIntervalSince(hours(43.0 / 3))) <= 600)
        #expect(result.resumesAt == hours(24))
        #expect(result.atReset["main"] == 100)
    }

    @Test("ゆっくり使うと、先に戻る sub を使い切ってから戻った main に移り、全部が 1 回戻るまで閾値を越えない")
    func enoughUntilHorizon() throws {
        let result = try #require(
            UsageForecast.simulate(
                accounts: [.init(name: "main", sevenDay: 100, resetsAt: hours(24)), .init(name: "sub", sevenDay: 10, resetsAt: hours(150))],
                perHour: 1, threshold: 99, now: now))
        #expect(result.exhaustedAt == nil)
        #expect(result.horizon == hours(150))
        // sub は 89 時間で閾値に達し、その後は main（24 時間で 0 に戻った）を使う
        let sub = try #require(result.atReset["sub"])
        #expect(sub >= 99 && sub < 99.2)
        #expect(result.atReset["main"] == 100, "最初に戻る直前は今の 100%")
    }

    @Test("消費が 0 なら越えない。アカウントが無ければ見込みを出さない")
    func edges() {
        #expect(UsageForecast.simulate(accounts: [.init(name: "login", sevenDay: 50, resetsAt: hours(10))], perHour: 0, threshold: 99, now: now)?.exhaustedAt == nil)
        #expect(UsageForecast.simulate(accounts: [], perHour: 3, threshold: 99, now: now) == nil)
    }

    @Test("速さは同じ窓の中で増えた分の合計を観測した時間で割る。リセットで下がった分と、窓の違う観測の間は数えない。観測が 1 時間に満たなければ出さない")
    func perHour() throws {
        let subReset = hours(150), mainReset = hours(24)
        let samples = [
            // 09:00 の 41% から 14:00 の 56%（Studio と DMM の観測が混ざっても、アカウントの値なのでそのまま足せる）
            UsageAccountSample(account: "sub", at: hours(-5), sevenDay: 41, sevenDayResetsAt: subReset),
            UsageAccountSample(account: "sub", at: hours(-2), sevenDay: 50, sevenDayResetsAt: subReset.addingTimeInterval(30)),
            UsageAccountSample(account: "sub", at: hours(0), sevenDay: 56, sevenDayResetsAt: subReset),
            UsageAccountSample(account: "main", at: hours(-4), sevenDay: 100, sevenDayResetsAt: mainReset),
            // リセットで下がった（窓が違う）
            UsageAccountSample(account: "login", at: hours(-3), sevenDay: 90, sevenDayResetsAt: hours(-1)),
            UsageAccountSample(account: "login", at: hours(-1), sevenDay: 2, sevenDayResetsAt: hours(167)),
            // 24 時間より前は数えない
            UsageAccountSample(account: "sub", at: hours(-30), sevenDay: 0, sevenDayResetsAt: subReset),
        ]
        #expect(try #require(UsageForecast.perHour(samples, now: now)) == 3)
        #expect(UsageForecast.perHour([UsageAccountSample(account: "sub", at: hours(-0.5), sevenDay: 1, sevenDayResetsAt: subReset)], now: now) == nil)
        #expect(UsageForecast.perHour([], now: now) == nil)
    }
}
