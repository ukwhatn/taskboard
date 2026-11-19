import Foundation
import Logging
import TaskboardKit

extension ConversationService {
    /// 起動の画面が開いている間に温めておく会話のプロセス。DB に記録を作らず（捨てた事前起動の記録を残さない）、引き取るときに作る
    struct Prewarm {
        enum Phase: String {
            /// 起こしている（initialize まで）
            case starting
            /// 待っている
            case parked
            /// 会話として引き取っている
            case adopting
            /// 捨てている
            case discarding
        }

        /// 引き取ったときの会話の id（host の key も同じ）
        var id: String
        var agentSessionID: String
        var request: ConversationPrewarmRequest
        var phase: Phase
        var helper: HelperProcess
        /// host の行（`route` が入れ、1 本の Task が順に `helper` へ渡す）
        var inbox: AsyncStream<AgentHostNotice>.Continuation
        var start: Task<Bool, Never>?
        var expiry: Task<Void, Never>?
        var discard: Task<Void, Never>?
    }

    /// 条件（cwd・モデル・effort・権限）で新しい会話のプロセスを温めておく。同じ条件なら捨てる時を延ばすだけ。違えば今のものを止め終えてから起こす
    /// （2 本が同時に枠を持たない）。目安の上限に空きが無ければ何もしない（温めるためにほかの会話を止めない）
    func prewarm(_ request: ConversationPrewarmRequest) async throws {
        var request = request
        if request.cwd.isEmpty { request.cwd = environment.home }
        request.model = try validated(
            ConversationStartRequest(cwd: request.cwd, model: request.model, effort: request.effort, permissionMode: request.permissionMode)
        ).model
        if let current = prewarm, current.phase == .starting || current.phase == .parked, Self.matches(current.request, request) {
            schedulePrewarmExpiry(current.id)
            return
        }
        await discardPrewarm()
        // 捨てている間に別の事前起動が入った
        guard prewarm == nil else { return }
        let id = UUID().uuidString.lowercased()
        let session = UUID().uuidString.lowercased()
        guard environment.slots.reserve(id, withinSoft: true) else { return }
        guard environment.reservations.reserve(ClaudeConversation.reservationKey(session), owner: id) else {
            environment.slots.release(id)
            return
        }
        let helper = HelperProcess(key: id, host: host)
        let (stream, inbox) = AsyncStream<AgentHostNotice>.makeStream()
        Task { for await notice in stream { await helper.receive(notice) } }
        prewarm = Prewarm(id: id, agentSessionID: session, request: request, phase: .starting, helper: helper, inbox: inbox)
        prewarm?.start = Task { await self.startPrewarm(id) }
        schedulePrewarmExpiry(id)
    }

    static func matches(_ prewarm: ConversationPrewarmRequest, _ request: ConversationStartRequest) -> Bool {
        matches(prewarm, ConversationPrewarmRequest(cwd: request.cwd, model: request.model, effort: request.effort, permissionMode: request.permissionMode))
    }

    static func matches(_ a: ConversationPrewarmRequest, _ b: ConversationPrewarmRequest) -> Bool {
        a.cwd == b.cwd && a.model == b.model && a.effort == b.effort && a.permissionMode == b.permissionMode
    }

    /// 起こして initialize まで済ませる（hook の登録と MCP の接続）。起こせなければ捨てて false
    func startPrewarm(_ id: String) async -> Bool {
        guard let current = prewarm, current.id == id else { return false }
        let helper = current.helper
        do {
            let launch = try await launch()
            let record = ConversationRecord(
                id: id, taskNumber: nil, agentSessionId: current.agentSessionID, cwd: current.request.cwd, model: current.request.model,
                effort: current.request.effort, permissionMode: current.request.permissionMode, runner: .none)
            try await helper.spawn(
                argv: ClaudeConversation.arguments(record: record, executable: launch.executable, resume: false),
                env: ClaudeConversation.environment(launch.environment, conversationID: id), cwd: current.request.cwd)
            let response = try await helper.control("initialize", ClaudeConversation.initialize, timeout: environment.timing.control)
            guard response.isSuccess else { throw ConversationError.failed("initialize を断られた: \(response.error ?? "")") }
            if let listed = ClaudeControls.models(initializePayload: response.payloadJSON) {
                Self.recordModels(listed.models, version: listed.version, supportDirectory: environment.supportDirectory, logger: environment.logger)
            }
        } catch {
            environment.logger.info("conversation prewarm failed", metadata: ["error": .string("\(error)")])
            // 捨てる処理はこの Task の終わりを待つので、ここでは待たない
            if prewarm?.id == id, prewarm?.phase == .starting { Task { await self.discardPrewarm() } }
            return false
        }
        guard prewarm?.id == id, prewarm?.phase == .starting else { return false }
        prewarm?.phase = .parked
        Task {
            await helper.waitUntilExited()
            await self.prewarmExited(id)
        }
        environment.logger.info("conversation prewarmed", metadata: ["key": .string(id)])
        return true
    }

    /// 待っている子が自分で終わった
    func prewarmExited(_ id: String) async {
        guard prewarm?.id == id, prewarm?.phase == .parked else { return }
        await discardPrewarm()
    }

    func schedulePrewarmExpiry(_ id: String) {
        prewarm?.expiry?.cancel()
        let lifetime = environment.prewarmLifetime
        prewarm?.expiry = Task { [weak self] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            await self?.prewarmExpired(id)
        }
    }

    func prewarmExpired(_ id: String) async {
        guard let current = prewarm, current.id == id, current.phase == .starting || current.phase == .parked else { return }
        environment.logger.info("conversation prewarm expired", metadata: ["key": .string(id)])
        await discardPrewarm()
    }

    /// 今の事前起動を止め、止め終えてから枠と予約を返す。捨てている途中なら終わるまで待つ。引き取っている途中なら何もしない
    func discardPrewarm() async {
        guard var current = prewarm, current.phase != .adopting else { return }
        if let running = current.discard {
            await running.value
            // 先に捨て始めた側が nil にするより先に戻ることがある（残すと、呼んだ側が別の事前起動が入ったと読む）
            if prewarm?.id == current.id { prewarm = nil }
            return
        }
        current.phase = .discarding
        current.expiry?.cancel()
        let (helper, start, id, session) = (current.helper, current.start, current.id, current.agentSessionID)
        let (timing, slots, reservations, inbox) = (environment.timing, environment.slots, environment.reservations, current.inbox)
        let task = Task {
            _ = await helper.finish(timing)
            _ = await start?.value
            inbox.finish()
            slots.release(id)
            reservations.release(ClaudeConversation.reservationKey(session), owner: id)
        }
        current.discard = task
        prewarm = current
        await task.value
        if prewarm?.id == id { prewarm = nil }
    }

    /// 条件が同じ事前起動を会話として引き取る。起こしている途中なら起き終えるのを待つ。引き取れなければ nil（呼ぶ側が普通に起こす）。
    /// 条件が違えば捨てる（止め終えてから、呼ぶ側が新しく起こす）
    func adoptPrewarm(_ request: ConversationStartRequest) async throws -> ConversationRecord? {
        guard let current = prewarm, current.phase != .adopting else { return nil }
        guard current.phase != .discarding, Self.matches(current.request, request) else {
            await discardPrewarm()
            return nil
        }
        guard await current.start?.value == true, var parked = prewarm, parked.id == current.id, parked.phase == .parked else {
            await discardPrewarm()
            return nil
        }
        parked.phase = .adopting
        parked.expiry?.cancel()
        prewarm = parked
        let id = parked.id
        let process: AgentHostProcessInfo
        let record: ConversationRecord
        do {
            guard let found = try await host.list().first(where: { $0.key == id }), found.alive else { throw ConversationError.failed("事前起動の子が無い") }
            process = found
            record = try environment.store.createConversation(
                ConversationRecord(
                    id: id, taskNumber: request.taskNumber, agentSessionId: parked.agentSessionID, cwd: parked.request.cwd, model: parked.request.model,
                    effort: parked.request.effort, permissionMode: parked.request.permissionMode, runner: .host))
        } catch {
            environment.logger.info("conversation prewarm not adopted", metadata: ["error": .string("\(error)")])
            prewarm?.phase = .parked
            await discardPrewarm()
            return nil
        }
        // 会話の actor を先に作り、以後の host の行を会話に入れる（引き取りは控えの頭から読み直す）
        let conversation = try make(record)
        prewarm = nil
        parked.inbox.finish()
        await parked.helper.abandon()
        await conversation.attach(process: process, prewarmed: true)
        // 枠は live の会話に移った。予約は同じ持ち主（会話の id）のまま
        environment.slots.release(id)
        environment.logger.info("conversation prewarm adopted", metadata: ["conversation": .string(id)])
        return record
    }
}
