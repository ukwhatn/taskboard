import Foundation
import Logging
import TaskboardKit

/// しばらく idle の host の会話を止める（タスクに結ばれ、画面に出ていないもの。`ConversationService.stopIdle`）。止めた会話は同じ会話で再開できる
public actor IdleReaper {
    let store: Store
    let conversations: ConversationService
    /// 設定より優先する秒数（確認用の `TASKBOARD_IDLE_STOP_SECONDS`）
    let overrideSeconds: Int?
    private let now: @Sendable () -> Date

    public static let environmentKey = "TASKBOARD_IDLE_STOP_SECONDS"
    static let interval: Duration = .seconds(300)

    init(
        store: Store, conversations: ConversationService, environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.conversations = conversations
        self.overrideSeconds = environment[Self.environmentKey].flatMap(Int.init)
        self.now = now
    }

    public func run() async {
        // 秒数を縮めて確かめるときは、見る間隔も縮める（5 分おきでは待ちが秒数の何倍にもなる）
        let interval = overrideSeconds.map { Duration.seconds(max(5, $0 / 4)) } ?? Self.interval
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            await tick()
        }
    }

    func tick() async {
        guard let threshold = threshold() else { return }
        _ = await conversations.stopIdle(before: now().addingTimeInterval(-threshold))
    }

    /// 止めるまでの秒数。nil は止めない
    func threshold() -> TimeInterval? {
        let seconds = overrideSeconds ?? ((try? store.settings()) ?? .defaults).idleStopMinutes * 60
        return seconds > 0 ? TimeInterval(seconds) : nil
    }
}
