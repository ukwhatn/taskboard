import Foundation
import Testing

@testable import TaskboardDaemon

@Suite("Claude Code の設定の置き場")
struct ClaudeConfigDirectoryTests {
    let home = URL(fileURLWithPath: "/Users/u", isDirectory: true)

    @Test("CLAUDE_CONFIG_DIR が無いか空なら ~/.claude、あれば ~ を展開してその下")
    func resolves() {
        #expect(ClaudeConfigDirectory.projects(environment: [:], home: home).path == "/Users/u/.claude/projects")
        #expect(ClaudeConfigDirectory.url(environment: ["CLAUDE_CONFIG_DIR": ""], home: home).path == "/Users/u/.claude")
        #expect(ClaudeConfigDirectory.url(environment: ["CLAUDE_CONFIG_DIR": "/opt/claude"], home: home).path == "/opt/claude")
        let mine = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ClaudeConfigDirectory.projects(environment: ["CLAUDE_CONFIG_DIR": "~/設定/claude"], home: home).path == mine + "/設定/claude/projects")
    }
}
