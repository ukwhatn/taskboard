import Foundation
import Logging
import TaskboardKit

/// 利用状況を貯める。1 分ごとに、このマシンの Claude Code の transcript（`projects` の下）と Codex の rollout（`sessions` の下）の
/// 追記された分を読み、トークン・skill の発火・圧縮・応答したセッションの数を数え、そのときの利用枠と一緒に DB に書く。
/// taskboard の外で起こしたセッションも数える（OpenTelemetry の代わり）。
///
/// 初めて動いたときに今ある transcript は末尾から読む（前の分は数えない）。動いている間に現れた transcript は頭から読むが、
/// 見つけた時刻の `newFileGrace` より前の行は数えない（フォークや再開で前の会話を写した行）。
/// 読み続けている transcript も、末尾まで読んだ時刻の `appendGrace` より前の行は数えない（会話を戻した Claude Code は、
/// 前の会話の行を元の時刻のまま末尾に書き直す）
actor UsageRecorder {
    struct Roots: Sendable {
        var claudeProjects: URL?
        var codexSessions: URL?
    }

    static let interval: Duration = .seconds(60)
    /// 1 回の見回りで 1 つの transcript から読む上限。残りは次の回に読む
    static let readLimit: UInt64 = 32 * 1_048_576
    static let newFileGrace: TimeInterval = 600
    static let appendGrace: TimeInterval = 120
    static let pruneInterval: TimeInterval = 6 * 3600

    private let store: Store
    private let state: DaemonState
    private let resolveRoots: @Sendable () async -> Roots
    private let excludedCommands: Set<String>
    private let logger = Logger(label: "uk.whatn.taskboardd.usage")
    private var roots: Roots?
    private var cursors: [String: UsageCursor]?
    /// 5 分の区切りごとの、応答したセッション。区切りが過ぎても次の回に遅れて届く行があるので、少し残す
    private var active: [Int64: [AgentKind: Set<String>]] = [:]
    private var prunedAt: Date?

    init(
        store: Store, state: DaemonState, excludedCommands: Set<String> = Set(BuiltinSlashCommands.all.map(\.name)),
        roots: @escaping @Sendable () async -> Roots
    ) {
        self.store = store
        self.state = state
        self.excludedCommands = excludedCommands
        resolveRoots = roots
    }

    func run() async {
        while !Task.isCancelled {
            do {
                try await scan(now: Date())
            } catch {
                logger.warning("usage scan failed", metadata: ["error": "\(error)"])
            }
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// 1 回の見回り。書いた分を返す（テスト用）
    @discardableResult
    func scan(now: Date) async throws -> UsageBatch {
        if roots == nil { roots = await resolveRoots() }
        let roots = roots ?? Roots()
        let firstRun: Bool
        if cursors == nil {
            cursors = try store.usageCursors()
            firstRun = cursors?.isEmpty ?? true
        } else {
            firstRun = false
        }
        var observations = UsageObservations()
        var changed: [String: UsageCursor] = [:]
        var seen = Set<String>()
        let files = (roots.claudeProjects.map { Self.transcripts(under: $0, skipping: "tool-results") } ?? []).map { ($0, AgentKind.claude) }
            + (roots.codexSessions.map { Self.transcripts(under: $0, skipping: nil) } ?? []).map { ($0, AgentKind.codex) }
        for (url, engine) in files {
            let path = url.path
            seen.insert(path)
            guard let file = Self.fileInfo(path) else { continue }
            var cursor: UsageCursor
            if let known = cursors?[path], known.inode == file.inode, known.offset <= file.size {
                cursor = known
            } else if cursors?[path] == nil, firstRun {
                cursor = UsageCursor(inode: file.inode, offset: file.size, countFrom: now.addingTimeInterval(-Self.appendGrace))
            } else {
                cursor = UsageCursor(inode: file.inode, offset: 0, countFrom: now.addingTimeInterval(-Self.newFileGrace))
            }
            if cursor.offset < file.size {
                read(url, engine: engine, size: file.size, cursor: &cursor, into: &observations)
                // 読む上限で途中までしか読めなかったときは進めない（残りの行を落とす）
                if cursor.offset == file.size {
                    cursor.countFrom = max(cursor.countFrom ?? .distantPast, now.addingTimeInterval(-Self.appendGrace))
                }
            }
            if cursor != cursors?[path] {
                changed[path] = cursor
                cursors?[path] = cursor
            }
        }
        let usage = await state.usageSnapshot()
        let batch = makeBatch(observations, cursors: changed, usage: usage, now: now)
        if !batch.isEmpty { try store.recordUsage(batch) }
        let threshold = Double(((try? store.settings()) ?? .defaults).usagePause.sevenDayPercent)
        let samples = try store.usageAccountSamples(since: now.addingTimeInterval(-86_400))
        await state.setClaudeForecast(UsageForecast.make(usage, samples: samples, threshold: threshold, now: now))
        if prunedAt.map({ now.timeIntervalSince($0) >= Self.pruneInterval }) ?? true {
            let missing = (cursors ?? [:]).keys.filter { !seen.contains($0) }
            try store.pruneUsage(before: now.addingTimeInterval(-UsageHistory.retention), missingPaths: missing)
            for path in missing { cursors?.removeValue(forKey: path) }
            prunedAt = now
        }
        return batch
    }

    /// `offset` から最後の改行までを読む。改行の無い大きな行は読む上限ごと飛ばす（その行は数えない）
    private func read(_ url: URL, engine: AgentKind, size: UInt64, cursor: inout UsageCursor, into out: inout UsageObservations) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let length = min(size - cursor.offset, Self.readLimit)
        guard (try? handle.seek(toOffset: cursor.offset)) != nil, let chunk = try? handle.read(upToCount: Int(length)), !chunk.isEmpty else { return }
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
            if UInt64(chunk.count) == Self.readLimit { cursor.offset += UInt64(chunk.count) }
            return
        }
        let codexSession = UsageLines.codexSession(fileName: url.lastPathComponent)
        let claudeSession = url.deletingPathExtension().lastPathComponent
        var start = chunk.startIndex
        while start <= lastNewline {
            let end = chunk[start...lastNewline].firstIndex(of: 0x0A) ?? lastNewline
            let line = chunk[start..<end]
            if !line.isEmpty {
                switch engine {
                case .claude: UsageLines.readClaude(Data(line), session: claudeSession, cursor: &cursor, into: &out, excludedCommands: excludedCommands)
                case .codex: UsageLines.readCodex(Data(line), session: codexSession, cursor: &cursor, into: &out)
                }
            }
            start = end + 1
        }
        cursor.offset += UInt64(lastNewline - chunk.startIndex + 1)
    }

    private func makeBatch(_ observations: UsageObservations, cursors: [String: UsageCursor], usage: UsageSnapshot, now: Date) -> UsageBatch {
        var batch = UsageBatch(cursors: cursors)
        struct TokenKey: Hashable {
            var hour: Int64
            var engine: AgentKind
            var session: String
            var model: String
        }
        struct SessionKey: Hashable {
            var engine: AgentKind
            var session: String
        }
        var tokens: [TokenKey: (Int, TokenCounts)] = [:]
        var sessions: [SessionKey: UsageBatch.Session] = [:]
        let sample = Int64(UsageHistory.sampleSeconds)
        for response in observations.responses {
            let seconds = Int64(response.at.timeIntervalSince1970)
            let key = TokenKey(hour: seconds / 3600 * 3600, engine: response.engine, session: response.session, model: response.model)
            let previous = tokens[key] ?? (0, TokenCounts())
            tokens[key] = (previous.0 + 1, previous.1 + response.tokens)
            let sessionKey = SessionKey(engine: response.engine, session: response.session)
            var session = sessions[sessionKey] ?? UsageBatch.Session(engine: response.engine, session: response.session)
            session.cwd = response.cwd ?? session.cwd
            session.firstAt = min(session.firstAt ?? seconds, seconds)
            session.lastAt = max(session.lastAt ?? seconds, seconds)
            if let context = response.context { session.maxContext = max(session.maxContext ?? 0, context) }
            sessions[sessionKey] = session
            active[seconds / sample * sample, default: [:]][response.engine, default: []].insert(response.session)
        }
        for (session, title) in observations.titles {
            let key = SessionKey(engine: .claude, session: session)
            sessions[key, default: UsageBatch.Session(engine: .claude, session: session)].title = title
        }
        for (session, cwd) in observations.cwds {
            let key = SessionKey(engine: .codex, session: session)
            sessions[key, default: UsageBatch.Session(engine: .codex, session: session)].cwd = cwd
        }
        batch.tokens = tokens.map { key, value in
            UsageBatch.Token(hour: key.hour, engine: key.engine, session: key.session, model: key.model, requests: value.0, tokens: value.1)
        }
        batch.sessions = Array(sessions.values)
        batch.events = observations.events.map {
            UsageBatch.Event(
                at: Int64($0.at.timeIntervalSince1970), engine: $0.engine, session: $0.session, kind: $0.kind, name: $0.name, source: $0.source, before: $0.before,
                after: $0.after)
        }
        // 応答したセッションの数は、区切りの中で見た全部の和（遅れて届いた行の分も数え直して大きいほうを残す）
        let current = Int64(now.timeIntervalSince1970) / sample * sample
        var samples: [Int64: UsageHistory.Sample] = [:]
        for (at, engines) in active {
            samples[at] = UsageHistory.Sample(
                at: Date(timeIntervalSince1970: TimeInterval(at)), claudeActive: engines[.claude]?.count ?? 0, codexActive: engines[.codex]?.count ?? 0)
        }
        active = active.filter { $0.key >= current - 2 * sample }
        var reading = samples[current] ?? UsageHistory.Sample(at: Date(timeIntervalSince1970: TimeInterval(current)))
        Self.fill(&reading, usage: usage, now: now)
        if reading != UsageHistory.Sample(at: reading.at) || samples[current] != nil { samples[current] = reading }
        batch.samples = samples.values.sorted { $0.at < $1.at }
        batch.accountSamples = UsageAccountSample.observations(usage, now: now)
        return batch
    }

    /// 今の利用枠を入れる。窓の終わりを過ぎた値は今の使用率ではないので入れない
    static func fill(_ sample: inout UsageHistory.Sample, usage: UsageSnapshot, now: Date) {
        func live(_ window: UsageWindow?) -> UsageWindow? {
            guard let window else { return nil }
            if let resets = window.resetsAt, resets <= now { return nil }
            return window
        }
        sample.claudeFiveHour = live(usage.claude?.fiveHour)?.usedPercent
        sample.claudeSevenDay = live(usage.claude?.sevenDay)?.usedPercent
        if let primary = live(usage.codex?.primary) {
            sample.codexPrimary = primary.usedPercent
            sample.codexPrimaryWindow = primary.windowSeconds
        }
        if let secondary = live(usage.codex?.secondary) {
            sample.codexSecondary = secondary.usedPercent
            sample.codexSecondaryWindow = secondary.windowSeconds
        }
        if let monthly = usage.codex?.monthly, monthly.resetsAt.map({ $0 > now }) ?? true { sample.codexMonthly = monthly.usedPercent }
    }

    /// `root` の下の `.jsonl`。`skipping` の名前のフォルダには入らない（Claude Code の tool-results は大きな出力の写しで数が多い）
    static func transcripts(under root: URL, skipping: String?) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if let skipping, url.lastPathComponent == skipping { enumerator.skipDescendants(); continue }
            if url.pathExtension == "jsonl" { found.append(url) }
        }
        return found
    }

    private static func fileInfo(_ path: String) -> (inode: UInt64, size: UInt64)? {
        var info = Darwin.stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (UInt64(info.st_ino), UInt64(info.st_size))
    }
}
