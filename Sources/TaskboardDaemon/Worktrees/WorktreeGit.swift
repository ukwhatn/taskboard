import Foundation

/// git の出力の読み方と、未マージを比べる先の決め方（どちらも純関数）
enum WorktreeGit {
    struct Checkout: Equatable {
        var path: String
        var branch: String?
        var isBare = false
        var isLocked = false
        var isPrunable = false
    }

    /// `git worktree list --porcelain -z`。先頭の 1 件が repo の本体
    static func parseWorktreeList(_ data: Data) -> [Checkout] {
        var checkouts: [Checkout] = []
        var current: Checkout?
        for field in data.split(separator: 0, omittingEmptySubsequences: false).map({ String(decoding: $0, as: UTF8.self) }) {
            if field.isEmpty {
                if let finished = current { checkouts.append(finished) }
                current = nil
            } else if field.hasPrefix("worktree ") {
                if let finished = current { checkouts.append(finished) }
                current = Checkout(path: String(field.dropFirst("worktree ".count)))
            } else if field.hasPrefix("branch refs/heads/") {
                current?.branch = String(field.dropFirst("branch refs/heads/".count))
            } else if field == "bare" {
                current?.isBare = true
            } else if field == "locked" || field.hasPrefix("locked ") {
                current?.isLocked = true
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                current?.isPrunable = true
            }
        }
        if let finished = current { checkouts.append(finished) }
        return checkouts
    }

    /// `git status --porcelain=v1 -z` の件数。追跡しているファイルの変更と、追跡していないファイル（無視されたものは出ない）
    static func parseStatus(_ data: Data) -> (changed: Int, untracked: Int) {
        var changed = 0
        var untracked = 0
        var fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }[...]
        while let entry = fields.popFirst() {
            if entry.hasPrefix("??") {
                untracked += 1
            } else if entry.hasPrefix("!!") {
                continue
            } else {
                changed += 1
                // rename と copy は元のパスが続く
                if entry.first == "R" || entry.first == "C" || entry.dropFirst().first == "R" || entry.dropFirst().first == "C" { _ = fields.popFirst() }
            }
        }
        return (changed, untracked)
    }

    /// `git for-each-ref --format=%(refname)\t%(upstream)` の行（ref の全名と upstream の全名）
    static func parseRefs(_ data: Data) -> [String: String?] {
        var refs: [String: String?] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { continue }
            let upstream = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
            refs[String(name)] = upstream
        }
        return refs
    }

    /// 未マージを比べる先。次の順で最初に当たる ref の全名（無ければ nil）:
    /// 1. ブランチの upstream が別の名前のブランチ（`origin/develop` から切って追跡している）
    /// 2. `origin/develop`・`origin/main`・`origin/master`
    /// 3. ローカルの `develop`・`main`・`master`
    /// ブランチ自身と同じ名前のものは使わない
    static func base(branch: String, upstream: String?, refs: Set<String>) -> String? {
        if let upstream, refs.contains(upstream), branchName(of: upstream) != branch { return upstream }
        let names = ["develop", "main", "master"].filter { $0 != branch }
        for prefix in ["refs/remotes/origin/", "refs/heads/"] {
            if let found = names.map({ prefix + $0 }).first(where: refs.contains) { return found }
        }
        return nil
    }

    /// 画面に出す名前（`origin/develop`・`develop`）
    static func shortName(_ ref: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/"] where ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    }

    private static func branchName(of ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        if ref.hasPrefix("refs/remotes/") {
            let rest = ref.dropFirst("refs/remotes/".count)
            return rest.firstIndex(of: "/").map { String(rest[rest.index(after: $0)...]) } ?? String(rest)
        }
        return ref
    }
}
