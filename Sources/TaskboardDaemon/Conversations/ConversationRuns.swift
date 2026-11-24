// ui-copy:ignore-file
// このファイルの文（Run の失敗）は API の応答とログに出て、画面には出ない（アプリは失敗のコードから文を組む）
import Foundation
import Logging
import TaskboardKit

/// 会話のコードブロックの Run。会話とシェルの種類（`RunShell`）ごとに、agent host の擬似端末のシェルを起こしたままにし、
/// コードをそのシェルで読ませる（変数と cd が次の Run に残る）。出力は Claude に渡さない。
///
/// - 1 本のシェルで同時に動かすのは 1 つ。動いている間の次の Run は 409
/// - 止める・時間切れは Ctrl-C と停止の目印の行を書き、`killGrace` の後も目印が来なければシェルを閉じる（状態は消える）
/// - シェルは host が持つので daemon を入れ替えても残る。最初の Run で購読し直し、ためた出力の最後の目印で空いているかを決める
/// - Run の記録はメモリだけで、daemon が起き直すと無くなる
actor ConversationRuns {
    static let keyPrefix = "run-"

    struct Limits: Sendable {
        /// 持つ出力（先頭から）
        var outputBytes = 1_048_576
        var duration: Duration = .seconds(600)
        /// 会話ごとに持つ数（古い終わったものから捨てる）
        var kept = 20
        /// 出力をまとめて流す間
        var batch: Duration = .milliseconds(100)
        /// 止めると決めてから、シェルを閉じるまで
        var killGrace: Duration = .seconds(5)
        /// 停止の目印の行を書き直す間
        var stopRetry: Duration = .milliseconds(300)
        /// シェルを起こしてから準備の目印が来るまで
        var startup: Duration = .seconds(30)
        /// 擬似端末の幅（出力の折り返しを減らす）
        var columns = 200
    }

    enum Event: Sendable {
        case update(conversationID: String, ConversationRunUpdate)
        /// 終わった（会話の差分を取り直し、結果を会話に送る）
        case finished(ConversationRun)
    }

    private struct Entry {
        var run: ConversationRun
        var key: String
        var file: URL
        /// 持っている確定した出力の量（上限まで）
        var bytes = 0
        var screen = RunScreen()
        /// 状態が変わったが、まだ流していない
        var changed = false
        var flush: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var stopper: Task<Void, Never>?
        /// 止めると決めた理由（取り消し・打ち切り）
        var stopping: ConversationRun.Status?
        /// 会話の記録を消した：終わったら記録も捨てる
        var discard = false
    }

    private enum Phase: Equatable {
        /// 準備の目印（この id）を待っている
        case starting(String)
        case idle
        case busy(String)
    }

    private struct Shell {
        var conversationID: String
        var kind: RunShell
        var phase: Phase
        var scanner = RunShellScanner()
        /// ここまでの出力を読んだ（位置）。購読し直しで同じ出力を 2 回読まない
        var through = 0
        /// 始まりの目印から終わりの目印までの間
        var inside = false
        /// 購読の応答を待つ間に届いた出力（位置つき）。nil なら届いたらすぐ読む
        var held: [(start: Int, data: Data)]?
        var ready: CheckedContinuation<Void, Error>?
    }

    private let limits: Limits
    /// 動かす時間の上限
    nonisolated var timeout: Duration { limits.duration }
    private let shells: ConversationShells
    private let directory: URL
    private let loginShell: String?
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    /// 会話の id → Run の id（始めた順）
    private var order: [String: [String]] = [:]
    private var hostShells: [String: Shell] = [:]
    /// この daemon で Run を動かしたシェル（key）。無くなった後に起こし直したら、その Run に `newShell` を付ける。［シェルを再起動］で外す
    private var usedShells: Set<String> = []
    private var opening: [String: Task<Bool, Error>] = [:]
    /// シェルごとの書き込みの列（書いた順に届ける）
    private var writes: [String: Task<Void, Never>] = [:]
    private let sink: AsyncStream<Event>.Continuation
    nonisolated let events: AsyncStream<Event>

    /// `directory` はコードを書くファイルの置き場
    init(
        shells: ConversationShells, directory: URL, loginShell: String?, limits: Limits = Limits(), logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.shells = shells
        self.directory = directory
        self.loginShell = loginShell
        self.limits = limits
        self.logger = logger
        self.now = now
        (events, sink) = AsyncStream<Event>.makeStream()
        Self.removeStaleFiles(in: directory, olderThan: now().addingTimeInterval(-3600))
        Task { [weak self] in
            for await notice in shells.runNotices { await self?.received(notice) }
        }
    }

    static func key(conversation id: String, _ shell: RunShell) -> String { "\(keyPrefix)\(id)-\(shell.rawValue)" }

    func start(conversationID: String, cwd: String, environment: [String: String], _ request: ConversationRunRequest) async throws -> ConversationRun {
        guard let resolved = RunShell.resolve(language: request.language, loginShell: loginShell, path: environment["PATH"]) else {
            if request.language.lowercased() == "fish" { throw ConversationError.failed("fish が見つからない") }
            throw ConversationError.invalid("実行できる言語は \(ConversationRunRequest.languages.sorted().joined(separator: "・"))")
        }
        let kind = resolved.shell
        guard !request.code.isEmpty, request.code.utf8.count <= ConversationInput.textBytes else { throw ConversationError.invalid("code が無いか 1MB を超える") }
        let key = Self.key(conversation: conversationID, kind)
        guard !entries.values.contains(where: { $0.key == key && $0.run.status == .running }) else {
            throw ConversationError(status: 409, code: .runLimit, params: ["limit": "1"], description: "このシェルで動いている Run がある")
        }
        let id = UUID().uuidString.lowercased()
        let file = directory.appending(path: id)
        let run = ConversationRun(
            id: id, conversationID: conversationID, messageID: request.messageID, language: request.language, code: request.code, status: .running,
            startedAt: now())
        // シェルを待つ間に同じシェルの次の Run を受けないよう、先に載せる
        entries[id] = Entry(run: run, key: key, file: file)
        order[conversationID, default: []].append(id)
        do {
            try Self.write(request.code, to: file, in: directory)
            var env = environment
            // スピナーと進捗バーを出させ、`RunScreen` で上書きを解釈する（色は捨てる）
            env["TERM"] = "xterm-256color"
            // 画面から入力を送れないので、ページャ（less）が RETURN を待って止まらないようにする
            for name in ["PAGER", "GIT_PAGER", "GH_PAGER"] { env[name] = "cat" }
            // 更新とアンケートの案内を止める。入力の問いは標準入力が /dev/null なので元から出ない
            for name in ["CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK", "CLOUDSDK_SURVEY_DISABLE_PROMPTS", "CHECKPOINT_DISABLE"] {
                env[name] = "1"
            }
            let opened = try await ensureShell(key, conversationID: conversationID, kind: kind, argv: [resolved.executable] + kind.arguments, env: env, cwd: cwd)
            if opened, usedShells.contains(key) { entries[id]?.run.newShell = true }
            usedShells.insert(key)
        } catch {
            entries.removeValue(forKey: id)
            order[conversationID]?.removeAll { $0 == id }
            try? FileManager.default.removeItem(at: file)
            if let failure = error as? ConversationError { throw failure }
            throw ConversationError.failed("Run を起こせない: \(error)")
        }
        trim(conversationID)
        guard let entry = entries[id] else { return run }
        // シェルを待つ間に取り消した・会話を消した
        if entry.stopping != nil || entry.discard {
            finish(id, exitCode: nil)
            return entries[id]?.run ?? run
        }
        hostShells[key]?.phase = .busy(id)
        hostShells[key]?.inside = false
        write(key, kind.runLine(id: id, file: file.path))
        let timeout = limits.duration
        entries[id]?.deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.stop(id, as: .timedOut)
        }
        logger.info("conversation run started", metadata: ["conversation": .string(conversationID), "run": .string(id), "shell": .string(kind.rawValue)])
        return entries[id]?.run ?? run
    }

    func get(conversationID: String, _ id: String) -> ConversationRun? {
        guard let entry = entries[id], entry.run.conversationID == conversationID else { return nil }
        return entry.run
    }

    /// 取り消す。終わっていれば何もしない
    func cancel(conversationID: String, _ id: String) -> Bool {
        guard let entry = entries[id], entry.run.conversationID == conversationID else { return false }
        stop(id, as: .cancelled)
        return true
    }

    /// 会話のシェルを全部閉じる（変数と cd を捨てる）。動いている Run は取り消しで終わる
    func reset(conversationID: String) async {
        for (id, entry) in entries where entry.run.conversationID == conversationID && entry.run.status == .running && entry.stopping == nil {
            entries[id]?.stopping = .cancelled
        }
        // daemon を入れ替える前から残るシェルもあるので、覚えていない種類も閉じる
        for kind in RunShell.allCases {
            let key = Self.key(conversation: conversationID, kind)
            usedShells.remove(key)
            await shells.close(key)
        }
        logger.info("conversation run shells reset", metadata: ["conversation": .string(conversationID)])
    }

    /// 会話の記録を消した：シェルを閉じ、記録を捨てる
    func remove(conversationID: String) async {
        for id in order.removeValue(forKey: conversationID) ?? [] {
            guard entries[id]?.run.status == .running else {
                entries.removeValue(forKey: id)
                continue
            }
            entries[id]?.discard = true
        }
        await reset(conversationID: conversationID)
    }

    /// daemon が普通に終わる：動いている Run を止める（シェルは閉じない）。止まるか `killGrace` まで待つ
    func shutdown() async {
        let running = entries.filter { $0.value.run.status == .running }.map(\.key)
        for id in running { stop(id, as: .cancelled) }
        let deadline = ContinuousClock.now + limits.killGrace
        while ContinuousClock.now < deadline, running.contains(where: { entries[$0]?.run.status == .running }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// host に繋ぎ直した。起き直した host はシェルを持たず、終わりも知らせないので、全部無くなったことにする。
    /// 同じ host なら、購読は接続ごとなので購読し直す
    func hostConnected(restarted: Bool) async {
        for key in Array(hostShells.keys) {
            if restarted {
                shellGone(key, reason: "agent host が起き直した")
            } else {
                do {
                    try await subscribe(key)
                } catch {
                    shellGone(key, reason: "購読し直せない: \(error)")
                }
            }
        }
    }

    // MARK: シェル

    /// 新しくシェルを起こしたら true（残っていたシェルを使ったら false）
    private func ensureShell(_ key: String, conversationID: String, kind: RunShell, argv: [String], env: [String: String], cwd: String) async throws -> Bool {
        if hostShells[key]?.phase == .idle { return false }
        if let task = opening[key] { return try await task.value }
        let task = Task { try await self.openShell(key, conversationID: conversationID, kind: kind, argv: argv, env: env, cwd: cwd) }
        opening[key] = task
        defer { opening[key] = nil }
        return try await task.value
    }

    /// 残っているシェルが空いていれば使い（false）、無いか様子が分からなければ起こし直す（true）
    private func openShell(_ key: String, conversationID: String, kind: RunShell, argv: [String], env: [String: String], cwd: String) async throws -> Bool {
        if try await shells.isLive(key) {
            hostShells[key] = Shell(conversationID: conversationID, kind: kind, phase: .idle)
            switch try await subscribe(key) {
            case .ready, .end, .stop:
                logger.info("conversation run shell resumed", metadata: ["key": .string(key)])
                return false
            case .start, nil:
                // 前の daemon が始めた Run の途中か、準備の前：記録が無いので閉じて起こし直す
                hostShells.removeValue(forKey: key)
                await shells.close(key)
            }
        }
        let ready = UUID().uuidString.lowercased()
        hostShells[key] = Shell(conversationID: conversationID, kind: kind, phase: .starting(ready))
        do {
            try await shells.open(key: key, argv: argv, env: env, cwd: cwd, cols: limits.columns, rows: 50)
            try await subscribe(key)
            write(key, kind.setupLine(id: ready))
            let startup = limits.startup
            let timer = Task { [weak self] in
                do { try await Task.sleep(for: startup) } catch { return }
                await self?.startupTimedOut(key)
            }
            defer { timer.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if hostShells[key]?.phase == .idle {
                    continuation.resume()
                } else if hostShells[key] == nil {
                    continuation.resume(throwing: ConversationError.failed("シェルが終わった"))
                } else {
                    hostShells[key]?.ready = continuation
                }
            }
        } catch {
            if hostShells[key] != nil {
                hostShells.removeValue(forKey: key)
                await shells.close(key)
            }
            throw error
        }
        logger.info("conversation run shell opened", metadata: ["key": .string(key), "shell": .string(argv[0])])
        return true
    }

    private func startupTimedOut(_ key: String) {
        guard case .starting? = hostShells[key]?.phase else { return }
        hostShells[key]?.ready?.resume(throwing: ConversationError.failed("シェルの準備が終わらない"))
        hostShells[key]?.ready = nil
    }

    /// 購読し、ためた出力のうちまだ読んでいない所を読む。返すのはためた出力の最後の目印
    @discardableResult
    private func subscribe(_ key: String) async throws -> RunShellScanner.Mark? {
        hostShells[key]?.held = []
        let (kept, offset) = try await shells.subscribe(key)
        guard hostShells[key] != nil else { return nil }
        var scanner = RunShellScanner()
        var last: RunShellScanner.Mark?
        for case .mark(let mark) in scanner.feed(kept) { last = mark }
        // 前から残るシェルは、ためた分を読まずに今の位置から読む
        if hostShells[key]?.phase == .idle, hostShells[key]?.through == 0 { hostShells[key]?.through = offset }
        let held = hostShells[key]?.held ?? []
        hostShells[key]?.held = nil
        read(key, start: offset - kept.count, kept)
        for chunk in held { read(key, start: chunk.start, chunk.data) }
        return last
    }

    private func received(_ notice: AgentHostNotice) {
        switch notice.event {
        case .shellOutput:
            guard let start = notice.seq, let data = notice.data.flatMap({ Data(base64Encoded: $0) }), hostShells[notice.key] != nil else { return }
            if hostShells[notice.key]?.held != nil {
                hostShells[notice.key]?.held?.append((start, data))
            } else {
                read(notice.key, start: start, data)
            }
        case .shellExit:
            shellGone(notice.key, reason: "シェルが終わった")
        default:
            break
        }
    }

    private func read(_ key: String, start: Int, _ data: Data) {
        guard var shell = hostShells[key] else { return }
        let end = start + data.count
        guard end > shell.through else { return }
        let fresh = start >= shell.through ? data : data.suffix(end - shell.through)
        shell.through = end
        let pieces = shell.scanner.feed(fresh)
        hostShells[key] = shell
        for piece in pieces { handle(key, piece) }
    }

    private func handle(_ key: String, _ piece: RunShellScanner.Piece) {
        guard let shell = hostShells[key] else { return }
        switch piece {
        case .query:
            // 動いているコードの標準入力は /dev/null なので、その間の答えは次の行として打ち込まれてしまう
            if !shell.inside { write(key, Data("\u{1b}[?62;22c".utf8)) }
        case .mark(.ready(let id)):
            guard shell.phase == .starting(id) else { return }
            hostShells[key]?.phase = .idle
            hostShells[key]?.ready?.resume()
            hostShells[key]?.ready = nil
        case .mark(.start(let id)):
            if shell.phase == .busy(id) { hostShells[key]?.inside = true }
        case .mark(.end(let id, let code)):
            ended(key, id, exitCode: code)
        case .mark(.stop(let id)):
            ended(key, id, exitCode: nil)
        case .text(let data):
            guard shell.inside, case .busy(let id) = shell.phase, entries[id]?.stopping == nil else { return }
            entries[id]?.screen.write(data)
            scheduleFlush(id)
        case .control(let control):
            guard shell.inside, case .busy(let id) = shell.phase, entries[id]?.stopping == nil else { return }
            entries[id]?.screen.apply(control)
            scheduleFlush(id)
        }
    }

    private func ended(_ key: String, _ id: String, exitCode: Int32?) {
        guard hostShells[key]?.phase == .busy(id) else { return }
        hostShells[key]?.phase = .idle
        hostShells[key]?.inside = false
        finish(id, exitCode: exitCode)
    }

    /// シェルが無くなった：動いていた Run を終わりにし、起こしている途中なら待っているものに失敗を返す
    private func shellGone(_ key: String, reason: String) {
        guard let shell = hostShells.removeValue(forKey: key) else { return }
        shell.ready?.resume(throwing: ConversationError.failed(reason))
        writes[key] = nil
        if case .busy(let id) = shell.phase { finish(id, exitCode: nil) }
        logger.info("conversation run shell gone", metadata: ["key": .string(key), "reason": .string(reason)])
    }

    /// 書いた順に届ける
    private func write(_ key: String, _ data: Data) {
        let previous = writes[key]
        let shells = shells
        let logger = logger
        writes[key] = Task {
            await previous?.value
            do {
                try await shells.input(key, data)
            } catch {
                logger.warning("conversation run shell input failed", metadata: ["key": .string(key), "error": "\(error)"])
            }
        }
    }

    // MARK: Run

    /// 画面で確定した出力を上限まで持つ。上限を超えた分は捨てて `truncated` にする
    private func commit(_ text: String, to entry: inout Entry) {
        guard !text.isEmpty else { return }
        let room = limits.outputBytes - entry.bytes
        guard room > 0 else {
            if !entry.run.truncated { entry.run.truncated = true; entry.changed = true }
            return
        }
        let kept = Self.utf8Prefix(text, bytes: room)
        entry.run.output += kept
        entry.bytes += kept.utf8.count
        if kept.utf8.count < text.utf8.count, !entry.run.truncated {
            entry.run.truncated = true
            entry.changed = true
        }
    }

    private func finish(_ id: String, exitCode: Int32?) {
        guard var entry = entries[id], entry.run.status == .running else { return }
        entry.deadline?.cancel()
        entry.stopper?.cancel()
        entry.flush?.cancel()
        entry.flush = nil
        entry.run.exitCode = exitCode
        entry.run.status = entry.stopping ?? (exitCode == 0 ? .succeeded : .failed)
        entry.run.endedAt = now()
        let before = entry.run.output.utf8.count
        commit(entry.screen.take(final: true).committed, to: &entry)
        let chunk = String(decoding: entry.run.output.utf8.dropFirst(before), as: UTF8.self)
        entry.run.tail = nil
        entry.changed = false
        try? FileManager.default.removeItem(at: entry.file)
        if entry.discard {
            entries.removeValue(forKey: id)
        } else {
            entries[id] = entry
            publish(entry.run, chunk: chunk)
            sink.yield(.finished(entry.run))
        }
        logger.info(
            "conversation run finished",
            metadata: ["run": .string(id), "status": .string(entry.run.status.rawValue), "exit": .stringConvertible(exitCode ?? -1)])
    }

    /// 取り消し・打ち切り：Ctrl-C と停止の目印の行を書き、目印が来なければ `killGrace` の後にシェルを閉じる
    private func stop(_ id: String, as status: ConversationRun.Status) {
        guard var entry = entries[id], entry.run.status == .running, entry.stopping == nil else { return }
        entry.stopping = status
        entry.deadline?.cancel()
        let key = entry.key
        guard let kind = hostShells[key]?.kind, hostShells[key]?.phase == .busy(id) else {
            // シェルを起こしている途中：起き終えたら Run の行を書かずに終える（`start`）
            entries[id] = entry
            return
        }
        write(key, Data([0x03]))
        let limits = limits
        entry.stopper = Task { [weak self] in
            let deadline = ContinuousClock.now + limits.killGrace
            while ContinuousClock.now < deadline {
                do { try await Task.sleep(for: limits.stopRetry) } catch { return }
                guard let self, await self.isRunning(id) else { return }
                await self.write(key, kind.stopLine(id: id))
            }
            await self?.closeIfStill(id)
        }
        entries[id] = entry
    }

    private func isRunning(_ id: String) -> Bool { entries[id]?.run.status == .running }

    private func closeIfStill(_ id: String) async {
        guard let entry = entries[id], entry.run.status == .running else { return }
        logger.warning("conversation run did not stop; closing the shell", metadata: ["run": .string(id)])
        await shells.close(entry.key)
    }

    private func scheduleFlush(_ id: String) {
        guard entries[id]?.flush == nil else { return }
        let batch = limits.batch
        entries[id]?.flush = Task { [weak self] in
            do { try await Task.sleep(for: batch) } catch { return }
            await self?.flush(id)
        }
    }

    /// まとめた出力を流す。文字の途中で切れた末尾のバイトは次に回す
    private func flush(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.flush = nil
        guard entry.run.status == .running else {
            entries[id] = entry
            return
        }
        let taken = entry.screen.take()
        let before = entry.run.output.utf8.count
        commit(taken.committed, to: &entry)
        let chunk = String(decoding: entry.run.output.utf8.dropFirst(before), as: UTF8.self)
        if let tail = taken.tail { entry.run.tail = tail }
        let changed = entry.changed || taken.tail != nil
        entry.changed = false
        entries[id] = entry
        if !chunk.isEmpty || changed { publish(entry.run, chunk: chunk) }
    }

    private func publish(_ run: ConversationRun, chunk: String) {
        sink.yield(
            .update(
                conversationID: run.conversationID,
                ConversationRunUpdate(
                    id: run.id, messageID: run.messageID, status: run.status, exitCode: run.exitCode, chunk: chunk, tail: run.tail, truncated: run.truncated)))
    }

    /// 古い終わった Run から捨てて `kept` 件にする（動いているものは捨てない）
    private func trim(_ conversationID: String) {
        var ids = order[conversationID] ?? []
        while ids.count > limits.kept, let index = ids.firstIndex(where: { entries[$0]?.run.status != .running }) {
            entries.removeValue(forKey: ids.remove(at: index))
        }
        order[conversationID] = ids
    }

    /// 先頭から `bytes` バイトまで（文字の途中で切らない）
    static func utf8Prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: bytes)
        while end > text.utf8.startIndex, String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }

    /// UTF-8 として読める先頭と、そのバイト数。末尾の 3 バイトまでは、文字の途中で切れたものとして残す（それより前の読めないバイトは置き換える）
    static func decodePrefix(_ data: Data) -> (String, Int) {
        for cut in 0...min(3, data.count) {
            let prefix = data.prefix(data.count - cut)
            if let text = String(data: prefix, encoding: .utf8) { return (text, prefix.count) }
        }
        return (String(decoding: data, as: UTF8.self), data.count)
    }

    // MARK: コードのファイル

    private static func write(_ code: String, to file: URL, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: file.path, contents: Data(code.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 前の daemon が消せなかったファイル（動いている Run が読んでいるかもしれないので、古いものだけ）
    private static func removeStaleFiles(in directory: URL, olderThan cutoff: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
