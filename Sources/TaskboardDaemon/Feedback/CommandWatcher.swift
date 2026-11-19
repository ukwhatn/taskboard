import CryptoKit
import Darwin
import Foundation
import Logging
import TaskboardKit

/// コマンドの見張り（`Watch.Kind.command`）を動かす。`tick` ごとに時刻の来た見張りのコマンドを、Run と同じく自分の process group の
/// `/bin/bash -c` で起こし（`CommandProcess`）、結果を条件と前の回の様子で比べて、出来事にしたら `WatchNotices` に渡す。
///
/// - 繰り返す見張りは、前の回が終わってから `interval` 秒あける。合っていない状態から合ったときだけ届ける（1 回目で合えば届ける）
/// - `finishes` は 1 回だけ動かす。始めた時刻を記録してから起こし、daemon が途中で起き直したら結果が分からないことを届けて終える
/// - 同時に動かすのは `concurrent` 本まで。DarkWake の間は始めない
/// - 打ち切りと daemon の終わりでは、グループに TERM、`killGrace` の後も残っていれば KILL
actor CommandWatcher {
    struct Limits: Sendable {
        var tick: Duration = .seconds(5)
        var concurrent = 4
        /// 持つ出力（先頭から）。条件と出力の末尾はここまでで見る
        var outputBytes = 1_048_576
        var killGrace: Duration = .seconds(5)
    }

    private let store: Store
    private let limits: Limits
    private let environment: @Sendable () async -> [String: String]
    private let isFullWake: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var onEvents: (@Sendable ([Int64]) async -> Void)?
    /// 動いている見張りの id → process group
    private var running: [Int64: pid_t] = [:]
    /// この daemon で始めた `finishes`（記録に始めた時刻があってもここに無ければ、前の daemon が始めたもの）
    private var startedHere: Set<Int64> = []
    /// 起こせなかった繰り返しの見張りを次に試す時刻（取った時刻は動かさないので、ここで間をあける）
    private var retryAt: [Int64: Date] = [:]
    private let logger = Logger(label: "uk.whatn.taskboardd.command-watcher")

    init(
        store: Store, limits: Limits = Limits(), environment: @escaping @Sendable () async -> [String: String],
        isFullWake: @escaping @Sendable () -> Bool = SystemPower.isFullWake, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.limits = limits
        self.environment = environment
        self.isFullWake = isFullWake
        self.now = now
    }

    func onEvents(_ handler: @escaping @Sendable ([Int64]) async -> Void) { onEvents = handler }

    func run() async {
        while !Task.isCancelled {
            await sweep()
            try? await Task.sleep(for: limits.tick)
        }
    }

    /// 時刻の来た見張りを始める（終わりは待たない）
    func sweep() async {
        guard isFullWake() else { return }
        let rows: [Store.WatchRow]
        do {
            rows = try store.activeCommandWatches()
        } catch {
            logger.warning("command watches not read", metadata: ["error": "\(error)"])
            return
        }
        let at = now()
        for row in rows {
            guard running.count < limits.concurrent else { return }
            guard let id = row.id, running[id] == nil, let spec = row.commandSpec else { continue }
            let state = store.commandWatchState(row) ?? Store.CommandWatchState()
            if spec.condition == .finishes {
                if state.startedAt != nil {
                    if !startedHere.contains(id) { interrupted(id, state: state) }
                    continue
                }
            } else if let last = row.fetchedAt, at.timeIntervalSince(last) < Double(spec.interval) {
                continue
            } else if let retry = retryAt[id], at < retry {
                continue
            }
            await start(id, spec: spec, state: state)
        }
    }

    /// daemon が終わる：動いているコマンドを止め、グループが空くか KILL を送るまで待つ
    func shutdown() async {
        let groups = Array(running.values)
        for pgid in groups { killpg(pgid, SIGTERM) }
        let deadline = ContinuousClock.now + limits.killGrace
        while ContinuousClock.now < deadline, groups.contains(where: { killpg($0, 0) == 0 }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for pgid in groups where killpg(pgid, 0) == 0 { killpg(pgid, SIGKILL) }
    }

    // MARK: 内部

    private func start(_ id: Int64, spec: CommandWatchSpec, state: Store.CommandWatchState) async {
        var state = state
        if spec.condition == .finishes {
            state.startedAt = now()
            do {
                try store.recordCommandCheck(id: id, state: state, result: nil, checked: false, at: now())
            } catch {
                logger.warning("command watch not started", metadata: ["watch": .stringConvertible(id), "error": "\(error)"])
                return
            }
            startedHere.insert(id)
        }
        let cwd = spec.cwd ?? NSHomeDirectory()
        let process: CommandProcess.Spawned
        do {
            process = try CommandProcess.spawn(argv: ["/bin/bash", "-c", spec.command], environment: await environment(), cwd: cwd)
        } catch {
            try? store.noteWatchFailure(id: id, reason: "コマンドを起こせない: \(error)", at: now())
            if spec.condition == .finishes {
                startedHere.remove(id)
                record(id, spec: spec, state: state, outcome: Outcome(exitCode: nil, output: Data(), seconds: 0))
            } else {
                retryAt[id] = now().addingTimeInterval(Double(spec.interval))
            }
            return
        }
        retryAt.removeValue(forKey: id)
        running[id] = process.pid
        let started = ContinuousClock.now
        let limits = limits
        let timeout = Duration.seconds(spec.timeout)
        Task {
            let outcome = await Self.collect(process, outputBytes: limits.outputBytes, timeout: timeout, killGrace: limits.killGrace, started: started)
            await self.finished(id, spec: spec, state: state, outcome: outcome)
        }
    }

    struct Outcome: Sendable {
        var exitCode: Int32?
        var timedOut = false
        var output: Data
        var truncated = false
        var seconds: Int
    }

    /// 出力を `outputBytes` まで持ち、終わるか打ち切るまで待つ
    private static func collect(_ process: CommandProcess.Spawned, outputBytes: Int, timeout: Duration, killGrace: Duration, started: ContinuousClock.Instant) async -> Outcome {
        let (stream, continuation) = AsyncStream<CommandProcess.Event>.makeStream()
        CommandProcess.watch(process, continuation)
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return false }
            killpg(process.pid, SIGTERM)
            try? await Task.sleep(for: killGrace)
            if killpg(process.pid, 0) == 0 { killpg(process.pid, SIGKILL) }
            return true
        }
        var output = Data()
        var truncated = false
        var exit: AgentHostExit?
        for await event in stream {
            switch event {
            case .output(let data):
                let room = outputBytes - output.count
                if room > 0 { output.append(data.prefix(room)) }
                if data.count > max(room, 0) { truncated = true }
            case .closed: break
            case .exited(let status): exit = status
            }
        }
        deadline.cancel()
        // 打ち切りの TERM を送った後なら打ち切り（`cancel` の後の値は、送る前なら false）
        let timedOut = await deadline.value
        let elapsed = ContinuousClock.now - started
        return Outcome(exitCode: timedOut ? nil : exit?.status, timedOut: timedOut, output: output, truncated: truncated, seconds: Int(elapsed.components.seconds))
    }

    private func finished(_ id: Int64, spec: CommandWatchSpec, state: Store.CommandWatchState, outcome: Outcome) async {
        running.removeValue(forKey: id)
        startedHere.remove(id)
        record(id, spec: spec, state: state, outcome: outcome)
    }

    private func record(_ id: Int64, spec: CommandWatchSpec, state: Store.CommandWatchState, outcome: Outcome) {
        let (next, result) = Self.evaluate(spec, previous: state, outcome: outcome)
        do {
            let touched = try store.recordCommandCheck(id: id, state: next, result: result, at: now())
            if touched, let onEvents { Task { await onEvents([id]) } }
        } catch {
            logger.warning("command watch not recorded", metadata: ["watch": .stringConvertible(id), "error": "\(error)"])
        }
    }

    private func interrupted(_ id: Int64, state: Store.CommandWatchState) {
        var next = state
        next.startedAt = nil
        do {
            let touched = try store.recordCommandCheck(id: id, state: next, result: Store.CommandWatchResult(interrupted: true), at: now())
            if touched, let onEvents { Task { await onEvents([id]) } }
        } catch {
            logger.warning("interrupted command watch not recorded", metadata: ["watch": .stringConvertible(id), "error": "\(error)"])
        }
    }

    /// 回の結果を条件で見て、次の様子と、届けるなら結果を返す
    static func evaluate(_ spec: CommandWatchSpec, previous: Store.CommandWatchState, outcome: Outcome) -> (Store.CommandWatchState, Store.CommandWatchResult?) {
        let text = String(decoding: outcome.output, as: UTF8.self)
        var result = Store.CommandWatchResult(
            exitCode: outcome.exitCode, timedOut: outcome.timedOut, seconds: outcome.seconds,
            outputTail: String(text.suffix(Store.CommandWatchResult.outputTailLimit)), truncated: outcome.truncated)
        var next = previous
        next.startedAt = nil
        let matched: Bool
        switch spec.condition {
        case .finishes:
            return (next, result)
        case .changes:
            var digest = SHA256()
            digest.update(data: outcome.output)
            digest.update(data: Data((outcome.timedOut ? "timeout" : "exit \(outcome.exitCode.map(String.init) ?? "?")").utf8))
            let value = digest.finalize().map { String(format: "%02x", $0) }.joined()
            next.digest = value
            return (next, previous.digest.map { $0 != value } == true ? result : nil)
        case .succeeds:
            matched = !outcome.timedOut && outcome.exitCode == 0
        case .fails:
            matched = outcome.timedOut || outcome.exitCode != 0
        case .matches:
            let line = spec.pattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }.flatMap { regex in
                regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { match in
                    Range(match.range, in: text).map { range in String(text[text.lineRange(for: range)]).trimmingCharacters(in: .newlines) }
                }
            }
            result.matchedLine = line
            matched = line != nil
        }
        next.matched = matched
        return (next, matched && previous.matched != true ? result : nil)
    }
}
