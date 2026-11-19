import Foundation

extension Fleet {
    /// 同じアカウントの同じ PR を 1 つにする（取ったマシンが違っても）。違うアカウントの同じ PR は別々に残す（区分がアカウントから見た区分なので）。
    /// 残すのは `updatedAt` の新しい方。同じなら machine の id の小さい方（辞書の順に左右されないように）
    nonisolated static func mergedByAccount(_ states: [MachineState]) -> [String: PullRequestSummary] {
        var merged: [String: PullRequestSummary] = [:]
        for pr in states.flatMap({ $0.prs?.pullRequests ?? [] }) {
            let key = pr.accountScopedID
            if let current = merged[key], (current.updatedAt, pr.machine.rawValue) >= (pr.updatedAt, current.machine.rawValue) { continue }
            merged[key] = pr
        }
        return merged
    }

    /// 新しい順
    nonisolated static func newestFirst(_ prs: some Sequence<PullRequestSummary>) -> [PullRequestSummary] {
        prs.sorted { ($0.updatedAt, $0.url, $0.account) > ($1.updatedAt, $1.url, $1.account) }
    }
}

extension PullRequestSummary {
    /// 取ったアカウントと URL の組。同じ PR を 2 つのアカウントが見ているとき、一覧の行を分ける（`id` の URL だけだと、片方の行が描かれない）
    public var accountScopedID: String { "\(host)|\(account)|\(url)" }
}
