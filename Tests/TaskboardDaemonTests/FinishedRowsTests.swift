import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-finished")
private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
private let prURL = "https://github.com/o/r/pull/12"

@Suite("終えた予定と見張りの扱い（取り消せる状態と、消すまでの期間）")
struct FinishedRowsTests {
    private func world() throws -> (Store, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        return (store, try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t")))
    }

    private func wake(_ store: Store, _ task: BoardTask) throws -> Wake {
        try store.createWake(WakeCreateRequest(at: t0 + 3600, prompt: "p", taskNumber: task.number), now: t0)
    }

    @Test("予定は pending だけ取り消せる。届けた・失敗した・取り消した予定と、無い予定は断る")
    func wakeCancelsOnlyPending() throws {
        let (store, task) = try world()
        let pending = try wake(store, task)
        let delivered = try wake(store, task)
        try store.markWakeDelivered(id: delivered.wakeID, now: t0)
        let failed = try wake(store, task)
        try store.markWakeFailed(id: failed.wakeID, reason: "x", now: t0)

        let cancelled = try store.cancelWake(id: pending.wakeID, now: t0 + 10)
        #expect(cancelled.state == .cancelled && cancelled.updatedAt == t0 + 10)
        for (row, state) in [(pending, "cancelled"), (delivered, "delivered"), (failed, "failed")] {
            #expect(throws: StoreError.conflict("予定 #\(row.wakeID) は \(state)（取り消せるのは pending だけ）")) { try store.cancelWake(id: row.wakeID, now: t0 + 20) }
        }
        #expect(throws: StoreError.wakeNotFound(99)) { try store.cancelWake(id: 99, now: t0 + 20) }
        #expect(try store.wake(id: delivered.wakeID)?.state == .delivered, "断った予定は書き換えない")
    }

    @Test("見張りは active だけ取り消せる。終えた・取り消した見張りと、無い見張りは断る")
    func watchCancelsOnlyActive() throws {
        let (store, task) = try world()
        let active = try store.createWatch(WatchCreateRequest(url: prURL, taskNumber: task.number), now: t0).watch
        let ended = try store.createWatch(WatchCreateRequest(url: "https://github.com/o/r/issues/7", taskNumber: task.number), now: t0).watch
        try store.endWatch(id: ended.watchID, .expired, at: t0)

        #expect(try store.cancelWatch(id: active.watchID, now: t0 + 10).state == .cancelled)
        #expect(throws: StoreError.conflict("見張り #\(active.watchID) は cancelled（取り消せるのは active だけ）")) { try store.cancelWatch(id: active.watchID, now: t0 + 20) }
        #expect(throws: StoreError.conflict("見張り #\(ended.watchID) は ended（取り消せるのは active だけ）")) { try store.cancelWatch(id: ended.watchID, now: t0 + 20) }
        #expect(throws: StoreError.watchNotFound(99)) { try store.cancelWatch(id: 99, now: t0 + 20) }
    }

    @Test("終えた予定は、終えてから 7 日を過ぎたものだけ消す。待っている予定は消さない")
    func wakePurgeKeepsPending() throws {
        let (store, task) = try world()
        let pending = try wake(store, task)
        let cancelled = try wake(store, task)
        _ = try store.cancelWake(id: cancelled.wakeID, now: t0)
        let delivered = try wake(store, task)
        try store.markWakeDelivered(id: delivered.wakeID, now: t0 + 100)
        let failed = try wake(store, task)
        try store.markWakeFailed(id: failed.wakeID, reason: "x", now: t0)

        let week: TimeInterval = 7 * 24 * 3600
        try store.purgeFinishedWakes(now: t0 + week - 1)
        #expect(try store.wakes().count == 4, "7 日に届かなければ消さない")
        try store.purgeFinishedWakes(now: t0 + week + 1)
        #expect(Set(try store.wakes().map(\.wakeID)) == [pending.wakeID, delivered.wakeID], "届けたのが 100 秒後の予定は、まだ 7 日に届かない")
        try store.purgeFinishedWakes(now: t0 + week + 101)
        #expect(try store.wakes().map(\.wakeID) == [pending.wakeID])
    }
}
