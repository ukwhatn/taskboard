import Foundation
import Testing

@testable import TaskboardKit

private struct ScriptedSource: SnapshotSource {
    let snap: StateSnapshot
    let stream: AsyncThrowingStream<DaemonEvent, any Error>

    func snapshot() async throws -> StateSnapshot { snap }
    func events() -> AsyncThrowingStream<DaemonEvent, any Error> { stream }
}

@Suite("見張り盤の札")
struct ConversationTilesTests {
    let machine = MachineID(rawValue: "m")
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    func conversation(
        _ id: String, phase: Conversation.Phase = .idle, task: Int? = nil, created: TimeInterval = 0, turn: TimeInterval? = nil,
        pending: [ConversationRequest] = []
    ) -> Conversation {
        var made = Conversation(
            id: id, machine: machine, taskNumber: task, agentSessionID: "s-\(id)", cwd: "/", title: id, runner: phase == .stopped ? .none : .host,
            phase: phase, pending: pending, createdAt: t0.addingTimeInterval(created), updatedAt: t0.addingTimeInterval(created))
        made.turnStartedAt = turn.map { t0.addingTimeInterval($0) }
        return made
    }

    func permission(_ id: String, since: TimeInterval) -> ConversationRequest {
        ConversationRequest(
            id: id, kind: .permission, toolName: "Bash", toolUseID: id,
            waiting: RequestWaiting(id: id, since: t0.addingTimeInterval(since), permission: .init(tool: "Bash", summary: "git push")))
    }

    func tile(_ conversation: Conversation, unread: Bool = false, now: Date? = nil) -> ConversationTile? {
        ConversationTile(conversation, task: nil, board: nil, unread: unread, now: now ?? t0)
    }

    // MARK: 値

    @Test("前の版の daemon の会話（最後の応答とターンの始まりが無い）を読め、欄は nil")
    func oldDaemonConversation() throws {
        let json = #"""
            {"id":"c1","machine":"m","taskNumber":7,"engine":"claude","agentSessionID":"a1","cwd":"/tmp","runner":"host","phase":"idle","pending":[],
             "createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z"}
            """#
        let read = try WireJSON.decoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(read.lastReply == nil && read.turnStartedAt == nil)
        #expect(read.id == "c1")
    }

    @Test("最後の応答とターンの始まりは書いて読み戻せ、読めない値は nil で、会話は読める")
    func replyRoundTrip() throws {
        var made = conversation("c1", turn: 30)
        made.lastReply = ConversationReply(text: "レビューを書きました。", at: t0.addingTimeInterval(90))
        let data = try WireJSON.encoder().encode(made)
        let read = try WireJSON.decoder().decode(Conversation.self, from: data)
        #expect(read.lastReply == made.lastReply && read.turnStartedAt == t0.addingTimeInterval(30))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["lastReply"] = ["text": 3]
        object["turnStartedAt"] = "きのう"
        let broken = try WireJSON.decoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(broken.lastReply == nil && broken.turnStartedAt == nil)
    }

    @Test("最後の応答の頭は 200 字まで（日本語も英語も字で数える）")
    func replyLimit() {
        #expect(ConversationReply(text: String(repeating: "あ", count: 250), at: t0).text.count == 200)
        #expect(ConversationReply(text: String(repeating: "a", count: 200), at: t0).text.count == 200)
        #expect(ConversationReply(text: "", at: t0).text.isEmpty)
        #expect(ConversationReply(text: "短い", at: t0).text == "短い")
    }

    @Test("ツールの知らせは書いて読み戻せ、前の版の daemon の全体（ツールの欄なし）も読める")
    func toolActivityWire() throws {
        let activity = ConversationToolActivity(conversation: ConversationKey(machine: machine, id: "c1"), toolName: "Bash")
        let event = DaemonEvent.conversationActivity(activity)
        #expect(event.name == "conversation.activity")
        #expect(try WireJSON.decoder().decode(DaemonEvent.self, from: WireJSON.encoder().encode(event)) == event)
        let ended = DaemonEvent.conversationActivity(ConversationToolActivity(conversation: activity.conversation, toolName: nil))
        #expect(try WireJSON.decoder().decode(DaemonEvent.self, from: WireJSON.encoder().encode(ended)) == ended)
        var snapshot = StateSnapshot(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"), generatedAt: t0)
        snapshot.conversationActivities = [activity]
        let data = try WireJSON.encoder().encode(snapshot)
        #expect(try WireJSON.decoder().decode(StateSnapshot.self, from: data).conversationActivities == [activity])
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["conversationActivities"] = nil
        #expect(try WireJSON.decoder().decode(StateSnapshot.self, from: JSONSerialization.data(withJSONObject: object)).conversationActivities.isEmpty)
    }

    // MARK: 札にするもの

    @Test("止まった会話（プロセスが無い待機）は札にしない。人が止めた会話・終了した会話も出さない")
    func stoppedConversationsAreHidden() {
        #expect(tile(conversation("c1", phase: .stopped)) == nil)
        var stopped = conversation("c2", phase: .stopped)
        stopped.lastExit = ConversationStopCause.person.lastExit
        #expect(tile(stopped) == nil)
        stopped.lastExit = ConversationStopCause.idle.lastExit
        #expect(tile(stopped) == nil)
        stopped.lastExit = ConversationStopCause.closed.lastExit
        #expect(tile(stopped, unread: true) == nil, "終了した会話は未読でも出さない")
    }

    @Test("止まりの異常（応答の止まり・送り直し・利用枠・ネットワーク・予期しない終了）は対応待ちの組に札で出す")
    func problemsGoToWaiting() throws {
        var stalled = conversation("c1", phase: .running)
        stalled.stalledSince = t0
        #expect(tile(stalled)?.state == .problem(.stalled(since: t0)))
        var retrying = conversation("c2", phase: .running)
        let retry = ConversationAPIRetry(attempt: 3, maxRetries: 10, retryAt: t0, kind: "overloaded")
        retrying.apiRetry = retry
        #expect(tile(retrying)?.state == .problem(.apiRetry(retry)))
        var limited = conversation("c3", phase: .stopped)
        limited.limitResumeAt = t0
        limited.limitPaused = true
        #expect(tile(limited)?.state == .problem(.usageLimit(resumeAt: t0, paused: true)))
        var offline = conversation("c4", phase: .idle)
        offline.networkResume = true
        #expect(tile(offline)?.state == .problem(.network))
        var crashed = conversation("c5", phase: .stopped, turn: 10)
        crashed.lastExit = "終了コード 1"
        #expect(tile(crashed)?.state == .problem(.exited("終了コード 1")))
        for made in [stalled, retrying, limited, offline, crashed] { #expect(tile(made)?.group == .waiting) }
    }

    @Test("入力待ちの間に予期せず終わった会話（始めたターンに応答が付いている・ターンを始めていない）は異常にせず、ほかの止まった会話と同じく札を出さない")
    func exitWhileIdleIsNotAProblem() {
        var answered = conversation("c1", phase: .stopped, turn: 10)
        answered.lastReply = ConversationReply(text: "済んだ", at: t0.addingTimeInterval(20))
        answered.lastExit = "終了コード 143 で終わった"
        #expect(tile(answered) == nil)
        var neverTurned = conversation("c2", phase: .stopped)
        neverTurned.lastExit = "終了コード 143 で終わった"
        #expect(tile(neverTurned) == nil)
        var midTurn = conversation("c3", phase: .stopped, turn: 30)
        midTurn.lastReply = ConversationReply(text: "前の応答", at: t0.addingTimeInterval(20))
        midTurn.lastExit = "終了コード 143 で終わった"
        #expect(tile(midTurn)?.state == .problem(.exited("終了コード 143 で終わった")))
        #expect(!answered.stoppedInTurn && !neverTurned.stoppedInTurn && midTurn.stoppedInTurn)
    }

    @Test("問いは止まりの異常より先（札の上で答える）。defer で終えた問いは止まった会話でも対応待ち")
    func requestBeforeProblem() {
        var waiting = conversation("c1", phase: .waiting, pending: [permission("r1", since: 0)])
        waiting.stalledSince = t0
        #expect(tile(waiting)?.state == .request(permission("r1", since: 0)))
        var deferred = conversation("c2", phase: .stopped)
        deferred.deferred = permission("r2", since: 5)
        deferred.lastExit = ConversationStopCause.deferred.lastExit
        #expect(tile(deferred)?.group == .waiting)
    }

    @Test("生成中と起動中は実行中、入力待ちは待機、未読の印があれば未読（止まった会話でも）")
    func phases() {
        #expect(tile(conversation("c1", phase: .running))?.state == .running)
        #expect(tile(conversation("c2", phase: .starting))?.state == .starting)
        #expect(tile(conversation("c3", phase: .waiting))?.state == .running, "問いが届く前の waiting は答えるものが無い")
        #expect(tile(conversation("c4", phase: .idle))?.group == .idle)
        #expect(tile(conversation("c5", phase: .idle), unread: true)?.group == .unread)
        #expect(tile(conversation("c6", phase: .stopped), unread: true)?.group == .unread)
        #expect(tile(conversation("c7", phase: .running), unread: true)?.group == .running, "動いていれば未読より実行中")
    }

    // MARK: 並び

    func state(_ conversations: [Conversation], boards: [Board] = [], tasks: [BoardTask] = []) -> MachineState {
        var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        state.conversations = Dictionary(uniqueKeysWithValues: conversations.map { ($0.key, $0) })
        state.boards = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
        state.tasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return state
    }

    func board(_ id: String, position: Int) -> Board {
        Board(id: id, machine: machine, name: id, position: position, columns: [], createdAt: t0)
    }

    func task(_ number: Int, board: String) -> BoardTask {
        BoardTask(machine: machine, number: number, boardID: board, columnID: "working", title: "#\(number)", createdAt: t0, updatedAt: t0)
    }

    @Test("対応待ちは待ち始めの古い順、実行中はターンの始まりの新しい順、未読は最後の応答の新しい順")
    func ordering() {
        var unreadOld = conversation("u1", phase: .idle)
        unreadOld.lastReply = ConversationReply(text: "前", at: t0.addingTimeInterval(10))
        var unreadNew = conversation("u2", phase: .idle)
        unreadNew.lastReply = ConversationReply(text: "後", at: t0.addingTimeInterval(20))
        let tiles = ConversationTiles(
            [
                state([
                    conversation("w-new", phase: .waiting, pending: [permission("r1", since: 50)]),
                    conversation("w-old", phase: .waiting, pending: [permission("r2", since: 10)]),
                    conversation("run-old", phase: .running, turn: 5), conversation("run-new", phase: .running, turn: 40),
                    conversation("run-unknown", phase: .running, created: 1), unreadOld, unreadNew,
                ])
            ], unread: [unreadOld.key, unreadNew.key])
        #expect(tiles.waiting.map(\.id.id) == ["w-old", "w-new"])
        #expect(tiles.running.map(\.id.id) == ["run-new", "run-old", "run-unknown"], "前の版の daemon（ターンの始まりなし）は作った時刻で並べる")
        #expect(tiles.unread.map(\.id.id) == ["u2", "u1"])
        #expect(tiles[.waiting] == tiles.waiting)
    }

    @Test("案件で絞ると、その案件のタスクの会話だけ。タスクの無い会話は入れない")
    func filterByBoard() {
        let tiles = ConversationTiles(
            [
                state(
                    [conversation("a", phase: .running, task: 1), conversation("b", phase: .running, task: 2), conversation("orchestrator", phase: .running)],
                    boards: [board("store", position: 0), board("tools", position: 1)], tasks: [task(1, board: "store"), task(2, board: "tools")])
            ], unread: [])
        #expect(tiles.running.count == 3)
        #expect(tiles.filtered(board: "store", machine: machine).running.map(\.id.id) == ["a"])
        #expect(tiles.filtered(board: "store", machine: MachineID(rawValue: "other")).running.isEmpty, "別のマシンの同じ id の案件は別物")
    }

    // MARK: 札と 1 行の送り分け

    func layout(waiting: Int, running: Int, boards: [String] = ["store"], window: Double) -> ConversationBoardLayout {
        let conversations =
            (0..<waiting).map { conversation("w\($0)", phase: .waiting, pending: [permission("r\($0)", since: Double($0))]) }
            + (0..<running).map { conversation("run\($0)", phase: .running, task: $0 % boards.count + 1, turn: Double($0)) }
        let tiles = ConversationTiles(
            [state(conversations, boards: boards.enumerated().map { board($1, position: $0) }, tasks: boards.enumerated().map { task($0 + 1, board: $1) })],
            unread: [])
        return ConversationBoardLayout(tiles, windowHeight: window, columns: 4, lineHeight: 20) { $0.group == .waiting ? 150 : 100 }
    }

    @Test("札が窓の高さの 3 分の 2 に収まれば、実行中も札")
    func tilesFit() {
        // 対応待ち 4 枚で 1 段（150）、実行中 4 枚で 1 段（100）。250 ≦ 400
        let made = layout(waiting: 4, running: 4, window: 600)
        #expect(made.waiting.count == 4)
        guard case .tiles(let tiles) = made.running else { Issue.record("札のまま"); return }
        #expect(tiles.count == 4)
    }

    @Test("札が窓の高さの 3 分の 2 を超えたら、実行中を 1 行に送り、対応待ちは札のまま")
    func runningMovesToLines() {
        // 対応待ち 1 段（150）+ 実行中 3 段（300）= 450 > 400。1 行なら 150 + 10 × 20 = 350 ≦ 400
        let made = layout(waiting: 4, running: 10, window: 600)
        #expect(made.waiting.count == 4, "対応待ちは送らない")
        guard case .lines(let lines) = made.running else { Issue.record("1 行に送る: \(made.running)"); return }
        #expect(lines.count == 10)
    }

    @Test("1 行にしても多いときは、実行中を案件ごとの見出しで分け、各案件の新しい 2 件だけを出す（マシンでは分けない）")
    func runningSplitsByBoard() {
        // 1 行でも 150 + 18 × 20 = 510 > 400
        let made = layout(waiting: 4, running: 18, boards: ["store", "tools", "home"], window: 600)
        guard case .boards(let groups) = made.running else { Issue.record("案件で分ける: \(made.running)"); return }
        #expect(groups.map { $0.board?.id } == ["store", "tools", "home"], "案件の並び（position）")
        #expect(groups.allSatisfy { $0.machine == machine })
        #expect(groups.map(\.lines.count) == [2, 2, 2])
        #expect(groups.map(\.hidden) == [4, 4, 4])
        // run15（store）が store の中でいちばん新しいターン
        #expect(groups[0].lines.map(\.id.id) == ["run15", "run12"])
    }

    @Test("対応待ちだけで窓を超えても、対応待ちは札のまま")
    func waitingNeverMoves() {
        let made = layout(waiting: 20, running: 0, window: 300)
        #expect(made.waiting.count == 20)
    }

    // MARK: 判定の寄せ（見張り盤の札・サイドバーの札・バッジが同じ判定を読む）

    @Test("問いの無い waiting は実行中。サイドバーの札も実行中（答えるものが無い状態を対応待ちに数えない）")
    func waitingWithoutRequestIsRunning() {
        let made = conversation("c1", phase: .waiting)
        #expect(tile(made)?.group == .running)
        #expect(SidebarStatus.of(made) == .running)
        #expect(SidebarStatus.of(conversation("c2", phase: .waiting, pending: [permission("r1", since: 0)])) == .waiting)
    }

    @Test("止まりの異常は対応待ち。サイドバーの札も対応待ち")
    func problemsAreWaitingInSidebar() {
        var stalled = conversation("c1", phase: .running)
        stalled.stalledSince = t0
        var offline = conversation("c2", phase: .idle)
        offline.networkResume = true
        var crashed = conversation("c3", phase: .stopped, turn: 0)
        crashed.lastExit = "終了コード 1"
        for made in [stalled, offline, crashed] {
            #expect(tile(made, now: t0)?.group == .waiting)
            #expect(SidebarStatus.of(made, now: t0) == .waiting)
        }
    }

    @Test("止まった会話は見張り盤に出さず、サイドバーの札は待機のまま")
    func stoppedStaysIdleInSidebar() {
        var stopped = conversation("c1", phase: .stopped)
        stopped.lastExit = ConversationStopCause.idle.lastExit
        #expect(tile(stopped) == nil)
        #expect(SidebarStatus.of(stopped) == .idle)
        #expect(SidebarStatus.of(conversation("c2", phase: .stopped)) == .idle)
    }

    @Test("受信箱で非表示にした問いは対応待ちに数えず、対応待ちの数はバッジの数と同じ")
    func dismissedRequestsLeaveWaiting() {
        let blocked = conversation("c1", phase: .waiting, pending: [permission("r1", since: 0)])
        let twice = conversation("c2", phase: .waiting, pending: [permission("r2", since: 0), permission("r3", since: 1)])
        var stalled = conversation("c3", phase: .running)
        stalled.stalledSince = t0
        let made = state([blocked, twice, stalled])
        let dismissed: [ConversationKey: Set<String>] = [blocked.key: ["r1"], twice.key: ["r2"]]
        let tiles = ConversationTiles([made], unread: [], dismissed: dismissed, now: t0)
        #expect(tiles.waiting.map(\.id.id).sorted() == ["c2", "c3"], "非表示にした問いだけの会話は対応待ちから外す")
        #expect(tiles.waiting.first { $0.id == twice.key }?.state == .request(permission("r3", since: 1)), "残っている問いを出す")
        #expect(tiles.idle.map(\.id) == [blocked.key], "問いを非表示にした会話は入力待ち（待機）")
        // バッジは会話の問いを札の対応待ちで数え、ほかの対応待ち（文書の質問・PR など）を足す
        let items = made.inboxItems(now: t0)
        #expect(items.count == 3, "受信箱には非表示にした問いも含めて 3 件")
        let other = InboxItem(id: "prsync/a", kind: .prSync(PRAccountStatus(host: "h", account: "a")), group: .waiting, machine: machine, taskNumber: nil, title: "t", details: [], at: t0)
        #expect(tiles.waitingCount(with: items) == 2)
        #expect(tiles.waitingCount(with: items + [other]) == 3)
    }

    @Test("予期しない終了で止まった会話は、終了から 24 時間を過ぎたら出さない（溜まらないように）")
    func oldExitsExpire() {
        var crashed = conversation("c1", phase: .stopped, turn: 0)
        crashed.lastExit = "終了コード 1"
        #expect(tile(crashed, now: t0.addingTimeInterval(24 * 3600 - 1))?.group == .waiting)
        #expect(tile(crashed, now: t0.addingTimeInterval(24 * 3600)) == nil)
        #expect(SidebarStatus.of(crashed, now: t0.addingTimeInterval(24 * 3600)) == .idle, "サイドバーの札は待機に戻す")
        let tiles = ConversationTiles([state([crashed])], unread: [], now: t0)
        #expect(tiles.validUntil == t0.addingTimeInterval(24 * 3600), "外れる時刻に組み直す")
        #expect(ConversationTiles([state([conversation("c2", phase: .running)])], unread: [], now: t0).validUntil == nil)
    }

    // MARK: Fleet

    @MainActor
    @Test("Fleet は札を更新のときに組み、未読の印も効かせる。ツールの知らせはマシンの状態を変えない")
    func fleetTilesAndTools() async throws {
        let fleet = Fleet()
        let (stream, continuation) = AsyncThrowingStream<DaemonEvent, any Error>.makeStream()
        var snap = StateSnapshot(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"), generatedAt: t0)
        let running = conversation("c1", phase: .running, turn: 0)
        let idle = conversation("c2", phase: .idle)
        snap.conversations = [running, idle]
        snap.conversationActivities = [ConversationToolActivity(conversation: running.key, toolName: "Read")]
        fleet.add(id: "local", source: ScriptedSource(snap: snap, stream: stream))
        for _ in 0..<100 where fleet.allMachines["local"]?.machine == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fleet.conversationTiles.running.map(\.id) == [running.key])
        #expect(fleet.conversationTiles.idle.map(\.id) == [idle.key])
        #expect(fleet.toolName(of: running.key) == "Read", "全体の中のツール")

        fleet.unreadConversations = [idle.key]
        #expect(fleet.conversationTiles.unread.map(\.id) == [idle.key])

        let before = fleet.allMachines
        continuation.yield(.conversationActivity(ConversationToolActivity(conversation: running.key, toolName: "Bash")))
        for _ in 0..<100 where fleet.toolName(of: running.key) != "Bash" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fleet.toolName(of: running.key) == "Bash")
        #expect(fleet.allMachines == before, "ツールのたびにマシンの状態を書かない")

        continuation.yield(.conversationRemoved(running.key))
        for _ in 0..<100 where fleet.toolName(of: running.key) != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fleet.toolName(of: running.key) == nil, "消えた会話のツールは残さない")
        #expect(fleet.conversationTiles.running.isEmpty)
        fleet.remove(id: "local")
    }

    @MainActor
    @Test("Fleet で問いを非表示にすると、札は対応待ちから外れ、対応待ちの数もバッジと同じに減る")
    func fleetDismissal() async throws {
        let fleet = Fleet()
        let (stream, _) = AsyncThrowingStream<DaemonEvent, any Error>.makeStream()
        var snap = StateSnapshot(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"), generatedAt: t0)
        let blocked = conversation("c1", phase: .waiting, pending: [permission("r1", since: 0)])
        snap.conversations = [blocked]
        fleet.add(id: "local", source: ScriptedSource(snap: snap, stream: stream))
        for _ in 0..<100 where fleet.allMachines["local"]?.machine == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fleet.conversationTiles.waiting.map(\.id) == [blocked.key])
        let item = try #require(fleet.inbox.items.first)
        #expect(fleet.conversationTiles.waitingCount(with: fleet.inbox.items) == 1)
        fleet.inboxPending = [item.id: item.revision]
        #expect(fleet.conversationTiles.waiting.isEmpty)
        #expect(fleet.conversationTiles.idle.map(\.id) == [blocked.key])
        #expect(fleet.conversationTiles.waitingCount(with: fleet.inbox.items) == 0)
        fleet.remove(id: "local")
    }
}
