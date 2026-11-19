import Foundation
import TaskboardKit

/// 会話の worktree を `git worktree add` で切る。置き場は `~/.taskboard/worktrees/<repo の名前>/<branch の / を - にしたもの>`
enum GitWorktrees {
    /// 大きな repo の checkout を途中で止めない
    static let timeout: Duration = .seconds(120)

    static func root(home: String) -> String { home + "/.taskboard/worktrees" }

    /// 切った worktree の path。同じ branch の worktree が既にあればそれを返す（branch は 1 つの worktree にしか checkout できない）
    static func create(_ cwd: String, _ spec: LaunchRequest.WorktreeSpec, home: String) async throws -> String {
        let common = try await output(cwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let checkouts = WorktreeGit.parseWorktreeList(Data(try await output(cwd, ["worktree", "list", "--porcelain", "-z"], trimmed: false).utf8))
        // 先頭は repo の本体。本体の branch は git に断らせる
        if let existing = checkouts.dropFirst().first(where: { $0.branch == spec.branch && !$0.isPrunable }) { return existing.path }
        let path = spec.path.map { ($0 as NSString).expandingTildeInPath }
            ?? root(home: home) + "/" + repoName(commonDirectory: common) + "/" + spec.branch.replacingOccurrences(of: "/", with: "-")
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let hasBranch = try await GitCommand.run(cwd, ["show-ref", "--verify", "--quiet", "refs/heads/" + spec.branch], limit: 4_096).status == 0
        let arguments = hasBranch ? ["worktree", "add", path, spec.branch] : ["worktree", "add", "-b", spec.branch, path] + [spec.base].compactMap(\.self)
        let added = try await GitCommand.run(cwd, arguments, limit: 1 << 20, timeout: timeout)
        guard added.status == 0, !added.timedOut else { throw ConversationError.failed("worktree を作れない: \(GitCommand.message(added, timeout: timeout))") }
        return path
    }

    /// `--git-common-dir` から repo の名前。普通の repo は `<repo>/.git`、bare の repo は `<名前>.git`
    static func repoName(commonDirectory: String) -> String {
        let url = URL(fileURLWithPath: commonDirectory)
        if url.lastPathComponent == ".git" { return url.deletingLastPathComponent().lastPathComponent }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func output(_ cwd: String, _ arguments: [String], trimmed: Bool = true) async throws -> String {
        let outcome = try await GitCommand.run(cwd, arguments, limit: 1 << 20)
        guard outcome.status == 0, !outcome.timedOut, !outcome.overflowed else {
            throw ConversationError.failed("worktree を作れない: \(GitCommand.message(outcome))")
        }
        let text = String(decoding: outcome.stdout, as: UTF8.self)
        return trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}
