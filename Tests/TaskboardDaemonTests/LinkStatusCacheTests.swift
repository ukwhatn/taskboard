import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("リンクの状態の控え")
struct LinkStatusCacheTests {
    @Test("保存した一覧をそのまま読み戻し、次の保存で無くなった URL は消える")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "link-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(
            databaseURL: dir.appending(path: "taskboard.db"), backupDirectory: dir.appending(path: "backups"), machineID: MachineID(rawValue: "m"))
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        let pr = LinkStatus(url: "https://github.com/o/r/pull/1", fetchedAt: t0, pullRequest: PullRequestLinkState(state: .merged, checks: .success))
        let jira = LinkStatus(url: "https://x.atlassian.net/browse/ABC-1", fetchedAt: t0, jira: JiraLinkState(key: "ABC-1", statusName: "完了", category: .done))
        #expect(try store.cachedLinkStatuses().isEmpty)

        try store.saveLinkStatuses([pr, jira])
        #expect(try store.cachedLinkStatuses() == [jira, pr].sorted { $0.url < $1.url })

        try store.saveLinkStatuses([pr])
        #expect(try store.cachedLinkStatuses() == [pr])
        try store.close()
    }
}
