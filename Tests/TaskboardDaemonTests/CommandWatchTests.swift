import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-command")
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func world() throws -> (Store, BoardTask) {
    let store = try Store(inMemory: machine)
    let board = try store.createBoard(name: "a", columns: nil)
    return (store, try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t")))
}

private func request(_ spec: CommandWatchSpec, task: BoardTask, once: Bool = false) -> WatchCreateRequest {
    WatchCreateRequest(command: spec, taskNumber: task.number, once: once)
}

private func outcome(_ exitCode: Int32?, _ output: String = "", timedOut: Bool = false) -> CommandWatcher.Outcome {
    CommandWatcher.Outcome(exitCode: exitCode, timedOut: timedOut, output: Data(output.utf8), seconds: 1)
}

@Suite("コマンドの見張りの記録")
struct CommandWatchStoreTests {
    @Test("コマンドは前後の空白を落として持ち、finishes は 1 回だけにする。空のコマンド、pattern の無い matches、読めない正規表現、無いディレクトリ、finishes の間隔、範囲の外の間隔と打ち切り、url との同時指定は断る")
    func validates() throws {
        let (store, task) = try world()
        let created = try store.createWatch(request(CommandWatchSpec(command: "  test -f /tmp/x \n", condition: .succeeds), task: task), now: t0).watch
        #expect(created.kind == .command && created.command?.command == "test -f /tmp/x" && !created.once)
        #expect(try store.createWatch(request(CommandWatchSpec(command: "make", cwd: "/tmp", condition: .finishes), task: task), now: t0).watch.once)

        let invalid: [CommandWatchSpec] = [
            CommandWatchSpec(command: " ", condition: .succeeds),
            CommandWatchSpec(command: String(repeating: "a", count: CommandWatchSpec.commandLimit + 1), condition: .succeeds),
            CommandWatchSpec(command: "ls", condition: .matches),
            CommandWatchSpec(command: "ls", condition: .matches, pattern: "("),
            CommandWatchSpec(command: "ls", condition: .succeeds, pattern: "x"),
            CommandWatchSpec(command: "ls", cwd: "tmp", condition: .succeeds),
            CommandWatchSpec(command: "ls", cwd: "/no/such/dir", condition: .succeeds),
            CommandWatchSpec(command: "ls", condition: .finishes, intervalSeconds: 60),
            CommandWatchSpec(command: "ls", condition: .succeeds, intervalSeconds: 29),
            CommandWatchSpec(command: "ls", condition: .succeeds, timeoutSeconds: 601),
            CommandWatchSpec(command: "ls", condition: .finishes, timeoutSeconds: 86_401),
        ]
        for spec in invalid {
            #expect(throws: StoreError.self, "\(spec)") { try store.createWatch(request(spec, task: task), now: t0) }
        }
        #expect(throws: StoreError.self) {
            try store.createWatch(WatchCreateRequest(url: "https://github.com/o/r/pull/1", command: CommandWatchSpec(command: "ls", condition: .succeeds), taskNumber: task.number), now: t0)
        }
        #expect(try store.watches().count == 2)
    }

    @Test("同じコマンド・条件・届け先の有効な見張りは作り直さない。有効な見張りは 20 件まで")
    func dedupesAndLimits() throws {
        let (store, task) = try world()
        let spec = CommandWatchSpec(command: "ls", condition: .succeeds)
        let first = try store.createWatch(request(spec, task: task), now: t0)
        let again = try store.createWatch(request(spec, task: task), now: t0)
        #expect(again.existing && again.watch.watchID == first.watch.watchID)
        for index in 1..<Store.commandWatchLimit {
            _ = try store.createWatch(request(CommandWatchSpec(command: "ls \(index)", condition: .succeeds), task: task), now: t0)
        }
        #expect(throws: StoreError.self) { try store.createWatch(request(CommandWatchSpec(command: "ls over", condition: .succeeds), task: task), now: t0) }
    }

    @Test("コマンドの見張りも state に載せて配る（アプリのタスクの［状態］に出す）")
    func broadcastsInState() async throws {
        let (store, task) = try world()
        let watch = try store.createWatch(request(CommandWatchSpec(command: "ls", condition: .succeeds), task: task), now: t0).watch
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        await state.upsert(watch)
        #expect(await state.snapshot().watches.map(\.command?.command) == ["ls"])
    }
}

@Suite("コマンドの回の判定")
struct CommandWatchEvaluationTests {
    private let empty = Store.CommandWatchState()

    @Test("succeeds は合わない回から合う回に変わったときだけ届ける。1 回目で合えば届ける")
    func succeedsOnTransition() {
        let spec = CommandWatchSpec(command: "x", condition: .succeeds)
        let (first, event) = CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(0, "ok\n"))
        #expect(event?.exitCode == 0 && event?.outputTail == "ok\n" && first.matched == true)
        let (second, repeated) = CommandWatcher.evaluate(spec, previous: first, outcome: outcome(0))
        #expect(repeated == nil)
        let (third, failed) = CommandWatcher.evaluate(spec, previous: second, outcome: outcome(1))
        #expect(failed == nil && third.matched == false)
        #expect(CommandWatcher.evaluate(spec, previous: third, outcome: outcome(0)).1 != nil)
        #expect(CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(nil, timedOut: true)).1 == nil, "打ち切りは成功にしない")
    }

    @Test("fails は 0 以外の終了と打ち切りで届ける")
    func failsOnNonZeroOrTimeout() {
        let spec = CommandWatchSpec(command: "x", condition: .fails)
        #expect(CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(0)).1 == nil)
        #expect(CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(2)).1?.exitCode == 2)
        #expect(CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(nil, timedOut: true)).1?.timedOut == true)
    }

    @Test("matches は最初に合った行を添える。行ごとに ^ $ が効き、日本語の行も合う")
    func matchesLine() {
        let spec = CommandWatchSpec(command: "x", condition: .matches, pattern: "^状態: 完了$")
        let (_, event) = CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(0, "開始\n状態: 完了\n状態: 完了\n"))
        #expect(event?.matchedLine == "状態: 完了")
        let (state, none) = CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(0, "状態: 完了しない\n"))
        #expect(none == nil && state.matched == false)
    }

    @Test("changes は 1 回目を元にするだけで、出力か終了コードが変わった回に届ける")
    func changesAgainstPrevious() {
        let spec = CommandWatchSpec(command: "x", condition: .changes)
        let (first, initial) = CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(0, "a"))
        #expect(initial == nil && first.digest != nil)
        let (same, unchanged) = CommandWatcher.evaluate(spec, previous: first, outcome: outcome(0, "a"))
        #expect(unchanged == nil && same.digest == first.digest)
        #expect(CommandWatcher.evaluate(spec, previous: same, outcome: outcome(1, "a")).1 != nil)
        #expect(CommandWatcher.evaluate(spec, previous: same, outcome: outcome(0, "b")).1?.outputTail == "b")
    }

    @Test("finishes は結果をそのまま届け、始めた時刻を削除する")
    func finishesAlways() {
        let spec = CommandWatchSpec(command: "x", condition: .finishes)
        let (state, event) = CommandWatcher.evaluate(spec, previous: Store.CommandWatchState(startedAt: t0), outcome: outcome(3))
        #expect(event?.exitCode == 3 && state.startedAt == nil)
    }

    @Test("出力の末尾は決めた字数まで")
    func tailsOutput() {
        let spec = CommandWatchSpec(command: "x", condition: .finishes)
        let output = String(repeating: "あ", count: 10) + String(repeating: "b", count: Store.CommandWatchResult.outputTailLimit)
        #expect(CommandWatcher.evaluate(spec, previous: empty, outcome: outcome(0, output)).1?.outputTail == String(repeating: "b", count: Store.CommandWatchResult.outputTailLimit))
    }
}

@Suite("コマンドを回す", .serialized)
struct CommandWatcherRunTests {
    private func eventually(_ condition: @Sendable () async throws -> Bool) async throws -> Bool {
        for _ in 0..<250 {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func watcher(_ store: Store, clock: @escaping @Sendable () -> Date = { Date() }) -> CommandWatcher {
        CommandWatcher(
            store: store, limits: .init(tick: .milliseconds(50), killGrace: .milliseconds(200)), environment: { ["PATH": "/usr/bin:/bin"] },
            isFullWake: { true }, now: clock)
    }

    @Test("bash で回して結果を出来事にし、届けの口に知らせる。間隔が来るまで回し直さない")
    func runsAndRecords() async throws {
        let (store, task) = try world()
        let watch = try store.createWatch(request(CommandWatchSpec(command: "cd /tmp && pwd; echo 日本語; exit 0", condition: .succeeds), task: task)).watch
        let commands = watcher(store)
        let notified = Notified()
        await commands.onEvents { ids in await notified.add(ids) }

        await commands.sweep()
        #expect(try await eventually { try !store.undeliveredCommandEvents(watch: watch.watchID).isEmpty })
        let result = try #require(try store.undeliveredCommandEvents(watch: watch.watchID).first?.result)
        #expect(result.exitCode == 0 && !result.timedOut)
        #expect(result.outputTail.hasSuffix("/tmp\n日本語\n"))
        #expect(try await eventually { await notified.ids == [watch.watchID] })
        #expect(try store.watch(id: watch.watchID)?.fetchedAt != nil)

        await commands.sweep()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try store.undeliveredCommandEvents(watch: watch.watchID).count == 1)
    }

    @Test("打ち切りではグループごと停止し、finishes は打ち切りの結果を届ける")
    func timesOut() async throws {
        let (store, task) = try world()
        let watch = try store.createWatch(request(CommandWatchSpec(command: "sleep 30 & wait", condition: .finishes, timeoutSeconds: 1), task: task)).watch
        let commands = watcher(store)
        await commands.sweep()
        #expect(try await eventually { try !store.undeliveredCommandEvents(watch: watch.watchID).isEmpty })
        let result = try #require(try store.undeliveredCommandEvents(watch: watch.watchID).first?.result)
        #expect(result.timedOut && result.exitCode == nil)
        let row = try #require(try store.watchRow(id: watch.watchID))
        #expect(store.commandWatchState(row)?.startedAt == nil)
    }

    @Test("前の daemon が始めた finishes は、結果が分からないことを届ける")
    func reportsInterrupted() async throws {
        let (store, task) = try world()
        let watch = try store.createWatch(request(CommandWatchSpec(command: "sleep 1", condition: .finishes), task: task)).watch
        try store.recordCommandCheck(id: watch.watchID, state: Store.CommandWatchState(startedAt: t0), result: nil, checked: false, at: t0)

        await watcher(store).sweep()
        let events = try store.undeliveredCommandEvents(watch: watch.watchID)
        #expect(events.map(\.result.interrupted) == [true])
    }

    @Test("DarkWake の間は回さない")
    func skipsDarkWake() async throws {
        let (store, task) = try world()
        let watch = try store.createWatch(request(CommandWatchSpec(command: "true", condition: .succeeds), task: task)).watch
        let commands = CommandWatcher(store: store, environment: { [:] }, isFullWake: { false })
        await commands.sweep()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try store.watch(id: watch.watchID)?.fetchedAt == nil)
    }
}

@Suite("コマンドの見張りの文")
struct CommandWatchTextTests {
    @Test("印・送り主・コマンド・条件・結果・出力の末尾・作成時の指示の順に並べ、出力の ``` より長い fence で囲む")
    func composesText() throws {
        let (store, task) = try world()
        let spec = CommandWatchSpec(command: "curl -fsS localhost:8080/health\necho done", cwd: "/tmp", condition: .matches, pattern: "ok")
        let watch = try store.createWatch(WatchCreateRequest(command: spec, taskNumber: task.number, prompt: "起動したら続ける")).watch
        let row = try #require(try store.watchRow(id: watch.watchID))
        let result = Store.CommandWatchResult(exitCode: 0, seconds: 2, outputTail: "```\nok\n", matchedLine: "ok")
        let lines = WatchNotices.commandText(row, results: [result], omitted: 1).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(
            lines == [
                "<!-- taskboard: watch id=\(watch.watchID) -->",
                "[taskboard 通知] 監視 #\(watch.watchID)（コマンド）に動きがあった",
                TaskboardNotice.senderItem,
                "- コマンド: `curl -fsS localhost:8080/health`",
                "- 作業フォルダ: /tmp",
                "- 条件: 出力が `ok` に合った（60 秒ごとに確認する）",
                "- 省いた回: 1 件",
                "結果:",
                "- 終了コード 0（2 秒）",
                "  - 合った行: `ok`",
                "  - 出力:",
                "````", "```", "ok", "````",
                TaskboardNotice.promptHeading, "起動したら続ける",
            ])
        #expect(TaskboardNotice(text: lines.joined(separator: "\n")) == .watch)
    }
}

private actor Notified {
    var ids: [Int64] = []
    func add(_ more: [Int64]) { ids += more }
}
