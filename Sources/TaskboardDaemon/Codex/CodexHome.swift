import Foundation

/// Codex の置き場（`CODEX_HOME`、無ければ `~/.codex`）。rollout（`sessions`）はこの下。渡す環境は Codex を起こす環境（ログインシェルのもの）
enum CodexHome {
    static func url(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let value = environment["CODEX_HOME"], !value.isEmpty else { return home.appending(path: ".codex", directoryHint: .isDirectory) }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
    }
}
