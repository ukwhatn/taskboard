import Foundation

/// マシンの接続（`CodexMachine`）が読んだコネクタに対して、CLI でしかできない操作
enum CodexConnectors {
    /// `codex mcp logout <名前>` を、app-server を起こすときと同じ codex・環境で走らせる。
    /// 名前は `--` の後に渡す（シェルを通さず、名前が `-` で始まってもオプションにしない）。出力は読まず、ログにも出さない（認証の情報を書くことがある）
    static func logout(
        install: @escaping @Sendable () async throws -> CodexInstall = { try await CodexInstall.resolve() }, timeout: Duration = .seconds(30)
    ) -> CodexMachine.Logout {
        { name in
            let outcome: Subprocess.Outcome
            do {
                let codex = try await install()
                outcome = try await Subprocess.capture(
                    codex.executable, ["mcp", "logout", "--", name], cwd: FileManager.default.homeDirectoryForCurrentUser,
                    environment: codex.environment, timeout: timeout, outputLimit: 65_536)
            } catch {
                throw CodexMachine.LogoutError.codexUnavailable
            }
            if outcome.timedOut { throw CodexMachine.LogoutError.timedOut }
            guard outcome.status == 0, !outcome.overflowed else { throw CodexMachine.LogoutError.refused }
        }
    }
}
