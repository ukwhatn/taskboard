import Foundation
import Logging
import TaskboardKit

/// 起こす予定（`wake`）を時刻どおりに届ける。時刻を過ぎた予定の文を、止まっていれば起こしてから発言として入れる
/// （人が止めた・終了した会話も起こす。`DeliveryKind.wake`）。起こすと終了の印が外れ、一覧に戻る。
///
/// - 20 秒ごとと、会話が入力待ちに入ったときに見る。DarkWake の間は見ない（`SystemPower`）。Mac が眠っていた・daemon が止まっていた間に
///   過ぎた予定は、次に完全に起きた最初の回に届ける
/// - 発言の uuid は予定の id と取り消された回数から決める。会話は受けた uuid を記録に残し、同じ uuid を受け直さないので、
///   届けてから記録するまでに daemon が落ちても 2 回入らない
/// - タスク宛ては、その時点の lead（`TaskDeliveryTarget`。止まった・終了した会話も候補）。lead が無ければ案件の起動の既定で新しく起こす
///   （会話の id は予定の id から決めるので 2 つ作らない）
/// - 届けられないまま 24 時間たったら失敗にする。会話を起こせなかった回は 10 分あけて試し直す
/// - 仕掛けた会話の終了（`closeConversationId`）は、その会話が静かになってから行う（tool の途中で止めると返事が返らない）
actor WakeService {
    let store: Store
    let state: DaemonState
    let conversations: ConversationService
    private let delivery: NoticeDelivery<Int64>
    let interval: Duration
    let isFullWake: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var firing: Set<Int64> = []
    /// 起こせなかった予定を次に試す時刻
    private var retryAt: [Int64: Date] = [:]
    private let logger = Logger(label: "uk.whatn.taskboardd.wake")

    static let retryInterval: TimeInterval = 600
    static let giveUpAfter: TimeInterval = 24 * 3600
    /// これより遅れて届けたら、文に届けた時刻も書く
    static let lateAfter: TimeInterval = 300

    init(
        store: Store, state: DaemonState, conversations: ConversationService,
        interval: Duration = .seconds(20), isFullWake: @escaping @Sendable () -> Bool = SystemPower.isFullWake,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.state = state
        self.conversations = conversations
        delivery = NoticeDelivery(state: state, conversations: conversations)
        self.interval = interval
        self.isFullWake = isFullWake
        self.now = now
    }

    func run() async {
        // 起動直後は agent host の会話の引き取りが済んでいない
        await state.waitForAgentHost()
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: interval)
        }
    }

    /// 会話が入力待ちに入った（`ConversationService.onIdle`）
    func conversationIdle(_ id: String) async {
        await tick()
    }

    func tick() async {
        let now = now()
        do {
            try store.purgeFinishedWakes(now: now)
        } catch {
            logger.warning("finished wakes not purged", metadata: ["error": "\(error)"])
        }
        if isFullWake() {
            for row in (try? store.dueWakes(now: now)) ?? [] { await fire(row, now: now) }
        }
        for row in (try? store.closingWakes()) ?? [] { await closeCreator(row) }
    }

    // MARK: 届ける

    private func fire(_ row: Store.WakeRow, now: Date) async {
        guard let id = row.id, firing.insert(id).inserted else { return }
        defer { firing.remove(id) }
        if let retry = retryAt[id], retry > now { return }
        let text = Self.text(row, now: now)
        if let conversationID = row.conversationId {
            await deliver(row, to: conversationID, text: text, now: now)
        } else if let number = row.taskNumber {
            await deliver(row, task: number, text: text, now: now)
        }
    }

    private func deliver(_ row: Store.WakeRow, to conversationID: String, text: String, now: Date) async {
        guard let id = row.id else { return }
        guard (try? store.conversation(id: conversationID)) != nil else {
            return await fail(id, .conversationMissing, now: now)
        }
        await record(id, await delivery.deliver(text, toConversation: conversationID, key: id, uuidSeed: Self.uuidSeed(wakeID: id), kind: .wake), now: now)
    }

    /// タスク宛て：その時点の lead に届ける。lead が無ければ新しく起こす
    private func deliver(_ row: Store.WakeRow, task number: Int, text: String, now: Date) async {
        guard let id = row.id else { return }
        // 前の回に新しく起こした会話（記録する前に daemon が落ちた）
        let started = Self.conversationID(wakeID: id)
        if (try? store.conversation(id: started)) != nil { return await assignAndDeliver(id, to: started, text: text, now: now) }
        switch await delivery.lead(task: number) {
        case .conversation(let conversationID):
            await assignAndDeliver(id, to: conversationID, text: text, now: now)
        case let target?:
            // 止まった TUI を戻したら、戻した会話が次の回に lead になり、そこへ届ける
            await record(id, await delivery.deliver(text, to: target, task: number, key: id, uuidSeed: Self.uuidSeed(wakeID: id), kind: .wake), now: now)
        case nil:
            await start(row, task: number, text: text, now: now)
        }
    }

    private func assignAndDeliver(_ id: Int64, to conversationID: String, text: String, now: Date) async {
        do {
            let row = try store.assignWake(id: id, conversationID: conversationID, now: now)
            await deliver(row, to: row.conversationId ?? conversationID, text: text, now: now)
        } catch {
            logger.warning("wake target not recorded", metadata: ["wake": .stringConvertible(id), "error": "\(error)"])
        }
    }

    private func record(_ id: Int64, _ outcome: NoticeDelivery<Int64>.Outcome, now: Date) async {
        switch outcome {
        case .delivered(let to): await delivered(id, to: to, now: now)
        case .cancelled: return
        case .busy: await note(id, .busy, now: now)
        case .unknown: await note(id, .unconfirmed, now: now)
        case .unavailable:
            retryAt[id] = now.addingTimeInterval(Self.retryInterval)
            await note(id, .resumeFailed, now: now)
        case .resuming: await note(id, .resuming, now: now)
        }
    }

    /// タスクにセッションが 1 つも無い：案件の起動の既定（無ければ `session_start` を省いたときと同じ）で起こし、列の起動プロンプトを予定の文の後に付ける
    private func start(_ row: Store.WakeRow, task number: Int, text: String, now: Date) async {
        guard let id = row.id else { return }
        guard let task = await state.task(number: number) else { return await fail(id, .taskMissing, now: now) }
        let uuid = await delivery.uuid(Self.uuidSeed(wakeID: id), key: id)
        let board = await state.allBoards().first { $0.id == task.boardID }
        let plan = Self.launchPlan(task: task, board: board, fallbackCwd: row.cwd)
        let prompt = plan.template.isEmpty ? text : text + "\n\n" + plan.template
        let conversationID = Self.conversationID(wakeID: id)
        do {
            var request = try await conversations.launchRequest(kind: plan.kind, agentArgs: plan.agentArgs, cwd: plan.cwd, taskNumber: number)
            request.prompt = prompt
            _ = try await conversations.start(request, id: conversationID, firstMessageID: uuid)
            _ = try? store.assignWake(id: id, conversationID: conversationID, now: now)
            await delivered(id, to: conversationID, now: now)
        } catch {
            retryAt[id] = now.addingTimeInterval(Self.retryInterval)
            logger.warning("wake conversation not started", metadata: ["wake": .stringConvertible(id), "error": "\(error)"])
            await note(id, .startFailed, now: now)
        }
    }

    struct LaunchPlan: Equatable {
        var kind: AgentKind
        var agentArgs: [String]
        var cwd: String
        /// 列の起動プロンプト（埋める前）
        var template: String
    }

    /// 新しく起こすときの起こし方。kind・引数は `LaunchChoice(defaults:)`（`session_start` で省いたときと同じ）。
    /// cwd は `launchDefaults` → タスクに最後に結んだセッション → 予定を作ったところ
    static func launchPlan(task: BoardTask, board: Board?, fallbackCwd: String) -> LaunchPlan {
        let defaults = board?.launchDefaults
        let choice = LaunchChoice(defaults: defaults)
        let lastSession = task.sessions.max { $0.linkedAt < $1.linkedAt }?.cwd
        let cwd = [defaults?.cwd, lastSession, fallbackCwd].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return LaunchPlan(
            kind: choice.kind, agentArgs: choice.args, cwd: cwd, template: board.map { PromptTemplate.template(for: task.columnID, in: $0) } ?? "")
    }

    private func delivered(_ id: Int64, to target: String, now: Date) async {
        await delivery.forget(id)
        retryAt.removeValue(forKey: id)
        do {
            try store.markWakeDelivered(id: id, now: now)
            logger.info("wake delivered", metadata: ["wake": .stringConvertible(id), "to": .string(target)])
        } catch {
            logger.warning("wake not marked delivered", metadata: ["wake": .stringConvertible(id), "error": "\(error)"])
        }
    }

    /// 届けられなかった回。最初の回から 24 時間たっていたら失敗にする
    private func note(_ id: Int64, _ problem: WakeProblem, now: Date) async {
        guard let row = try? store.noteWakeAttempt(id: id, reason: problem.failure, now: now) else { return }
        // triedAt は DB の精度（ミリ秒）に丸めて戻るので、今の時刻も同じく丸めて比べる
        if let first = row.triedAt, Store.storedDate(now).timeIntervalSince(first) >= Self.giveUpAfter {
            await fail(id, .gaveUp(problem), now: now)
        }
    }

    private func fail(_ id: Int64, _ problem: WakeProblem, now: Date) async {
        let reason = problem.failure
        await delivery.forget(id)
        retryAt.removeValue(forKey: id)
        try? store.markWakeFailed(id: id, reason: reason, now: now)
        logger.warning("wake failed", metadata: ["wake": .stringConvertible(id), "reason": .string(reason)])
    }

    // MARK: 仕掛けた会話の終了

    private func closeCreator(_ row: Store.WakeRow) async {
        guard let id = row.id, let conversationID = row.closeConversationId else { return }
        guard let conversation = try? await conversations.get(conversationID), !conversation.isClosed else {
            try? store.clearWakeClose(id: id)
            return
        }
        if conversation.phase == .stopped {
            do {
                try await conversations.close(conversationID)
            } catch {
                return logger.warning("wake creator not closed", metadata: ["wake": .stringConvertible(id), "error": "\(error)"])
            }
        } else if await !conversations.closeIfResting(conversationID) {
            return
        }
        try? store.clearWakeClose(id: id)
        logger.info("wake creator closed", metadata: ["wake": .stringConvertible(id), "conversation": .string(conversationID)])
    }

    // MARK: 文と id

    /// 会話に入れる文。1 行目に予定の時刻、項目の後の「作成時の指示:」の下に予定を作ったときの指示
    static func text(_ row: Store.WakeRow, now: Date) -> String {
        var lines = [
            TaskboardNotice.marker(.wake, ["id": "\(row.id ?? 0)"]),
            TaskboardNotice.wakePrefix + "\(row.id ?? 0)（\(Wake.agentTime(row.at))）" + TaskboardNotice.wakeMarker,
            TaskboardNotice.senderItem,
        ]
        if now.timeIntervalSince(row.at) >= lateAfter {
            lines.append(Copy.text("agent.notice.wakeService.lines", ["agentTime": "\(Wake.agentTime(now))"]))  // ui-copy:ignore（会話に入れる文。agent が読む）
        }
        lines += [TaskboardNotice.promptHeading, row.prompt]  // ui-copy:ignore（会話に入れる文。agent が読む）
        return lines.joined(separator: "\n")
    }

    /// 会話に入れる発言の uuid の元（`NoticeDelivery` が取り消された回数を付ける）
    static func uuidSeed(wakeID: Int64) -> String { "taskboard-wake:\(wakeID)" }
    /// タスク宛てで新しく起こす会話の id
    static func conversationID(wakeID: Int64) -> String { StableUUID.make("taskboard-wake-conversation:\(wakeID)") }
}
