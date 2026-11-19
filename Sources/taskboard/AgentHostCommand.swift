import ArgumentParser
import Foundation
import Logging
import TaskboardDaemon

/// `taskboard agent-host`：Claude Code の会話の CLI を子として持つ（launchd の `uk.whatn.taskboard-agent-host`）。
/// daemon の入れ替えで会話を止めないため、daemon とは別の job にする
struct AgentHostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent-host", abstract: "会話の CLI を持つ host を前景で動かす（launchd からもこれを呼ぶ）")

    @OptionGroup var common: CommonOptions

    func run() async throws {
        let paths = try Paths(directory: common.supportDirectoryURL)
        let logger = Logger(label: "uk.whatn.taskboard-agent-host")
        let watcher = Task { await LaunchdJobRepair.watch(LaunchdJobRepair.peerLabels, logger: logger) }
        defer { watcher.cancel() }
        try await AgentHostServer.run(supportDirectory: paths.directory, logger: logger)
    }
}
