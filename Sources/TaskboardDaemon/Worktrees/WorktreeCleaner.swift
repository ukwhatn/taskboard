import Foundation
import TaskboardKit

/// 使っていない git worktree の一覧と削除（`GET /v1/worktrees`・`POST /v1/worktrees/remove`）。
///
/// 消せるかは一覧の判定を引き継がず、削除の要求ごとに 1 件ずつ今の状態から読み直す。消すときは `--force` も `branch -D` も使わず、
/// git が断ったらその文をそのまま失敗として返す
struct WorktreeCleaner: Sendable {
    /// 終了していない会話。`cwds` のどれかが worktree の下にあれば使っている
    struct Occupant: Sendable {
        var cwds: [String]
        var user: WorktreeUser
    }

    struct Sources: Sendable {
        /// worktree を探す起点（repo のどこかのパス。重複・存在しないパスは構わない）
        var directories: @Sendable () async -> [String]
        var occupants: @Sendable () async -> [Occupant]
    }

    var sources: Sources
    /// 消す（git）の打ち切り。大きな worktree の削除を途中で止めない
    var removalTimeout: Duration = .seconds(600)

    private struct GitFailure: Error {
        var message: String
    }

    // MARK: 一覧

    func list() async -> [WorktreeInfo] {
        let occupants = await sources.occupants()
        let repos = await discoverRepos(from: await sources.directories())
        return await withTaskGroup(of: [WorktreeInfo].self) { group in
            for repo in repos {
                group.addTask {
                    var infos: [WorktreeInfo] = []
                    for checkout in repo.checkouts {
                        infos.append(await assess(checkout, in: repo, occupants))
                    }
                    return infos
                }
            }
            var all: [WorktreeInfo] = []
            for await infos in group { all += infos }
            return all.sorted { ($0.repo, $0.path) < ($1.repo, $1.path) }
        }
    }

    // MARK: 削除

    func remove(paths: [String]) async -> [WorktreeRemoveResult] {
        var results: [WorktreeRemoveResult] = []
        for path in paths { results.append(await remove(path: path)) }
        return results
    }

    private func remove(path requested: String) async -> WorktreeRemoveResult {
        guard requested.hasPrefix("/") else { return WorktreeRemoveResult(path: requested, outcome: .failed, message: "パスは絶対パスで指定する") }
        guard FileManager.default.fileExists(atPath: requested) else {
            return WorktreeRemoveResult(path: requested, outcome: .refused, blockers: [WorktreeBlocker(.missing)])
        }
        let path = Self.realPath(requested)
        let repo: Repo
        let checkout: WorktreeGit.Checkout
        do {
            guard let found = try await Self.repo(containing: path), let match = found.checkouts.first(where: { $0.path == path }) else {
                return WorktreeRemoveResult(path: requested, outcome: .failed, message: "git の worktree の根のパスではない")
            }
            repo = found
            checkout = match
        } catch {
            return WorktreeRemoveResult(path: requested, outcome: .failed, message: "\(error)")
        }
        let info = await assess(checkout, in: repo, await sources.occupants())
        guard info.removable else {
            return WorktreeRemoveResult(path: requested, outcome: .refused, blockers: info.blockers, branch: info.branch)
        }
        return await delete(info, in: repo, requested: requested)
    }

    /// 判定が通ったものを消す。worktree、続いてブランチ。ブランチが残っても worktree は消えているので `removed` で返し、残った理由を添える
    private func delete(_ info: WorktreeInfo, in repo: Repo, requested: String) async -> WorktreeRemoveResult {
        let path = info.path
        let branch = info.branch
        let outcome: Subprocess.Outcome
        do {
            outcome = try await GitCommand.run(repo.main, ["worktree", "remove", path], limit: 64 << 10, timeout: removalTimeout)
        } catch {
            return WorktreeRemoveResult(path: requested, outcome: .failed, branch: branch, message: "\(error)")
        }
        if outcome.status != 0 || outcome.timedOut {
            return WorktreeRemoveResult(path: requested, outcome: .failed, branch: branch, message: GitCommand.message(outcome, timeout: removalTimeout))
        }
        guard !FileManager.default.fileExists(atPath: path) else {
            return WorktreeRemoveResult(path: requested, outcome: .failed, branch: branch, message: "worktree のディレクトリが残っている")
        }
        guard let branch else { return WorktreeRemoveResult(path: requested, outcome: .removed) }
        return await deleteBranch(branch, in: repo, path: requested)
    }

    /// ブランチが既に無ければ何もしない
    private func deleteBranch(_ branch: String, in repo: Repo, path: String) async -> WorktreeRemoveResult {
        do {
            let exists = try await GitCommand.run(repo.main, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], limit: 4 << 10)
            guard exists.status == 0 else { return WorktreeRemoveResult(path: path, outcome: .removed, branch: branch, branchDeleted: true) }
            let deletion = try await GitCommand.run(repo.main, ["branch", "-d", branch], limit: 64 << 10)
            guard deletion.status == 0 else {
                return WorktreeRemoveResult(path: path, outcome: .removed, branch: branch, message: GitCommand.message(deletion))
            }
            return WorktreeRemoveResult(path: path, outcome: .removed, branch: branch, branchDeleted: true)
        } catch {
            return WorktreeRemoveResult(path: path, outcome: .removed, branch: branch, message: "\(error)")
        }
    }

    // MARK: 判定

    /// 1 つの worktree の消せない理由。git が答えられなかった項目があれば、消せる側に倒さず `unknown` を足す
    private func assess(_ checkout: WorktreeGit.Checkout, in repo: Repo, _ occupants: [Occupant]) async -> WorktreeInfo {
        var info = WorktreeInfo(path: checkout.path, repo: repo.main, branch: checkout.branch, hasWorkspace: false)
        if checkout.path == repo.main || checkout.isBare {
            info.blockers = [WorktreeBlocker(.main)]
            return info
        }
        if checkout.isLocked { info.blockers.append(WorktreeBlocker(.locked)) }
        guard !checkout.isPrunable, FileManager.default.fileExists(atPath: checkout.path) else {
            info.blockers.append(WorktreeBlocker(.missing))
            return info
        }
        info.users = occupants.filter { $0.cwds.contains { Self.isInside($0, of: checkout.path) } }.map(\.user)
        if !info.users.isEmpty { info.blockers.append(WorktreeBlocker(.inUse, count: info.users.count)) }
        do {
            let status = WorktreeGit.parseStatus(try await Self.output(checkout.path, ["status", "--porcelain=v1", "-z", "--untracked-files=normal"]))
            if status.changed > 0 { info.blockers.append(WorktreeBlocker(.uncommitted, count: status.changed)) }
            if status.untracked > 0 { info.blockers.append(WorktreeBlocker(.untracked, count: status.untracked)) }
            if let branch = checkout.branch {
                try await assessBranch(branch, in: repo, into: &info)
            } else {
                info.blockers.append(WorktreeBlocker(.noBranch))
            }
        } catch {
            info.blockers.append(WorktreeBlocker(.unknown))
        }
        return info
    }

    private func assessBranch(_ branch: String, in repo: Repo, into info: inout WorktreeInfo) async throws {
        let ref = "refs/heads/\(branch)"
        let refs = WorktreeGit.parseRefs(try await Self.output(repo.main, ["for-each-ref", "--format=%(refname)\t%(upstream)", "refs/heads", "refs/remotes"]))
        let unpushed = try await Self.count(repo.main, [ref, "--not", "--remotes"])
        if unpushed > 0 { info.blockers.append(WorktreeBlocker(.unpushed, count: unpushed)) }
        guard let base = WorktreeGit.base(branch: branch, upstream: refs[ref] ?? nil, refs: Set(refs.keys)) else {
            info.blockers.append(WorktreeBlocker(.noBase))
            return
        }
        info.base = WorktreeGit.shortName(base)
        let unmerged = try await Self.count(repo.main, ["\(base)..\(ref)"])
        if unmerged > 0 { info.blockers.append(WorktreeBlocker(.unmerged, count: unmerged)) }
    }

    // MARK: git

    /// repo の本体と、その worktree（本体を含む）
    private struct Repo: Sendable {
        var main: String
        var checkouts: [WorktreeGit.Checkout]
    }

    /// `path` を含む repo。git の外なら nil
    private static func repo(containing path: String) async throws -> Repo? {
        let outcome = try await GitCommand.run(path, ["worktree", "list", "--porcelain", "-z"], limit: 4 << 20)
        guard outcome.status == 0, !outcome.timedOut else { return nil }
        let checkouts = WorktreeGit.parseWorktreeList(outcome.stdout).map { checkout -> WorktreeGit.Checkout in
            var checkout = checkout
            checkout.path = realPath(checkout.path)
            return checkout
        }
        guard let main = checkouts.first else { return nil }
        return Repo(main: main.path, checkouts: checkouts)
    }

    private func discoverRepos(from directories: [String]) async -> [Repo] {
        var repos: [Repo] = []
        var seen = Set<String>()
        for directory in Set(directories).sorted() where FileManager.default.fileExists(atPath: directory) {
            guard let repo = try? await Self.repo(containing: directory), seen.insert(repo.main).inserted else { continue }
            repos.append(repo)
        }
        return repos
    }

    private static func output(_ directory: String, _ arguments: [String]) async throws -> Data {
        let outcome = try await GitCommand.run(directory, arguments, limit: 8 << 20)
        guard outcome.status == 0, !outcome.timedOut, !outcome.overflowed else { throw GitFailure(message: GitCommand.message(outcome)) }
        return outcome.stdout
    }

    private static func count(_ directory: String, _ revisions: [String]) async throws -> Int {
        let text = String(decoding: try await output(directory, ["rev-list", "--count"] + revisions), as: UTF8.self)
        guard let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw GitFailure(message: "rev-list の出力が数でない") }
        return count
    }

    // MARK: パス

    /// symlink を解いたパス（git は解いたパスで答えるので、比べる前にそろえる）。存在しなければそのまま
    static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isInside(_ cwd: String, of root: String) -> Bool {
        let path = realPath(cwd)
        return path == root || path.hasPrefix(root + "/")
    }
}
