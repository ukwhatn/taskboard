import Foundation
import Testing

@testable import TaskboardKit

/// snapshot だけを返し、イベントを流さない供給元
private struct StaticSource: SnapshotSource {
    let snap: StateSnapshot

    func snapshot() async throws -> StateSnapshot { snap }
    func events() -> AsyncThrowingStream<DaemonEvent, any Error> { AsyncThrowingStream { _ in } }
}

@Suite("受信箱の無視と既読")
struct InboxDismissalKitTests {
    let machine = MachineID(rawValue: "m")
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    func info(_ id: MachineID) -> MachineInfo { MachineInfo(id: id, name: id.rawValue, daemonVersion: "t") }

    func pr(_ number: Int, machine: MachineID? = nil, updated: TimeInterval = 0) -> PullRequestSummary {
        PullRequestSummary(
            machine: machine ?? self.machine, host: "github.com", account: "me", category: .reviewRequested, url: "https://github.com/o/r/pull/\(number)",
            repository: "o/r", number: number, title: "PR \(number)", author: "other", isDraft: false, headRef: "f", createdAt: t0,
            updatedAt: t0.addingTimeInterval(updated))
    }

    /// 権限の確認を 1 つ待っている会話
    func waiting(_ requestID: String) -> Conversation {
        let request = ConversationRequest(
            id: requestID, kind: .permission, toolName: "Bash", toolUseID: requestID,
            waiting: RequestWaiting(id: requestID, since: t0, permission: .init(tool: "Bash", summary: "git push")))
        return Conversation(
            id: "c1", machine: machine, taskNumber: nil, agentSessionID: "s1", cwd: "/", runner: .host, phase: .waiting, pending: [request], createdAt: t0,
            updatedAt: t0)
    }

    func dismiss(_ state: inout MachineState, _ item: InboxItem) {
        state.inboxDismissals[item.localID] = InboxDismissal(itemID: item.localID, revision: item.revision, dismissedAt: t0)
    }

    func item(_ state: MachineState, _ localID: String) throws -> InboxItem {
        try #require(state.inboxItems(now: t0.addingTimeInterval(60)).first { $0.localID == localID })
    }

    // MARK: また出す条件

    @Test("会話の問い: 無視すると隠れ、次の問い（別の id）はまた出る")
    func requestReappears() throws {
        var state = MachineState(machine: info(machine))
        state.conversations[waiting("r1").key] = waiting("r1")
        dismiss(&state, try item(state, "conversation/c1/r1"))
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.isEmpty)
        #expect(state.inbox(now: t0.addingTimeInterval(60)).dismissed.map(\.localID) == ["conversation/c1/r1"])

        state.conversations[waiting("r2").key] = waiting("r2")
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.map(\.localID) == ["conversation/c1/r2"])
    }

    @Test("作業項目の承認・回答待ちは受信箱に出さない（質問・会話の問いが依頼の実体で、待ちはカードの待ち理由に出る）")
    func approvalWorkItemsAreNotRequests() {
        var state = MachineState(machine: info(machine))
        state.tasks[TaskKey(machine: machine, number: 1)] = BoardTask(
            machine: machine, number: 1, boardID: "b", columnID: "working", title: "題", createdAt: t0, updatedAt: t0)
        state.workItems[WorkItemKey(machine: machine, id: 3)] = WorkItem(
            machine: machine, itemID: 3, taskNumber: 1, title: "送信", state: .wait, blockerKind: .approval, blockerText: "承認",
            position: 0, source: "session", createdAt: t0, updatedAt: t0)
        #expect(state.inboxItems(now: t0.addingTimeInterval(60)).isEmpty)
    }

    @Test("レビュー依頼: 頼み直される（時刻が変わる）とまた出る")
    func reviewRequestReappears() throws {
        var state = MachineState(machine: info(machine))
        let key = TaskKey(machine: machine, number: 1)
        state.reviewRequests[key] = ReviewRequest(machine: machine, taskNumber: 1, requestedAt: t0)
        dismiss(&state, try item(state, "review/1"))
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.isEmpty)
        state.reviewRequests[key] = ReviewRequest(machine: machine, taskNumber: 1, requestedAt: t0.addingTimeInterval(20))
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.map(\.localID) == ["review/1"])
    }

    @Test("自分の番の PR: PR が更新されるとまた出る。秒より細かい違いではまた出さない")
    func pullRequestTurnReappears() throws {
        var state = MachineState(machine: info(machine))
        state.prs = PRSnapshot(pullRequests: [pr(1)], notices: [])
        let turn = try item(state, "prturn/https://github.com/o/r/pull/1")
        #expect(turn.revision == "reviewRequested@1791100000")
        dismiss(&state, turn)
        state.prs = PRSnapshot(pullRequests: [pr(1, updated: 0.4)], notices: [])
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.isEmpty)
        state.prs = PRSnapshot(pullRequests: [pr(1, updated: 90)], notices: [])
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.map(\.localID) == ["prturn/https://github.com/o/r/pull/1"])
    }

    @Test("質問: 無視した束は隠れ、新しい束（別の id）は出る")
    func questionsByBundle() throws {
        var state = MachineState(machine: info(machine))
        func ask(_ id: Int64) -> Ask {
            Ask(machine: machine, askID: id, taskNumber: 1, docID: 9, status: .open, questions: [AskQuestion(id: "q1", question: "質問", options: [])], createdAt: t0)
        }
        state.asks[AskKey(machine: machine, id: 1)] = ask(1)
        dismiss(&state, try item(state, "ask/1"))
        state.asks[AskKey(machine: machine, id: 2)] = ask(2)
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.map(\.localID) == ["ask/2"])
    }

    @Test("お知らせ: 既読にした版は隠れ、新しい版は出る")
    func documentNoticeByRevision() throws {
        var state = MachineState(machine: info(machine))
        func doc(rev: Int) -> Document {
            Document(machine: machine, docID: 7, taskNumber: 1, name: "plan.md", format: .markdown, latestRev: rev, createdAt: t0, updatedAt: t0)
        }
        state.documents[DocKey(machine: machine, id: 7)] = doc(rev: 1)
        let notice = try item(state, "doc/7/1")
        #expect(notice.revision == "")
        dismiss(&state, notice)
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.isEmpty)
        state.documents[DocKey(machine: machine, id: 7)] = doc(rev: 2)
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.map(\.localID) == ["doc/7/2"])
    }

    @Test("PR の取得の失敗: 理由が変わるとまた出る")
    func prSyncByReason() throws {
        var state = MachineState(machine: info(machine))
        state.prs = PRSnapshot(accounts: [PRAccountStatus(host: "github.com", account: "a", fetchedAt: t0, error: "exit 1: HTTP 401")], pullRequests: [], notices: [])
        dismiss(&state, try item(state, "prsync/github.com|a"))
        state.prs = PRSnapshot(accounts: [PRAccountStatus(host: "github.com", account: "a", fetchedAt: t0.addingTimeInterval(30), error: "exit 1: HTTP 401")], pullRequests: [], notices: [])
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.isEmpty, "取り直しただけではまた出さない")
        state.prs = PRSnapshot(
            accounts: [PRAccountStatus(host: "github.com", account: "a", fetchedAt: t0, error: "API rate limit exceeded", rateLimited: true)], pullRequests: [],
            notices: [])
        #expect(state.inbox(now: t0.addingTimeInterval(60)).items.count == 1)
    }

    // MARK: 記録の届き方

    @Test("state.snapshot と inbox.dismissals_updated で記録が入る。古い daemon の snapshot は空")
    func appliesRecords() throws {
        var state = MachineState()
        var snap = StateSnapshot(machine: info(machine), generatedAt: t0)
        snap.inboxDismissals = [InboxDismissal(itemID: "ask/1", revision: "", dismissedAt: t0)]
        let decoded = try WireJSON.decoder().decode(StateSnapshot.self, from: try WireJSON.encoder().encode(snap))
        state.apply(.stateSnapshot(decoded))
        #expect(state.inboxDismissals.keys.sorted() == ["ask/1"])
        state.apply(.inboxDismissalsUpdated([]))
        #expect(state.inboxDismissals.isEmpty)

        let old = #"{"machine":{"id":"m","name":"m","herdrConnected":true,"daemonVersion":"t"},"sessions":[],"generatedAt":"2026-10-06T00:00:00Z"}"#
        #expect(try WireJSON.decoder().decode(StateSnapshot.self, from: Data(old.utf8)).inboxDismissals.isEmpty)
    }

    @Test("すべて既読にする: 項目のマシンごとに、上限で区切って送る")
    func requestsByMachine() {
        let other = MachineID(rawValue: "o")
        let items = (0..<(InboxDismissal.batchLimit + 1)).map { n in
            InboxItem(id: "doc/\(n)/1", kind: .prSync(PRAccountStatus(host: "h", account: "a")), group: .notice, machine: machine, taskNumber: nil, title: "t", details: [], at: t0)
        } + [InboxItem(id: "doc/1/1", kind: .prSync(PRAccountStatus(host: "h", account: "a")), group: .notice, machine: other, taskNumber: nil, title: "t", details: [], at: t0)]
        let batches = InboxDismissal.batches(items)
        #expect(batches[machine]?.map(\.count) == [InboxDismissal.batchLimit, 1])
        #expect(batches[machine]?.last?.map(\.localID) == ["doc/\(InboxDismissal.batchLimit)/1"])
        #expect(batches[other]?.map { $0.map(\.localID) } == [["doc/1/1"]])
    }

    // MARK: Fleet

    @MainActor
    func fleet(_ snaps: [String: StateSnapshot]) async throws -> Fleet {
        let now = t0.addingTimeInterval(60)
        let fleet = Fleet(now: { now })
        for (id, snap) in snaps { fleet.add(id: id, source: StaticSource(snap: snap), reconnectDelay: .seconds(60)) }
        for _ in 0..<100 where fleet.allMachines.values.contains(where: { $0.machine == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        return fleet
    }

    @MainActor
    @Test("同じ PR を 2 台が持つとき、残った側の記録で隠し、別のマシンの同じ PR を代わりに出さない")
    func dedupeBeforeDismissal() async throws {
        let a = MachineID(rawValue: "a")
        let b = MachineID(rawValue: "b")
        var snapA = StateSnapshot(machine: info(a), prs: PRSnapshot(pullRequests: [pr(1, machine: a)], notices: []), generatedAt: t0)
        let turn = InboxItem(
            id: "prturn/https://github.com/o/r/pull/1", kind: .pullRequestTurn(pr(1, machine: a), .reviewRequested), group: .waiting, machine: a,
            taskNumber: nil, title: "", details: [], at: t0)
        snapA.inboxDismissals = [InboxDismissal(itemID: turn.localID, revision: turn.revision, dismissedAt: t0)]
        let snapB = StateSnapshot(machine: info(b), prs: PRSnapshot(pullRequests: [pr(1, machine: b)], notices: []), generatedAt: t0)
        let fleet = try await fleet(["a": snapA, "b": snapB])
        #expect(fleet.inbox.items.isEmpty)
        #expect(fleet.inbox.dismissed.map(\.machine) == [a])
        #expect(fleet.inboxIncludingHidden.count == 1, "通知の「もう見た」には消した項目も入れる")
    }

    @MainActor
    @Test("送っている途中の操作は記録より先に効き、応答の記録で置き換えられる")
    func pendingOverrides() async throws {
        var snap = StateSnapshot(machine: info(machine), generatedAt: t0)
        snap.conversations = [waiting("r1")]
        let fleet = try await fleet(["local": snap])
        let item = try #require(fleet.inbox.items.first)
        fleet.inboxPending = [item.id: item.revision]
        #expect(fleet.inbox.items.isEmpty)
        fleet.inboxPending = [:]

        fleet.setInboxDismissals([InboxDismissal(itemID: item.localID, revision: item.revision, dismissedAt: t0)], for: machine)
        #expect(fleet.inbox.items.isEmpty)
        fleet.inboxPending = [item.id: String?.none]
        #expect(fleet.inbox.items.map(\.id) == [item.id], "戻している途中は出す")
    }
}
