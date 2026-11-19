import Foundation
import Logging
import TaskboardKit

/// 定期起動の回の会話を、最初の発言を受けてターンを終え、静かになったら（空いている・裏のタスクが 0 と分かっている・問いが無い・画面に出ていない・
/// 利用枠の上限で待っていない）止める。終わった後に読む人がいないので `IdleReaper` の `idleStopMinutes` を待たない。
/// 会話の様子が変わるたびと 1 分ごとに見直す（画面から外れたときは知らせが来ない）
public actor ScheduledRunCloser {
    let store: Store
    let state: DaemonState
    let conversations: ConversationService
    let sweepInterval: Duration
    private let logger = Logger(label: "uk.whatn.taskboardd.schedule.close")

    init(store: Store, state: DaemonState, conversations: ConversationService, sweepInterval: Duration = .seconds(60)) {
        self.store = store
        self.state = state
        self.conversations = conversations
        self.sweepInterval = sweepInterval
    }

    /// 購読で会話の変化を受ける
    public func run() async {
        await state.observe(every: sweepInterval, sweepFirst: false, handle: { await self.handle($0) }, sweep: { await self.sweepConversations() })
    }

    func handle(_ event: DaemonEvent) async {
        switch event {
        case .conversationUpdated(let conversation):
            guard conversation.purpose == .schedule, conversation.runner == .host, conversation.phase == .idle else { return }
            await stopIfFinished(conversation.id)
        default:
            return
        }
    }

    /// 回の会話を、最初の発言を受けてターンを終え、静かになっていれば止める。止めたら true
    @discardableResult
    func stopIfFinished(_ conversationID: String) async -> Bool {
        guard let run = try? store.scheduleRun(conversationID: conversationID) else { return false }
        return await conversations.stopIfFinished(conversationID, firstMessageID: Scheduler.firstMessageID(runID: run.id))
    }

    func sweepConversations() async {
        for conversation in await conversations.list() where conversation.purpose == .schedule && conversation.runner == .host {
            await stopIfFinished(conversation.id)
        }
    }
}
