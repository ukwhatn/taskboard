import TaskboardKit

/// PR の head のチェック 1 件。`gh pr view --json statusCheckRollup` の配列の 1 件と、
/// GraphQL の `statusCheckRollup.contexts`（`CheckRollup.contextsQuery` で同じ鍵に揃えたもの）の 1 件を、同じ形で読む
struct CheckContext: Decodable, Sendable {
    var __typename: String
    // CheckRun
    var name: String?
    /// gh の配列にだけある。GraphQL では `checkSuite` から引く
    var workflowName: String?
    var checkSuite: CheckSuite?
    var status: String?
    var conclusion: String?
    var detailsUrl: String?
    // StatusContext
    var context: String?
    var state: String?
    var targetUrl: String?
    /// StatusContext は作られた時刻
    var startedAt: String?

    struct CheckSuite: Decodable, Sendable {
        struct Run: Decodable, Sendable {
            struct Workflow: Decodable, Sendable { var name: String }
            var workflow: Workflow?
        }
        var workflowRun: Run?
    }

    var isCheckRun: Bool { __typename == "CheckRun" }
    var workflow: String? { workflowName ?? checkSuite?.workflowRun?.workflow?.name }
}

/// CI のまとめ。PR の一覧・中身（`PullRequestQueries`）とリンク（`PullRequestView`）が同じ規則で `CheckState` にする
enum CheckRollup {
    /// GraphQL で contexts を取る断片。鍵は gh の `statusCheckRollup` の配列に揃える
    static let contextsQuery = """
        commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { __typename
          ... on CheckRun { name status conclusion startedAt detailsUrl checkSuite { workflowRun { workflow { name } } } }
          ... on StatusContext { context state startedAt: createdAt targetUrl } } } } } } }
        """

    /// GraphQL の `statusCheckRollup.state` と同じ結果にまとめる。
    /// 配列は再実行前の run も含むので、同じチェック（CheckRun は workflow 名 + 名前、StatusContext は context）の最新だけを見る。
    /// 失敗が 1 つでもあれば実行中があっても FAILURE（rust-lang/rust#163735 の実出力で確認）
    static func state(_ checks: [CheckContext]) -> CheckState? {
        let states = Set(latest(checks).compactMap(state(of:)))
        guard !states.isEmpty else { return nil }
        for candidate: CheckState in [.failure, .error, .pending, .expected] where states.contains(candidate) { return candidate }
        return .success
    }

    /// 落ちたチェックの名前（同じチェックは最新の run だけ）
    static func failedNames(_ checks: [CheckContext]) -> [String] {
        latest(checks).filter { state(of: $0)?.isFailing == true }.map { ($0.isCheckRun ? $0.name : $0.context) ?? "" }.filter { !$0.isEmpty }
    }

    /// 同じチェックの最新の run だけ（元の並びの順）
    private static func latest(_ checks: [CheckContext]) -> [CheckContext] {
        var latest: [String: (index: Int, check: CheckContext)] = [:]
        for (index, check) in checks.enumerated() {
            let key = check.isCheckRun ? "run|\(check.workflow ?? "")|\(check.name ?? "")" : "status|\(check.context ?? "")"
            if let existing = latest[key], (existing.check.startedAt ?? "") > (check.startedAt ?? "") { continue }
            latest[key] = (latest[key]?.index ?? index, check)
        }
        return latest.values.sorted { $0.index < $1.index }.map(\.check)
    }

    private static func state(of check: CheckContext) -> CheckState? {
        guard check.isCheckRun else { return check.state.flatMap { CheckState(rawValue: $0.uppercased()) } }
        guard check.status?.uppercased() == "COMPLETED" else { return .pending }
        switch check.conclusion?.uppercased() {
        case "SUCCESS", "NEUTRAL", "SKIPPED": return .success
        default: return .failure
        }
    }
}
