import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("利用枠の配信")
struct UsageStateTests {
    static func report(_ session: String, ctx: Double, at: Date, fiveHour: Double? = 42) -> ClaudeUsageReport {
        ClaudeUsageReport(
            context: SessionContext(agentSessionID: session, model: "Opus 5.5", effort: "medium", usedPercent: ctx, inputTokens: nil, windowSize: nil, at: at),
            fiveHour: fiveHour.map { UsageWindow(usedPercent: $0, resetsAt: nil, windowSeconds: 18_000) }, sevenDay: nil)
    }

    @Test("時刻だけが変わった statusline は配らない。中身が変われば配る")
    func dedupe() async throws {
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
        let (_, events) = await state.subscribe()
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        await state.record(Self.report("session-a", ctx: 10, at: t0), now: t0)
        await state.record(Self.report("session-a", ctx: 10, at: t0.addingTimeInterval(10)), now: t0.addingTimeInterval(10))
        await state.record(Self.report("session-a", ctx: 50, at: t0.addingTimeInterval(20)), now: t0.addingTimeInterval(20))
        var seen: [Double?] = []
        for await event in events {
            if case .usageUpdated(let usage) = event { seen.append(usage.contexts.first?.usedPercent) }
            if seen.count == 2 { break }
        }
        #expect(seen == [10, 50])
        #expect(await state.usageSnapshot().contexts.count == 1)
        #expect(await state.snapshot().usage?.claude?.fiveHour?.usedPercent == 42)
    }

    @Test("枠の無い statusline は前の枠を消さない。30 分届かないセッションの context は落とす")
    func keepsLimitsAndExpires() async {
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        await state.record(Self.report("session-a", ctx: 10, at: t0), now: t0)
        let later = t0.addingTimeInterval(DaemonState.contextTTL + 1)
        await state.record(Self.report("session-b", ctx: 20, at: later, fiveHour: nil), now: later)
        let usage = await state.usageSnapshot()
        #expect(usage.claude?.fiveHour?.usedPercent == 42)
        #expect(usage.contexts.map(\.agentSessionID) == ["session-b"])
    }

    @Test("古いセッションの statusline が古い枠の値を送っても、同じ窓なら大きいほうを残す。窓が替われば新しい値にする")
    func keepsLargestInWindow() async {
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        let reset = t0.addingTimeInterval(3_600)
        func report(_ session: String, _ used: Double, resetsAt: Date, at: Date) -> ClaudeUsageReport {
            ClaudeUsageReport(
                context: SessionContext(agentSessionID: session, model: nil, effort: nil, usedPercent: nil, inputTokens: nil, windowSize: nil, at: at),
                fiveHour: UsageWindow(usedPercent: used, resetsAt: resetsAt, windowSeconds: 18_000), sevenDay: nil)
        }
        await state.record(report("fresh", 16, resetsAt: reset, at: t0), now: t0)
        await state.record(report("stale", 12, resetsAt: reset, at: t0.addingTimeInterval(1)), now: t0.addingTimeInterval(1))
        #expect(await state.usageSnapshot().claude?.fiveHour?.usedPercent == 16)
        // 同じ窓でも秒の端数はずれることがある
        await state.record(report("fresh", 18, resetsAt: reset.addingTimeInterval(-1), at: t0.addingTimeInterval(2)), now: t0.addingTimeInterval(2))
        #expect(await state.usageSnapshot().claude?.fiveHour?.usedPercent == 18)
        // 前の窓の値を持ったままのセッション
        await state.record(report("old", 90, resetsAt: reset.addingTimeInterval(-18_000), at: t0.addingTimeInterval(3)), now: t0.addingTimeInterval(3))
        #expect(await state.usageSnapshot().claude?.fiveHour?.usedPercent == 18)
        // 窓が明けた後の最初の報告
        let next = reset.addingTimeInterval(10)
        await state.record(report("fresh", 1, resetsAt: reset.addingTimeInterval(18_000), at: next), now: next)
        #expect(await state.usageSnapshot().claude?.fiveHour?.usedPercent == 1)
    }

    @Test("リセットで使用率が下がり窓の終わりが変わらなくても、止まっているセッションの古い値に負けずに下がる")
    func followsResetInSameWindow() async {
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        let reset = t0.addingTimeInterval(259_200)
        func report(_ session: String, _ used: Double, at: Date) -> ClaudeUsageReport {
            ClaudeUsageReport(
                context: SessionContext(agentSessionID: session, model: nil, effort: nil, usedPercent: nil, inputTokens: nil, windowSize: nil, at: at),
                fiveHour: nil, sevenDay: UsageWindow(usedPercent: used, resetsAt: reset, windowSeconds: 604_800))
        }
        await state.record(report("active", 76, at: t0), now: t0)
        await state.record(report("stale", 76, at: t0.addingTimeInterval(1)), now: t0.addingTimeInterval(1))
        await state.record(report("active", 9, at: t0.addingTimeInterval(10)), now: t0.addingTimeInterval(10))
        // 止まっているセッションは前の値を送り続ける
        await state.record(report("stale", 76, at: t0.addingTimeInterval(11)), now: t0.addingTimeInterval(11))
        #expect(await state.usageSnapshot().claude?.sevenDay?.usedPercent == 9)
        // 止まっていたセッションが応答を受けると、その時点の値が新しい
        await state.record(report("stale", 10, at: t0.addingTimeInterval(20)), now: t0.addingTimeInterval(20))
        await state.record(report("active", 9, at: t0.addingTimeInterval(21)), now: t0.addingTimeInterval(21))
        #expect(await state.usageSnapshot().claude?.sevenDay?.usedPercent == 10)
    }

    @Test("daemon の起動直後は大きいほうを残し、枠の値が動かなくても context が動いたセッションの値に移る")
    func followsActiveSessionAfterRestart() async {
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        let reset = t0.addingTimeInterval(259_200)
        func report(_ session: String, _ used: Double, tokens: Int, at: Date) -> ClaudeUsageReport {
            ClaudeUsageReport(
                context: SessionContext(agentSessionID: session, model: nil, effort: nil, usedPercent: nil, inputTokens: tokens, windowSize: nil, at: at),
                fiveHour: nil, sevenDay: UsageWindow(usedPercent: used, resetsAt: reset, windowSeconds: 604_800))
        }
        await state.record(report("stale", 66, tokens: 500, at: t0), now: t0)
        await state.record(report("active", 9, tokens: 1_000, at: t0.addingTimeInterval(1)), now: t0.addingTimeInterval(1))
        #expect(await state.usageSnapshot().claude?.sevenDay?.usedPercent == 66)
        await state.record(report("active", 9, tokens: 1_200, at: t0.addingTimeInterval(10)), now: t0.addingTimeInterval(10))
        await state.record(report("stale", 66, tokens: 500, at: t0.addingTimeInterval(11)), now: t0.addingTimeInterval(11))
        #expect(await state.usageSnapshot().claude?.sevenDay?.usedPercent == 9)
    }
}
