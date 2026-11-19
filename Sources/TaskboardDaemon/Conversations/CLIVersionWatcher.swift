import Foundation
import Logging
import TaskboardKit

/// CLI（Claude Code・codex）の新しい版が入ったら、`ClaudeCheck`・`CodexCheck`（短い会話）で確かめて `VerifiedCLI` に足す。host の会話は確かめた版でだけ
/// 起きるので、版が上がるたびに人が `taskboard conversation check` を回さなくてよくする。engine ごとに 1 つ動かす
///
/// - daemon の起動の 2 分後と 1 時間ごとに、版ごとの実行ファイルの置き場（`VerifiedCLI.versionsDirectory`）の最も新しい版を見る。1 度に 1 本で、
///   確かめる間は会話の枠を 1 つ使う（目安に空きが無ければ待つ）
/// - 通らなかった版を試し直すのは 1 日 1 回まで（試した記録は support の `agent-host/check-attempts.json`・`check-attempts-codex.json`。0600）。
///   通った版が記録から落ちていれば試し直す
actor CLIVersionWatcher {
    struct Attempt: Codable, Equatable, Sendable {
        var version: String
        var at: Date
        var passed: Bool
        /// 通らなかった最初の段
        var failedStep: String?
    }

    let engine: AgentKind
    let supportDirectory: URL
    let versionsDirectory: URL
    let slots: ConversationSlots
    let state: DaemonState
    /// 実行ファイルを確かめる（本物は `ClaudeCheck.run`・`CodexCheck.run`）
    let check: @Sendable (_ executable: String) async throws -> EngineCheck.Report
    private let now: @Sendable () -> Date
    private var running = false
    private let logger = Logger(label: "uk.whatn.taskboardd.cli-check")

    static let firstDelay: Duration = .seconds(120)
    static let interval: Duration = .seconds(3600)
    static let retryAfter: TimeInterval = 24 * 3600
    var slotKey: String { "\(engine.rawValue)-version-check" }

    init(
        engine: AgentKind, supportDirectory: URL, versionsDirectory: URL? = nil, slots: ConversationSlots, state: DaemonState,
        check: (@Sendable (String) async throws -> EngineCheck.Report)? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.supportDirectory = supportDirectory
        self.versionsDirectory = versionsDirectory ?? VerifiedCLI.versionsDirectory(engine)
        self.slots = slots
        self.state = state
        self.check =
            check
            ?? { executable in
                switch engine {
                case .claude: try await ClaudeCheck.run(executable: executable)
                case .codex: try await CodexCheck.run(executable: executable)
                }
            }
        self.now = now
    }

    func run() async {
        await publish()
        try? await Task.sleep(for: Self.firstDelay)
        while !Task.isCancelled {
            await checkNewest()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// 最も新しい版を、まだ確かめていなければ確かめる。確かめたら true
    @discardableResult
    func checkNewest() async -> Bool {
        defer { Task { await self.publish() } }
        guard !running, let newest = newestInstalled() else { return false }
        if VerifiedCLI.load(engine, supportDirectory: supportDirectory)?.entries.contains(where: { $0.version == newest.version }) == true { return false }
        if let last = attempts().last(where: { $0.version == newest.version }), !last.passed, now().timeIntervalSince(last.at) < Self.retryAfter {
            return false
        }
        guard slots.reserve(slotKey, withinSoft: true) else {
            logger.info("cli check waits for a free slot", metadata: ["version": .string(newest.version)])
            return false
        }
        running = true
        defer {
            running = false
            slots.release(slotKey)
        }
        logger.notice("checking new CLI", metadata: ["engine": .string(engine.rawValue), "version": .string(newest.version)])
        var attempt = Attempt(version: newest.version, at: now(), passed: false)
        do {
            let report = try await check(newest.path)
            attempt.passed = report.passed
            attempt.failedStep = report.steps.first { !$0.passed }?.name
            if report.passed { try EngineCheck.record(report, supportDirectory: supportDirectory) }
        } catch {
            attempt.failedStep = "起動: \(error)"
        }
        logger.notice(
            "CLI checked",
            metadata: [
                "engine": .string(engine.rawValue), "version": .string(newest.version), "passed": .stringConvertible(attempt.passed),
                "step": .string(attempt.failedStep ?? ""),
            ])
        record(attempt)
        return true
    }

    /// 入っている実行ファイルのうち最も新しい版
    func newestInstalled() -> (version: String, path: String)? {
        VerifiedCLI.installed(engine, in: versionsDirectory).max { VerifiedCLI.precedes($0.version, $1.version) }
    }

    /// 会話が使う版・入っている最も新しい版・通らなかった版を health に出す。codex が入っていないマシンでは codex の様子を出さない
    func publish() async {
        let using = VerifiedCLI.load(engine, supportDirectory: supportDirectory)?.newest(requiring: Self.requiredCapabilities(engine))?.version
        let newest = newestInstalled()?.version
        if engine == .codex, using == nil, newest == nil { return }
        let failed = newest.flatMap { version in attempts().last { $0.version == version && !$0.passed } }
        await state.setCLIStatus(CLIVersionStatus(using: using, newest: newest, failedVersion: failed?.version, failedStep: failed?.failedStep), engine: engine)
    }

    /// 会話を起こすのに要る capabilities（codex の確かめは capabilities を記録しない）
    static func requiredCapabilities(_ engine: AgentKind) -> [String] {
        switch engine {
        case .claude: ClaudeConversation.requiredCapabilities
        case .codex: []
        }
    }

    // MARK: 試した記録

    private var attemptsFile: URL {
        AgentHostServer.directory(supportDirectory: supportDirectory).appending(path: engine == .claude ? "check-attempts.json" : "check-attempts-\(engine.rawValue).json")
    }

    func attempts() -> [Attempt] {
        guard let data = try? Data(contentsOf: attemptsFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Attempt].self, from: data)) ?? []
    }

    /// 同じ版の前の記録を置き換え、新しい 20 件だけ残す。別のファイルに書いてから rename する
    private func record(_ attempt: Attempt) {
        var all = attempts().filter { $0.version != attempt.version }
        all.append(attempt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(all.suffix(20))) else { return }
        let directory = attemptsFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appending(path: ".check-attempts.\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, attemptsFile.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }
}
