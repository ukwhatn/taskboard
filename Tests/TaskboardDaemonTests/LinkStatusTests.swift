import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// `gh pr view <url> --json state,isDraft,statusCheckRollup,reviewDecision` の実出力（2026-10-04 取得、配列は抜粋）。
/// 期待値は同じ PR の GraphQL `commits(last: 1) { statusCheckRollup { state } }`
private enum Fixture {
    /// swiftlang/swift-format#1292（GraphQL: SUCCESS）。失敗した 2 つのチェックを再実行して通している
    static let rerun = #"""
        {"state":"MERGED","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[{"__typename":"CheckRun","completedAt":"2026-09-15T21:41:08Z","conclusion":"FAILURE","detailsUrl":"https://github.com/swiftlang/swift-format/actions/runs/35026794710/job/104575632776","name":"Test / Linux (6.3 - jammy - x86_64)","startedAt":"2026-09-15T21:38:57Z","status":"COMPLETED","workflowName":"Pull request"},{"__typename":"CheckRun","completedAt":"2026-09-15T21:48:06Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/swiftlang/swift-format/actions/runs/35027287961/job/104577236729","name":"Test / Linux (6.3 - jammy - x86_64)","startedAt":"2026-09-15T21:44:24Z","status":"COMPLETED","workflowName":"Pull request"},{"__typename":"CheckRun","completedAt":"2026-09-15T21:50:17Z","conclusion":"FAILURE","detailsUrl":"https://github.com/swiftlang/swift-format/actions/runs/35026794710/job/104575633224","name":"Test / Windows (nightly-6.3 - windows-2022)","startedAt":"2026-09-15T21:38:57Z","status":"COMPLETED","workflowName":"Pull request"},{"__typename":"CheckRun","completedAt":"2026-09-15T22:01:01Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/swiftlang/swift-format/actions/runs/35027287961/job/104577236633","name":"Test / Windows (nightly-6.3 - windows-2022)","startedAt":"2026-09-15T21:44:24Z","status":"COMPLETED","workflowName":"Pull request"},{"__typename":"CheckRun","completedAt":"2026-09-15T21:38:54Z","conclusion":"SKIPPED","detailsUrl":"https://github.com/swiftlang/swift-format/actions/runs/35026794710/job/104575633734","name":"Test / macOS (Xcode ${{ matrix.xcode_version }} - ${{ matrix.os_version }} - ${{ matrix.arch }})","startedAt":"2026-09-15T21:38:55Z","status":"COMPLETED","workflowName":"Pull request"}]}
        """#
    /// rust-lang/rust#163735（GraphQL: FAILURE）。失敗と実行中が混ざっている
    static let failingWhileRunning = #"""
        {"state":"OPEN","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"__typename":"CheckRun","completedAt":"2026-10-04T02:32:04Z","conclusion":"FAILURE","detailsUrl":"https://bors.rust-lang.org","name":"Bors try build","startedAt":"2026-10-04T02:31:10Z","status":"COMPLETED","workflowName":""},{"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"","detailsUrl":"https://github.com/rust-lang/rust/actions/runs/37171285200/job/111344691424","name":"PR - test-aarch64-gnu-llvm-22-1","startedAt":"2026-10-04T02:31:44Z","status":"IN_PROGRESS","workflowName":"CI"},{"__typename":"CheckRun","completedAt":"2026-10-04T02:31:40Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/rust-lang/rust/actions/runs/37171285200/job/111344568316","name":"Calculate job matrix","startedAt":"2026-10-04T02:30:55Z","status":"COMPLETED","workflowName":"CI"}]}
        """#
    /// microsoft/vscode#339543（GraphQL: PENDING）。QUEUED と IN_PROGRESS
    static let queued = #"""
        {"state":"OPEN","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"","detailsUrl":"https://github.com/apps/microsoft-github-policy-service","name":"license/cla","startedAt":"2026-10-04T02:23:02Z","status":"QUEUED","workflowName":""},{"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"","detailsUrl":"https://code.visualstudio.com","name":"VS Code PR Check","startedAt":"2026-10-04T02:28:19Z","status":"IN_PROGRESS","workflowName":""},{"__typename":"CheckRun","completedAt":"2026-10-04T02:23:27Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/microsoft/vscode-engineering/actions/runs/37170875891","name":"Dependencies Check","startedAt":"2026-10-04T02:23:26Z","status":"COMPLETED","workflowName":""}]}
        """#
    /// kubernetes/kubernetes#142656（GraphQL: PENDING）。StatusContext だけ。gh は同じ context を重ねて返すことがある
    static let statusContexts = #"""
        {"state":"OPEN","isDraft":false,"reviewDecision":"","statusCheckRollup":[{"__typename":"StatusContext","context":"tide","startedAt":"2026-10-04T00:50:09Z","state":"PENDING","targetUrl":"https://prow.k8s.io/pr?query=is%3Apr+repo%3Akubernetes%2Fkubernetes+author%3Adims+head%3Akubeadm-dryrun-roundtripper"},{"__typename":"StatusContext","context":"tide","startedAt":"2026-10-04T00:50:09Z","state":"PENDING","targetUrl":"https://prow.k8s.io/pr?query=is%3Apr+repo%3Akubernetes%2Fkubernetes+author%3Adims+head%3Akubeadm-dryrun-roundtripper"},{"__typename":"StatusContext","context":"EasyCLA","startedAt":"2026-10-04T00:49:59Z","state":"SUCCESS","targetUrl":"https://easycla.lfx.linuxfoundation.org/#/?version=2"}]}
        """#
    /// swiftlang/swift#92893（GraphQL: FAILURE）。StatusContext の失敗
    static let statusFailure = #"""
        {"state":"OPEN","isDraft":false,"reviewDecision":"","statusCheckRollup":[{"__typename":"StatusContext","context":"Swift Test Linux Platform (Ubuntu 22.04) (x86_64)","startedAt":"2026-10-04T01:47:24Z","state":"FAILURE","targetUrl":"https://ci.swift.org/job/swift-PR-Linux/30820/"},{"__typename":"StatusContext","context":"Swift Test Windows Platform (x86_64)","startedAt":"2026-10-04T02:14:56Z","state":"SUCCESS","targetUrl":"https://ci-external.swift.org/job/swift-PR-windows/62422/"},{"__typename":"StatusContext","context":"Swift Test macOS Platform (arm64)","startedAt":"2026-10-04T01:37:26Z","state":"SUCCESS","targetUrl":"https://ci.swift.org/job/swift-PR-macos-arm64/5416/"}]}
        """#
    /// swiftlang/swift-format#1309（GraphQL: null）。チェックが無い
    static let noChecks = #"{"state":"OPEN","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[]}"#
}

private func view(_ json: String) throws -> PullRequestLinkState? {
    try PullRequestView.parse(Data(json.utf8)).linkState
}

@Suite("リンクの状態")
struct LinkStatusTests {
    @Test("statusCheckRollup を GraphQL の state と同じ規則でまとめる")
    func rollup() throws {
        #expect(try view(Fixture.rerun) == PullRequestLinkState(state: .merged, isDraft: false, checks: .success, reviewDecision: "APPROVED"))
        #expect(try view(Fixture.failingWhileRunning)?.checks == .failure)
        #expect(try view(Fixture.queued)?.checks == .pending)
        #expect(try view(Fixture.statusContexts) == PullRequestLinkState(state: .open, isDraft: false, checks: .pending, reviewDecision: nil))
        #expect(try view(Fixture.statusFailure)?.checks == .failure)
        #expect(try view(Fixture.noChecks) == PullRequestLinkState(state: .open, isDraft: false, checks: nil, reviewDecision: "REVIEW_REQUIRED"))
    }

    @Test("draft と知らない状態")
    func states() throws {
        #expect(try view(#"{"state":"OPEN","isDraft":true,"reviewDecision":"","statusCheckRollup":[]}"#)?.isDraft == true)
        #expect(try view(#"{"state":"CLOSED","isDraft":false,"reviewDecision":"","statusCheckRollup":[]}"#)?.state == .closed)
        #expect(try view(#"{"state":"LOCKED","isDraft":false,"reviewDecision":"","statusCheckRollup":[]}"#) == nil)
    }

    @Test("gh の失敗文は最初の行だけを画面に出す")
    func firstLine() {
        #expect(GitHubSync.firstLine("\n  GraphQL: Could not resolve to a PullRequest  \nsecond") == "GraphQL: Could not resolve to a PullRequest")
        #expect(GitHubSync.firstLine(" \n") == "gh が失敗しました")
    }

    private static let machine = MachineID(rawValue: "m")
    private static let pr = "https://github.com/o/r/pull/1"
    private static let jira = "https://x.atlassian.net/browse/ABC-1"

    private static func task(_ number: Int, _ urls: [String]) -> BoardTask {
        BoardTask(
            machine: machine, number: number, boardID: "b", columnID: "working", title: "t",
            links: urls.enumerated().map { TaskLink(id: Int64($0.offset), url: $0.element, kind: TaskLink.kind(of: $0.element), addedAt: Date()) },
            createdAt: Date(), updatedAt: Date())
    }

    private static func linkEvents(_ state: DaemonState) async -> AsyncStream<[LinkStatus]> {
        let (_, events) = await state.subscribe()
        return AsyncStream { continuation in
            Task {
                for await event in events { if case .linksUpdated(let links) = event { continuation.yield(links) } }
            }
        }
    }

    @Test("取得の時刻だけが変わったときは配らない。失敗は前回の値を残して理由を足す")
    func broadcastOnlyOnChange() async throws {
        let state = DaemonState(machine: MachineInfo(id: Self.machine, name: "m", daemonVersion: "t"))
        await state.load(boards: [], tasks: [Self.task(1, [Self.pr, Self.jira])])
        var events = await Self.linkEvents(state).makeAsyncIterator()
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        let open = PullRequestLinkState(state: .open, checks: .pending)
        let issue = JiraLinkState(key: "ABC-1", statusName: "進行中", category: .indeterminate)

        await state.record(links: [Self.pr: .pullRequest(open), Self.jira: .jira(issue)], at: t0)
        await state.record(links: [Self.pr: .pullRequest(open)], at: t0.addingTimeInterval(180))
        await state.record(links: [Self.pr: .failed("PR の状態を取得できません: x")], at: t0.addingTimeInterval(360))

        let first = try #require(await events.next())
        #expect(first.map(\.url) == [Self.pr, Self.jira])
        let second = try #require(await events.next())
        let failed = try #require(second.first { $0.url == Self.pr })
        #expect(failed.pullRequest == open)
        #expect(failed.error == "PR の状態を取得できません: x")
        #expect(failed.fetchedAt == t0.addingTimeInterval(180))

        await state.record(links: [Self.pr: .pullRequest(open)], at: t0.addingTimeInterval(540))
        let recovered = try #require(await events.next())
        #expect(recovered.first { $0.url == Self.pr }?.error == nil)
        #expect(await state.snapshot().links.count == 2)
    }

    @Test("タスクから外れたリンク・消えたタスクのリンクは落とす。付いていない URL の結果は入れない")
    func prune() async throws {
        let state = DaemonState(machine: MachineInfo(id: Self.machine, name: "m", daemonVersion: "t"))
        await state.load(boards: [], tasks: [Self.task(1, [Self.pr, Self.jira]), Self.task(2, ["https://github.com/o/r/pull/2"])])
        let open = PullRequestLinkState(state: .open)
        await state.record(links: [
            Self.pr: .pullRequest(open), Self.jira: .jira(JiraLinkState(key: "ABC-1", statusName: "s", category: .new)),
            "https://github.com/o/r/pull/2": .pullRequest(open), "https://github.com/o/r/pull/9": .pullRequest(open),
        ])
        #expect(await state.linkStatuses().map(\.url) == ["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2", Self.jira])

        var events = await Self.linkEvents(state).makeAsyncIterator()
        await state.upsert(Self.task(1, [Self.pr]))
        #expect(try #require(await events.next()).map(\.url) == ["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2"])
        await state.removeTask(number: 2)
        #expect(try #require(await events.next()).map(\.url) == ["https://github.com/o/r/pull/1"])
        #expect(await state.snapshot().links.map(\.url) == [Self.pr])
    }
}
