import Foundation
import Testing

@testable import TaskboardDaemon

@Suite("利用枠の上限の後に続けるかの設定")
struct UsageLimitSettingTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tb-usage-limit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url.appending(path: ".claude"), withIntermediateDirectories: true)
        return url
    }

    private func record(settings: String?) -> ConversationRecord {
        var record = ConversationRecord(taskNumber: nil, agentSessionId: "s1", cwd: "/w", model: "haiku", runner: .none)
        if let settings { record.extraArguments = ["--settings", settings] }
        return record
    }

    @Test("--settings のファイルの鍵を先に読み、無ければ設定のフォルダの settings.json、どちらにも無ければ続ける")
    func readsInOrder() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let given = home.appending(path: "given.json")
        try Data(#"{"autoContinueAtUsageLimit":true}"#.utf8).write(to: given)
        try Data(#"{"autoContinueAtUsageLimit":false}"#.utf8).write(to: home.appending(path: ".claude/settings.json"))
        #expect(UsageLimitSetting.continues(record: record(settings: given.path), environment: [:], home: home.path))
        #expect(!UsageLimitSetting.continues(record: record(settings: nil), environment: [:], home: home.path))

        try Data(#"{"model":"opus"}"#.utf8).write(to: home.appending(path: ".claude/settings.json"))
        #expect(UsageLimitSetting.continues(record: record(settings: nil), environment: [:], home: home.path))
    }

    @Test("--settings がファイルでない（フォルダ・大きすぎる）なら読まずに次を見る")
    func skipsUnreadableSettings() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"autoContinueAtUsageLimit":false}"#.utf8).write(to: home.appending(path: ".claude/settings.json"))
        #expect(!UsageLimitSetting.continues(record: record(settings: home.path), environment: [:], home: home.path))

        let large = home.appending(path: "large.json")
        var body = Data(#"{"autoContinueAtUsageLimit":true,"pad":""#.utf8)
        body.append(Data(repeating: UInt8(ascii: "a"), count: UsageLimitSetting.maxBytes))
        body.append(Data(#""}"#.utf8))
        try body.write(to: large)
        #expect(!UsageLimitSetting.continues(record: record(settings: large.path), environment: [:], home: home.path))
    }
}
