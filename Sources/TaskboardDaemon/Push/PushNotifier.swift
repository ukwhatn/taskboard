import Foundation
import Logging
import TaskboardKit

/// 受信箱に鳴らす項目が増えたら、登録のある端末に APNs で送る（アプリの `InboxNotifier.tick` と同じ差分）。
///
/// - 起動したら agent host の会話を引き取るのを待ち、その時点の受信箱を基準にする（通知しない）
/// - 出来事を `MachineState` に当てていき、`debounce` まとめてから受信箱を作り直し、基準に無い項目を送る。基準は毎回今の項目に置き換える
///   （応答待ちが解けてまた応答待ちになれば、また送る）
/// - 出来事の取りこぼしに備え、`resyncInterval` ごとに snapshot から作り直す
/// - ターンの完了（`TurnWatch`）は出来事ごとに見て溜め、受信箱の項目と一緒に送る（まとめる間に応答を始めて終えた分も落とさない）
/// - 鍵が無い間は送らない（基準だけを進める。鍵を入れたときに、それまでの項目がまとめて鳴らないように）
public actor PushNotifier {
    let state: DaemonState
    let push: PushService
    let debounce: Duration
    let resyncInterval: Duration
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.whatn.taskboardd.push")

    private var machine = MachineState()
    private var known: Set<String>?
    private var turns = TurnWatch()
    /// まだ送っていないターンの完了
    private var finishedTurns: [TurnFinished] = []
    private var pendingFlush: Task<Void, Never>?

    public init(state: DaemonState, push: PushService) {
        self.init(state: state, push: push, debounce: .seconds(2))
    }

    init(state: DaemonState, push: PushService, debounce: Duration, resyncInterval: Duration = .seconds(300), now: @escaping @Sendable () -> Date = { Date() }) {
        self.state = state
        self.push = push
        self.debounce = debounce
        self.resyncInterval = resyncInterval
        self.now = now
    }

    public func run() async {
        await state.waitForAgentHost()
        await state.observe(
            every: resyncInterval, sweepFirst: false, subscribed: { await self.start() }, handle: { await self.handle($0) }, sweep: { await self.resync() })
        pendingFlush?.cancel()
    }

    /// 今の受信箱を基準にする（通知しない）
    func start() async {
        machine = MachineState()
        machine.apply(.stateSnapshot(await state.snapshot()))
        known = Set(loudItems().map(\.id))
        turns.reset(machine)
        finishedTurns = []
    }

    func handle(_ event: DaemonEvent) {
        machine.apply(event)
        switch event {
        // 消した記録は送るものを変えない（APNs は受信箱の記録を見ない）
        case .usageUpdated, .devicesUpdated, .inboxDismissalsUpdated: return
        default: break
        }
        finishedTurns += turns.update(machine)
        guard pendingFlush == nil else { return }
        pendingFlush = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.flushPending()
        }
    }

    func resync() async {
        machine = MachineState()
        machine.apply(.stateSnapshot(await state.snapshot()))
        finishedTurns += turns.update(machine)
        await flush()
    }

    private func flushPending() async {
        pendingFlush = nil
        await flush()
    }

    private func loudItems() -> [InboxItem] {
        machine.inboxItems(now: now()).filter { InboxNotification.make($0, machineName: "") != nil }
    }

    /// 基準に無い項目を送り、基準を今の項目に置き換える
    func flush() async {
        let items = loudItems()
        // 送っている間（await）に次の flush が入っても同じ項目を 2 度送らないよう、送る前に基準を置き換える
        let previous = known
        known = Set(items.map(\.id))
        guard let previous else { return }
        let fresh = items.filter { !previous.contains($0.id) }
        let finished = finishedTurns
        finishedTurns = []
        guard !fresh.isEmpty || !finished.isEmpty, await push.hasCredentials() else { return }
        let targets = await push.targets()
        guard !targets.isEmpty else { return }
        await deliver(turns: finished, to: targets)
        for item in fresh {
            guard let kind = NotifyKind.of(item) else { continue }
            let receivers = targets.filter { $0.registration.kinds.contains(kind) }
            guard !receivers.isEmpty else { continue }
            var conversation: (id: String, request: String)?
            if case .conversationRequest(let owner, let request) = item.kind { conversation = (owner.id, request.id) }
            for target in receivers {
                guard let notification = InboxNotification.make(item, machineName: target.registration.machineName) else { continue }
                let apns = APNsPush.inbox(notification, conversation: conversation, machine: item.machine, registration: target.registration, now: now())
                await push.deliver(apns, to: target)
            }
        }
    }

    /// ターンの完了は、設定が「出さない」でなく、1 台だけ表示で隠していない（種類が空でない）端末に送る。前面かどうかは届いた端末が決める
    private func deliver(turns finished: [TurnFinished], to targets: [Store.PushTarget]) async {
        let receivers = targets.filter { ($0.registration.turns ?? .never) != .never && !$0.registration.kinds.isEmpty }
        for turn in finished {
            for target in receivers {
                let notification = turn.notification(machineName: target.registration.machineName)
                await push.deliver(APNsPush.inbox(notification, machine: turn.machine, registration: target.registration, now: now()), to: target)
            }
        }
    }
}
