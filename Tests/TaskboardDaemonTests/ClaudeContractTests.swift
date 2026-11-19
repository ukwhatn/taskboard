import Foundation
import Testing

@testable import TaskboardDaemon

/// 本物の Claude Code（haiku）で `conversation check` と同じ会話を通す。利用枠を使うので `TASKBOARD_CONTRACT_CLAUDE=1` のときだけ回す
@Suite("Claude Code の stream-json の契約", .enabled(if: ProcessInfo.processInfo.environment["TASKBOARD_CONTRACT_CLAUDE"] == "1"))
struct ClaudeContractTests {
    @Test("確かめの会話が全段通る", .timeLimit(.minutes(5)))
    func check() async throws {
        let executable = try EngineCheck.resolveExecutable(ProcessInfo.processInfo.environment["TASKBOARD_CONTRACT_CLAUDE_PATH"], engine: .claude)
        let report = try await ClaudeCheck.run(executable: executable)
        for step in report.steps where !step.passed { Issue.record("\(step.name): \(step.detail)") }
        #expect(report.passed)
        #expect(Set(ClaudeConversation.requiredCapabilities).isSubset(of: report.capabilities))
    }
}
