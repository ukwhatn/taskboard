import Foundation

/// Claude Code の設定の置き場（`CLAUDE_CONFIG_DIR`、無ければ `~/.claude`）。transcript（`projects`）と settings.json はこの下。
/// 渡す環境は Claude Code を起こす環境（daemon ではログインシェルのもの。launchd の daemon の環境にはシェルの設定の変数が無い）
enum ClaudeConfigDirectory {
    static func url(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty else { return home.appending(path: ".claude", directoryHint: .isDirectory) }
        return URL(fileURLWithPath: (config as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func projects(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        url(environment: environment, home: home).appending(path: "projects", directoryHint: .isDirectory)
    }
}
