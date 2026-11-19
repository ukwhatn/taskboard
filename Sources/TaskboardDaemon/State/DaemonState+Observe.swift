import Foundation
import TaskboardKit

extension DaemonState {
    /// 出来事を受けて `handle` し、`interval` ごとに `sweep` する。止められたら購読を外して戻る。
    /// `sweepFirst` なら始めに 1 回見回ってから待つ。そうでなければ待ってから見回る（止められたときは、どちらも見回らずに抜ける）。
    /// `subscribed` は購読した直後、出来事を配り始める前に呼ぶ（その間の出来事は購読が溜める）
    nonisolated func observe(
        every interval: Duration, sweepFirst: Bool, subscribed: @Sendable () async -> Void = {},
        handle: @escaping @Sendable (DaemonEvent) async -> Void, sweep: @escaping @Sendable () async -> Void
    ) async {
        let (id, stream) = await subscribe()
        await subscribed()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await event in stream { await handle(event) } }
            group.addTask {
                while !Task.isCancelled {
                    if sweepFirst { await sweep() }
                    guard (try? await Task.sleep(for: interval)) != nil else { return }
                    if !sweepFirst { await sweep() }
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
        await unsubscribe(id)
    }

    /// agent host に繋がるまで `poll` ごとに待ち（`timeout` で諦める）、続けて `settle` 待つ（繋がった直後の引き取りが済んでから見る）
    nonisolated func waitForAgentHost(poll: Duration = .seconds(1), timeout: Duration = .seconds(120), settle: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled, await machineInfo().agentHost?.connected != true, ContinuousClock.now < deadline {
            try? await Task.sleep(for: poll)
        }
        try? await Task.sleep(for: settle)
    }
}
