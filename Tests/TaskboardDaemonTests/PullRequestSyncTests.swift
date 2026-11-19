import Foundation
import TaskboardKit
import Testing
import TestSupport

@testable import TaskboardDaemon

/// gh の代わりに置くスクリプト。`auth status` と `auth token` に答え、`api graphql` は検索語ごとに応答を返す。
/// `fail` があれば api を失敗させ、stderr に環境の token をそのまま書く（gh が token を漏らした最悪の場合）。`ratelimit` があれば api を rate limit で断る
private struct FakeGH {
    static let token = "ghp_FAKE0123456789abcdefghijklmnopqrstuv"
    static let shared = SharedExecutable(
        name: "tb-test-sync-gh-v2.sh",
        script: """
            #!/bin/sh
            D="$(dirname "$0")"
            if [ "$1" = auth ] && [ "$2" = status ]; then
              [ -f "$D/statusfail" ] && exit 1
              [ -f "$D/status.json" ] && { cat "$D/status.json"; exit 0; }
              echo '{"hosts":{"github.com":[{"login":"alice","state":"success","active":true}],"ghe.example":[{"login":"bob","state":"error","active":true}]}}'; exit 0
            fi
            if [ "$1" = auth ] && [ "$2" = token ]; then echo "\(token)"; exit 0; fi
            if [ "$1" = api ]; then
              [ -f "$D/fail" ] && { echo "HTTP 401: Bad credentials (token $GH_TOKEN)" >&2; exit 1; }
              [ -f "$D/ratelimit" ] && { echo 'HTTP 403: API rate limit exceeded for user' >&2; exit 1; }
              case "$*" in
                *review-requested*) cat "$D/requested.json" ;;
                *reviewed-by*) cat "$D/reviewed.json" ;;
                *author:@me*) cat "$D/authored.json" ;;
                *) echo '{"data":{"resource":null}}' ;;
              esac
              exit 0
            fi
            exit 2

            """)

    let directory: URL
    let executable: URL

    init(searchResponses: [String: String], fail: Bool = false, rateLimit: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fakegh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (key, body) in searchResponses {
            try body.write(to: directory.appendingPathComponent("\(key).json"), atomically: true, encoding: .utf8)
        }
        for (name, on) in [("fail", fail), ("ratelimit", rateLimit)] where on {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        executable = try Self.shared.link(in: directory, as: "gh")
    }
}

private let passed = #"[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-03T09:00:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]"#

private func searchJSON(_ nodes: [String]) -> String {
    #"{"data":{"search":{"nodes":["# + nodes.joined(separator: ",") + "]}}}"
}

/// `checks` は head の contexts（`CheckRollup.contextsQuery` の形）。nil ならチェックの無い PR
private func node(_ number: Int, repo: String = "o/r", draft: Bool = false, author: String = "alice", authorType: String = "User", checks: String? = passed, decision: String? = nil, updated: String = "2026-10-03T10:00:00Z") -> String {
    let rollup = checks.map { #"{"contexts":{"nodes":\#($0)}}"# } ?? "null"
    let decisionJSON = decision.map { "\"\($0)\"" } ?? "null"
    return """
        {"number":\(number),"title":"PR \(number)","url":"https://github.com/\(repo)/pull/\(number)","isDraft":\(draft),"createdAt":"2026-10-01T00:00:00Z","updatedAt":"\(updated)","headRefName":"feature/\(number)","reviewDecision":\(decisionJSON),"additions":10,"deletions":2,"changedFiles":3,"repository":{"nameWithOwner":"\(repo)"},"author":{"login":"\(author)","__typename":"\(authorType)"},"commits":{"nodes":[{"commit":{"statusCheckRollup":\(rollup)}}]},"latestReviews":{"nodes":[{"author":{"login":"carol"},"state":"COMMENTED"}]},"reviewRequests":{"nodes":[{"requestedReviewer":{"login":"alice"}},{"requestedReviewer":{"name":"core-team"}}]}}
        """
}

@Suite("PR の取得: 4 区分・キャッシュ・token を漏らさない")
struct PullRequestSyncTests {
    private let machine = MachineID(rawValue: "m-test")

    private func makeSync(_ gh: FakeGH, clock: @escaping @Sendable () -> Date = Date.init) throws -> (PullRequestSync, Store, DaemonState) {
        let (sync, store, state, _) = try makeSyncWithCLI(gh, clock: clock)
        return (sync, store, state)
    }

    private func makeSyncWithCLI(_ gh: FakeGH, clock: @escaping @Sendable () -> Date = Date.init) throws -> (PullRequestSync, Store, DaemonState, GitHubCLI) {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let cli = GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: gh.executable, now: clock)
        return (PullRequestSync(store: store, state: state, cli: cli, machine: machine, now: clock), store, state, cli)
    }

    @Test("3 本の検索を 4 区分にまとめる。頼まれた PR は「未レビュー」を優先、自分の PR は draft で分ける。権限の無い空 node は落とす")
    func classify() async throws {
        let gh = try FakeGH(searchResponses: [
            "requested": searchJSON([node(1, author: "dave"), node(2, author: "dependabot", authorType: "Bot"), "{}"]),
            "reviewed": searchJSON([node(2, author: "dependabot", authorType: "Bot"), node(3, author: "frank", checks: nil)]),
            "authored": searchJSON([node(4, draft: true), node(5, decision: "APPROVED", updated: "2026-10-03T11:00:00Z")]),
        ])
        let (sync, store, state) = try makeSync(gh)
        let snapshot = await sync.refresh(force: true)
        let byNumber = Dictionary(uniqueKeysWithValues: snapshot.pullRequests.map { ($0.number, $0) })
        #expect(byNumber.mapValues(\.category) == [1: .reviewRequested, 2: .reviewRequested, 3: .reviewed, 4: .myDraft, 5: .myReady])
        #expect(snapshot.pullRequests.first?.number == 5, "新しい順")
        #expect(byNumber[3]?.checks == nil && byNumber[1]?.checks == .success && byNumber[5]?.reviewDecision == "APPROVED")
        #expect(byNumber[2]?.authorIsBot == true && byNumber[1]?.authorIsBot == false, "作者の種類（__typename）が Bot かを持つ")
        #expect(byNumber[1]?.requestedReviewers == ["alice", "core-team"] && byNumber[1]?.latestReviews == [PRReviewer(login: "carol", state: "COMMENTED")])
        #expect(snapshot.accounts.map(\.id) == ["github.com|alice"], "state が error のアカウントは取らない")
        #expect(snapshot.accounts.first?.error == nil && snapshot.notices.isEmpty, "初回は知らせない")
        #expect(await state.snapshot().prs == snapshot, "state に載って配られる")
        #expect(try store.cachedPullRequests().first?.pullRequests.count == 5, "取れた一覧は保存する")

        // 再起動: 保存した一覧が先に出る
        let state2 = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let restarted = PullRequestSync(store: store, state: state2, cli: GitHubCLI(environment: [:], executable: gh.executable), machine: machine)
        await restarted.loadCache()
        #expect(await state2.snapshot().prs?.pullRequests.count == 5)
    }

    @Test("gh がアカウントの状態を確かめられなかった（timeout・auth status の失敗）ときは、前の PR と控えを残す。一覧から消えたアカウントだけ外す")
    func keepsAccountsWhenStatusUncertain() async throws {
        let gh = try FakeGH(searchResponses: [
            "requested": searchJSON([]), "reviewed": searchJSON([]), "authored": searchJSON([node(4), node(5)]),
        ])
        let (sync, store, _) = try makeSync(gh)
        #expect(await sync.refresh(force: true).pullRequests.count == 2)

        try #"{"hosts":{"github.com":[{"login":"alice","state":"timeout","active":true}]}}"#.write(
            to: gh.directory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        #expect(await sync.refresh(force: true).pullRequests.count == 2, "timeout はログアウトでない")
        #expect(try store.cachedPullRequests().first?.pullRequests.count == 2)

        try Data().write(to: gh.directory.appendingPathComponent("statusfail"))
        #expect(await sync.refresh(force: true).pullRequests.count == 2, "auth status が読めないときも残す")
        #expect(try store.cachedPullRequests().first?.pullRequests.count == 2)

        try FileManager.default.removeItem(at: gh.directory.appendingPathComponent("statusfail"))
        try #"{"hosts":{"github.com":[]}}"#.write(to: gh.directory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        let dropped = await sync.refresh(force: true)
        #expect(dropped.pullRequests.isEmpty && dropped.accounts.isEmpty, "一覧から消えたら外す")
        #expect(try store.cachedPullRequests().isEmpty)
    }

    @Test("gh が stderr に token を書いて失敗しても、状態・保存・配る JSON に token は出ない")
    func tokenNeverLeaks() async throws {
        let gh = try FakeGH(searchResponses: [:], fail: true)
        let (sync, store, state) = try makeSync(gh)
        let snapshot = await sync.refresh(force: true)
        let error = try #require(snapshot.accounts.first?.error)
        #expect(error.contains("Bad credentials") && error.contains("<token>"), "\(error)")
        let wire = String(decoding: try WireJSON.encoder().encode(await state.snapshot()), as: UTF8.self)
        #expect(!wire.contains(FakeGH.token) && !error.contains(FakeGH.token))
        #expect(try store.cachedPullRequests().isEmpty)
        let detailError = await #expect(throws: GitHubCLI.Failure.self) { try await sync.detail(url: "https://github.com/o/r/pull/1") }
        #expect(!(detailError?.description.contains(FakeGH.token) ?? true))
    }

    @Test("rate limit の待ちは 2 分から倍にし、明けるまで手動の更新でも取らない。取り直しは 5 分より早めない。受信箱のお知らせに出る")
    func rateLimitBacksOff() async throws {
        let gh = try FakeGH(searchResponses: [:], rateLimit: true)
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let clock = Clock(start)
        let (sync, _, state) = try makeSync(gh, clock: { clock.now })
        let first = await sync.refresh(force: true)
        let status = try #require(first.accounts.first)
        #expect(status.rateLimited && status.nextFetchAt == start.addingTimeInterval(300), "待ちは 2 分でも 5 分は空ける: \(status)")
        clock.advance(60)
        let again = await sync.refresh(force: true)
        #expect(again.accounts.first?.fetchedAt == nil && again.accounts.first?.nextFetchAt == status.nextFetchAt, "rate limit 中は手動でも取らない")
        clock.advance(240)
        let third = await sync.refresh(force: false)
        #expect(third.accounts.first?.nextFetchAt == clock.now.addingTimeInterval(300), "2 回目の待ちは 4 分")
        clock.advance(300)
        let fourth = await sync.refresh(force: false)
        #expect(fourth.accounts.first?.nextFetchAt == clock.now.addingTimeInterval(480), "3 回目は 8 分で、5 分を超える")
        var machineState = MachineState(machine: await state.snapshot().machine)
        machineState.apply(.stateSnapshot(await state.snapshot()))
        #expect(machineState.inboxItems(now: clock.now).contains { $0.localID == "prsync/github.com|alice" && $0.title.contains("GitHubの利用の上限") })
    }

    @Test("リンクの取得（GitHubSync）で同じアカウントが rate limit に当たっていたら、PR の一覧も明けるまで手動でも取らない")
    func sharesRateLimitWithLinks() async throws {
        let gh = try FakeGH(searchResponses: ["requested": searchJSON([]), "reviewed": searchJSON([]), "authored": searchJSON([node(1)])])
        let clock = Clock(Date(timeIntervalSince1970: 1_791_000_000))
        let (sync, _, _, cli) = try makeSyncWithCLI(gh, clock: { clock.now })
        await cli.noteRateLimit(GitHubCLI.Account(host: "github.com", login: "alice"))
        #expect(await sync.refresh(force: true).pullRequests.isEmpty)
        clock.advance(GitHubCLI.firstRateLimitWait)
        #expect(await sync.refresh(force: true).pullRequests.map(\.number) == [1])
        #expect(await cli.rateLimitedUntil(GitHubCLI.Account(host: "github.com", login: "alice")) == nil)
    }

    @Test("CI のまとめは、一覧・中身（GraphQL の contexts）とリンク（gh pr view の配列）で同じ規則。再実行は最新の run だけ、失敗は実行中より先")
    func sameRollupEverywhere() throws {
        let rerun = #"""
            [{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-03T09:00:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},
             {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-03T09:30:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},
             {"__typename":"StatusContext","context":"tide","state":"SUCCESS","startedAt":"2026-10-03T09:00:00Z"}]
            """#
        let failing = #"""
            [{"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-10-03T09:00:00Z","checkSuite":null},
             {"__typename":"StatusContext","context":"deploy","state":"FAILURE","startedAt":"2026-10-03T09:00:00Z"}]
            """#
        let running = #"[{"__typename":"CheckRun","name":"lint","status":"QUEUED","conclusion":null,"startedAt":"2026-10-03T09:00:00Z","checkSuite":null}]"#
        for (contexts, expected) in [(rerun, CheckState.success), (failing, .failure), (running, .pending), ("[]", nil)] as [(String, CheckState?)] {
            let listed = try PullRequestQueries.parseSearch(Data(searchJSON([node(1, checks: contexts)]).utf8)).first?.commits.flatMap { CheckRollup.state($0.contexts) }
            let detail = try PullRequestQueries.parseDetail(
                Data(#"{"data":{"resource":{"number":1,"url":"https://github.com/o/r/pull/1","repository":{"nameWithOwner":"o/r"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":\#(contexts)}}}}]}}}}"#.utf8),
                fetchedAt: Date())
            // gh pr view の配列は CheckRun の workflow を workflowName に平らにして返す
            let flat = contexts.replacingOccurrences(of: #""checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}"#, with: #""workflowName":"CI""#)
            let linked = try PullRequestView.parse(Data(#"{"state":"OPEN","isDraft":false,"statusCheckRollup":\#(flat)}"#.utf8)).linkState?.checks
            #expect(listed == expected && detail.checkState == expected && linked == expected, "\(contexts)")
        }
    }

    @Test("中身: チェック（CheckRun と StatusContext）・レビュー・ファイルを読む。PR でない URL は notAPullRequest")
    func parseDetail() throws {
        let json = """
            {"data":{"resource":{"number":7,"title":"t","url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,"body":"本文","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-02T00:00:00Z","mergedAt":null,"baseRefName":"main","headRefName":"f","additions":3,"deletions":1,"changedFiles":2,"reviewDecision":"CHANGES_REQUESTED","mergeable":"CONFLICTING","repository":{"nameWithOwner":"o/r"},"author":{"login":"a"},
            "files":{"nodes":[{"path":"a.swift","additions":3,"deletions":0,"changeType":"ADDED"},{"path":"b.swift","additions":0,"deletions":1,"changeType":"MODIFIED"}]},
            "reviews":{"nodes":[{"author":{"login":"b"},"state":"CHANGES_REQUESTED","body":"直して","submittedAt":"2026-10-02T00:00:00Z"}]},
            "comments":{"totalCount":4},
            "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
              {"__typename":"CheckRun","name":"test","conclusion":"FAILURE","status":"COMPLETED","detailsUrl":"https://x/1","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},
              {"__typename":"CheckRun","name":"lint","conclusion":null,"status":"IN_PROGRESS","detailsUrl":null,"checkSuite":null},
              {"__typename":"StatusContext","context":"deploy/preview","state":"SUCCESS","targetUrl":"https://x/2"}]}}}}]}}}}
            """
        let detail = try PullRequestQueries.parseDetail(Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 0))
        #expect(detail.shortLabel == "o/r#7" && detail.mergeable == "CONFLICTING" && detail.checkState == .failure && detail.commentCount == 4)
        #expect(detail.checks == [
            PullRequestDetail.Check(name: "test", workflow: "CI", state: "FAILURE", url: "https://x/1"),
            PullRequestDetail.Check(name: "lint", state: "IN_PROGRESS"),
            PullRequestDetail.Check(name: "deploy/preview", state: "SUCCESS", url: "https://x/2"),
        ])
        #expect(detail.files.map(\.changeType) == ["ADDED", "MODIFIED"] && detail.reviews.first?.body == "直して")
        #expect(throws: PullRequestQueries.ParseError.notAPullRequest) {
            try PullRequestQueries.parseDetail(Data(#"{"data":{"resource":null}}"#.utf8), fetchedAt: Date())
        }
        #expect(throws: PullRequestQueries.ParseError.graphQL(type: "RATE_LIMITED", message: "API rate limit exceeded")) {
            try PullRequestQueries.parseSearch(Data(#"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#.utf8))
        }
    }
}

/// テストで進める時計
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
