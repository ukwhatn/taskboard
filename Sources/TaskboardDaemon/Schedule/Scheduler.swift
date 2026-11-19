import Foundation
import Logging
import TaskboardKit

/// 定期起動を時刻どおりに起こす。各回は `scheduleRun` に記録してから起こすので、
/// daemon の再起動や tick の重なりで同じ回を 2 度起こさない（記録の UNIQUE が弾く）。
///
/// 各回は host の会話で動かす。会話の id と最初の発言の uuid は回の id から決め、回を記録する書き込みで会話の id も入れる
/// （同じ回の 2 つ目は会話の表の主キーが断る）。会話を起こせない回（読み替えられない引数・CLI や agent host が無い）は失敗に記録する
public actor Scheduler {
    let store: Store
    let state: DaemonState
    let conversations: ConversationService
    /// Claude Code のアカウント。あれば、全部のアカウントの利用枠が尽きたときだけ後へ回す
    let accounts: ClaudeAccounts?
    let interval: Duration
    let isFullWake: @Sendable () -> Bool
    let isOnline: @Sendable () -> Bool
    private let startedAt = Date()
    private let logger = Logger(label: "uk.whatn.taskboardd.schedule")

    init(
        store: Store, state: DaemonState, conversations: ConversationService, accounts: ClaudeAccounts?, interval: Duration = .seconds(20),
        isFullWake: @escaping @Sendable () -> Bool = SystemPower.isFullWake, isOnline: @escaping @Sendable () -> Bool = NetworkPath.isSatisfied
    ) {
        self.store = store
        self.state = state
        self.conversations = conversations
        self.accounts = accounts
        self.interval = interval
        self.isFullWake = isFullWake
        self.isOnline = isOnline
    }

    public func run() async {
        // 起動直後は agent host が会話を引き取っておらず、前回の会話が動いているかを判定できない
        await state.waitForAgentHost()
        Task { await self.recoverInterruptedRuns() }
        while !Task.isCancelled {
            await tick(now: Date())
            try? await Task.sleep(for: interval)
        }
    }

    /// 過ぎた時刻があれば最新の 1 回だけ起こす（スリープ中に過ぎた分をまとめて 1 回にする）。あわせて全件の見え方を配り直す。
    /// DarkWake の間は記録もしない。起こした回はネットワークの無いまま次に起きるまで止まり、重なりの skip で次の回まで飛ばす（2026-10-06 の 20:00 の回）。
    /// 記録しなければ、完全に起きた最初の tick で過ぎた分の最新の 1 回として起こす。
    /// 回線が無い・利用枠が尽きそうな間の回は、理由を付けてスキップに記録し、戻った最初の tick で 1 回だけ起こす（`catchUpDeferred`）
    func tick(now: Date) async {
        guard isFullWake() else { return }
        for (schedule, at) in (try? store.dueSchedules(now: now)) ?? [] {
            let busy = schedule.overlap == .skip ? await previousRunIsActive(schedule) : false
            let skipped = busy ? Self.skippedBusyReason : await deferralReason(schedule, now: now)
            await fire(schedule, at: at, skipped: skipped, now: now)
        }
        await catchUpDeferred(now: now)
    }

    private func fire(_ schedule: Schedule, at: Date, skipped: String?, now: Date) async {
        do {
            if let run = try store.recordScheduleRun(
                id: schedule.scheduleID, at: at, trigger: .schedule, skipped: skipped, conversationID: Self.conversationID(runID:), now: now)
            {
                logger.info(
                    "schedule due", metadata: ["id": .stringConvertible(schedule.scheduleID), "at": .stringConvertible(at), "skipped": .string(skipped ?? "")])
                await start(schedule, run)
            }
        } catch {
            logger.warning("schedule record failed", metadata: ["id": .stringConvertible(schedule.scheduleID), "error": .string("\(error)")])
        }
    }

    /// 最後の回を後へ回した定期起動を、回せなくなった理由が消えたら今の時刻の回として起こす。
    /// 後へ回した後に人が定期起動を変えた（止めて再開した・規則を変えた）ものは起こさない（`updatedAt` がその回より後）
    func catchUpDeferred(now: Date) async {
        for schedule in (try? store.schedules(now: now)) ?? [] where schedule.enabled {
            guard let last = schedule.lastRun, last.trigger == .schedule, let skipped = last.skipped, Self.deferralReasons.contains(skipped),
                last.createdAt >= schedule.updatedAt
            else { continue }
            guard await deferralReason(schedule, now: now) == nil else { continue }
            logger.info("deferred schedule caught up", metadata: ["id": .stringConvertible(schedule.scheduleID), "deferredAt": .stringConvertible(last.scheduledAt)])
            let busy = schedule.overlap == .skip ? await previousRunIsActive(schedule) : false
            await fire(schedule, at: Store.storedDate(now), skipped: busy ? Self.skippedBusyReason : nil, now: now)
        }
    }

    /// 今は起こさず後へ回す理由。回線が無い（どの agent も API に届かない）か、Claude の回で利用枠が上限か閾値を越えている
    func deferralReason(_ schedule: Schedule, now: Date) async -> String? {
        if !isOnline() { return Self.offlineReason }
        if schedule.kind == .claude, await claudeUsageExhausted(now: now) { return Self.usageLimitReason }
        return nil
    }

    /// マシンの利用枠（statusline と会話の報告）が区切る閾値を越えているか、上限で待っている・区切って待っている会話がある。
    /// Claude Code のアカウントがあれば、全部のアカウントが越えているときだけ（起こすときに越えていないアカウントへ移す）
    private func claudeUsageExhausted(now: Date) async -> Bool {
        let pause = ((try? store.settings()) ?? .defaults).usagePause
        if let accounts, await accounts.hasAccounts { return await accounts.allExhausted(pause: pause, now: now) }
        if let claude = await state.usageSnapshot().claude {
            let windows = ["five_hour": claude.fiveHour, "seven_day": claude.sevenDay].compactMapValues { $0 }
            if UsagePauseRule.resetsAt(windows: windows, pause: pause, now: now) != nil { return true }
        }
        return await conversations.waitsForUsage(now: now)
    }

    /// 前回の実行が動いているときのスキップの理由（アプリはこの文を help に出す）
    public static let skippedBusyReason = "前回の実行が終わっていません"
    /// 後へ回した回のスキップの理由。戻ったら 1 回だけ起こす
    public static let offlineReason = "ネットワークに接続していないため、接続してから実行します"
    public static let usageLimitReason = "利用枠が残り少ないため、戻ってから実行します"
    static let deferralReasons: Set<String> = [offlineReason, usageLimitReason]
    static let interruptedReason = "起動の途中でTaskboardが停止しました"
    static let recoveryWindow: TimeInterval = 3600

    /// 会話で動かす回の会話の id（回答の配送の uuid と同じ作り方）
    static func conversationID(runID: Int64) -> String { StableUUID.make("taskboard-schedule-run:\(runID)") }
    /// 会話で動かす回の最初の発言の uuid
    static func firstMessageID(runID: Int64) -> String { StableUUID.make("taskboard-schedule-prompt:\(runID)") }

    /// 「今すぐ実行」。重なりの設定は見ない（人が押したので）
    public func runNow(id: Int64, now: Date = Date()) async throws -> ScheduleRun {
        let schedule = try store.schedule(id: id, now: now)
        guard let run = try store.recordScheduleRun(id: id, at: now, trigger: .manual, skipped: nil, conversationID: Self.conversationID(runID:), now: now)
        else {
            throw StoreError.refused(.scheduleRunExists, [:], "同じ時刻の回が既にある")
        }
        await start(schedule, run)
        return try store.scheduleRuns(id: id, limit: 1).first ?? run
    }

    /// 前回の回の会話が止まっていない
    func previousRunIsActive(_ schedule: Schedule) async -> Bool {
        guard let last = schedule.lastRun, last.skipped == nil, let id = last.conversationID else { return false }
        return await conversations.isLive(id)
    }

    private func start(_ schedule: Schedule, _ run: ScheduleRun) async {
        guard let id = run.conversationID else { return }
        do {
            var request = try await conversations.launchRequest(kind: schedule.kind, agentArgs: schedule.agentArgs, cwd: schedule.cwd, taskNumber: schedule.taskNumber)
            request.prompt = schedule.prompt
            request.title = ConversationInput.clippedTitle(schedule.name)
            _ = try await conversations.start(request, purpose: .schedule, id: id, firstMessageID: Self.firstMessageID(runID: run.id))
        } catch {
            // 起こした会話が最初の発言を受けていなければ止める
            logger.warning("schedule conversation failed", metadata: ["id": .stringConvertible(schedule.scheduleID), "error": .string("\(error)")])
            try? store.markScheduleRunFailed(runID: run.id, reason: String(describing: error))
            await conversations.stopQuietly(id)
        }
    }

    /// daemon が起き直した：会話の回のうち、この daemon が起こす前に記録した回で、会話の記録が無いか最初の発言を受けていないものは、
    /// 起こす途中で止まった回として失敗にする（起こし直さない。会話は止める）。agent host に繋がって会話を引き取るのを待ってから見る
    func recoverInterruptedRuns(hostGrace: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + .seconds(120)
        while await state.machineInfo().agentHost?.connected != true, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: hostGrace)
        // shortcut: 起こす途中で止まった回を、この daemon の起動の前 1 時間に記録した回に絞る（古い回は、人が会話を消して記録が無くても失敗にしない）。
        // daemon が止まったまま 1 時間を過ぎた回は見逃す。見逃しが問題になったら、最初の発言を受けた印を回に持たせる
        let window = startedAt.addingTimeInterval(-Self.recoveryWindow)
        for run in (try? store.conversationScheduleRuns()) ?? [] where run.createdAt < startedAt && run.createdAt > window {
            guard let id = run.conversationID else { continue }
            if run.stage == nil {
                try? store.markScheduleRunFailed(runID: run.id, reason: Self.interruptedReason)
            } else if await !conversations.received(id, uuid: Self.firstMessageID(runID: run.id)) {
                try? store.markScheduleRunFailed(runID: run.id, reason: Self.interruptedReason)
                await conversations.stopQuietly(id)
            } else {
                continue
            }
            logger.warning("schedule run interrupted", metadata: ["run": .stringConvertible(run.id), "conversation": .string(id)])
        }
    }
}
