import Foundation
import Testing

@testable import TaskboardKit

@Suite("PR の変化の知らせと、マシンをまたいだ一覧")
struct PullRequestsTests {
    private let machine = MachineID(rawValue: "m1")
    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    private func pr(
        _ number: Int, _ category: PRCategory = .myReady, checks: CheckState? = .pending, decision: String? = nil, reviews: [PRReviewer] = [],
        machine: MachineID? = nil, updated: TimeInterval = 0, account: String = "me", host: String = "github.com", bot: Bool = false
    ) -> PullRequestSummary {
        PullRequestSummary(
            machine: machine ?? self.machine, host: host, account: account, category: category, url: "https://github.com/o/r/pull/\(number)",
            repository: "o/r", number: number, title: "PR \(number)", author: category == .myReady || category == .myDraft ? "me" : "other",
            isDraft: category == .myDraft, headRef: "f", createdAt: t0, updatedAt: t0.addingTimeInterval(updated), reviewDecision: decision,
            checks: checks, latestReviews: reviews, authorIsBot: bot ? true : nil)
    }

    @Test("初回は何も知らせない。自分の PR の CI 失敗・成功、approve / changes requested、判定の無い repo の新しいレビュー、新しいレビュー依頼を出す")
    func diff() {
        #expect(PRNotice.diff(old: nil, new: [pr(1, .reviewRequested)], at: t0).isEmpty)

        let before = [pr(1, checks: .pending), pr(2, checks: .failure), pr(3, decision: "REVIEW_REQUIRED"), pr(4, decision: nil), pr(5, .reviewed)]
        let after = [
            pr(1, checks: .failure),
            pr(2, checks: .success),
            pr(3, decision: "APPROVED", reviews: [PRReviewer(login: "bob", state: "APPROVED")]),
            pr(4, decision: nil, reviews: [PRReviewer(login: "carol", state: "COMMENTED"), PRReviewer(login: "dan", state: "PENDING")]),
            pr(5, .reviewRequested),
            pr(6, .reviewRequested),
            pr(7, checks: .success),
        ]
        let notices = PRNotice.diff(old: before, new: after, at: t0)
        #expect(notices.map { "\($0.label):\($0.kind.rawValue):\($0.detail)" } == [
            "o/r#1:ciFailed:", "o/r#2:ciPassed:", "o/r#3:approved:bob", "o/r#4:newReview:carol", "o/r#5:reviewRequested:other",
            "o/r#6:reviewRequested:other",
        ])
        #expect(PRNotice.diff(old: after, new: after, at: t0).isEmpty, "変わらなければ出さない")
        #expect(PRNotice.diff(old: [pr(8, .reviewed, checks: .pending)], new: [pr(8, .reviewed, checks: .failure)], at: t0).isEmpty, "他人の PR の CI は知らせない")
    }

    @Test("同じ PR を 2 台が取っていたら 1 つにまとめ、新しい順に並べる。受信箱のお知らせにタスクの紐づけが付く")
    func fleetMerge() {
        let other = MachineID(rawValue: "m2")
        let task = BoardTask(
            machine: machine, number: 3, boardID: "b", columnID: "review", title: "直す",
            links: [TaskLink(id: 1, url: "https://github.com/o/r/pull/1", kind: .githubPR, addedAt: t0)], createdAt: t0, updatedAt: t0)
        let notice = PRNotice(machine: machine, url: "https://github.com/o/r/pull/1", label: "o/r#1", title: "PR 1", kind: .approved, at: t0)
        var a = MachineState(machine: MachineInfo(id: machine, name: "a", daemonVersion: "t"))
        a.apply(
            .stateSnapshot(
                StateSnapshot(
                    machine: MachineInfo(id: machine, name: "a", daemonVersion: "t"), tasks: [task],
                    prs: PRSnapshot(pullRequests: [pr(1, updated: 10), pr(2, updated: 5)], notices: [notice]), generatedAt: t0)))
        var b = MachineState(machine: MachineInfo(id: other, name: "b", daemonVersion: "t"))
        b.apply(.prsUpdated(PRSnapshot(pullRequests: [pr(1, machine: other, updated: 20), pr(9, machine: other, updated: 1)])))
        let merged = Fleet.mergePullRequests([a, b])
        #expect(merged.map(\.number) == [1, 2, 9])
        #expect(merged.first?.machine == other, "新しく取れた方")
        let item = a.inboxItems(now: t0.addingTimeInterval(60)).first { $0.localID.hasPrefix("pr/") }
        #expect(item?.taskNumber == 3 && item?.group == .notice && item?.detail == "o/r#1・#3 直す")
        #expect(a.inboxItems(now: t0.addingTimeInterval(PRSnapshot.noticeWindow + 1)).allSatisfy { !$0.localID.hasPrefix("pr/") }, "24 時間で消える")
    }

    private func machineState(_ id: String, connected: Bool = true, accounts: [PRAccountStatus] = [], prs: [PullRequestSummary]) -> MachineState {
        var state = MachineState(machine: MachineInfo(id: MachineID(rawValue: id), name: id, daemonVersion: "t"), connected: connected)
        state.apply(.prsUpdated(PRSnapshot(accounts: accounts, pullRequests: prs)))
        return state
    }

    @Test("同じアカウントの同じ PR は取ったマシンが違っても 1 つ（新しい方）。違うアカウントの同じ PR は、区分が違っても両方残る")
    func mergeByAccount() {
        let m2 = MachineID(rawValue: "m2")
        let a = machineState("m1", prs: [pr(1, .reviewRequested, updated: 10), pr(2, updated: 5)])
        let b = machineState("m2", prs: [pr(1, .reviewRequested, machine: m2, updated: 20), pr(1, .myReady, machine: m2, updated: 3, account: "bot")])
        let merged = Fleet.mergePullRequests([a, b])
        #expect(merged.map { "\($0.account)#\($0.number)" } == ["me#1", "me#2", "bot#1"], "新しい順")
        #expect(merged.first?.machine == m2, "同じアカウントは新しく取れた方")
        #expect(merged.last?.category == .myReady, "別のアカウントの区分は消えない")
        #expect(Fleet.mergePullRequests([b, a]) == merged, "マシンの順に左右されない")
    }

    @Test("同じアカウントの同じ PR が同じ時刻なら、machine の id の小さい方を残す（順に左右されない）")
    func mergeTie() {
        let a = machineState("m1", prs: [pr(1, updated: 10)])
        let b = machineState("m2", prs: [pr(1, machine: MachineID(rawValue: "m2"), updated: 10)])
        #expect(Fleet.mergePullRequests([a, b]).map(\.machine.rawValue) == ["m1"])
        #expect(Fleet.mergePullRequests([b, a]).map(\.machine.rawValue) == ["m1"])
    }

    @Test("URL で引くと、どのアカウントの分でも最後に更新されたものを返す。URL ごとの一覧とレビュー依頼の数は同じ PR を 2 回数えない")
    func lookupByURL() {
        let a = machineState("m1", prs: [pr(1, .reviewRequested, updated: 10), pr(2, .reviewRequested, updated: 1)])
        let b = machineState("m2", prs: [pr(1, .reviewRequested, machine: MachineID(rawValue: "m2"), updated: 30, account: "bot"), pr(3, .myReady, updated: 2)])
        let merged = Fleet.mergePullRequests([a, b])
        #expect(merged.count == 4)
        #expect(merged.first { $0.number == 1 }?.account == "bot", "URL で引くのは最初（いちばん新しい）の 1 件")
        #expect(Fleet.uniqueByURL(merged).map(\.number) == [1, 3, 2])
        #expect(Fleet.reviewRequestedCount(merged) == 2)
        #expect(Fleet.reviewRequestedCount([]) == 0)
    }

    @Test("中身を頼むマシンは、その PR を取ったマシンのうち接続しているものを先に、その中は新しく取れた方")
    func fetchingMachines() {
        let url = "https://github.com/o/r/pull/1"
        let a = machineState("m1", connected: false, prs: [pr(1, updated: 50)])
        let b = machineState("m2", prs: [pr(1, machine: MachineID(rawValue: "m2"), updated: 10)])
        let c = machineState("m3", prs: [pr(1, machine: MachineID(rawValue: "m3"), updated: 20, account: "bot")])
        let d = machineState("m4", prs: [pr(2, machine: MachineID(rawValue: "m4"))])
        #expect(Fleet.machinesFetching(url: url, [a, b, c, d]).map(\.rawValue) == ["m3", "m2", "m1"])
        #expect(Fleet.machinesFetching(url: "https://github.com/o/r/pull/9", [a, b]).isEmpty)
    }

    @Test("自分の番の PR: 人からのレビュー依頼と、タスクにリンクした PR の CI 失敗・修正依頼・bot からのレビュー依頼を対応待ちに出し、同じ PR の同じ種類のお知らせは出さない。直れば消える")
    func turns() {
        let task = BoardTask(
            machine: machine, number: 3, boardID: "b", columnID: "review", title: "直す",
            links: [
                TaskLink(id: 1, url: "https://github.com/o/r/pull/2", kind: .githubPR, addedAt: t0),
                TaskLink(id: 2, url: "https://github.com/o/r/pull/8", kind: .githubPR, addedAt: t0),
            ], createdAt: t0, updatedAt: t0)
        let prs = [
            pr(1, .reviewRequested),
            pr(2, checks: .failure),
            pr(3, checks: .failure, decision: "CHANGES_REQUESTED"),
            pr(4, checks: .success),
            pr(5, .reviewed, checks: .failure),
            pr(6, .myDraft, checks: .error),
            pr(7, .reviewRequested, bot: true),
            pr(8, .reviewRequested, bot: true),
        ]
        let notices = [
            PRNotice(machine: machine, url: prs[1].url, label: "o/r#2", title: "PR 2", kind: .ciFailed, at: t0),
            PRNotice(machine: machine, url: prs[3].url, label: "o/r#4", title: "PR 4", kind: .ciPassed, at: t0),
            PRNotice(machine: machine, url: prs[5].url, label: "o/r#6", title: "PR 6", kind: .ciFailed, at: t0),
        ]
        var state = MachineState(machine: MachineInfo(id: machine, name: "a", daemonVersion: "t"))
        state.apply(
            .stateSnapshot(
                StateSnapshot(
                    machine: MachineInfo(id: machine, name: "a", daemonVersion: "t"), tasks: [task],
                    prs: PRSnapshot(pullRequests: prs, notices: notices), generatedAt: t0)))
        let items = state.inboxItems(now: t0.addingTimeInterval(60))
        let turns = items.compactMap { item -> String? in
            guard case .pullRequestTurn(let pr, let reason) = item.kind else { return nil }
            return "\(pr.number):\(reason.rawValue):\(item.group == .waiting):\(item.taskNumber.map(String.init) ?? "-")"
        }
        // 自分の PR はタスクにリンクしたものだけを依頼にする（3・6 はリンクしていない）。人からのレビュー依頼はリンクが無くても出し、
        // bot（Dependabot など）からのレビュー依頼はリンクしたもの（8）だけを出す
        #expect(turns.sorted() == ["1:reviewRequested:true:-", "2:ciFailed:true:3", "8:reviewRequested:true:3"])
        let shownNotices = items.compactMap { item -> PRNotice.Kind? in
            if case .pullRequest(let notice) = item.kind { return notice.kind }
            return nil
        }
        #expect(shownNotices.sorted { $0.rawValue < $1.rawValue } == [.ciFailed, .ciPassed], "リンクした PR の CI 失敗は依頼に出ているので重ねず、リンクしていない PR の CI 失敗はお知らせに出す")

        state.apply(.prsUpdated(PRSnapshot(pullRequests: [pr(2, checks: .success)], notices: [])))
        #expect(!state.inboxItems(now: t0).contains { if case .pullRequestTurn = $0.kind { true } else { false } }, "直れば消える")
    }

    @Test("同じ PR を 2 台が取っていたら、自分の番の PR は 1 つ。残すのはタスクに紐づく側、無ければマシン ID の小さい側")
    func turnsDeduped() {
        func item(_ machine: String, task: Int?) -> InboxItem {
            let summary = pr(1, .reviewRequested, machine: MachineID(rawValue: machine))
            return InboxItem(
                id: "prturn/\(summary.url)", kind: .pullRequestTurn(summary, .reviewRequested), group: .waiting, machine: MachineID(rawValue: machine),
                taskNumber: task, title: "PR 1", details: [], at: t0)
        }
        #expect(Fleet.dedupedPullRequestTurns([item("b", task: nil), item("a", task: nil)]).map(\.machine.rawValue) == ["a"])
        #expect(Fleet.dedupedPullRequestTurns([item("a", task: nil), item("b", task: nil)]).map(\.machine.rawValue) == ["a"])
        #expect(Fleet.dedupedPullRequestTurns([item("a", task: nil), item("b", task: 4)]).map(\.machine.rawValue) == ["b"])
    }

    @Test("prs.updated は往復する")
    func wire() throws {
        let snapshot = PRSnapshot(
            accounts: [PRAccountStatus(host: "github.com", account: "me", fetchedAt: t0, error: "x", rateLimited: true, nextFetchAt: t0)],
            pullRequests: [pr(1)], notices: [PRNotice(machine: machine, url: "u", label: "o/r#1", title: "t", kind: .approved, detail: "b", at: t0)])
        let event = DaemonEvent.prsUpdated(snapshot)
        #expect(try WireJSON.decoder().decode(DaemonEvent.self, from: try WireJSON.encoder().encode(event)) == event)
    }
}
