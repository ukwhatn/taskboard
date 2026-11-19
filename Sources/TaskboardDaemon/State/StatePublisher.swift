import Foundation
import Logging
import TaskboardKit

/// Store に書いた後の `DaemonState` への反映（1 つの層）。Store の書き込みが流した `StoreChange` を受け、Store から今の行を読み直して入れる。
/// 1 つの Store に 1 つ（`Store.statePublisher(state:)`）。route は middleware が応答の前に `settled()` を待つので、知らせは応答より先に届く
actor StatePublisher {
    private let store: Store
    private let state: DaemonState
    private let conversationHandler = HandlerSlot()
    /// 配り終えた通し番号
    private var applied = 0
    private var waiters: [(through: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let logger = Logger(label: "uk.whatn.taskboardd.publisher")

    init(store: Store, state: DaemonState) {
        self.store = store
        self.state = state
        Task { await self.run() }
    }

    /// 会話の結び直し（`StoreChange.conversation`）を受ける口。`ConversationService` が作られたときに 1 回だけ登録する
    nonisolated func onConversation(_ handler: @escaping @Sendable (String) async -> Void) {
        conversationHandler.value = handler
    }

    /// 呼んだ時点までに流れた変更を配り終えるまで待つ（後から流れた分は待たない）
    func settled() async {
        let target = store.changeLog.recorded
        guard applied < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    private func run() async {
        for await _ in store.changeLog.wakes {
            let (changes, through) = store.changeLog.take()
            for change in changes { await apply(change) }
            applied = max(applied, through)
            let ready = waiters.filter { $0.through <= applied }
            waiters.removeAll { $0.through <= applied }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    private func apply(_ change: StoreChange) async {
        do {
            switch change {
            case .board(let id):
                if let board = try store.boards().first(where: { $0.id == id }) { await state.upsert(board) } else { await state.removeBoard(id: id) }
            case .task(let number):
                if let task = try store.task(number: number) { await state.upsert(task) } else { await state.removeTask(number: number) }
            case .workItems(let number):
                await state.replaceWorkItems(task: number, with: try store.workItems(task: number))
            case .document(let id):
                if let document = try store.document(id: id) { await state.upsert(document) } else { await state.removeDocument(id: id) }
            case .ask(let id):
                if let ask = try store.ask(id: id) { await state.upsert(ask) }
            case .reviewRequest(let number):
                if let request = try store.reviewRequests().first(where: { $0.taskNumber == number }) {
                    await state.upsert(request)
                } else {
                    await state.removeReviewRequest(task: number)
                }
            case .schedule(let id):
                do {
                    await state.upsert(try store.schedule(id: id))
                } catch StoreError.scheduleNotFound {
                    await state.removeSchedule(id: id)
                }
            case .wake(let id):
                if let wake = try store.wake(id: id) { await state.upsert(wake) } else { await state.removeWake(id: id) }
            case .watch(let id):
                if let watch = try store.watch(id: id) { await state.upsert(watch) } else { await state.removeWatch(id: id) }
            case .panel(let number):
                if let panel = try store.panel(task: number) { await state.upsert(panel) } else { await state.removePanel(task: number) }
            case .settings:
                await state.setSettings(try store.settings())
            case .conversation(let id):
                await conversationHandler.value?(id)
            }
        } catch {
            logger.warning("store change not published", metadata: ["change": .string("\(change)"), "error": .string("\(error)")])
        }
    }
}

/// 会話の口。登録は同期で済ませる（登録の前に流れた結び直しを落とさないよう、`ConversationService` の init で入れる）
private final class HandlerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) async -> Void)?

    var value: (@Sendable (String) async -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
}
