import Foundation

/// git を短命の子として動かす。`GIT_OPTIONAL_LOCKS=0`（agent の git と index.lock を取り合わない）、pager・色・外部 diff・パスの引用に左右されない環境で、
/// 既定は 1 回 5 秒で打ち切る
enum GitCommand {
    static let executable = URL(fileURLWithPath: "/usr/bin/git")
    static let defaultTimeout: Duration = .seconds(5)

    /// 終了コードを問わず、終わり方と出力を返す（起こせなければ投げる）
    static func run(
        _ directory: String, _ arguments: [String], limit: Int, timeout: Duration = defaultTimeout
    ) async throws -> Subprocess.Outcome {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        return try await Subprocess.capture(
            executable, ["-C", directory, "-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments, environment: environment, timeout: timeout,
            outputLimit: limit)
    }

    /// 失敗した呼び出しの理由の文（git の stderr。打ち切りと出力超過はその旨）
    static func message(_ outcome: Subprocess.Outcome, timeout: Duration = defaultTimeout) -> String {
        if outcome.timedOut { return "git が \(timeout) で終わらない" }
        if outcome.overflowed { return "git の出力が大きすぎる" }
        return String(decoding: outcome.stderr.prefix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
