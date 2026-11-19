import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("定期起動の記録と起こし方")
struct SchedulerTests {
    let machine = MachineID(rawValue: "m-test")
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    func makeStore() throws -> (Store, Board) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        return (store, board)
    }

    func every(_ minutes: Int) -> ScheduleRule { .interval(minutes: minutes) }

    @Test("常設タスクを作って結び、次の時刻は作成の時刻から数える")
    func createWithTask() throws {
        let (store, board) = try makeStore()
        let (schedule, task) = try store.createSchedule(
            ScheduleCreateRequest(name: "PR 棚卸し", rule: every(60), cwd: "~/dev", kind: .claude, prompt: "棚卸し", newTask: .init(boardID: board.id, columnID: board.columns[0].id)),
            now: t0)
        let created = try #require(task)
        #expect(created.title == "PR 棚卸し")
        #expect(schedule.taskNumber == created.number)
        #expect(schedule.nextAt == t0.addingTimeInterval(3600))
        #expect(schedule.lastRun == nil)
    }

    @Test("同じ時刻の回は 2 度記録しない。過ぎた分は最新の 1 回だけ")
    func dedupeAndCatchUp() throws {
        let (store, _) = try makeStore()
        let (schedule, _) = try store.createSchedule(ScheduleCreateRequest(name: "a", rule: every(60), cwd: "", kind: .claude, prompt: ""), now: t0)
        // 3 時間半スリープしていた: 1h / 2h / 3h が過ぎていて、起こすのは 3h の 1 回
        let wake = t0.addingTimeInterval(3.5 * 3600)
        let due = try store.dueSchedules(now: wake)
        #expect(due.map(\.due) == [t0.addingTimeInterval(3 * 3600)])
        let first = try store.recordScheduleRun(id: schedule.scheduleID, at: due[0].due, trigger: .schedule, skipped: nil, conversationID: Scheduler.conversationID(runID:), now: wake)
        #expect(first?.conversationID == Scheduler.conversationID(runID: first?.id ?? 0))
        #expect(try store.recordScheduleRun(id: schedule.scheduleID, at: due[0].due, trigger: .schedule, skipped: nil, conversationID: Scheduler.conversationID(runID:), now: wake) == nil)
        #expect(try store.dueSchedules(now: wake).isEmpty)
        #expect(try store.schedule(id: schedule.scheduleID, now: wake).nextAt == t0.addingTimeInterval(4 * 3600))
        #expect(try store.scheduleRuns(id: schedule.scheduleID).count == 1)
    }

    @Test("規則を変えたとき・再開したときは、その時刻より前の分を起こさない")
    func anchorMoves() throws {
        let (store, _) = try makeStore()
        let (schedule, _) = try store.createSchedule(ScheduleCreateRequest(name: "a", rule: every(60), cwd: "", kind: .claude, prompt: ""), now: t0)
        let later = t0.addingTimeInterval(5 * 3600)
        _ = try store.updateSchedule(id: schedule.scheduleID, ScheduleUpdateRequest(enabled: false), now: t0.addingTimeInterval(60))
        #expect(try store.dueSchedules(now: later).isEmpty, "停止中は起こさない")
        let (resumed, _) = try store.updateSchedule(id: schedule.scheduleID, ScheduleUpdateRequest(enabled: true), now: later)
        #expect(resumed.nextAt == later.addingTimeInterval(3600))
        let (changed, _) = try store.updateSchedule(id: schedule.scheduleID, ScheduleUpdateRequest(rule: every(30)), now: later.addingTimeInterval(600))
        #expect(changed.nextAt == later.addingTimeInterval(600 + 1800))
    }

    @Test("名前・規則が不正なら作らない。タスクを消すと紐づけが外れる")
    func validation() throws {
        let (store, board) = try makeStore()
        #expect(throws: StoreError.self) { try store.createSchedule(ScheduleCreateRequest(name: " ", rule: every(60), cwd: "", kind: .claude, prompt: ""), now: t0) }
        #expect(throws: StoreError.self) { try store.createSchedule(ScheduleCreateRequest(name: "a", rule: .cron("61 * * * *"), cwd: "", kind: .claude, prompt: ""), now: t0) }
        #expect(throws: StoreError.self) { try store.createSchedule(ScheduleCreateRequest(name: "a", rule: every(60), cwd: "", kind: .claude, prompt: "", taskNumber: 999), now: t0) }
        let (schedule, task) = try store.createSchedule(
            ScheduleCreateRequest(name: "a", rule: every(60), cwd: "", kind: .claude, prompt: "", newTask: .init(boardID: board.id, columnID: board.columns[0].id)), now: t0)
        try store.deleteTask(number: try #require(task).number)
        #expect(try store.schedule(id: schedule.scheduleID).taskNumber == nil)
    }

    @Test("tick を重ねても、再起動しても同じ回は 1 度だけ。前回の会話が動いていればスキップとして記録する")
    func tickAndOverlap() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let (store, state) = (world.store, world.state)
        let scheduler = Scheduler(store: store, state: state, conversations: world.service, accounts: nil, isOnline: { true })
        let (schedule, _) = try store.createSchedule(ScheduleCreateRequest(name: "a", rule: every(60), cwd: "/tmp", kind: .claude, prompt: ""), now: t0)

        let firstDue = t0.addingTimeInterval(3600)
        await scheduler.tick(now: firstDue)
        await scheduler.tick(now: firstDue.addingTimeInterval(20))
        // daemon の再起動: 同じ DB に新しい Scheduler が付いて、同じ回の時刻内に tick する
        let restarted = Scheduler(store: store, state: state, conversations: world.service, accounts: nil, isOnline: { true })
        await restarted.tick(now: firstDue.addingTimeInterval(40))
        let runs = try store.scheduleRuns(id: schedule.scheduleID)
        #expect(runs.count == 1)
        let launched = try #require(runs.first?.conversationID)
        #expect(try store.conversation(id: launched) != nil, "会話を起こした")
        await store.statePublisher(state: state).settled()
        #expect(await state.snapshot().schedules.first?.lastRun?.id == runs.first?.id)

        // 前回の回の会話が動いている: 次の回はスキップ
        await scheduler.tick(now: t0.addingTimeInterval(2 * 3600))
        let after = try store.scheduleRuns(id: schedule.scheduleID)
        #expect(after.count == 2)
        #expect(after.first?.skipped == Scheduler.skippedBusyReason)
        #expect(after.first?.outcome == .skipped)
        #expect(after.first?.conversationID == nil)
    }

    @Test("ふたを閉じたスリープの短い復帰（DarkWake）の間は記録も起動もせず、完全に起きた tick で最新の 1 回を起こす")
    func darkWakeDefersToFullWake() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let (store, state) = (world.store, world.state)
        let (schedule, _) = try store.createSchedule(ScheduleCreateRequest(name: "a", rule: every(60), cwd: "/tmp", kind: .claude, prompt: ""), now: t0)

        // 2026-10-06: 20:00 を過ぎた後の 20:13 の DarkWake で起こした回が、ネットワークの無いまま 21:00 まで止まり、21:00 の回をスキップさせた
        let dark = Scheduler(store: store, state: state, conversations: world.service, accounts: nil, isFullWake: { false }, isOnline: { true })
        await dark.tick(now: t0.addingTimeInterval(3600 + 13 * 60))
        await dark.tick(now: t0.addingTimeInterval(2 * 3600))
        #expect(try store.scheduleRuns(id: schedule.scheduleID).isEmpty)

        // 21:04 にふたを開けた
        let awake = Scheduler(store: store, state: state, conversations: world.service, accounts: nil, isFullWake: { true }, isOnline: { true })
        await awake.tick(now: t0.addingTimeInterval(2 * 3600 + 4 * 60))
        let runs = try store.scheduleRuns(id: schedule.scheduleID)
        #expect(runs.map(\.scheduledAt) == [t0.addingTimeInterval(2 * 3600)])
        #expect(runs.first?.skipped == nil)
        #expect(runs.first?.conversationID != nil)
    }

    @Test("回線が無い間の回は理由付きのスキップとして記録して起こさず、繋がった最初の tick で今の時刻の回を 1 回だけ起こす")
    func offlineDefersRun() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let (store, state) = (world.store, world.state)
        let online = Locked(false)
        let scheduler = Scheduler(store: store, state: state, conversations: world.service, accounts: nil, isFullWake: { true }, isOnline: { online.value })
        let (schedule, _) = try store.createSchedule(ScheduleCreateRequest(name: "a", rule: every(60), cwd: "/tmp", kind: .codex, prompt: ""), now: t0)

        await scheduler.tick(now: t0.addingTimeInterval(3600))
        await scheduler.tick(now: t0.addingTimeInterval(3620))
        var runs = try store.scheduleRuns(id: schedule.scheduleID)
        #expect(runs.count == 1)
        #expect(runs.first?.skipped == Scheduler.offlineReason)
        #expect(runs.first?.conversationID == nil && runs.first?.outcome == .skipped)

        online.update { $0 = true }
        let back = t0.addingTimeInterval(3700)
        await scheduler.tick(now: back)
        await scheduler.tick(now: back.addingTimeInterval(20))
        runs = try store.scheduleRuns(id: schedule.scheduleID)
        #expect(runs.count == 2)
        #expect(runs.first?.scheduledAt == back && runs.first?.skipped == nil && runs.first?.conversationID != nil)
        #expect(try store.schedule(id: schedule.scheduleID, now: back).nextAt == t0.addingTimeInterval(2 * 3600), "次の回は規則どおり")
    }

    @Test("後へ回した後に定期起動を変えたら、戻っても取り返さない")
    func editedScheduleIsNotCaughtUp() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let (store, state) = (world.store, world.state)
        let online = Locked(false)
        let scheduler = Scheduler(store: store, state: state, conversations: world.service, accounts: nil, isFullWake: { true }, isOnline: { online.value })
        let (schedule, _) = try store.createSchedule(ScheduleCreateRequest(name: "a", rule: every(60), cwd: "/tmp", kind: .codex, prompt: ""), now: t0)
        await scheduler.tick(now: t0.addingTimeInterval(3600))
        _ = try store.updateSchedule(id: schedule.scheduleID, ScheduleUpdateRequest(prompt: "直した"), now: t0.addingTimeInterval(3610))
        online.update { $0 = true }
        await scheduler.tick(now: t0.addingTimeInterval(3700))
        #expect(try store.scheduleRuns(id: schedule.scheduleID).count == 1)
    }

    @Test("claude の回は、マシンの利用枠が区切る閾値以上の間は後へ回し、窓が戻ったら起こす。codex の回は利用枠で止めない")
    func usageDefersClaudeRun() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let (store, state) = (world.store, world.state)
        let scheduler = Scheduler(store: store, state: state, conversations: world.service, accounts: nil, isFullWake: { true }, isOnline: { true })
        let (claude, _) = try store.createSchedule(ScheduleCreateRequest(name: "c", rule: every(60), cwd: "/tmp", kind: .claude, prompt: ""), now: t0)
        let (codex, _) = try store.createSchedule(ScheduleCreateRequest(name: "x", rule: every(60), cwd: "/tmp", kind: .codex, prompt: ""), now: t0)
        let resets = t0.addingTimeInterval(3600 + 600)
        let context = SessionContext(agentSessionID: "s1", model: nil, effort: nil, usedPercent: nil, inputTokens: nil, windowSize: nil, at: t0)
        await state.record(
            ClaudeUsageReport(context: context, fiveHour: UsageWindow(usedPercent: 90, resetsAt: resets, windowSeconds: 18_000), sevenDay: nil), now: t0)

        await scheduler.tick(now: t0.addingTimeInterval(3600))
        #expect(try store.scheduleRuns(id: claude.scheduleID).first?.skipped == Scheduler.usageLimitReason)
        #expect(try store.scheduleRuns(id: codex.scheduleID).first?.skipped == nil)

        await scheduler.tick(now: resets.addingTimeInterval(-1))
        #expect(try store.scheduleRuns(id: claude.scheduleID).count == 1, "戻る前は起こさない")
        await scheduler.tick(now: resets.addingTimeInterval(1))
        let runs = try store.scheduleRuns(id: claude.scheduleID)
        #expect(runs.count == 2 && runs.first?.skipped == nil && runs.first?.conversationID != nil)
    }

    @Test("会話を起こせなかった回はスキップでなく起動失敗として残り、理由を持つ")
    func startFailureIsFailure() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        // 確かめた Codex の版が無いので、会話を起こせない
        let scheduler = Scheduler(store: world.store, state: world.state, conversations: world.service, accounts: nil, isOnline: { true })
        let (schedule, _) = try world.store.createSchedule(ScheduleCreateRequest(name: "a", rule: every(60), cwd: "/tmp", kind: .codex, prompt: ""), now: t0)
        await scheduler.tick(now: t0.addingTimeInterval(3600))
        let run = try #require(try world.store.scheduleRuns(id: schedule.scheduleID).first)
        #expect(run.skipped == nil)
        #expect(run.stage == .failed)
        #expect(run.outcome == .failed)
        #expect(run.error != nil)
        #expect(try world.store.schedule(id: schedule.scheduleID).lastRun?.outcome == .failed)
    }

    @Test("既存の定期起動を「新しいタスク」に変えると、名前の題の常設タスクを作って紐づけ直す")
    func updateWithNewTask() throws {
        let (store, board) = try makeStore()
        let (schedule, _) = try store.createSchedule(ScheduleCreateRequest(name: "棚卸し", rule: every(60), cwd: "", kind: .claude, prompt: ""), now: t0)
        #expect(schedule.taskNumber == nil)
        let (updated, task) = try store.updateSchedule(
            id: schedule.scheduleID, ScheduleUpdateRequest(name: "PR の棚卸し", newTask: .init(boardID: board.id, columnID: "todo")), now: t0)
        let created = try #require(task)
        #expect(created.title == "PR の棚卸し")
        #expect(updated.taskNumber == created.number)
        #expect(throws: StoreError.self) {
            try store.updateSchedule(id: schedule.scheduleID, ScheduleUpdateRequest(clearTask: true, newTask: .init(boardID: board.id, columnID: "todo")))
        }
        // 規則を変えずに紐づけだけ変えたら、次の時刻は動かない
        #expect(updated.nextAt == schedule.nextAt)
    }
}

@Suite("作業ディレクトリのブックマークと最近使ったもの")
struct WorkdirStoreTests {
    let machine = MachineID(rawValue: "m-test")

    @Test("ブックマークは同じパスを 2 度足しても 1 件。消せる。無い id は断る")
    func bookmarks() throws {
        let store = try Store(inMemory: machine)
        let a = try store.addWorkdirBookmark(path: " /Users/x/dev/作業 ")
        #expect(a.path == "/Users/x/dev/作業")
        #expect(try store.addWorkdirBookmark(path: "/Users/x/dev/作業").id == a.id)
        _ = try store.addWorkdirBookmark(path: "/Users/x/dev/b")
        #expect(try store.workingDirectories().bookmarks.map(\.path) == ["/Users/x/dev/作業", "/Users/x/dev/b"])
        try store.deleteWorkdirBookmark(id: a.id)
        #expect(try store.workingDirectories().bookmarks.map(\.path) == ["/Users/x/dev/b"])
        #expect(throws: StoreError.self) { try store.deleteWorkdirBookmark(id: a.id) }
        #expect(throws: StoreError.self) { try store.addWorkdirBookmark(path: "  ") }
    }

    @Test("最近使ったもの: タスクに結んだ会話の cwd を新しい順に。重複・空・ホームを除き 8 件まで")
    func recent() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "b", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "t"))
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        for (index, cwd) in ["/old", "/dup", "/new", "/dup", ""].enumerated() {
            _ = try store.createConversation(
                ConversationRecord(taskNumber: task.number, agentSessionId: "s\(index)", cwd: cwd, runner: .host, createdAt: t0.addingTimeInterval(Double(index))))
        }
        _ = try store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: "s-free", cwd: "/free", runner: .host, createdAt: t0.addingTimeInterval(9)))
        #expect(try store.workingDirectories().recent == ["/dup", "/new", "/old"])
        #expect(Store.recentWorkdirs(["/h", "~", "/a"], home: "/h") == ["/a"])
        #expect(Store.recentWorkdirs((0..<20).map { "/d\($0)" }).count == Store.recentWorkdirLimit)
    }

    @Test("新しい案件は既定の起動プロンプトと、レビュー依頼の列の既定を持つ")
    func defaultTemplates() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "b", columns: nil)
        #expect(board.promptTemplate == PromptTemplate.defaultBoardTemplate)
        #expect(board.columns.first { $0.id == "review_req" }?.promptTemplate == PromptTemplate.defaultReviewRequestTemplate)
        #expect(board.columns.first { $0.id == "working" }?.promptTemplate == nil)
        #expect(PromptTemplate.template(for: "working", in: board) == PromptTemplate.defaultBoardTemplate)
    }
}
