import Foundation
import Logging
import TaskboardKit

/// host の会話への届け口（`ConversationService`）。`FeedbackService` と `ConversationService` は互いを呼ぶので、組み立てた後に `setConversations` で渡す
protocol FeedbackConversations: Sendable {
    /// その Claude の会話 ID（`/clear` の前のものを含む）を持つ host の会話。止まっている会話も返す
    func conversationID(owning agentSessionID: String) async -> String?
    /// 空いている（生成中でも問い待ちでもない）host の会話と、結ばれたタスク
    func idleConversations() async -> [(id: String, task: Int)]
    /// 発言として入れる。止まっている会話は `kind.wake` が起こすなら起こしてから入れ、会話が無いか起こせなければ nil
    func deliver(conversationID: String, text: String, uuid: String, kind: DeliveryKind) async -> ConversationDeliveryOutcome?
    /// 止まった TUI の lead を、`kind` が戻すものなら会話で戻す。戻した会話が入力待ちに入ったら（`conversationIdle`）そこへ入れる
    func resumeStoppedLead(task number: Int, agentSessionID: String, for kind: DeliveryKind) async
}

/// 人のフィードバック（質問の回答・レビュー・済ませた手作業）をセッションへ届ける窓口。
///
/// 届け先は、質問・レビューを頼んだ会話（記録の `requesterSessionId`）。host の会話ならそこへ発言として入れる。
/// 頼んだ会話が host の会話でない分（taskboard の外の Claude Code・頼まれずに送ったレビュー・前の版の記録・頼んだ会話がもう無い）は、
/// Stop hook が取りに来なければタスクの lead（`TaskDeliveryTarget`）に届ける。届け方は 2 つ。
///
/// - **host の会話**: daemon が持つ会話には、空いているときに発言として入れる（`deliverViaHost`）。入力待ちに入ったとき（`conversationIdle`）にも試す
/// - **hook**: taskboard の外の Claude Code（普段使いの端末・`claude -p`）は、Stop hook が `claim` で取りに来る。
///   未受領があれば claim を切って返し、hook が stderr に載せきったら `ack` で受領済みにする。無ければ届くまで待つ（`notify` で起きる）。
///   hook は毎ターン走るので、同じタスクの前の待機者は新しい claim が来た時点で解放する
///
/// claim はメモリだけ（TTL 2 時間）。ack されなければ未受領のまま残り、次の claim か `feedback_list` で再配送される。
/// 回答・レビューが届くと、タスクに結ばれたセッションに印（`FeedbackMarkers`）を置く。ターンの途中の hook（PostToolUse・UserPromptSubmit）は
/// 印のあるときだけ待たずに claim する（Stop hook はターンの終わりにしか走らず、割り込みでは走らない）。
/// 会話に入れている間の分は hook の claim に載せず、hook が claim して ack するまでの分は会話に入れない（同じ回答を 2 回入れない）
public actor FeedbackService {
    struct Claim {
        var taskNumber: Int
        var items: [Store.FeedbackItem]
        var createdAt: Date
        /// host の会話に入れている最中の分（hook の claim に載せない）
        var delivering = false
    }

    /// 1 件ずつの届け先
    enum Route: Hashable {
        case conversation(String)
        /// 頼んだ会話が無い。タスクに結ばれたセッションから決める
        case estimate
    }

    let store: Store
    let state: DaemonState
    let markers: FeedbackMarkers?
    private let now: @Sendable () -> Date
    private var claims: [String: Claim] = [:]
    private var waiters: [Int: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    /// 入れている最中の host の会話
    private var deliveringConversations: Set<String> = []
    private var conversations: (any FeedbackConversations)?
    private let logger = Logger(label: "uk.whatn.taskboardd.feedback")

    static let claimTTL: TimeInterval = 2 * 3600
    /// hook が待つ既定（kairan と同じ 1 時間）。settings.json の timeout 3900 秒より短い
    public static let defaultWaitMs = 3_600_000
    public static let maxWaitMs = 3_600_000
    /// hook が claim してから ack するまでの間。この間の分は会話に入れない（hook は claim の直後に出力して ack する）
    static let hookClaimWindow: TimeInterval = 30
    static let resyncInterval: Duration = .seconds(300)
    /// host の会話に入れる文の上限。発言として送るので、端末に貼るときの 4,000 字では切らない
    static let hostPromptLimit = 200_000

    public init(store: Store, state: DaemonState, markers: FeedbackMarkers? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.state = state
        self.markers = markers
        self.now = now
    }

    func setConversations(_ conversations: any FeedbackConversations) {
        self.conversations = conversations
    }

    /// MCP が送った手がかりから、頼んだ Claude の会話 ID を決める。host の会話は今の ID、そうでなければ環境のセッション ID
    public func requesterSessionID(_ requester: FeedbackRequester?) async -> String? {
        guard let requester else { return nil }
        if let id = requester.conversationID, let record = try? store.conversation(id: id) { return record.agentSessionId }
        return requester.agentSessionID
    }

    /// セッションに紐づくタスクの未受領フィードバックを返す。無ければ届くまで（`timeoutMs` まで）待つ。
    /// 待つのは taskboard の外のセッションの Stop hook。
    /// `timeoutMs` が 0 なら待たず、このセッションの印を消す（長くて ack できなかった分を、ツールのたびに入れ直さない）。
    /// 0 のときは同じタスクの待機者（前のターンの Stop hook）を解放しない
    public func claim(_ request: FeedbackClaimRequest) async throws -> FeedbackClaimResponse {
        guard let task = try store.task(linkedToSession: request.agentSessionID) else {
            markers?.clear(sessions: [request.agentSessionID])
            return FeedbackClaimResponse(status: .noSession)
        }
        dropExpiredClaims()
        if request.timeoutMs == 0 {
            markers?.clear(sessions: [request.agentSessionID])
            return try await claimIfAny(task: task.number) ?? FeedbackClaimResponse(status: .pending)
        }
        if let response = try await claimIfAny(task: task.number) { return response }
        let timeout = min(max(request.timeoutMs ?? Self.defaultWaitMs, 1), Self.maxWaitMs)
        releaseWaiters(task: task.number)
        _ = await wait(task: task.number, timeoutMs: timeout)
        // 待っている間にタスクが消えていたら no-session
        guard try store.task(number: task.number) != nil else { return FeedbackClaimResponse(status: .noSession) }
        return try await claimIfAny(task: task.number) ?? FeedbackClaimResponse(status: .pending)
    }

    /// 届けきれたので受領済みにする。知らない claim は false。
    public func ack(claimID: String) async throws -> Bool {
        guard let claim = claims.removeValue(forKey: claimID) else { return false }
        _ = try store.markFeedbackDelivered(claim.items)
        // claim の後に届いた分が残っていれば、印はそのままにする
        if try store.peekUndeliveredFeedback(task: claim.taskNumber).bundle.isEmpty { try clearMarkers(task: claim.taskNumber) }
        return true
    }

    /// `feedback_list`: 未受領を返して受領済みにする。
    public func take(task number: Int) async throws -> FeedbackBundle {
        let (bundle, _) = try store.takeUndeliveredFeedback(task: number)
        try clearMarkers(task: number)
        return bundle
    }

    /// 回答・レビューの送信と、手作業を済ませたときに呼ぶ。結ばれたセッションに印を置き、そのタスクを待っている hook を起こし、頼んだ会話に入れる。
    /// 印を先に置く（起きた Stop hook が ack した後に置くと、受領済みなのに印が残る）
    public func notify(task number: Int) async {
        if let markers, let sessions = try? store.agentSessionIDs(linkedToTask: number) { markers.mark(sessions: sessions) }
        var estimate = true
        if let pending = waiters.removeValue(forKey: number) {
            // taskboard の外のセッションの Stop hook が待っていた。頼んだ会話の決まっていない分はそちらが取るので、lead には入れない
            for continuation in pending.values { continuation.resume(returning: true) }
            estimate = false
        }
        await deliver(task: number, estimate: estimate)
    }

    /// host の会話が入力待ち（idle）に入った（`ConversationService.onIdle`）
    public func conversationIdle(_ id: String) async {
        guard hasUndelivered(),
            let task = await conversations?.idleConversations().first(where: { $0.id == id })?.task
        else { return }
        await deliver(task: task)
    }

    /// タスクに結ばれたときに入れる。取りこぼしに備えて `resyncInterval` ごとに全部を見直す
    public func run() async {
        await state.observe(every: Self.resyncInterval, sweepFirst: false, handle: { await self.handle($0) }, sweep: { await self.sweep() })
    }

    func handle(_ event: DaemonEvent) async {
        switch event {
        case .taskUpdated(let task):
            // 再開の直後は、idle を見た時点でまだ結ばれていない（session ID が付くまで 30 秒かかることがあり、SessionStart の結びはその後に来ることもある）
            await deliver(task: task.number)
        case .stateSnapshot:
            await sweep()
        default:
            return
        }
    }

    /// 空いている host の会話が結ばれたタスクを全部見直す
    func sweep() async {
        guard hasUndelivered() else { return }
        var numbers: Set<Int> = []
        for conversation in await conversations?.idleConversations() ?? [] { numbers.insert(conversation.task) }
        for number in numbers.sorted() { await deliver(task: number) }
    }

    /// タスクの未受領を届け先ごとに分けて入れる。`estimate` が false なら、頼んだ会話の決まっていない分は入れない（taskboard の外のセッションの Stop hook が取る）
    func deliver(task number: Int, estimate: Bool = true) async {
        dropExpiredClaims()
        guard hasUndelivered(task: number), let pending = try? store.peekUndeliveredFeedback(task: number) else { return }
        let free = excludingBusy(pending, at: now())
        guard !free.bundle.isEmpty else { return }
        let routes = await routes(free).sorted { String(describing: $0.key) < String(describing: $1.key) }
        for (route, items) in routes {
            let subset = free.only(items)
            switch route {
            case .conversation(let id):
                await deliverViaHost(subset, conversation: id, task: number)
            case .estimate:
                guard estimate, waiters[number]?.isEmpty ?? true else { continue }
                switch await lead(task: number) {
                // 止まった lead の会話は起こして入れる（頼んだ会話が host の会話のときと同じ）
                case .conversation(let id): await deliverViaHost(subset, conversation: id, task: number)
                // 止まった TUI は会話で戻し、空いたら入れる
                case .stoppedTerminal(let agentSessionID): await conversations?.resumeStoppedLead(task: number, agentSessionID: agentSessionID, for: .feedback)
                case nil: break
                }
            }
        }
    }

    /// 1 件ずつの届け先。頼んだ会話が host の会話なら、その会話（止まっていても。未受領のまま残る）。そうでなければ決める
    func routes(_ pending: Store.UndeliveredFeedback) async -> [Route: Set<Store.FeedbackItem>] {
        var resolved: [String: Route] = [:]
        var result: [Route: Set<Store.FeedbackItem>] = [:]
        for item in pending.items {
            var route = Route.estimate
            if let requester = pending.requesters[item] {
                if let known = resolved[requester] {
                    route = known
                } else {
                    if let owner = await conversations?.conversationID(owning: requester) { route = .conversation(owner) }
                    resolved[requester] = route
                }
            }
            result[route, default: []].insert(item)
        }
        return result
    }

    /// host の会話に発言として入れる。モデルに渡ったら受領済みにする。待ち行列に入ったまま取り消されたら回数を進めて未受領に残し
    /// （次に空いたときに別の uuid で届ける）、生成中・止まっている・確かめられなかったときは未受領のまま残す
    func deliverViaHost(_ subset: Store.UndeliveredFeedback, conversation id: String, task number: Int) async {
        guard let conversations, !deliveringConversations.contains(id), let free = stillFree(subset, task: number) else { return }
        let prompt = FeedbackText.forPrompt(free.bundle, limitChars: Self.hostPromptLimit)
        // 1 件で上限を超えるものは feedback_list で取ってもらう（入れる文が無い）
        guard !prompt.included.isEmpty else { return }
        let included = free.only(Set(prompt.included.reviews.map { .review($0.review.id) } + prompt.included.answeredAsks.map { .ask($0.askID) }
            + prompt.included.finishedWork.map { .finished($0.itemID) }
            + prompt.included.drafts.map { .draft($0.answerID) }))
        let claimID = UUID().uuidString.lowercased()
        claims[claimID] = Claim(taskNumber: number, items: included.items, createdAt: now(), delivering: true)
        deliveringConversations.insert(id)
        defer { deliveringConversations.remove(id) }
        let outcome = await conversations.deliver(conversationID: id, text: prompt.text, uuid: Self.messageID(included), kind: .feedback)
        let metadata: Logger.Metadata = [
            "task": .stringConvertible(number), "conversation": .string(id), "reviews": .stringConvertible(included.bundle.reviews.count),
            "asks": .stringConvertible(included.bundle.answeredAsks.count), "finished": .stringConvertible(included.bundle.finishedWork.count), "outcome": .string(outcome.map { "\($0)" } ?? "stopped"),
        ]
        switch outcome {
        case .delivered:
            logger.info("feedback sent to conversation", metadata: metadata)
            _ = try? await ack(claimID: claimID)
        case .cancelled:
            logger.info("feedback cancelled in conversation", metadata: metadata)
            claims.removeValue(forKey: claimID)
            try? store.markFeedbackAttempted(included.items)
        case .busy, .unknown, nil:
            claims.removeValue(forKey: claimID)
        }
    }

    /// host の会話に入れる発言の uuid。同じ回答とレビューを同じ回数で届けるなら同じ値にし、daemon が送った後 ack の前に落ちても、
    /// 起き直した後に会話が受けた uuid（控えか記録の `recentMessageIds`）と照らして二重に入れない
    static func messageID(_ feedback: Store.UndeliveredFeedback) -> String {
        let seed = "taskboard-feedback:" + feedback.items.map { item in
            let attempt = feedback.attempts[item] ?? 0
            switch item {
            case .review(let id): return "r\(id).\(attempt)"
            case .ask(let id): return "a\(id).\(attempt)"
            case .finished(let id): return "w\(id).\(attempt)"
            case .draft(let id): return "p\(id).\(attempt)"
            }
        }.joined(separator: ",")
        return StableUUID.make(seed)
    }

    /// 最後の await の後、claim を置く前に呼ぶ（間にほかの配送が同じ分を取っていないか、記録と claim を読み直す）
    private func stillFree(_ subset: Store.UndeliveredFeedback, task number: Int) -> Store.UndeliveredFeedback? {
        dropExpiredClaims()
        guard let current = try? store.peekUndeliveredFeedback(task: number) else { return nil }
        let free = excludingBusy(current.only(Set(subset.items)), at: now())
        return free.bundle.isEmpty ? nil : free
    }

    /// その Claude の会話 ID を持つ host の会話の id
    func conversationID(owning agentSessionID: String) async -> String? {
        await conversations?.conversationID(owning: agentSessionID)
    }

    /// 頼んだ会話の決まっていない分の届け先（タスクの lead）
    func lead(task number: Int) async -> TaskDeliveryTarget? {
        await TaskDeliveryTarget.lead(task: number, state: state, conversations: conversations)
    }

    /// 入れている最中の分と、hook が claim して ack を待つ分を除く
    private func excludingBusy(_ pending: Store.UndeliveredFeedback, at: Date) -> Store.UndeliveredFeedback {
        let busy = claims.values.filter { $0.delivering || at.timeIntervalSince($0.createdAt) < Self.hookClaimWindow }
        return pending.excluding(Set(busy.flatMap(\.items)))
    }

    func waiterCount(task number: Int) -> Int { waiters[number]?.count ?? 0 }

    /// state のイベントのたびに呼ぶので、未受領を読む前にこれで絞る（Store の控えを見るだけで、たいてい DB に行かない）。
    /// 控えを読めなければ、読んでみる側に倒す
    private func hasUndelivered(task number: Int? = nil) -> Bool {
        guard let numbers = try? store.tasksWithUndeliveredFeedback() else { return true }
        return number.map(numbers.contains) ?? !numbers.isEmpty
    }

    /// hook の claim で取ってよいのは、頼んだ会話の決まっていない分。host の会話に届ける分は取らない
    private func claimIfAny(task number: Int) async throws -> FeedbackClaimResponse? {
        let peeked = try store.peekUndeliveredFeedback(task: number)
        guard !peeked.bundle.isEmpty else { return nil }
        var kept: Set<Store.FeedbackItem> = []
        for (route, items) in await routes(peeked) {
            switch route {
            case .estimate: kept.formUnion(items)
            case .conversation: continue
            }
        }
        // await の後なので読み直す
        let inFlight = claims.values.filter(\.delivering)
        let pending = try store.peekUndeliveredFeedback(task: number).only(kept)
            .excluding(Set(inFlight.flatMap(\.items)))
        guard !pending.bundle.isEmpty else { return nil }
        let id = UUID().uuidString.lowercased()
        claims[id] = Claim(taskNumber: number, items: pending.items, createdAt: now())
        logger.info(
            "feedback claimed",
            metadata: [
                "task": .stringConvertible(number), "reviews": .stringConvertible(pending.bundle.reviews.count),
                "asks": .stringConvertible(pending.bundle.answeredAsks.count), "finished": .stringConvertible(pending.bundle.finishedWork.count),
            ])
        return FeedbackClaimResponse(status: .feedback, claimID: id, bundle: pending.bundle)
    }

    private func releaseWaiters(task number: Int) {
        guard let pending = waiters.removeValue(forKey: number) else { return }
        for continuation in pending.values { continuation.resume(returning: false) }
    }

    /// 通知で true、timeout か解放で false。
    private func wait(task number: Int, timeoutMs: Int) async -> Bool {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            await self?.timeOut(task: number, id: id)
        }
        let signalled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters[number, default: [:]][id] = continuation
        }
        timer.cancel()
        return signalled
    }

    private func timeOut(task number: Int, id: UUID) {
        guard let continuation = waiters[number]?.removeValue(forKey: id) else { return }
        if waiters[number]?.isEmpty == true { waiters.removeValue(forKey: number) }
        continuation.resume(returning: false)
    }

    private func clearMarkers(task number: Int) throws {
        guard let markers else { return }
        markers.clear(sessions: try store.agentSessionIDs(linkedToTask: number))
    }

    private func dropExpiredClaims() {
        let cutoff = now().addingTimeInterval(-Self.claimTTL)
        claims = claims.filter { $0.value.createdAt >= cutoff }
    }
}
