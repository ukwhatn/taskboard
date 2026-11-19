import Foundation
import Logging
import TaskboardKit

/// `taskboard conversation check --engine codex`：本物の codex を短い会話で通し、host の会話が頼る app-server の動き（thread/start と resume・流れる返事・
/// 承認の要求・turn/interrupt・止まった thread の items/list と fork）が今の版でも変わっていないかを確かめる（結果と記録は `EngineCheck`）
public enum CodexCheck {
    /// 作業フォルダ（使い捨て）で会話を 1 本起こして通す。作った thread は終わりに archive する。`model` を省くと codex の既定のモデル
    public static func run(
        executable: String, model: String? = nil, logger: Logger = Logger(label: "uk.whatn.taskboard.check"),
        progress: @escaping @Sendable (EngineCheck.Step) -> Void = { _ in }
    ) async throws -> EngineCheck.Report {
        let version = try await EngineCheck.version(of: executable, engine: .codex)
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let work = base.appending(path: "taskboard-check-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work.appending(path: "logs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let environment = await LoginShellEnvironment.capture(shell: LoginShell.path ?? "/bin/zsh") ?? ClaudeCheck.fallbackEnvironment()
        let run = CodexCheckRun(
            launch: EngineLaunch(executable: executable, environment: environment), model: model, work: work, logger: logger, progress: progress)
        let steps = await run.perform()
        await run.archiveThreads()
        return EngineCheck.Report(engine: .codex, version: version, executable: executable, capabilities: [], steps: steps)
    }
}

/// 確かめの 1 回分
private actor CodexCheckRun: EngineCheckRun {
    static let fullAccess = "bypassPermissions"

    let launch: EngineLaunch
    let model: String?
    let work: URL
    let logger: Logger
    let progress: @Sendable (EngineCheck.Step) -> Void
    private let route = EngineCheckRoute()
    var events: [ConversationEvent] = []
    var steps: [EngineCheck.Step] = []
    /// 作った thread（終わりに archive する）
    private var threads: [String] = []

    init(launch: EngineLaunch, model: String?, work: URL, logger: Logger, progress: @escaping @Sendable (EngineCheck.Step) -> Void) {
        self.launch = launch
        self.model = model
        self.work = work
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
            let id = UUID().uuidString.lowercased()
            record = try store.createConversation(
                ConversationRecord(id: id, taskNumber: nil, engine: .codex, agentSessionId: id, cwd: work.path, model: model, permissionMode: Self.fullAccess, runner: .none))
        } catch {
            note("準備", false, "\(error)")
            return steps
        }
        var conversation = make(record: record, store: store, host: host)

        guard
            await step("起動（thread/start）", {
                try await conversation.start(resume: false)
                let thread = await conversation.snapshot().agentSessionID
                guard thread != record.id else { throw CheckFailure("thread の ID が返らない") }
                self.threads.append(thread)
                return await conversation.snapshot().phase == .idle ? "" : nil
            })
        else { return steps }
        let sent = UUID().uuidString.lowercased()
        _ = await step("送信（発言の uuid が item に残る）") {
            let mark = self.events.count
            let outcome = try await conversation.send(ConversationSendRequest(text: "Reply with exactly the word PONG and nothing else.", clientMessageID: sent))
            guard outcome == .accepted else { throw CheckFailure("送った文を app-server が受けたか確かめられない（\(outcome)）") }
            let text = try await self.turnText(after: mark)
            guard self.messageIDs(after: mark).contains(sent) else { throw CheckFailure("送った発言の写しが送った uuid で返らない") }
            return text.contains("PONG") ? "" : nil
        }
        _ = await step("承認（確認ありで touch を許可する）") {
            let manual = ConversationControlRequest(kind: .setPermissionMode, value: "manual")
            let full = ConversationControlRequest(kind: .setPermissionMode, value: Self.fullAccess)
            _ = try await conversation.control(manual)
            let result: String?
            do {
                result = try await self.approve(conversation)
            } catch {
                _ = try? await conversation.control(full)
                throw error
            }
            _ = try await conversation.control(full)
            return result
        }
        _ = await step("生成中に止める（turn/interrupt）") {
            let mark = self.events.count
            try await self.send(conversation, "Count from 1 to 400, one number per line, with no other text.")
            let streamed = try await self.waitFor(after: mark, .seconds(120)) { event -> Result<Void, CheckFailure>? in
                switch event.kind {
                case .delta: .success(())
                case .turn(let turn): .failure(CheckFailure("流れる前にターンが終わった（\(turn.stopReason ?? "completed")）"))
                default: nil
                }
            }
            try streamed.get()
            _ = try await conversation.control(ConversationControlRequest(kind: .interrupt))
            let turn = try await self.waitFor(after: mark, .seconds(30)) { event in
                if case .turn(let turn) = event.kind { return turn }
                return nil
            }
            return "stop_reason \(turn.stopReason ?? "-")"
        }
        _ = await step("コンテキスト（thread/tokenUsage/updated）") {
            try await conversation.control(ConversationControlRequest(kind: .contextBreakdown)).payloadJSON == nil ? nil : ""
        }
        _ = await step("daemon の入れ替えの後に引き取る（控えを読み直す）") {
            guard let process = try await host.list().first(where: { $0.key == record.id }), process.alive else { throw CheckFailure("子が動いていない") }
            guard let reopened = try store.conversation(id: record.id) else { throw CheckFailure("記録が無い") }
            conversation = self.make(record: reopened, store: store, host: host)
            await conversation.attach(process: process)
            guard await conversation.isIdle else { throw CheckFailure("引き取った後に空いていない（\(await conversation.snapshot().phase.rawValue)）") }
            let text = try await self.ask(conversation, "Reply with exactly the word AGAIN and nothing else.")
            return text.contains("AGAIN") ? "" : nil
        }
        _ = await step("止める") {
            await conversation.stop(.taskboard)
            return await conversation.isLive ? nil : ""
        }
        guard let thread = threads.first else { return steps }
        var turnID: String?
        _ = await step("止まった thread を別の app-server で読む（thread/items/list）") {
            let page = try await CodexOneShot.call(self.launch, "thread/items/list", CodexProtocol.ItemsList(threadId: thread, limit: 100), timeout: .seconds(60))
                .result(CodexProtocol.ItemsPage.self)
            let wanted = CodexItems.itemID(ofMessage: sent)
            guard let entry = page.data.first(where: { CodexItems.matches($0.item, itemID: wanted) }), let turn = entry.turnId else {
                throw CheckFailure("送った発言が items に無い")
            }
            turnID = turn
            return "items \(page.data.count)"
        }
        _ = await step("フォーク（thread/fork の thread を戻して送る）") {
            guard let turnID else { throw CheckFailure("フォークする turn が分からない") }
            let forked = try await CodexOneShot.call(
                self.launch, "thread/fork",
                CodexProtocol.ThreadFork(threadId: thread, lastTurnId: turnID, cwd: self.work.path, approvalPolicy: "never", sandbox: "danger-full-access"),
                timeout: .seconds(60)
            ).result(CodexProtocol.ThreadOpened.self).thread.id
            self.threads.append(forked)
            let copy = try store.createConversation(
                ConversationRecord(taskNumber: nil, engine: .codex, agentSessionId: forked, cwd: self.work.path, model: self.model, permissionMode: Self.fullAccess, runner: .none))
            let branch = self.make(record: copy, store: store, host: host)
            try await branch.start(resume: true)
            let text = try await self.ask(branch, "Reply with exactly the word FORKED and nothing else.")
            await branch.stop(.taskboard)
            return text.contains("FORKED") ? "" : nil
        }
        return steps
    }

    /// 作った thread を archive する（codex の一覧に確かめの会話を残さない）。外せなかったものはログに残すだけ
    func archiveThreads() async {
        for thread in threads {
            do {
                _ = try await CodexOneShot.call(launch, "thread/archive", CodexProtocol.ThreadArchive(threadId: thread), timeout: .seconds(30))
            } catch {
                logger.warning("check thread not archived", metadata: ["thread": .string(thread), "error": "\(error)"])
            }
        }
    }

    // MARK: 会話

    private func make(record: ConversationRecord, store: Store, host: InProcessAgentHost) -> CodexConversation {
        let launch = launch
        let context = CodexConversation.Context(
            shared: ConversationContext(
                machine: MachineID(rawValue: "check"), store: store, host: host, launch: { launch },
                attachments: nil, guide: { _ in nil }, becameIdle: { _ in }, logger: logger))
        let conversation = CodexConversation(record: record, context: context)
        route.set(record.id, conversation.inbox)
        Task { [weak self] in
            for await event in await conversation.events(after: 0) { await self?.received(event) }
        }
        return conversation
    }

    /// コマンドを頼み、承認の問いを許可して、ファイルができたかを見る
    private func approve(_ conversation: CodexConversation) async throws -> String? {
        let mark = events.count
        try await send(conversation, "Run the shell command `touch tb-check.txt` in the current directory. Then reply with only DONE.")
        // 問いの前にターンが終わったら（codex が断られた・使える量を超えた）待たずに止める
        let waited = try await waitFor(after: mark, Self.answerTimeout) { event -> Result<ConversationRequest, CheckFailure>? in
            switch event.kind {
            case .conversation(let snapshot): snapshot.pending.first { $0.kind == .permission }.map { .success($0) }
            case .turn(let turn): .failure(CheckFailure("問いの前にターンが終わった（\(turn.stopReason ?? "completed")）"))
            default: nil
            }
        }
        let request = try waited.get()
        try await conversation.answer(ConversationAnswerRequest(requestID: request.id, allow: true))
        _ = try await turnText(after: mark)
        guard FileManager.default.fileExists(atPath: work.appending(path: "tb-check.txt").path) else { throw CheckFailure("許可した後にファイルができていない") }
        return "\(request.toolName ?? "-") の問い"
    }

    private func send(_ conversation: CodexConversation, _ text: String) async throws {
        let outcome = try await conversation.send(ConversationSendRequest(text: text))
        guard outcome == .accepted else { throw CheckFailure("送った文を app-server が受けたか確かめられない（\(outcome)）") }
    }

    /// 送ってターンの終わりまで待ち、その間の返事の文を返す
    private func ask(_ conversation: CodexConversation, _ text: String) async throws -> String {
        let mark = events.count
        try await send(conversation, text)
        return try await turnText(after: mark)
    }

    private func messageIDs(after mark: Int) -> Set<String> {
        Set(events[min(mark, events.count)...].flatMap { event -> [String] in
            guard case .messages(let messages, _) = event.kind else { return [] }
            return messages.map(\.id)
        })
    }

    func assistantText(after mark: Int) -> String {
        events[min(mark, events.count)...].flatMap { event -> [String] in
            guard case .messages(let messages, _) = event.kind else { return [] }
            return messages.filter { $0.role == .assistant && $0.kind == .text }.map(\.text)
        }.joined(separator: "\n")
    }
}
