import Foundation
import Testing

@testable import TaskboardKit

private struct ScriptedSource: SnapshotSource {
    let snap: StateSnapshot
    let stream: AsyncThrowingStream<DaemonEvent, any Error>

    func snapshot() async throws -> StateSnapshot { snap }
    func events() -> AsyncThrowingStream<DaemonEvent, any Error> { stream }
}

/// 数えたものの控えが、中身と時刻が変わったら新しい答えを返すこと（控えを使わない数え方と同じ答え）
@Suite("数えたものの控え")
struct MachineDerivedTests {
    private let machine = MachineID(rawValue: "m")
    private let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    private func state() -> MachineState {
        var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        let task = BoardTask(
            machine: machine, number: 1, boardID: "b", columnID: "working", title: "題",
            sessions: [TaskSessionRef(id: 1, agent: "claude", sessionID: "s1", cwd: "", linkedAt: t0)], createdAt: t0, updatedAt: t0)
        state.tasks[task.id] = task
        return state
    }

    private var task: BoardTask { state().tasks.values.first! }

    private func work(_ id: Int64, position: Int) -> WorkItem {
        WorkItem(machine: machine, itemID: id, taskNumber: 1, title: "項目\(id)", state: .doing, position: position, source: "session", createdAt: t0, updatedAt: t0)
    }

    private func conversation(_ id: String, closed: Bool = false) -> Conversation {
        Conversation(
            id: id, machine: machine, taskNumber: 1, agentSessionID: "a-\(id)", cwd: "/", runner: closed ? .none : .host, phase: closed ? .stopped : .idle,
            lastExit: closed ? "終了した" : nil, createdAt: t0, updatedAt: t0)
    }

    private func document(_ id: Int64, updated: Date) -> Document {
        Document(machine: machine, docID: id, taskNumber: 1, name: "d\(id).md", format: .markdown, latestRev: 1, createdAt: updated, updatedAt: updated)
    }

    @Test("読んだ後に欄を変えると、作業項目・会話・置き場・動いているタスクが新しい中身で返る")
    func followsChanges() {
        var state = state()
        #expect(state.workItems(forTask: 1).isEmpty && state.conversations(of: task).isEmpty && state.members(of: .task(1)).isEmpty)
        #expect(state.activeTaskNumbers().isEmpty)

        state.workItems[WorkItemKey(machine: machine, id: 2)] = work(2, position: 1)
        state.workItems[WorkItemKey(machine: machine, id: 3)] = work(3, position: 0)
        state.conversations[ConversationKey(machine: machine, id: "c1")] = conversation("c1")
        #expect(state.workItems(forTask: 1).map(\.itemID) == [3, 2])
        #expect(state.conversations(of: task).map(\.id) == ["c1"])
        #expect(state.members(of: .task(1)).map(\.conversation.id) == ["c1"])
        #expect(state.activeTaskNumbers() == [1])

        state.apply(.conversationUpdated(conversation("c1", closed: true)))
        #expect(state.activeTaskNumbers().isEmpty, "終了した会話だけのタスクは動いていない")
        state.apply(.workRemoved(WorkItemKey(machine: machine, id: 3)))
        #expect(state.workItems(forTask: 1).map(\.itemID) == [2])
    }

    @Test("写した state を変えても、写す前の state の答えは変わらない")
    func copiesAreIndependent() {
        let before = state()
        #expect(before.workItems(forTask: 1).isEmpty)
        var after = before
        after.workItems[WorkItemKey(machine: machine, id: 2)] = work(2, position: 0)
        #expect(after.workItems(forTask: 1).count == 1)
        #expect(before.workItems(forTask: 1).isEmpty)
        #expect(before == after.with { $0.workItems = [:] }, "控えは比べる中身に入らない")
    }

    @Test("受信箱: 同じ中身でも、時刻が進んでお知らせが 24 時間の窓を出たら出さない")
    func inboxNoticeExpires() {
        var state = state()
        state.documents[DocKey(machine: machine, id: 7)] = document(7, updated: t0)
        #expect(state.inboxItems(now: t0.addingTimeInterval(3600)).contains { $0.localID == "doc/7/1" })
        #expect(state.inboxItems(now: t0.addingTimeInterval(24 * 3600 - 1)).contains { $0.localID == "doc/7/1" })
        #expect(!state.inboxItems(now: t0.addingTimeInterval(24 * 3600 + 1)).contains { $0.localID == "doc/7/1" })
        #expect(state.inboxItems(now: t0.addingTimeInterval(3600)).contains { $0.localID == "doc/7/1" }, "前の時刻で引き直しても、その時刻の答え")
    }

    @Test("受信箱: 日付が替わると、同じ中身でも動いていない日数が増えて出る")
    func inboxStallFollowsDate() {
        let state = state()
        let calendar = Calendar.current
        let twoDaysLater = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: t0))!.addingTimeInterval(23 * 3600)
        #expect(!state.inboxItems(now: twoDaysLater).contains { $0.localID == "stall/1" })
        let item = state.inboxItems(now: twoDaysLater.addingTimeInterval(2 * 3600)).first { $0.localID == "stall/1" }
        #expect(item?.details.last == "3日更新なし")
    }

    @Test("受信箱: 中身が変われば、時刻が同じでも数え直す")
    func inboxFollowsChanges() {
        var state = state()
        let now = t0.addingTimeInterval(60)
        #expect(state.inboxItems(now: now).isEmpty)
        state.documents[DocKey(machine: machine, id: 7)] = document(7, updated: t0)
        #expect(state.inboxItems(now: now).map(\.localID) == ["doc/7/1"])
    }

    @MainActor
    @Test("Fleet の受信箱: 既読の記録・中身・時刻のどれが変わっても新しい答え")
    func fleetInboxFollowsChanges() async throws {
        let now = t0.addingTimeInterval(60)
        var clock = now
        let fleet = Fleet(now: { clock })
        let (stream, continuation) = AsyncThrowingStream<DaemonEvent, any Error>.makeStream()
        let info = MachineInfo(id: machine, name: "m", daemonVersion: "t")
        fleet.add(id: "local", source: ScriptedSource(snap: StateSnapshot(machine: info, documents: [document(7, updated: t0)], generatedAt: t0), stream: stream))
        for _ in 0..<100 where fleet.allMachines["local"]?.machine == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fleet.inbox.items.map(\.localID) == ["doc/7/1"])
        fleet.inboxPending = ["m/doc/7/1": ""]
        #expect(fleet.inbox.items.isEmpty, "送っている途中の既読")
        fleet.inboxPending = [:]

        fleet.setInboxDismissals([InboxDismissal(itemID: "doc/7/1", revision: "", dismissedAt: now)], for: machine)
        #expect(fleet.inbox.items.isEmpty && fleet.inbox.dismissed.map(\.localID) == ["doc/7/1"])

        continuation.yield(.docUpdated(document(8, updated: t0)))
        for _ in 0..<100 where fleet.allMachines["local"]?.documents.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fleet.inbox.items.map(\.localID) == ["doc/8/1"])
        clock = t0.addingTimeInterval(25 * 3600)
        fleet.rebuildOverview()
        #expect(fleet.inbox.items.isEmpty, "窓を出た")
        fleet.remove(id: "local")
    }
}

private extension MachineState {
    func with(_ body: (inout MachineState) -> Void) -> MachineState {
        var copy = self
        body(&copy)
        return copy
    }
}
