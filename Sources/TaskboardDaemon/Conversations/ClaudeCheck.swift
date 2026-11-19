import Foundation
import Logging
import NIOCore
import TaskboardKit

/// `taskboard conversation check`：本物の Claude Code を短い会話で通し、host の会話が頼る動き（stream-json の行・制御要求・hook_callback・defer と `--resume`・
/// 待ち行列の取り消し）が今の版でも変わっていないかを確かめる（結果と記録は `EngineCheck`）
public enum ClaudeCheck {
    /// 作業フォルダ（使い捨て）で会話を 1 本起こして通す。`progress` は各段の結果
    public static func run(
        executable: String, model: String = "haiku", logger: Logger = Logger(label: "uk.whatn.taskboard.check"),
        progress: @escaping @Sendable (EngineCheck.Step) -> Void = { _ in }
    ) async throws -> EngineCheck.Report {
        let version = try await EngineCheck.version(of: executable, engine: .claude)
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let work = base.appending(path: "taskboard-check-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work.appending(path: "logs"), withIntermediateDirectories: true)
        let environment = await LoginShellEnvironment.capture(shell: LoginShell.path ?? "/bin/zsh") ?? fallbackEnvironment()
        defer {
            removeTranscripts(cwd: work.path, environment: environment)
            try? FileManager.default.removeItem(at: work)
        }
        let run = CheckRun(executable: executable, model: model, work: work, environment: environment, logger: logger, progress: progress)
        let steps = await run.perform()
        return EngineCheck.Report(
            engine: .claude, version: version, executable: executable, capabilities: await run.capabilities, steps: steps, models: run.listedModels.value)
    }

    static func fallbackEnvironment() -> [String: String] {
        let output = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }.joined(separator: "\0")
        return LoginShellEnvironment.parse("\n\(LoginShellEnvironment.marker)\n" + output) ?? [:]
    }

    /// Claude Code が作業フォルダごとに作る transcript の置き場（パスの英数字以外を `-` にした名前）。確かめの会話の分だけ消す
    static func removeTranscripts(cwd: String, environment: [String: String]) {
        // Claude Code は realpath の名前で置く（`resolvingSymlinksInPath` は /private を外すので使わない）
        let real = realpath(cwd, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? cwd
        let name = String(real.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        guard name.contains("taskboard-check-") else { return }
        let directory = ClaudeConfigDirectory.projects(environment: environment).appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 確かめの 1 回分
private actor CheckRun: EngineCheckRun {
    final class ListedModels: @unchecked Sendable {
        private let lock = NSLock()
        private var models: [ClaudeMachineInfo.Model]?
        var value: [ClaudeMachineInfo.Model]? { lock.withLock { models } }
        func set(_ value: [ClaudeMachineInfo.Model]) { lock.withLock { models = value } }
    }

    private final class StopHook: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private(set) var calls = 0
        func arm() { lock.withLock { armed = true } }
        /// 1 回だけ続きを頼む（次の Stop では止めさせる）
        func take() -> String? {
            lock.withLock {
                calls += 1
                guard armed else { return nil }
                armed = false
                return "Before finishing, reply with the single word CONTINUED."
            }
        }
    }

    let executable: String
    let model: String
    let work: URL
    let environment: [String: String]
    let logger: Logger
    let progress: @Sendable (EngineCheck.Step) -> Void
    private let route = EngineCheckRoute()
    private let stopHook = StopHook()
    /// initialize の答えのモデルの一覧（最後に受けたもの）
    nonisolated let listedModels = ListedModels()
    var events: [ConversationEvent] = []
    var steps: [EngineCheck.Step] = []
    private(set) var capabilities: [String] = []

    init(
        executable: String, model: String, work: URL, environment: [String: String], logger: Logger, progress: @escaping @Sendable (EngineCheck.Step) -> Void
    ) {
        self.executable = executable
        self.model = model
        self.work = work
        self.environment = environment
        self.logger = logger
        self.progress = progress
    }

    func perform() async -> [EngineCheck.Step] {
        let host = InProcessAgentHost(logDirectory: work.appending(path: "logs"), logger: logger)
        await host.start { [route] notice in route.yield(notice) }
        defer { Task { await host.shutdown() } }
        let store: Store
        let record: ConversationRecord
        do {
            store = try Store(inMemory: MachineID(rawValue: "check"))
            record = try store.createConversation(
                ConversationRecord(taskNumber: nil, agentSessionId: UUID().uuidString.lowercased(), cwd: work.path, model: model, permissionMode: "bypassPermissions", runner: .none))
        } catch {
            note("準備", false, "\(error)")
            return steps
        }
        var conversation = await make(record: record, store: store, host: host)

        guard
            await step("起動", {
                try await conversation.start(resume: false)
                // 確かめの会話は画面に出ていないので、既定（auto）では問いを defer で終える。defer の段の外では切る
                _ = try await conversation.control(ConversationControlRequest(kind: .deferQuestions, value: "off"))
                return await conversation.snapshot().phase == .idle ? "" : nil
            })
        else { return steps }
        _ = await step("送信") {
            let mark = self.events.count
            let text = try await self.ask(conversation, "Reply with exactly the word PONG and nothing else.")
            self.capabilities = await conversation.info?.capabilities ?? []
            let missing = ClaudeConversation.requiredCapabilities.filter { !self.capabilities.contains($0) }
            guard missing.isEmpty else { throw CheckFailure("capabilities に \(missing.joined(separator: "・")) が無い") }
            try await self.idleAfterTurn(after: mark)
            return text.contains("PONG") ? "" : nil
        }
        _ = await step("送った発言と返答の uuid が transcript に残る") {
            let mark = self.events.count
            let sent = UUID().uuidString.lowercased()
            let outcome = try await conversation.send(ConversationSendRequest(text: "Reply with exactly the word UUID and nothing else.", clientMessageID: sent))
            guard outcome == .accepted else { throw CheckFailure("送った文を CLI が受けたか確かめられない（\(outcome)）") }
            _ = try await self.turnText(after: mark)
            let streamed = Set(self.events[mark...].flatMap { event -> [String] in
                guard case .messages(let messages, _) = event.kind else { return [] }
                return messages.map(\.id)
            })
            guard streamed.contains(where: { $0 == sent || $0.hasPrefix(sent + "#") }) else { throw CheckFailure("送った発言の写しが stream-json に無い") }
            let sessionID = await conversation.snapshot().agentSessionID
            let deadline = ContinuousClock.now + .seconds(10)
            var missing = streamed
            while ContinuousClock.now < deadline {
                missing = ClaudeCheck.missing(streamed, inTranscript: self.transcript(sessionID))
                if missing.isEmpty { return "" }
                try await Task.sleep(for: .milliseconds(300))
            }
            throw CheckFailure("transcript に無い発言の id: \(missing.sorted().prefix(3).joined(separator: ", "))")
        }
        _ = await step("フォーク（--fork-session と --resume-session-at）") {
            try await self.fork(from: conversation, record: record, store: store, host: host)
        }
        _ = await step("rewind_files の dry run") {
            let mark = self.events.count
            let sent = UUID().uuidString.lowercased()
            let outcome = try await conversation.send(
                ConversationSendRequest(text: "Use the Write tool to write exactly the text 1 into check.txt. Then reply with only DONE.", clientMessageID: sent))
            guard outcome == .accepted else { throw CheckFailure("送った文を CLI が受けたか確かめられない（\(outcome)）") }
            _ = try await self.turnText(after: mark)
            try await self.idleAfterTurn(after: mark)
            let result = try await conversation.rewindFiles(userMessageID: sent, dryRun: true)
            guard result.canRewind == true else { throw CheckFailure("戻せないと返った: \(result.error ?? "-")") }
            guard result.filesChanged?.contains(where: { $0.hasSuffix("/check.txt") }) == true else { throw CheckFailure("戻すファイルに check.txt が無い") }
            return "変わるファイル \(result.filesChanged?.count ?? 0)"
        }
        _ = await step("Stop の hook で続けさせる") {
            self.stopHook.arm()
            let text = try await self.ask(conversation, "Reply with exactly the word READY and nothing else.")
            return text.contains("CONTINUED") ? "" : nil
        }
        _ = await step("質問に答える") {
            let mark = self.events.count
            try await self.send(conversation, Self.questionPrompt)
            let request = try await self.waitFor(after: mark, Self.answerTimeout) { event in
                if case .conversation(let snapshot) = event.kind { return snapshot.pending.first { $0.kind == .question } }
                return nil
            }
            let label = try await self.answer(conversation, request, after: mark)
            let text = try await self.turnText(after: mark)
            try await self.idleAfterTurn(after: mark)
            return text.contains(label) ? "" : nil
        }
        _ = await step("defer で終えて --resume で答える") {
            let on = ConversationControlRequest(kind: .deferQuestions, value: "on")
            let off = ConversationControlRequest(kind: .deferQuestions, value: "off")
            _ = try await conversation.control(on)
            let result: String?
            do {
                result = try await self.deferAndAnswer(conversation)
            } catch {
                _ = try? await conversation.control(off)
                throw error
            }
            _ = try? await conversation.control(off)
            return result
        }
        _ = await step("生成中に止める（interrupt）") {
            let mark = self.events.count
            try await self.send(conversation, "Count from 1 to 400, one number per line, with no other text.")
            _ = try await self.waitFor(after: mark, .seconds(120)) { event in
                if case .delta = event.kind { return true }
                return nil
            }
            _ = try await conversation.control(ConversationControlRequest(kind: .interrupt))
            let turn = try await self.waitFor(after: mark, .seconds(30)) { event in
                if case .turn(let turn) = event.kind { return turn }
                return nil
            }
            return "stop_reason \(turn.stopReason ?? "-")"
        }
        _ = await step("mcp_status") { try await conversation.control(ConversationControlRequest(kind: .mcpStatus)).payloadJSON == nil ? nil : "" }
        _ = await step("get_context_usage") { try await conversation.control(ConversationControlRequest(kind: .contextUsage)).payloadJSON == nil ? nil : "" }
        _ = await step("daemon の入れ替えの後に引き取る（initialize の送り直し）") {
            guard let process = try await host.list().first(where: { $0.key == record.id }), process.alive else { throw CheckFailure("子が動いていない") }
            guard let reopened = try store.conversation(id: record.id) else { throw CheckFailure("記録が無い") }
            conversation = await self.make(record: reopened, store: store, host: host)
            await conversation.attach(process: process)
            guard await conversation.isIdle else { throw CheckFailure("引き取った後に空いていない（\(await conversation.snapshot().phase.rawValue)）") }
            let text = try await self.ask(conversation, "Reply with exactly the word AGAIN and nothing else.")
            return text.contains("AGAIN") ? "" : nil
        }
        _ = await step("止める") {
            await conversation.stop(.taskboard)
            return await conversation.isLive ? nil : ""
        }
        return steps
    }

    /// 元の会話の 1 回目の返答の行で分けた会話を起こして 1 回送り、新しい transcript に元の行が同じ uuid で写り、分けた所より後の行が無いことを見る
    private func fork(from conversation: ClaudeConversation, record: ConversationRecord, store: Store, host: InProcessAgentHost) async throws -> String? {
        let source = await conversation.snapshot().agentSessionID
        let lines = Self.mainLines(transcript(source))
        guard let first = lines.first, let at = lines.first(where: { $0.type == "assistant" }) else { throw CheckFailure("元の transcript に発言が無い") }
        let later = Set(lines.drop { $0.uuid != at.uuid }.dropFirst().map(\.uuid))
        guard !later.isEmpty else { throw CheckFailure("元の transcript に分ける所より後の行が無い") }
        let forkRecord = try store.createConversation(
            ConversationRecord(
                taskNumber: nil, agentSessionId: UUID().uuidString.lowercased(), cwd: work.path, model: model, permissionMode: "bypassPermissions", runner: .none
            ).forked(from: record.id, request: UUID().uuidString.lowercased(), point: ConversationFork(session: source, uuid: at.uuid)))
        let fork = await make(record: forkRecord, store: store, host: host)
        defer { Task { await fork.stop(.taskboard) } }
        try await fork.start(resume: false)
        let text = try await ask(fork, "Reply with exactly the word FORKED and nothing else.")
        let copied = Set(Self.mainLines(transcript(forkRecord.agentSessionId)).map(\.uuid))
        guard copied.contains(first.uuid), copied.contains(at.uuid) else { throw CheckFailure("新しい transcript に元の発言が同じ uuid で写っていない") }
        guard copied.isDisjoint(with: later) else { throw CheckFailure("--resume-session-at より後の行が写った") }
        guard try store.conversation(id: forkRecord.id)?.pendingForkSessionId == nil else { throw CheckFailure("transcript ができても、フォークの印が消えない") }
        await fork.stop(.taskboard)
        return text.contains("FORKED") ? "" : nil
    }

    /// transcript の会話の本筋の user と assistant の行（古い順）
    private static func mainLines(_ data: Data) -> [TranscriptLines.Line] {
        var offset: UInt64 = 0
        return data.split(separator: 0x0A, omittingEmptySubsequences: false).compactMap { body in
            let start = offset
            offset += UInt64(body.count + 1)
            guard !body.isEmpty, let line = TranscriptLines.parse(Data(body), start: start, end: offset) else { return nil }
            return line.type == "user" || line.type == "assistant" ? line : nil
        }
    }

    static let questionPrompt =
        "Use the AskUserQuestion tool exactly once: ask \"Which letter?\" with exactly two options labeled A and B. After I answer, reply with only the label I chose."

    // MARK: 会話

    private func make(record: ConversationRecord, store: Store, host: InProcessAgentHost) async -> ClaudeConversation {
        let launch = EngineLaunch(executable: executable, environment: environment)
        let stopHook = stopHook
        var context = ClaudeConversation.Context(
            shared: ConversationContext(
                machine: MachineID(rawValue: "check"), store: store, host: host, launch: { launch },
                attachments: nil, guide: { _ in nil }, becameIdle: { _ in }, logger: logger), stopHook: { _, _ in stopHook.take() })
        context.hasTranscript = { ClaudeConversation.transcriptExists($0, environment: $1) }
        context.transcriptSource = { ClaudeConversation.transcriptSource(fork: $0, source: $1, environment: $2) }
        let listedModels = listedModels
        context.modelsListed = { models, _ in listedModels.set(models) }
        let conversation = ClaudeConversation(record: record, context: context)
        route.set(record.id, conversation.inbox)
        let stream = await conversation.events(after: 0)
        Task { [weak self] in
            for await event in stream { await self?.received(event) }
        }
        return conversation
    }

    /// その Claude の会話 ID の transcript（無ければ空）
    private func transcript(_ sessionID: String) -> Data {
        let projects = ClaudeConfigDirectory.projects(environment: environment)
        guard let url = TranscriptTail.locate(sessionID, in: projects.standardizedFileURL.resolvingSymlinksInPath()) else { return Data() }
        return (try? Data(contentsOf: url)) ?? Data()
    }


    private func send(_ conversation: ClaudeConversation, _ text: String) async throws {
        let outcome = try await conversation.send(ConversationSendRequest(text: text))
        guard outcome == .accepted else { throw CheckFailure("送った文を CLI が受けたか確かめられない（\(outcome)）") }
    }

    /// 質問を defer で終えさせ、プロセスが終わった後に答えて `--resume` で続けさせる
    private func deferAndAnswer(_ conversation: ClaudeConversation) async throws -> String? {
        let mark = events.count
        try await send(conversation, Self.questionPrompt)
        let deferred = try await waitFor(after: mark, Self.answerTimeout) { event in
            if case .conversation(let snapshot) = event.kind, !snapshot.runnerIsLive { return snapshot.deferred }
            return nil
        }
        let resumed = events.count
        let label = try await answer(conversation, deferred, after: resumed)
        let text = try await turnText(after: resumed)
        return text.contains(label) ? "" : nil
    }

    /// 送ってターンの終わりまで待ち、その間の返答の文を返す
    private func ask(_ conversation: ClaudeConversation, _ text: String) async throws -> String {
        let mark = events.count
        try await send(conversation, text)
        return try await turnText(after: mark)
    }

    /// ターンの後に CLI が空いたと知らせ、会話が idle に戻る（`session_state_changed` が来ないと、問いに答えた後に running のまま残る）
    private func idleAfterTurn(after mark: Int) async throws {
        let turnIndex = try await waitFor(after: mark, Self.answerTimeout) { event in
            if case .turn = event.kind { return events.firstIndex { $0.seq == event.seq } }
            return nil
        }
        do {
            _ = try await waitFor(after: turnIndex ?? mark, .seconds(10)) { event in
                if case .conversation(let snapshot) = event.kind, snapshot.phase == .idle { return true }
                return nil
            }
        } catch {
            throw CheckFailure("ターンの後に idle に戻らなかった")
        }
    }

    /// 問いの最初の質問に 2 つ目の選択肢で答え、その選択肢の名前を返す
    private func answer(_ conversation: ClaudeConversation, _ request: ConversationRequest, after mark: Int) async throws -> String {
        guard let questions = request.waiting.questions, let first = questions.first, let option = first.options.dropFirst().first ?? first.options.first else {
            throw CheckFailure("問いに選択肢が無い")
        }
        let answers = questions.map { question in AskAnswer(questionID: question.id, selected: [question.id == first.id ? option.label : question.options.first?.label ?? ""]) }
        try await conversation.answer(ConversationAnswerRequest(requestID: request.id, answers: answers))
        return option.label
    }

    func assistantText(after mark: Int) -> String {
        events[min(mark, events.count)...].flatMap { event -> [String] in
            guard case .messages(let messages, _) = event.kind else { return [] }
            return messages.filter { $0.role == .assistant && $0.kind == .text && !$0.isThinking }.map(\.text)
        }.joined(separator: "\n")
    }

}

extension ClaudeCheck {
    /// stream-json で届いた発言の id のうち、transcript に無いもの（履歴の読み方と同じ `TranscriptParser` で id を振る）
    static func missing(_ streamed: Set<String>, inTranscript data: Data) -> Set<String> {
        var ids: Set<String> = []
        for (index, line) in data.split(separator: 0x0A).enumerated() {
            if case .messages(let messages) = TranscriptParser.parse(Data(line), index: index) { ids.formUnion(messages.map(\.id)) }
        }
        return streamed.subtracting(ids)
    }
}

extension Conversation {
    fileprivate var runnerIsLive: Bool { runner == .host }
}
