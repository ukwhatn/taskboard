import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

struct ClaudeUsageFileTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ percent: Double, resetsIn seconds: TimeInterval?, length: Int = 604_800) -> UsageWindow {
        UsageWindow(usedPercent: percent, resetsAt: seconds.map { now.addingTimeInterval($0) }, windowSeconds: length)
    }

    @Test("書いた枠を読み戻す。戻る時刻を過ぎた窓と、窓が残らない枠は落とす")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "claude-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ClaudeUsageFile(supportDirectory: directory)
        #expect(file.load(now: now) == ClaudeUsageFile.Contents(), "無ければ空")

        let login = ClaudeUsage(fiveHour: window(20, resetsIn: -60, length: 18_000), sevenDay: window(100, resetsIn: 86_400), at: now)
        let stale = ClaudeUsage(fiveHour: window(90, resetsIn: -1, length: 18_000), sevenDay: nil, at: now)
        try file.save(ClaudeUsageFile.Contents(login: login, accounts: ["sub": stale]))

        let loaded = file.load(now: now)
        #expect(loaded.login == ClaudeUsage(fiveHour: nil, sevenDay: window(100, resetsIn: 86_400), at: now))
        #expect(loaded.accounts.isEmpty)
    }

    @Test("起き直した daemon は、報告が来ていないログインとアカウントにだけ保存した枠を入れ、一覧に無いアカウントの枠は入れない")
    func restore() async {
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "t", daemonVersion: "t"))
        await state.setClaudeAccounts([ClaudeAccount(name: "sub", boards: [])])
        let saved = ClaudeUsage(fiveHour: nil, sevenDay: window(100, resetsIn: 86_400), at: now)
        await state.restoreClaudeUsage(ClaudeUsageFile.Contents(login: saved, accounts: ["sub": saved, "gone": saved]))
        let usage = await state.usageSnapshot()
        #expect(usage.claude == saved)
        #expect(usage.claudeUsage(account: "sub") == saved)
        #expect(usage.claudeAccounts?.map(\.name) == ["sub"])
        #expect(ClaudeAccounts.exhausted(usage.claude, pause: MachineSettings.UsagePause(fiveHourPercent: 90, sevenDayPercent: 90), now: now))
    }
}
