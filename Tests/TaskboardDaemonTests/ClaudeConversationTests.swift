import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

/// ログに出た文と metadata を全部集める（秘密が出ていないかを見る）
private struct CapturedLog: LogHandler {
    let lines: Calls
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:], uniquingKeysWith: { $1 })
        lines.add("\(event.message) \(merged)")
    }
}

@Suite("Claude の会話（偽物の host）", .serialized)
struct ClaudeConversationTests {
    private let machine = MachineID(rawValue: "m-test")

    private func make(
        record: ((Int) -> ConversationRecord)? = nil, stopHook: @escaping @Sendable (String, ClaudeHookCall) async -> String? = { _, _ in nil },
        hasTranscript: Bool = true, diff: @escaping @Sendable (String) async -> ConversationDiffSummary? = { _ in nil },
        configure: @escaping (inout ClaudeConversation.Context) -> Void = { _ in }
    ) async throws -> (ClaudeConversation, FakeHost, Store, Int, Calls) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        let made = record?(task.number) ?? ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", model: "haiku", runner: .none)
        let saved = try store.createConversation(made)
        let host = FakeHost()
        let calls = Calls()
        let conversation = await reopen(
            saved.id, store: store, host: host, calls: calls, stopHook: stopHook, hasTranscript: hasTranscript, diff: diff, configure: configure)
        return (conversation, host, store, task.number, calls)
    }

    /// 記録から actor を作り直す（daemon の入れ替え）
    private func reopen(
        _ id: String, store: Store, host: FakeHost, calls: Calls, stopHook: @escaping @Sendable (String, ClaudeHookCall) async -> String? = { _, _ in nil },
        hasTranscript: Bool = true, diff: @escaping @Sendable (String) async -> ConversationDiffSummary? = { _ in nil },
        configure: (inout ClaudeConversation.Context) -> Void = { _ in }
    ) async -> ClaudeConversation {
        var timing = ConversationTiming()
        timing.accept = .milliseconds(300)
        timing.stopResult = .milliseconds(300)
        timing.stopInput = .milliseconds(300)
        timing.stopTerm = .milliseconds(300)
        timing.control = .seconds(2)
        timing.diffBatch = .milliseconds(30)
        // 途中送りの裏回しは、それを確かめるテストだけが短くする（ほかのテストの background_tasks の数を変えない）
        timing.steerDetachAge = .seconds(600)
        var context = ClaudeConversation.Context(
            shared: ConversationContext(
                machine: machine, store: store, host: host, launch: { EngineLaunch(executable: "/x/claude", environment: ["PATH": "/usr/bin"]) },
                attachments: nil, guide: { task in "タスク #\(task) の案内" }, becameIdle: { calls.add("idle:\($0)") },
                logger: Logger(label: "test"), timing: timing),
            stopHook: stopHook)
        context.hasTranscript = { _, _ in hasTranscript }
        context.diff = diff
        configure(&context)
        let conversation = ClaudeConversation(record: try! store.conversation(id: id)!, context: context)
        await host.connect(conversation.inbox, key: id)
        return conversation
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("transcript の無い会話は --resume でなく同じ ID の --session-id で始め直す（起こした直後に止まった会話）")
    func resumeWithoutTranscript() async throws {
        let (conversation, host, _, _, _) = try await make(hasTranscript: false)
        try await conversation.start(resume: true)
        let argv = try #require(await host.requests.first { $0.op == .spawn }?.argv)
        #expect(!argv.contains("--resume"))
        #expect(argv.firstIndex(of: "--session-id").map { argv[$0 + 1] } == "s1")
    }

    @Test("transcript は CLI に渡す環境の CLAUDE_CONFIG_DIR の projects から引く")
    func transcriptExists() throws {
        let config = FileManager.default.temporaryDirectory.appending(path: "tb-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: config) }
        let project = config.appending(path: "projects/-w", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = "6f1d2b8e-2c4a-4a8f-9c11-5d7e0a3b9f01"
        #expect(!ClaudeConversation.transcriptExists(id, environment: ["CLAUDE_CONFIG_DIR": config.path]))
        try Data().write(to: project.appending(path: "\(id).jsonl"))
        #expect(ClaudeConversation.transcriptExists(id, environment: ["CLAUDE_CONFIG_DIR": config.path]))
        #expect(!ClaudeConversation.transcriptExists("../\(id)", environment: ["CLAUDE_CONFIG_DIR": config.path]))
    }

    @Test("起こすと --session-id と model・権限で spawn し、env に会話の ID を入れ、hook を付けて initialize する")
    func start() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        let spawn = try #require(await host.requests.first { $0.op == .spawn })
        let argv = spawn.argv ?? []
        #expect(argv.first == "/x/claude" && argv.contains("-p") && argv.contains("--replay-user-messages"))
        #expect(argv.firstIndex(of: "--session-id").map { argv[$0 + 1] } == "s1")
        #expect(argv.firstIndex(of: "--model").map { argv[$0 + 1] } == "haiku")
        #expect(argv.firstIndex(of: "--permission-mode").map { argv[$0 + 1] } == "bypassPermissions")
        #expect(spawn.env?["TASKBOARD_CONVERSATION_ID"] == conversation.id && spawn.env?["CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL"] == "1")
        #expect(spawn.env?["PATH"] == "/usr/bin" && spawn.cwd == "/w")
        let initialize = try #require(await host.written("initialize").first)
        let hooks = (initialize["request"] as? [String: Any])?["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["PreToolUse", "Stop", "UserPromptSubmit"])
        #expect((initialize["request"] as? [String: Any])?["perTaskStopAffordance"] as? Bool == true, "宣言しないと、生成を停止で裏の subagent も止まる")
        let snapshot = await conversation.snapshot()
        #expect(snapshot.phase == .idle && snapshot.runner == .host)
        #expect(try store.conversation(id: conversation.id)?.runnerValue == .host)
    }

    @Test("送ると uuid つきの発言を書き、command_lifecycle で受けたと返す。同じ id は 2 回書かない")
    func send() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let message = ConversationSendRequest(text: "こんにちは", clientMessageID: "1b4e28ba-2fa1-11d2-883f-0016d3cca427")
        async let outcome = conversation.send(message)
        #expect(await eventually { await host.written().contains { $0["type"] as? String == "user" } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"1b4e28ba-2fa1-11d2-883f-0016d3cca427","state":"queued"}"#)
        #expect(try await outcome == .accepted)
        #expect(try await conversation.send(message) == .duplicate)
        #expect(await host.written().filter { $0["type"] as? String == "user" }.count == 1)
        let user = try #require(await host.written().first { $0["type"] as? String == "user" })
        #expect(user["uuid"] as? String == "1b4e28ba-2fa1-11d2-883f-0016d3cca427")
        await #expect(throws: ConversationError.self) { try await conversation.send(ConversationSendRequest(text: "x", clientMessageID: "not-a-uuid")) }
    }

    @Test("受けたと分からなければ unknown を返し、書き直さない")
    func unconfirmed() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let outcome = try await conversation.send(ConversationSendRequest(text: "x", clientMessageID: "2b4e28ba-2fa1-11d2-883f-0016d3cca427"))
        #expect(outcome == .unknown)
        #expect(await host.written().filter { $0["type"] as? String == "user" }.count == 1)
    }

    @Test("can_use_tool の質問を問いにし、答えを answers に入れて返す")
    func question() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","input":{"questions":[{"question":"色は？","header":"色","options":[{"label":"赤"},{"label":"青"}],"multiSelect":false}]}}}"#
        )
        #expect(await eventually { await conversation.snapshot().pending.count == 1 })
        let request = try #require(await conversation.snapshot().pending.first)
        #expect(request.kind == .question && request.waiting.questions?.first?.options.map(\.label) == ["赤", "青"])
        #expect(await conversation.snapshot().phase == .waiting)
        await #expect(throws: ConversationError.self) { try await conversation.answer(ConversationAnswerRequest(requestID: "r1", answers: [])) }
        // 選択肢に無い label と、単一選択の 2 つは断り、問いは待ったまま
        await #expect(throws: ConversationError.invalid("「緑」は q0 の選択肢に無い。選択肢: 赤 / 青")) {
            try await conversation.answer(ConversationAnswerRequest(requestID: "r1", answers: [AskAnswer(questionID: "q0", selected: ["緑"])]))
        }
        await #expect(throws: ConversationError.invalid("q0 は 1 つだけ選ぶ")) {
            try await conversation.answer(ConversationAnswerRequest(requestID: "r1", answers: [AskAnswer(questionID: "q0", selected: ["赤", "青"])]))
        }
        #expect(await host.controlResponses().isEmpty)
        #expect(await conversation.snapshot().pending.count == 1)
        try await conversation.answer(ConversationAnswerRequest(requestID: "r1", answers: [AskAnswer(questionID: "q0", selected: ["青"])]))
        let response = try #require(await host.controlResponses().first)
        let body = response["response"] as? [String: Any]
        #expect(response["request_id"] as? String == "r1" && body?["behavior"] as? String == "allow")
        #expect(((body?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]) == ["色は？": "青"])
        #expect(await conversation.snapshot().pending.isEmpty)
        await #expect(throws: ConversationError.self) { try await conversation.answer(ConversationAnswerRequest(requestID: "r1", allow: true)) }
    }

    @Test("権限の確認を拒否すると deny と理由を返す。CLI が取り下げた問いは消える")
    func permission() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_b","input":{"command":"rm -rf build","description":"消す"}}}"#
        )
        await host.emit(
            #"{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool","tool_name":"Write","tool_use_id":"toolu_w","input":{"file_path":"/w/a.txt","content":"x"}}}"#
        )
        #expect(await eventually { await conversation.snapshot().pending.count == 2 })
        let first = try #require(await conversation.snapshot().pending.first)
        #expect(first.kind == .permission && first.waiting.permission?.summary == "rm -rf build" && first.waiting.permission?.detail == "消す")
        try await conversation.answer(ConversationAnswerRequest(requestID: "r2", allow: false, message: "やめて"))
        let body = try #require(await host.controlResponses().first?["response"] as? [String: Any])
        #expect(body["behavior"] as? String == "deny" && body["message"] as? String == "やめて")
        await host.emit(#"{"type":"control_cancel_request","request_id":"r3"}"#)
        #expect(await eventually { await conversation.snapshot().pending.isEmpty })
    }

    @Test("今後は聞かない候補：問いに載せ、選ぶと CLI が出した候補のまま updatedPermissions に入れて返す。モードの候補は記録も替える")
    func rememberedPermission() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        let suggestions = ClaudePermissionSuggestionTests.bashSuggestions
        let line =
            #"{"type":"control_request","request_id":"%@","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_%@","input":{"command":"touch probe-a.txt"},"permission_suggestions":%@%@}}"#
        await host.emit(String(format: line, "s1", "a", suggestions, ""))
        await host.emit(String(format: line, "s2", "b", suggestions, ""))
        await host.emit(String(format: line, "s3", "c", suggestions, #","suppress_always_allow_rule":true"#))
        #expect(await eventually { await conversation.snapshot().pending.count == 3 })
        let pending = await conversation.snapshot().pending
        #expect(pending.map { $0.suggestions?.count } == [3, 3, nil], "suppress_always_allow_rule の確認には候補を載せない")

        await #expect(throws: ConversationError.self) {
            try await conversation.answer(ConversationAnswerRequest(requestID: "s1", allow: true, suggestionID: "7"))
        }
        await #expect(throws: ConversationError.self) {
            try await conversation.answer(ConversationAnswerRequest(requestID: "s3", allow: true, suggestionID: "0"))
        }
        #expect(await host.controlResponses().isEmpty, "断った答えは CLI に書かない")

        try await conversation.answer(ConversationAnswerRequest(requestID: "s1", allow: true, suggestionID: "0"))
        let first = try #require(await host.controlResponses().first { $0["request_id"] as? String == "s1" }?["response"] as? [String: Any])
        let updated = try #require(first["updatedPermissions"] as? [[String: Any]])
        #expect(first["behavior"] as? String == "allow" && updated.count == 1 && updated[0]["destination"] as? String == "localSettings")
        #expect(try store.conversation(id: conversation.id)?.permissionMode != "acceptEdits")

        try await conversation.answer(ConversationAnswerRequest(requestID: "s2", allow: true, suggestionID: "2"))
        let second = try #require(await host.controlResponses().first { $0["request_id"] as? String == "s2" }?["response"] as? [String: Any])
        #expect((second["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String == "acceptEdits")
        #expect(try store.conversation(id: conversation.id)?.permissionMode == "acceptEdits")

        try await conversation.answer(ConversationAnswerRequest(requestID: "s3", allow: true))
        let plain = try #require(await host.controlResponses().first { $0["request_id"] as? String == "s3" }?["response"] as? [String: Any])
        #expect(plain["updatedPermissions"] == nil)
    }

    @Test("defer：質問を defer で終え、記録に残して入力を閉じ、答えたら --resume で起こして同じ tool_use に allow を返す")
    func deferAndResume() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        _ = try await conversation.control(ConversationControlRequest(kind: .deferQuestions, value: "on"))
        await host.emit(
            #"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback","callback_id":"tb_pre","input":{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","tool_input":{"questions":[{"question":"色は？","options":[{"label":"赤"},{"label":"青"}]}]}}}}"#
        )
        #expect(await eventually { await host.controlResponses().contains { $0["request_id"] as? String == "h1" } })
        let deferred = try #require(await host.controlResponses().first { $0["request_id"] as? String == "h1" }?["response"] as? [String: Any])
        #expect((deferred["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String == "defer")
        await host.emit(
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_deferred","terminal_reason":"tool_deferred","session_id":"s1","deferred_tool_use":{"id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"色は？","options":[{"label":"赤"},{"label":"青"}]}]}}}"#
        )
        #expect(await eventually { await conversation.snapshot().phase == .stopped })
        #expect(await host.ops().contains(.closeInput))
        let snapshot = await conversation.snapshot()
        #expect(snapshot.deferred?.id == "toolu_q" && snapshot.deferred?.kind == .question)
        #expect(try store.conversation(id: conversation.id)?.deferred != nil)

        try await conversation.answer(ConversationAnswerRequest(requestID: "toolu_q", answers: [AskAnswer(questionID: "q0", selected: ["赤"])]))
        let spawns = await host.requests.filter { $0.op == .spawn }
        #expect(spawns.count == 2 && spawns.last?.argv?.firstIndex(of: "--resume").map { spawns.last!.argv![$0 + 1] } == "s1")
        await host.emit(
            #"{"type":"control_request","request_id":"h2","request":{"subtype":"hook_callback","callback_id":"tb_pre","input":{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","tool_input":{"questions":[{"question":"色は？","options":[{"label":"赤"},{"label":"青"}]}]}}}}"#
        )
        #expect(await eventually { await host.controlResponses().contains { $0["request_id"] as? String == "h2" } })
        let allow = try #require(await host.controlResponses().first { $0["request_id"] as? String == "h2" }?["response"] as? [String: Any])
        let output = allow["hookSpecificOutput"] as? [String: Any]
        #expect(output?["permissionDecision"] as? String == "allow")
        #expect(((output?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]) == ["色は？": "赤"])
        #expect(await eventually { await conversation.snapshot().deferred == nil })
        #expect(try store.conversation(id: conversation.id)?.deferred == nil)
    }

    @Test("裏のタスクが動いている間の問いは defer で終えず、動いているプロセスで待つ（CLI は裏のタスクの知らせで次のターンを始め、問いを内部の誤りで埋めて先へ進む）")
    func noDeferWhileBackgroundTaskRuns() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        _ = try await conversation.control(ConversationControlRequest(kind: .deferQuestions, value: "on"))
        await host.emit(Self.toolUse("toolu_bg", "Bash"))
        await host.emit(Self.taskStarted("t1", tool: "toolu_bg", backgrounded: true))
        await host.emit(Self.toolResult("toolu_bg"))
        await host.emit(Self.deferredPreToolUse("h1"))
        #expect(await eventually { await host.controlResponses().contains { $0["request_id"] as? String == "h1" } })
        let kept = try #require(await host.controlResponses().first { $0["request_id"] as? String == "h1" }?["response"] as? [String: Any])
        #expect(kept["hookSpecificOutput"] == nil)

        await host.emit(#"{"type":"system","subtype":"task_notification","task_id":"t1","status":"completed","session_id":"s1"}"#)
        await host.emit(Self.deferredPreToolUse("h2"))
        #expect(await eventually { await host.controlResponses().contains { $0["request_id"] as? String == "h2" } })
        let deferred = try #require(await host.controlResponses().first { $0["request_id"] as? String == "h2" }?["response"] as? [String: Any])
        #expect((deferred["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String == "defer")
    }

    @Test("defer の答えを待っている会話には、回答や知らせを届けるために起こさない（起こしても CLI は同じ問いで終わり、起こし直しを繰り返す）")
    func deliverWaitsForDeferredAnswer() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.deferredResult)
        #expect(await eventually { await conversation.snapshot().phase == .stopped })
        let outcome = try await conversation.deliver(text: "知らせ", uuid: "5b4e28ba-2fa1-11d2-883f-0016d3cca427", wake: .always)
        #expect(outcome == .busy)
        #expect(await host.requests.filter { $0.op == .spawn }.count == 1)
    }

    @Test("defer の問いに答えて起こした後は、CLI が同じ tool_use の PreToolUse で答えを受け取るまで発言を入れない（先に入れると CLI が問いを捨てる）")
    func deliverWaitsUntilDeferredAnswerTaken() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.deferredResult)
        #expect(await eventually { await conversation.snapshot().phase == .stopped })
        try await conversation.answer(ConversationAnswerRequest(requestID: "toolu_q", answers: [AskAnswer(questionID: "q0", selected: ["赤"])]))
        let uuid = "5c4e28ba-2fa1-11d2-883f-0016d3cca427"
        #expect(try await conversation.deliver(text: "知らせ", uuid: uuid, wake: .always) == .busy)
        #expect(await !host.written().contains { $0["uuid"] as? String == uuid })

        await host.emit(Self.deferredPreToolUse("h2"))
        #expect(await eventually { await host.controlResponses().contains { $0["request_id"] as? String == "h2" } })
        async let delivered = conversation.deliver(text: "知らせ", uuid: uuid, wake: .always)
        #expect(await eventually { await host.written().contains { $0["uuid"] as? String == uuid } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"5c4e28ba-2fa1-11d2-883f-0016d3cca427","state":"started"}"#)
        #expect(try await delivered == .delivered)
    }

    @Test("起こし直した CLI が defer の問いに戻らずにターンを終えたら、問いは捨てられているので記録から消す（答えても届かない問いを残さない）")
    func abandonedDeferredCleared() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.deferredResult)
        #expect(await eventually { await conversation.snapshot().deferred?.id == "toolu_q" })
        try await conversation.answer(ConversationAnswerRequest(requestID: "toolu_q", answers: [AskAnswer(questionID: "q0", selected: ["赤"])]))
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().deferred == nil })
        #expect(try store.conversation(id: conversation.id)?.deferred == nil)
        let uuid = "5d4e28ba-2fa1-11d2-883f-0016d3cca427"
        async let delivered = conversation.deliver(text: "知らせ", uuid: uuid, wake: .always)
        #expect(await eventually { await host.written().contains { $0["uuid"] as? String == uuid } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"5d4e28ba-2fa1-11d2-883f-0016d3cca427","state":"started"}"#)
        #expect(try await delivered == .delivered)
    }

    private static func deferredPreToolUse(_ requestID: String) -> String {
        #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"hook_callback","callback_id":"tb_pre","input":{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","tool_input":{"questions":[{"question":"色は？","options":[{"label":"赤"},{"label":"青"}]}]}}}}"#
    }

    @Test("答えの tool_result を見た問いは記録から消し、その後に同じ問いの deferred_tool_use の result が届いても戻さない")
    func answeredDeferredStaysCleared() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.deferredResult)
        #expect(await eventually { await conversation.snapshot().deferred?.id == "toolu_q" })
        await host.emit(
            #"{"type":"user","uuid":"u-ans","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_q","content":"Your questions have been answered"}]}}"#)
        #expect(await eventually { await conversation.snapshot().deferred == nil })
        await host.emit(Self.deferredResult)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await conversation.snapshot().deferred == nil)
        #expect(try store.conversation(id: conversation.id)?.deferred == nil)
    }

    private static let deferredResult =
        #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_deferred","terminal_reason":"tool_deferred","session_id":"s1","deferred_tool_use":{"id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"色は？","options":[{"label":"赤"},{"label":"青"}]}]}}}"#

    @Test("圧縮と新しい thread の制御は Claude では断り、CLI に何も送らない（/compact・/clear は文で送る）")
    func compactUnsupported() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let before = await host.written().count
        await #expect(throws: ConversationError.controlUnsupported("compact", engine: .claude)) {
            _ = try await conversation.control(ConversationControlRequest(kind: .compact))
        }
        await #expect(throws: ConversationError.controlUnsupported("new_thread", engine: .claude)) {
            _ = try await conversation.control(ConversationControlRequest(kind: .newThread))
        }
        #expect(await host.written().count == before)
    }

    @Test("今すぐ送る：待っている発言の uuid を interrupt の send_now で送り（待ち行列は消さない）、CLI の答えを返す。口の無い CLI には送らない")
    func sendNow() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let uuid = "3b4e28ba-2fa1-11d2-883f-0016d3cca427"
        await #expect(throws: ConversationError.controlUnsupported("send_now", engine: .claude)) {
            _ = try await conversation.control(ConversationControlRequest(kind: .sendNow, value: uuid))
        }
        await host.emit(Self.initLine("s1", capabilities: ["interrupt_cancel_queued_v1", "msg_lifecycle_v1", "interrupt_send_now_v1"]))
        #expect(await eventually { await conversation.snapshot().currentStats?.engineVersion == "2.1.303" })
        await host.setReply("interrupt", #"{"send_now":"delivering"}"#)
        let response = try await conversation.control(ConversationControlRequest(kind: .sendNow, value: uuid.uppercased()))
        let request = try #require(await host.written("interrupt").last?["request"] as? [String: Any])
        #expect(request["send_now"] as? Bool == true && request["message_uuid"] as? String == uuid)
        #expect(request["cancel_queued"] == nil)
        let outcome = try JSONDecoder().decode(ConversationSendNow.self, from: Data(try #require(response.payloadJSON).utf8))
        #expect(outcome.outcome == .delivering)
        await #expect(throws: ConversationError.invalid("今すぐ送る発言の uuid が無い")) {
            _ = try await conversation.control(ConversationControlRequest(kind: .sendNow, value: "x"))
        }
    }

    private static let sendNowCapabilities = ["interrupt_cancel_queued_v1", "msg_lifecycle_v1", "interrupt_send_now_v1"]

    private static func toolUse(_ id: String, _ name: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]},"uuid":"a-\#(id)","parent_tool_use_id":null}"#
    }

    private static func toolResult(_ id: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"ok"}]},"uuid":"r-\#(id)","parent_tool_use_id":null}"#
    }

    private static func taskStarted(_ task: String, tool: String, backgrounded: Bool = false, inSubagent: Bool = false) -> String {
        let owner = inSubagent ? #""owned_by_subagent":true,"parent_task_id":"a1","# : ""
        return #"{"type":"system","subtype":"task_started","task_id":"\#(task)",\#(owner)"tool_use_id":"\#(tool)","is_backgrounded":\#(backgrounded),"task_type":"local_bash","session_id":"s1"}"#
    }

    /// 生成中に送り、CLI の待ち行列に入った発言の uuid
    private func queued(_ conversation: ClaudeConversation, _ host: FakeHost) async throws -> String {
        let uuid = UUID().uuidString.lowercased()
        let sending = Task { try await conversation.send(ConversationSendRequest(text: "今すぐ", clientMessageID: uuid)) }
        #expect(await eventually { await host.written().contains { $0["type"] as? String == "user" && $0["uuid"] as? String == uuid } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"queued","session_id":"s1"}"#)
        _ = try await sending.value
        return uuid
    }

    private func sendNow(_ conversation: ClaudeConversation, _ uuid: String) async throws -> ConversationSendNow.Outcome {
        let response = try await conversation.control(ConversationControlRequest(kind: .sendNow, value: uuid))
        return try JSONDecoder().decode(ConversationSendNow.self, from: Data(try #require(response.payloadJSON).utf8)).outcome
    }

    @Test("今すぐ送る：主の流れの前景で待っている Bash を background_tasks で裏に回し、回せたら interrupt を送らずに delivering を返す")
    func sendNowBackgrounds() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        await host.emit(Self.toolUse("toolu_b", "Bash"))
        await host.emit(Self.taskStarted("t1", tool: "toolu_b"))
        let uuid = try await queued(conversation, host)
        await host.setReply("background_tasks", #"{"backgrounded":true}"#)
        let response = try await conversation.control(ConversationControlRequest(kind: .sendNow, value: uuid))
        #expect(
            try JSONDecoder().decode(ConversationSendNow.self, from: Data(try #require(response.payloadJSON).utf8))
                == ConversationSendNow(outcome: .delivering, backgrounded: true))
        let requests = await host.written("background_tasks").compactMap { $0["request"] as? [String: Any] }
        #expect(requests.count == 1 && requests.first?["tool_use_id"] as? String == "toolu_b")
        #expect(await host.written("interrupt").isEmpty, "回した直後に interrupt を送ると、CLI が tool の結果を拒否に書き換える")
    }

    @Test("今すぐ送る：Bash がまだ task になっていなければ task_started を待ってから回す")
    func sendNowWaitsForTask() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        await host.emit(Self.toolUse("toolu_b", "Bash"))
        let uuid = try await queued(conversation, host)
        await host.setReply("background_tasks", #"{"backgrounded":true}"#)
        async let outcome = sendNow(conversation, uuid)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await host.written("background_tasks").isEmpty, "task になる前に送っても CLI は回さない")
        await host.emit(Self.taskStarted("t1", tool: "toolu_b"))
        #expect(try await outcome == .delivering)
        let detached = await host.written("background_tasks").count
        let interrupted = await host.written("interrupt").count
        #expect(detached == 1 && interrupted == 0)
    }

    @Test("今すぐ送る：回せないとき（回せなかった・待っても task にならない・subagent の中と裏のタスクだけ・tool が終わった・発言がもう待ち行列に無い）は interrupt の send_now にする")
    func sendNowFallsBack() async throws {
        let (conversation, host, _, _, _) = try await make(configure: { $0.timing.detachWait = .milliseconds(300) })
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        await host.setReply("interrupt", #"{"send_now":"stopped"}"#)
        @Sendable func interrupts() async -> Int { await host.written("interrupt").count }
        @Sendable func detaches() async -> Int { await host.written("background_tasks").count }

        // CLI が回せなかった
        await host.emit(Self.toolUse("toolu_a", "Bash"))
        await host.emit(Self.taskStarted("t1", tool: "toolu_a"))
        await host.setReply("background_tasks", #"{"backgrounded":false}"#)
        #expect(try await sendNow(conversation, try await queued(conversation, host)) == .stopped)
        #expect(await detaches() == 1)
        #expect(await interrupts() == 1)
        await host.emit(Self.toolResult("toolu_a"))

        // 待っても task にならない（すぐ終わるコマンド）
        await host.emit(Self.toolUse("toolu_b", "Bash"))
        #expect(try await sendNow(conversation, try await queued(conversation, host)) == .stopped)
        #expect(await detaches() == 1)
        #expect(await interrupts() == 2)
        await host.emit(Self.toolResult("toolu_b"))

        // subagent の中の Bash と、初めから裏のタスクと、裏に回った後のタスクは回さない
        await host.emit(Self.toolUse("toolu_c", "Agent"))
        await host.emit(Self.taskStarted("t3", tool: "toolu_x", inSubagent: true))
        await host.emit(Self.taskStarted("t4", tool: "toolu_y", backgrounded: true))
        await host.emit(Self.taskStarted("t5", tool: "toolu_c"))
        await host.emit(#"{"type":"system","subtype":"task_updated","task_id":"t5","patch":{"is_backgrounded":true},"session_id":"s1"}"#)
        #expect(try await sendNow(conversation, try await queued(conversation, host)) == .stopped)
        #expect(await detaches() == 1)
        #expect(await interrupts() == 3)

        // 結果の来た tool は回さない
        await host.emit(Self.toolUse("toolu_d", "Bash"))
        await host.emit(Self.taskStarted("t6", tool: "toolu_d"))
        await host.emit(Self.toolResult("toolu_d"))
        #expect(try await sendNow(conversation, try await queued(conversation, host)) == .stopped)
        #expect(await detaches() == 1)
        #expect(await interrupts() == 4)

        // 発言がもう待ち行列に無い（CLI が読み始めた）
        await host.emit(Self.toolUse("toolu_e", "Bash"))
        await host.emit(Self.taskStarted("t7", tool: "toolu_e"))
        let started = try await queued(conversation, host)
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(started)","state":"started","session_id":"s1"}"#)
        try await Task.sleep(for: .milliseconds(200))
        await host.setReply("interrupt", #"{"send_now":"nothing_waiting"}"#)
        #expect(try await sendNow(conversation, started) == .nothingWaiting)
        #expect(await detaches() == 1)
        #expect(await interrupts() == 5)
    }

    @Test("途中送り：発言が待ち行列に入ったら、tool_use から steerDetachAge たった主の流れの前景の task を裏に回す。1 つの発言で 2 つまでで、interrupt は送らない")
    func steerDetaches() async throws {
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.timing.steerDetachAge = .seconds(1)
            $0.timing.steerDetachRetry = .milliseconds(50)
        })
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        await host.setReply("background_tasks", #"{"backgrounded":true}"#)
        for n in 1...3 {
            await host.emit(Self.toolUse("toolu_\(n)", "Bash"))
            await host.emit(Self.taskStarted("t\(n)", tool: "toolu_\(n)"))
        }
        await host.emit(Self.taskStarted("t9", tool: "toolu_9", inSubagent: true))
        _ = try await queued(conversation, host)
        @Sendable func detached() async -> [String] {
            await host.written("background_tasks").compactMap { ($0["request"] as? [String: Any])?["tool_use_id"] as? String }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await detached().isEmpty, "tool_use から steerDetachAge たつまでは回さない")
        #expect(await eventually { await detached().count == 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await detached() == ["toolu_1", "toolu_2"], "1 つの発言で 2 つまで。subagent の中の task は回さない")
        #expect(await host.written("interrupt").isEmpty)
    }

    @Test("後で送る：user 行に priority later を付け、待ち行列に入っても前景の task を裏に回さない。ふつうの発言には priority を付けない")
    func sendLater() async throws {
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.timing.steerDetachAge = .milliseconds(200)
            $0.timing.steerDetachRetry = .milliseconds(50)
        })
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        await host.setReply("background_tasks", #"{"backgrounded":true}"#)
        await host.emit(Self.toolUse("toolu_1", "Bash"))
        await host.emit(Self.taskStarted("t1", tool: "toolu_1"))
        let uuid = UUID().uuidString.lowercased()
        let sending = Task { try await conversation.send(ConversationSendRequest(text: "後で", clientMessageID: uuid, later: true)) }
        #expect(await eventually { await host.written().contains { $0["uuid"] as? String == uuid } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"queued","session_id":"s1"}"#)
        _ = try await sending.value
        let line = await host.written().first { $0["uuid"] as? String == uuid }
        #expect(line?["priority"] as? String == "later")
        try await Task.sleep(for: .milliseconds(600))
        #expect(await host.written("background_tasks").isEmpty, "ターンの後に始める発言のために、今のターンの tool を裏に回さない")

        let plain = try await queued(conversation, host)
        let plainLine = await host.written().first { $0["uuid"] as? String == plain }
        #expect(plainLine?["priority"] == nil)
        #expect(await eventually { await host.written("background_tasks").count == 1 }, "ふつうの発言はこれまでどおり裏に回す")
    }

    @Test("後で送る発言の今すぐ送る：取り下げて priority なしで送り直し、取り下げた uuid の cancelled は発言の取り消しにせず、前景の task を裏に回す")
    func sendLaterNow() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        await host.emit(Self.toolUse("toolu_b", "Bash"))
        await host.emit(Self.taskStarted("t1", tool: "toolu_b"))
        let stream = await conversation.events(after: 0)
        let reading = Task {
            var seen: [ConversationEvent.Kind] = []
            for await event in stream { seen.append(event.kind) }
            return seen
        }
        let uuid = UUID().uuidString.lowercased()
        let sending = Task { try await conversation.send(ConversationSendRequest(text: "やっぱり今", clientMessageID: uuid, later: true)) }
        #expect(await eventually { await host.written().contains { $0["uuid"] as? String == uuid } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"queued","session_id":"s1"}"#)
        _ = try await sending.value
        await host.setReply("cancel_async_message", #"{"cancelled":true}"#)
        await host.setReply("background_tasks", #"{"backgrounded":true}"#)
        #expect(try await sendNow(conversation, uuid) == .delivering)

        let cancel = await host.written("cancel_async_message").compactMap { $0["request"] as? [String: Any] }
        #expect(cancel.count == 1 && cancel.first?["message_uuid"] as? String == uuid)
        let users = await host.written().filter { $0["type"] as? String == "user" }
        #expect(users.count == 2)
        let resent = try #require(users.last)
        let resentID = try #require(resent["uuid"] as? String)
        #expect(resentID != uuid && resent["priority"] == nil)
        #expect(((resent["message"] as? [String: Any])?["content"] as? String) == "やっぱり今")
        #expect(await host.written("background_tasks").count == 1)
        #expect(await host.written("interrupt").isEmpty, "ターンを止めない")

        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"cancelled","session_id":"s1"}"#)
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(resentID)","state":"queued","session_id":"s1"}"#)
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(resentID)","state":"completed","session_id":"s1"}"#)
        try await Task.sleep(for: .milliseconds(300))
        reading.cancel()
        let accepted = await reading.value.compactMap { kind -> String? in
            guard case .accepted(let id, let state) = kind else { return nil }
            return id == uuid ? state : "other \(state)"
        }
        #expect(accepted == ["queued", "queued", "completed"], "受付は元の uuid で出し、取り下げた方の cancelled は出さない")
    }

    @Test("後で送る発言の今すぐ送る：CLI が先に始めていて取り下げられなければ、送り直さない")
    func sendLaterNowTooLate() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        let uuid = UUID().uuidString.lowercased()
        let sending = Task { try await conversation.send(ConversationSendRequest(text: "後で", clientMessageID: uuid, later: true)) }
        #expect(await eventually { await host.written().contains { $0["uuid"] as? String == uuid } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"queued","session_id":"s1"}"#)
        _ = try await sending.value
        await host.setReply("cancel_async_message", #"{"cancelled":false}"#)
        await host.setReply("interrupt", #"{"send_now":"nothing_waiting"}"#)
        _ = try await sendNow(conversation, uuid)
        #expect(await host.written().filter { $0["type"] as? String == "user" }.count == 1)
    }

    @Test("途中送り：裏に回した task は、CLI の知らせ（task_backgrounded）が届く前の試し直しでも回し直さず、2 つに数えない")
    func steerDetachesOnce() async throws {
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.timing.steerDetachAge = .seconds(1)
            $0.timing.steerDetachRetry = .milliseconds(50)
        })
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        await host.setReply("background_tasks", #"{"backgrounded":true}"#)
        await host.emit(Self.toolUse("toolu_1", "Bash"))
        await host.emit(Self.taskStarted("t1", tool: "toolu_1"))
        _ = try await queued(conversation, host)
        // toolu_1 だけが steerDetachAge を過ぎ、toolu_2 はまだの間に、試し直しが何度か回る
        try await Task.sleep(for: .milliseconds(600))
        await host.emit(Self.toolUse("toolu_2", "Bash"))
        await host.emit(Self.taskStarted("t2", tool: "toolu_2"))
        @Sendable func detached() async -> [String] {
            await host.written("background_tasks").compactMap { ($0["request"] as? [String: Any])?["tool_use_id"] as? String }
        }
        #expect(await eventually { await detached().count == 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await detached() == ["toolu_1", "toolu_2"])
    }

    @Test("途中送り：回せなければ steerDetachRetry ごとに試し直し、発言が待ち行列を出るか steerDetachGiveUp でやめる")
    func steerRetries() async throws {
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.timing.steerDetachAge = .zero
            $0.timing.steerDetachRetry = .milliseconds(50)
            $0.timing.steerDetachGiveUp = .milliseconds(500)
        })
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        await host.setReply("background_tasks", #"{"backgrounded":false}"#)
        await host.emit(Self.toolUse("toolu_b", "Bash"))
        await host.emit(Self.taskStarted("t1", tool: "toolu_b"))
        @Sendable func detaches() async -> Int { await host.written("background_tasks").count }

        // 期限で諦める
        _ = try await queued(conversation, host)
        #expect(await eventually { await detaches() >= 3 }, "回せなければ試し直す")
        try await Task.sleep(for: .milliseconds(600))
        let gaveUp = await detaches()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await detaches() == gaveUp, "steerDetachGiveUp の後は送らない")

        // 発言が待ち行列を出たらやめる
        let started = try await queued(conversation, host)
        #expect(await eventually { await detaches() > gaveUp })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(started)","state":"started","session_id":"s1"}"#)
        try await Task.sleep(for: .milliseconds(150))
        let delivered = await detaches()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await detaches() == delivered)
    }

    @Test("計画は起こす前から様子に載り、TaskCreate・TaskUpdate の結果が届くたびに読み直して、変わったら出し直す。ほかの tool の結果では読まない")
    func plan() async throws {
        let items = Locked<[ConversationPlanItem]?>([ConversationPlanItem(id: "1", title: "調べる", status: .pending)])
        let reads = Locked(0)
        let published = Calls()
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.taskList = { session, _ in
                reads.update { $0 += 1 }
                return session == "s1" ? items.value : nil
            }
            $0.publish = { published.add($0.plan?.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: ",") ?? "-") }
        })
        #expect(await conversation.snapshot().plan?.map(\.title) == ["調べる"])
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1"))
        let before = reads.value

        await host.emit(Self.toolUse("toolu_b", "Bash"))
        await host.emit(Self.toolResult("toolu_b"))
        await host.emit(Self.toolUse("toolu_t", "TaskUpdate"))
        items.update { $0 = [ConversationPlanItem(id: "1", title: "調べる", activeTitle: "調べている", status: .inProgress)] }
        await host.emit(Self.toolResult("toolu_t"))
        #expect(await eventually { published.all.last == "1:inProgress" })
        #expect(reads.value == before + 1, "Bash の結果では読まない")
        #expect(await conversation.snapshot().plan?.first?.activeTitle == "調べている")

        // 中身が変わらなければ出し直さない。消えたら空にする
        let count = published.all.count
        await host.emit(Self.toolUse("toolu_l", "TaskCreate"))
        await host.emit(Self.toolResult("toolu_l"))
        #expect(await eventually { reads.value == before + 2 })
        #expect(published.all.count == count)
        await host.emit(Self.toolUse("toolu_d", "TaskUpdate"))
        items.update { $0 = nil }
        await host.emit(Self.toolResult("toolu_d"))
        #expect(await eventually { published.all.last == "-" })
        #expect(await conversation.snapshot().plan == nil)
    }

    @Test("裏に回せる tool の数を様子に載せ、数が変わったら出し直す。裏のタスクの一覧には前景か裏かを付け、CLI の一覧で置き換えても印を引き継ぐ")
    func backgroundMarks() async throws {
        let published = Calls()
        let (conversation, host, _, _, _) = try await make(configure: { $0.publish = { published.add("\($0.detachableTools ?? 0)") } })
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1", capabilities: Self.sendNowCapabilities))
        @Sendable func list() async throws -> [ConversationBackgroundTasks.Task] {
            try WireJSON.decoder().decode(
                ConversationBackgroundTasks.self, from: Data(try #require(try await conversation.control(.init(kind: .listBackgroundTasks)).payloadJSON).utf8)
            ).tasks
        }
        #expect(await conversation.snapshot().detachableTools == nil)

        // task になる前の Bash も、task になった後も 1 つ
        await host.emit(Self.toolUse("toolu_b", "Bash"))
        #expect(await eventually { await conversation.snapshot().detachableTools == 1 })
        #expect(published.all.last == "1")
        await host.emit(Self.taskStarted("t1", tool: "toolu_b"))
        await host.emit(Self.taskStarted("t2", tool: "toolu_z", backgrounded: true))
        #expect(await eventually { (try? await list().count) == 2 })
        #expect(try await list().map(\.backgrounded) == [false, true])
        #expect(await conversation.snapshot().detachableTools == 1)

        // CLI の一覧で置き換えても、前景・裏の印は残る（一覧に印は載らない）
        await host.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"local_bash","description":"ping"},{"task_id":"t2","task_type":"local_bash"}],"session_id":"s1"}"#)
        #expect(await eventually { (try? await list().first?.description) == "ping" })
        #expect(try await list().map(\.backgrounded) == [false, true])

        // 裏に回ると印が変わり、回せる tool は無くなる
        await host.emit(#"{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"is_backgrounded":true},"session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().detachableTools == nil })
        #expect(published.all.last == "0")
        #expect(try await list().map(\.backgrounded) == [true, true])

        // CLI の一覧から消えた task は外す
        await host.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t2","task_type":"local_bash"}],"session_id":"s1"}"#)
        #expect(await eventually { (try? await list().map(\.id)) == ["t2"] })
        #expect(await conversation.snapshot().backgroundTasks == 1)
    }

    @Test("待っている発言の取り消し：cancel_async_message に発言の uuid を送り、CLI の答え（外せたか）を返す")
    func cancelQueued() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let uuid = "4b4e28ba-2fa1-11d2-883f-0016d3cca427"
        await host.setReply("cancel_async_message", #"{"cancelled":true}"#)
        let response = try await conversation.control(ConversationControlRequest(kind: .cancelQueued, value: uuid.uppercased()))
        let request = try #require(await host.written("cancel_async_message").last?["request"] as? [String: Any])
        #expect(request["message_uuid"] as? String == uuid)
        let outcome = try JSONDecoder().decode(ConversationQueuedCancel.self, from: Data(try #require(response.payloadJSON).utf8))
        #expect(outcome.cancelled)
        await #expect(throws: ConversationError.invalid("取り消す発言の uuid が無い")) {
            _ = try await conversation.control(ConversationControlRequest(kind: .cancelQueued, value: "x"))
        }
    }

    @Test("止める：待ち行列ごと interrupt し、result の後に入力を閉じる。止めた会話へ送ると --resume で起こしてから送る")
    func stop() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .running })
        await conversation.stop(.person)
        let interrupt = try #require(await host.written("interrupt").first)
        #expect((interrupt["request"] as? [String: Any])?["cancel_queued"] as? Bool == true)
        let ops = await host.ops()
        #expect(ops.firstIndex(of: .closeInput) != nil && ops.firstIndex(of: .closeInput)! > ops.lastIndex(of: .write)!)
        #expect(await eventually { await conversation.snapshot().phase == .stopped })
        #expect(try store.conversation(id: conversation.id)?.runnerValue == Conversation.Runner.none)
        #expect(try store.conversation(id: conversation.id)?.lastExit == "止めた", "割り込みで 0 以外で終わっても、止めたことを理由に残す")
        _ = try await conversation.send(ConversationSendRequest(text: "x", clientMessageID: "3b4e28ba-2fa1-11d2-883f-0016d3cca427"))
        let spawns = await host.requests.filter { $0.op == .spawn }
        #expect(spawns.count == 2 && spawns.last?.argv?.contains("--resume") == true)
        #expect(await host.written().last?["type"] as? String == "user")
    }

    @Test("daemon が起き直したら、控えの hook_callback には答えず、initialize の送り直しで待っている問いを取り直す")
    func attach() async throws {
        let (conversation, host, _, _, _) = try await make()
        await host.setPending([
            #"{"type":"control_request","request_id":"r5","request":{"subtype":"can_use_tool","tool_name":"Write","tool_use_id":"toolu_5","input":{"file_path":"/w/b.txt"}}}"#
        ])
        // 前の daemon が答えた問い r4 と hook_callback、まだ答えていない問い r5
        await host.keep(
            #"{"type":"control_request","request_id":"r4","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_4","input":{"command":"ls"}}}"#)
        await host.keep(
            #"{"type":"control_request","request_id":"h9","request":{"subtype":"hook_callback","callback_id":"tb_prompt","input":{"hook_event_name":"UserPromptSubmit"}}}"#)
        await host.keep(
            #"{"type":"control_request","request_id":"r5","request":{"subtype":"can_use_tool","tool_name":"Write","tool_use_id":"toolu_5","input":{"file_path":"/w/b.txt"}}}"#)
        await conversation.attach(process: AgentHostProcessInfo(key: conversation.id, pid: 42, alive: true, lastSeq: 3, firstSeq: 1, keptBytes: 10, startedAt: 0))
        #expect(await eventually { await host.written("initialize").count == 1 })
        #expect(await eventually { await conversation.snapshot().pending.map(\.id) == ["r5"] })
        #expect(await host.controlResponses().isEmpty, "読み直しの hook_callback に答えない")
        #expect(await conversation.snapshot().phase == .waiting)
    }

    @Test("答えを待っている間の initialize の一覧に無い問いは消さない")
    func keepAbsentWhileWaiting() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"control_request","request_id":"r6","request":{"subtype":"can_use_tool","tool_name":"Write","tool_use_id":"toolu_6","input":{"file_path":"/w/c.txt"}}}"#)
        #expect(await eventually { await conversation.snapshot().pending.count == 1 })
        await host.setPending([], state: "requires_action")
        await host.gap(through: await host.seq)
        #expect(await eventually { await host.written("initialize").count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await conversation.snapshot().pending.map(\.id) == ["r6"])
        await host.setPending([], state: "idle")
        await host.gap(through: await host.seq)
        #expect(await eventually { await host.written("initialize").count == 3 })
        #expect(await eventually { await conversation.snapshot().pending.isEmpty }, "空いていれば、一覧に無い問いは答え済み")
    }

    @Test("daemon が止まっている間に defer で終わった子は、控えを読み終えてから引き取りが返り、問いが記録に残る")
    func attachDeadDeferred() async throws {
        let (conversation, host, store, _, _) = try await make()
        await host.keep(
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_deferred","session_id":"s1","deferred_tool_use":{"id":"toolu_d","name":"AskUserQuestion","input":{"questions":[{"question":"どれ？","options":[{"label":"A"}]}]}}}"#)
        await host.setExitedBeforeSubscribe()
        await conversation.attach(process: AgentHostProcessInfo(key: conversation.id, pid: 42, alive: false, lastSeq: 1, firstSeq: 1, keptBytes: 10, startedAt: 0))
        #expect(try store.conversation(id: conversation.id)?.deferred != nil)
        let snapshot = await conversation.snapshot()
        #expect(snapshot.deferred?.id == "toolu_d" && snapshot.phase == .stopped)
        #expect(await host.written("initialize").isEmpty, "終わった子に initialize を送らない")
    }

    @Test("記録に残った defer の問いでも、transcript にその答えがあれば引き取りのときに消す（答えの行が控えから捨てられた後に daemon が入れ替わった）")
    func attachClearsAnsweredDeferred() async throws {
        let deferred = DeferredQuestion(
            request: ClaudeRequests.make(
                id: "toolu_a", toolName: "AskUserQuestion", toolUseID: "toolu_a", inputJSON: #"{"questions":[{"question":"どれ？","options":[{"label":"A"}]}]}"#,
                description: nil, since: Date()),
            inputJSON: #"{"questions":[{"question":"どれ？","options":[{"label":"A"}]}]}"#)
        let encoded = String(decoding: try JSONEncoder().encode(deferred), as: UTF8.self)
        let (conversation, _, store, _, _) = try await make(
            record: { number in
                var record = ConversationRecord(taskNumber: number, agentSessionId: "s1", cwd: "/w", model: "haiku", runner: .host)
                record.deferred = encoded
                return record
            },
            configure: { $0.answeredInTranscript = { session, toolUseID, _ in session == "s1" && toolUseID == "toolu_a" } })
        #expect(await conversation.snapshot().deferred?.id == "toolu_a")
        await conversation.attach(process: AgentHostProcessInfo(key: conversation.id, pid: 42, alive: true, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 0))
        #expect(await conversation.snapshot().deferred == nil)
        #expect(try store.conversation(id: conversation.id)?.deferred == nil)
    }

    @Test("生きている子を引き取ったとき、記録に defer の問いが残っていれば消す（defer で終えた子は生きていないので、生きている子はもう問いに戻らない）")
    func attachLiveClearsStaleDeferred() async throws {
        let deferred = DeferredQuestion(
            request: ClaudeRequests.make(
                id: "toolu_s", toolName: "AskUserQuestion", toolUseID: "toolu_s", inputJSON: #"{"questions":[{"question":"どれ？","options":[{"label":"A"}]}]}"#,
                description: nil, since: Date()),
            inputJSON: #"{"questions":[{"question":"どれ？","options":[{"label":"A"}]}]}"#)
        let encoded = String(decoding: try JSONEncoder().encode(deferred), as: UTF8.self)
        let (conversation, _, store, _, _) = try await make(record: { number in
            var record = ConversationRecord(taskNumber: number, agentSessionId: "s1", cwd: "/w", model: "haiku", runner: .host)
            record.deferred = encoded
            return record
        })
        await conversation.attach(process: AgentHostProcessInfo(key: conversation.id, pid: 42, alive: true, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 0))
        #expect(await conversation.snapshot().deferred == nil)
        #expect(try store.conversation(id: conversation.id)?.deferred == nil)
    }

    @Test("transcript の答え：その tool_use の tool_result の行があるときだけ true（defer の記録の行の toolUseID・tool_use の id には当たらない）")
    func transcriptAnswered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tb-answered-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("projects/-w")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let environment = ["CLAUDE_CONFIG_DIR": root.path]
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_a","name":"AskUserQuestion","input":{}}]}}"#,
            #"{"type":"attachment","attachment":{"type":"hook_deferred_tool","toolUseID":"toolu_a"}}"#,
        ]
        let file = dir.appendingPathComponent("3b4e28ba-2fa1-11d2-883f-0016d3cca427.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(!ClaudeConversation.transcriptAnswered("3b4e28ba-2fa1-11d2-883f-0016d3cca427", toolUseID: "toolu_a", environment: environment))
        let answered = #"{"type":"user","message":{"content":[{"tool_use_id":"toolu_a","type":"tool_result","content":"答えた"}]}}"#
        try (lines.joined(separator: "\n") + "\n" + answered + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(ClaudeConversation.transcriptAnswered("3b4e28ba-2fa1-11d2-883f-0016d3cca427", toolUseID: "toolu_a", environment: environment))
        #expect(!ClaudeConversation.transcriptAnswered("3b4e28ba-2fa1-11d2-883f-0016d3cca427", toolUseID: "toolu_b", environment: environment))
    }

    @Test("受けた発言の uuid は記録に残り、控えを捨てて daemon が入れ替わっても 2 回入れない")
    func duplicateAfterRestart() async throws {
        let (conversation, host, store, _, calls) = try await make()
        try await conversation.start(resume: false)
        let message = ConversationSendRequest(text: "一度だけ", clientMessageID: "4b4e28ba-2fa1-11d2-883f-0016d3cca427")
        async let outcome = conversation.send(message)
        #expect(await eventually { await host.written().contains { $0["type"] as? String == "user" } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"4b4e28ba-2fa1-11d2-883f-0016d3cca427","state":"started"}"#)
        #expect(try await outcome == .accepted)
        #expect(try store.conversation(id: conversation.id)?.recentMessages == ["4b4e28ba-2fa1-11d2-883f-0016d3cca427"])
        let restarted = await reopen(conversation.id, store: store, host: host, calls: calls)
        #expect(try await restarted.send(message) == .duplicate)
    }

    @Test("待ち行列にある発言があれば、ターンの終わりでも控えを捨てない")
    func noTrimWhileQueued() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let before = await conversation.lastSeq
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"5b4e28ba-2fa1-11d2-883f-0016d3cca427","state":"queued"}"#)
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        // accepted と turn
        #expect(await eventually { await conversation.lastSeq >= before + 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !host.requests.contains { $0.op == .trim })
    }

    @Test("回答はモデルに渡ったら届いたとし、待ち行列のまま取り消されたら届いていないとする。空いていない会話には入れない")
    func deliver() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        async let first = conversation.deliver(text: "回答", uuid: "6b4e28ba-2fa1-11d2-883f-0016d3cca427", wake: .always)
        #expect(await eventually { await host.written().contains { $0["uuid"] as? String == "6b4e28ba-2fa1-11d2-883f-0016d3cca427" } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"6b4e28ba-2fa1-11d2-883f-0016d3cca427","state":"started"}"#)
        #expect(try await first == .delivered)

        async let second = conversation.deliver(text: "回答 2", uuid: "7b4e28ba-2fa1-11d2-883f-0016d3cca427", wake: .always)
        #expect(await eventually { await host.written().contains { $0["uuid"] as? String == "7b4e28ba-2fa1-11d2-883f-0016d3cca427" } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"7b4e28ba-2fa1-11d2-883f-0016d3cca427","state":"queued"}"#)
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"7b4e28ba-2fa1-11d2-883f-0016d3cca427","state":"cancelled"}"#)
        #expect(try await second == .cancelled)
        #expect(await conversation.deliveryState("7b4e28ba-2fa1-11d2-883f-0016d3cca427") == .cancelled)

        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .running })
        #expect(try await conversation.deliver(text: "回答 3", uuid: "8b4e28ba-2fa1-11d2-883f-0016d3cca427", wake: .always) == .busy)
    }

    @Test("Stop の hook：見直しの頼みがあれば block と理由を返し、無ければ何も決めない")
    func stopHook() async throws {
        let (conversation, host, _, _, _) = try await make(stopHook: { _, call in call.transcriptPath == "/t/a.jsonl" ? "見直して" : nil })
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"control_request","request_id":"st1","request":{"subtype":"hook_callback","callback_id":"tb_stop","input":{"hook_event_name":"Stop","transcript_path":"/t/a.jsonl","stop_hook_active":false}}}"#)
        await host.emit(
            #"{"type":"control_request","request_id":"st2","request":{"subtype":"hook_callback","callback_id":"tb_stop","input":{"hook_event_name":"Stop","transcript_path":"/t/b.jsonl","stop_hook_active":false}}}"#)
        #expect(await eventually { await host.controlResponses().count == 2 })
        let responses = await host.controlResponses()
        let first = responses.first { $0["request_id"] as? String == "st1" }?["response"] as? [String: Any]
        let second = responses.first { $0["request_id"] as? String == "st2" }?["response"] as? [String: Any]
        #expect(first?["decision"] as? String == "block" && first?["reason"] as? String == "見直して")
        #expect(second?.isEmpty == true)
    }

    @Test("控えから行が落ちたら gap を配り、initialize を送り直す")
    func gap() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let stream = await conversation.events(after: 0)
        await host.gap(through: 5)
        #expect(await eventually { await host.written("initialize").count == 2 })
        var sawGap = false
        for await event in stream {
            if case .gap = event.kind {
                sawGap = true
                break
            }
        }
        #expect(sawGap)
    }

    @Test("知らない制御要求には error を返す。知らない行と keep_alive は読み飛ばし、続く行を読む")
    func unknown() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(#"{"type":"control_request","request_id":"u1","request":{"subtype":"request_user_dialog","kind":"x"}}"#)
        await host.emit(#"{"type":"keep_alive"}"#)
        await host.emit(#"{"type":"brand_new_type","x":1}"#)
        await host.emit(#"{"type":"control_request","request_id":"u2","request":{"subtype":"request_user_dialog","kind":"y"}}"#)
        #expect(await eventually { await host.controlResponses().contains { $0["request_id"] as? String == "u2" } })
        let responses = await host.controlResponses().filter { ["u1", "u2"].contains($0["request_id"] as? String) }
        #expect(responses.map { $0["subtype"] as? String } == ["error", "error"])
        #expect(await conversation.isLive)
    }

    @Test("ターンの終わりに、答えを待つ問いが無ければその行まで控えを捨てる。配送は result でなく、その後の idle で呼ぶ")
    func trimAtResult() async throws {
        let (conversation, host, _, _, calls) = try await make()
        try await conversation.start(resume: false)
        let idle = "idle:\(conversation.id)"
        #expect(await eventually { calls.all == [idle] })
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1","duration_ms":900,"ttft_ms":400}"#)
        #expect(await eventually { await host.requests.contains { $0.op == .trim } })
        let trim = try #require(await host.requests.first { $0.op == .trim })
        #expect(trim.through == (await host.seq))
        // result の時点ではまだ running なので、ここで配送を呼ぶと空いていない会話に入れようとして何もしない
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.all == [idle])
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)
        #expect(await eventually { calls.all == [idle, idle] })
        #expect(await conversation.isIdle)
    }

    @Test("読まない購読は、待ちが上限を超えたら途中を落とさずに終わる。終わるまでに届いた番号は欠けない")
    func slowSubscriber() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let stream = await conversation.events(after: await conversation.lastSeq)
        // 同じ block の差分は 1 つにまとまるので、block を替えながら送る
        for n in 0..<(ConversationEventLog.subscriberLimit + 10) {
            await host.emit(#"{"type":"stream_event","event":{"type":"content_block_delta","index":\#(n % 2),"delta":{"type":"text_delta","text":"a"}},"api_message_id":"msg_1"}"#)
        }
        #expect(await eventually { await conversation.lastSeq > ConversationEventLog.subscriberLimit })
        var seqs: [Int] = []
        for await event in stream { seqs.append(event.seq) }
        #expect(seqs.count == ConversationEventLog.subscriberLimit)
        // 先頭は購読したときの会話の状態（番号はその時点の最後の番号）、続きは 1 ずつ
        #expect(zip(seqs, seqs.dropFirst()).allSatisfy { $1 == $0 + 1 })
    }

    @Test("問いの答えを host に書けなければ、問いを残して失敗を返す（答え直せる）")
    func answerWriteFails() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_b","input":{"command":"ls"}}}"#)
        #expect(await eventually { await conversation.snapshot().pending.count == 1 })
        await host.setFailing([.write])
        await #expect(throws: (any Error).self) { try await conversation.answer(ConversationAnswerRequest(requestID: "r1", allow: true)) }
        #expect(await conversation.snapshot().pending.map(\.id) == ["r1"])
        await host.setFailing([])
        try await conversation.answer(ConversationAnswerRequest(requestID: "r1", allow: true))
        #expect(await conversation.snapshot().pending.isEmpty)
    }

    @Test("答えが CLI に届いて書き込みの応答だけ切れたら、次の行で CLI の待っている問いと照らし直し、答え済みの問いを消して idle に置く")
    func answerReachedButReplyLost() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_b","input":{"command":"ls"}}}"#)
        #expect(await eventually { await conversation.snapshot().pending.count == 1 })
        await host.setFailing([.write])
        await #expect(throws: (any Error).self) { try await conversation.answer(ConversationAnswerRequest(requestID: "r1", allow: true)) }
        await host.setFailing([])
        await host.setPending([], state: "idle")
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)
        #expect(await eventually { await conversation.snapshot().pending.isEmpty })
        #expect(await conversation.snapshot().phase == .idle)
        let error = await #expect(throws: ConversationError.self) { try await conversation.answer(ConversationAnswerRequest(requestID: "r1", allow: true)) }
        #expect(error?.code == .notWaiting)
    }

    @Test("CLI が空いたと知らせた後に残った問いへ答え直しても、running に戻さない")
    func answerAfterIdleKeepsIdle() async throws {
        let (conversation, host, _, _, calls) = try await make()
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_b","input":{"command":"ls"}}}"#)
        #expect(await eventually { await conversation.snapshot().pending.count == 1 })
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)
        // 起こした後と、空いたと知らせたときの 2 回
        let idle = "idle:\(conversation.id)"
        #expect(await eventually { calls.all.filter { $0 == idle }.count == 2 })
        try await conversation.answer(ConversationAnswerRequest(requestID: "r1", allow: true))
        #expect(await conversation.snapshot().pending.isEmpty)
        #expect(await conversation.snapshot().phase == .idle)
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.all.filter { $0 == idle }.count == 2)
    }

    @Test("起こした後に購読できなければ失敗を返し、繋ぎ直したときに入力を閉じ直して、子が終わると予約が外れる")
    func startFailsAfterSpawn() async throws {
        let (conversation, host, _, _, _) = try await make()
        // 接続が切れていて、購読も入力を閉じるのも届かない
        await host.setFailing([.subscribe, .closeInput])
        await #expect(throws: ConversationError.self) { try await conversation.start(resume: false) }
        #expect(await host.ops().contains(.closeInput))
        #expect(await conversation.isLive)
        await host.setFailing([])
        await conversation.resubscribe()
        #expect(await eventually { await !conversation.isLive })
        try await conversation.start(resume: false)
        #expect(await conversation.isLive)
        // 前の子に向けた TERM の猶予（300ms）が過ぎても、起こし直した子には送らない
        try await Task.sleep(for: .milliseconds(600))
        #expect(await !host.ops().contains(.signal))
        #expect(await conversation.isLive)
    }

    @Test("起こした後に失敗して子を終わらせる間に起こし直されても、前の子に向けた TERM を新しい子に送らない")
    func terminateSparesRestartedChild() async throws {
        let (conversation, host, _, _, _) = try await make()
        await host.setFailing([.subscribe])
        await #expect(throws: (any Error).self) { try await conversation.start(resume: false) }
        #expect(await host.ops().contains(.closeInput))
        await host.setFailing([])
        await conversation.resubscribe()
        #expect(await eventually { await !conversation.isLive })
        // 繋ぎ直しで届いた終わりの知らせを読み終えてから、TERM の猶予（stopTerm）の間に起こし直す
        try await Task.sleep(for: .milliseconds(50))
        try await conversation.start(resume: false)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await !host.ops().contains(.signal))
        #expect(await conversation.isLive)
    }

    @Test("止める途中、入力を閉じた応答を待つ間に子が終わって起こし直されても、新しい子に TERM を送らない")
    func stopSparesRestartedChild() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.holdNextCloseInput()
        let stopping = Task { await conversation.stop(.person) }
        #expect(await eventually { await !conversation.isLive })
        try await conversation.start(resume: true)
        await host.releaseCloseInput()
        await stopping.value
        try await Task.sleep(for: .milliseconds(400))
        #expect(await !host.ops().contains(.signal))
        #expect(await conversation.isLive)
    }

    @Test("案内は起こした後と /clear の後の最初の発言にだけ入れ、/clear で会話 ID をタスクに結ぶ")
    func guideAndReset() async throws {
        let (conversation, host, store, task, _) = try await make()
        try await conversation.start(resume: false)
        func prompt(_ id: String) async { await host.emit(#"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"hook_callback","callback_id":"tb_prompt","input":{"hook_event_name":"UserPromptSubmit"}}}"#) }
        func context(_ id: String) async -> String? {
            let response = await host.controlResponses().first { $0["request_id"] as? String == id }?["response"] as? [String: Any]
            return (response?["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String
        }
        await prompt("p1")
        #expect(await eventually { await host.controlResponses().count == 1 })
        #expect(await context("p1") == "タスク #\(task) の案内")
        await prompt("p2")
        #expect(await eventually { await host.controlResponses().count == 2 })
        #expect(await context("p2") == nil)
        await host.emit(#"{"type":"conversation_reset","new_conversation_id":"s2"}"#)
        await prompt("p3")
        #expect(await eventually { await host.controlResponses().count == 3 })
        #expect(await context("p3") == "タスク #\(task) の案内")
        #expect(try store.conversation(id: conversation.id)?.agentSessionId == "s2")
        #expect(try store.task(linkedToSession: "s2")?.number == task)
    }

    @Test("/clear で控えを捨てて reset を流す（画面は手元を捨て、新しい会話の履歴を取り直す）")
    func clearResetsFeed() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let stream = await conversation.events(after: 0)
        await host.emit(
            #"{"type":"assistant","message":{"id":"msg_a","role":"assistant","content":[{"type":"text","text":"前の会話"}]},"parent_tool_use_id":null,"uuid":"a-1","session_id":"s1"}"#)
        await host.emit(#"{"type":"conversation_reset","new_conversation_id":"s2"}"#)
        var sawMessage = false
        var sawReset = false
        for await event in stream {
            if case .messages = event.kind { sawMessage = true }
            if case .reset = event.kind {
                sawReset = true
                break
            }
        }
        #expect(sawMessage && sawReset)
        var replay: [ConversationEvent.Kind] = []
        for await event in await conversation.events(after: 0) {
            replay.append(event.kind)
            if case .conversation = event.kind { continue }
            if replay.count >= 2 { break }
        }
        #expect(!replay.contains { if case .messages = $0 { true } else { false } }, "/clear の前の発言は控えに残らない")
    }

    @Test("init の capabilities が足りなければ入力を閉じて理由を残す")
    func capabilities() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setCapabilities(["interrupt_receipt_v1"])
        await host.emitInit()
        #expect(await eventually { await host.ops().contains(.closeInput) })
        #expect(await eventually { (try? store.conversation(id: conversation.id)?.lastExit)??.contains("interrupt_cancel_queued_v1") == true })
    }

    @Test("出来事は番号つきで、続きから取れる。古すぎる番号には先に gap を送る")
    func events() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"了解"}},"api_message_id":"msg_1"}"#)
        var deltaSeq = 0
        for await event in await conversation.events(after: 0) {
            if case .delta = event.kind {
                deltaSeq = event.seq
                break
            }
        }
        let last = deltaSeq
        var replay: [ConversationEvent] = []
        for await event in await conversation.events(after: last - 1) {
            replay.append(event)
            if replay.count == 2 { break }
        }
        guard case .conversation = replay.first?.kind, case .delta(let id, 0, .text, "了解") = replay.last?.kind else {
            Issue.record("続きが違う: \(replay)")
            return
        }
        #expect(id == "msg_1")
        var future: [ConversationEvent] = []
        for await event in await conversation.events(after: last + 100) {
            future.append(event)
            break
        }
        guard case .gap = future.first?.kind else {
            Issue.record("gap が無い")
            return
        }
    }

    @Test("止まった会話のモデル・effort・権限は記録だけを書き換え、次に起こす引数に入る（モデルは TUI の起動と同じ名前）。確認なし以外で起こしても、確認なしへ切り替えられる")
    func settingsWhileStopped() async throws {
        let (conversation, host, store, _, _) = try await make()
        _ = try await conversation.control(ConversationControlRequest(kind: .setModel, value: "sonnet"))
        _ = try await conversation.control(ConversationControlRequest(kind: .setEffort, value: "high"))
        _ = try await conversation.control(ConversationControlRequest(kind: .setPermissionMode, value: "plan"))
        #expect(await host.requests.isEmpty)
        let record = try #require(try store.conversation(id: conversation.id))
        #expect(record.model == "claude-sonnet-5" && record.effort == "high" && record.permissionMode == "plan")
        try await conversation.start(resume: false)
        let argv = try #require(await host.requests.first { $0.op == .spawn }?.argv)
        #expect(argv.firstIndex(of: "--model").map { argv[$0 + 1] } == "claude-sonnet-5")
        #expect(argv.firstIndex(of: "--effort").map { argv[$0 + 1] } == "high")
        #expect(argv.firstIndex(of: "--permission-mode").map { argv[$0 + 1] } == "plan")
        #expect(argv.contains("--allow-dangerously-skip-permissions"))
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .setEffort, value: "huge")) }
    }

    @Test("確認なしへの切り替えを CLI が断ったら（allow を付けずに起こした子）、空いていれば記録を替えて --resume で起こし直し、通知の行を出す。生成中は断る")
    func bypassRestarts() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1"))
        await host.setRefusal("set_permission_mode", "Cannot set permission mode to bypassPermissions because the session was not launched with --dangerously-skip-permissions")
        let bypass = ConversationControlRequest(kind: .setPermissionMode, value: "bypassPermissions")
        @Sendable func spawns() async -> [[String]] { await host.requests.filter { $0.op == .spawn }.compactMap(\.argv) }

        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .running })
        await #expect(throws: ConversationError.self) { try await conversation.control(bypass) }
        #expect(await spawns().count == 1, "生成中は起こし直さない")
        #expect(try store.conversation(id: conversation.id)?.permissionMode != "bypassPermissions")

        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .idle })
        let response = try await conversation.control(bypass)
        #expect(response.payloadJSON?.contains(#""restarted":true"#) == true)
        let argv = try #require(await spawns().last)
        #expect(await spawns().count == 2)
        #expect(argv.firstIndex(of: "--resume").map { argv[$0 + 1] } == "s1")
        #expect(argv.firstIndex(of: "--permission-mode").map { argv[$0 + 1] } == "bypassPermissions")
        #expect(argv.contains("--allow-dangerously-skip-permissions"))
        #expect(try store.conversation(id: conversation.id)?.permissionMode == "bypassPermissions")
        #expect(await conversation.isLive)

        var notices: [String] = []
        let stream = await conversation.events(after: 0)
        let reading = Task {
            var seen: [String] = []
            for await event in stream { if case .notice(let text) = event.kind { seen.append(text) } }
            return seen
        }
        try await Task.sleep(for: .milliseconds(300))
        reading.cancel()
        notices = await reading.value
        #expect(notices == [ConversationScreenText.restartedForBypass], "止めた知らせは出さず、起こし直したことだけを出す")
    }

    @Test("UserPromptSubmit の hook の時間切れで捨てられた発言は、別の uuid で 2 回まで送り直し、受付と写しは元の uuid で出す。尽きたら取り消しと知らせを出す")
    func hookTimeoutResends() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1"))
        let original = "3b4e28ba-2fa1-11d2-883f-0016d3cca427"
        @Sendable func users() async -> [[String: Any]] { await host.written().filter { $0["type"] as? String == "user" } }
        func lifecycle(_ uuid: String, _ state: String) -> String { #"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"\#(state)"}"# }
        // 2.1.304 が hook に 30 秒答えられなかったときに出す行（control_cancel_request の直後）
        let dropped = #"{"type":"system","subtype":"informational","content":"UserPromptSubmit operation blocked by hook:\nUserPromptSubmit hook callback timed out after 30000ms","level":"warning","prevent_continuation":true,"prompt_submit_outcome":{"kind":"no_verdict","prompt_kept":false,"no_verdict_kind":"callback_timed_out"}}"#
        let stream = await conversation.events(after: 0)
        let reading = Task {
            var seen: [ConversationEvent.Kind] = []
            for await event in stream { seen.append(event.kind) }
            return seen
        }

        async let outcome = conversation.send(ConversationSendRequest(text: "途中の発言", clientMessageID: original))
        #expect(await eventually { await users().count == 1 })
        await host.emit(lifecycle(original, "queued"))
        #expect(try await outcome == .accepted)
        // 生成中に送った発言は、hook が断られた後に started・completed が来てから informational が来る
        await host.emit(lifecycle(original, "started"))
        await host.emit(lifecycle(original, "completed"))
        await host.emit(dropped)
        #expect(await eventually { await users().count == 2 })
        let resent = try #require(await users().last)
        let second = try #require(resent["uuid"] as? String)
        #expect(second != original)
        #expect(((resent["message"] as? [String: Any])?["content"] as? String) == "途中の発言")
        await host.emit(lifecycle(second, "queued"))
        await host.emit(lifecycle(second, "started"))
        await host.emit(#"{"type":"user","message":{"role":"user","content":"途中の発言"},"parent_tool_use_id":null,"uuid":"\#(second)"}"#)

        // 空いているときは、informational が completed より先に来る
        await host.emit(dropped)
        #expect(await eventually { await users().count == 3 })
        let third = try #require(await users().last?["uuid"] as? String)
        #expect(![original, second].contains(third))
        await host.emit(lifecycle(third, "started"))
        await host.emit(dropped)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await users().count == 3, "送り直すのは 2 回まで")

        // ユーザーの hook が止めた発言（no_verdict でない）は送り直さない
        await host.emit(lifecycle("4b4e28ba-2fa1-11d2-883f-0016d3cca427", "started"))
        await host.emit(dropped.replacingOccurrences(of: #""kind":"no_verdict""#, with: #""kind":"blocked""#))
        try await Task.sleep(for: .milliseconds(300))
        reading.cancel()
        let kinds = await reading.value
        #expect(await users().count == 3)

        let accepted = kinds.compactMap { kind -> String? in
            guard case .accepted(let id, let state) = kind else { return nil }
            return "\(id == original ? "元" : String(id.prefix(4))) \(state)"
        }
        #expect(accepted == ["元 queued", "元 started", "元 completed", "元 queued", "元 started", "元 started", "元 cancelled", "4b4e started"])
        let echoed = kinds.flatMap { kind -> [ChatMessage] in
            guard case .messages(let messages, _) = kind else { return [] }
            return messages.filter { $0.role == .user }
        }
        #expect(echoed.map(\.lineID) == [original], "写しは元の uuid で出し、アプリの発言と結ぶ")
        let notices = kinds.compactMap { kind -> String? in
            guard case .notice(let text) = kind else { return nil }
            return text
        }
        #expect(notices == [ConversationScreenText.promptDropped])
    }

    @Test("CLI が取り込まずに捨てた発言（discarded・refused）は、取り消しと同じに待ち行列から外し、理由を知らせで言う。取り消しには知らせを出さない")
    func notTakenLifecycle() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1"))
        @Sendable func users() async -> [[String: Any]] { await host.written().filter { $0["type"] as? String == "user" } }
        func lifecycle(_ uuid: String, _ state: String) -> String { #"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"\#(state)"}"# }
        let stream = await conversation.events(after: 0)
        let reading = Task {
            var seen: [ConversationEvent.Kind] = []
            for await event in stream { seen.append(event.kind) }
            return seen
        }

        let ids = ["5b4e28ba-2fa1-11d2-883f-0016d3cca427", "6b4e28ba-2fa1-11d2-883f-0016d3cca427", "7b4e28ba-2fa1-11d2-883f-0016d3cca427"]
        // queued の後に discarded（CLI が終わる途中で、待ち行列の発言を捨てる）
        async let first = conversation.send(ConversationSendRequest(text: "待っていた発言", clientMessageID: ids[0]))
        #expect(await eventually { await users().count == 1 })
        await host.emit(lifecycle(ids[0], "queued"))
        #expect(try await first == .accepted)
        await host.emit(lifecycle(ids[0], "discarded"))
        // queued を経ずに refused
        async let second = conversation.send(ConversationSendRequest(text: "断られた発言", clientMessageID: ids[1]))
        #expect(await eventually { await users().count == 2 })
        await host.emit(lifecycle(ids[1], "refused"))
        #expect(try await second == .accepted, "send は受付の有無だけを返す。外れたことは cancelled の受付と知らせで伝える")
        #expect(await conversation.deliveryState(ids[1]) == .cancelled, "回答・レビューの届けは、断られたら届いていないとする")
        // ふつうの取り消しには知らせを出さない
        async let third = conversation.send(ConversationSendRequest(text: "取り消す発言", clientMessageID: ids[2]))
        #expect(await eventually { await users().count == 3 })
        await host.emit(lifecycle(ids[2], "queued"))
        #expect(try await third == .accepted)
        await host.emit(lifecycle(ids[2], "cancelled"))
        try await Task.sleep(for: .milliseconds(300))
        reading.cancel()
        let kinds = await reading.value

        let accepted = kinds.compactMap { kind -> String? in
            guard case .accepted(let id, let state) = kind else { return nil }
            return "\(id.prefix(1)) \(state)"
        }
        #expect(accepted == ["5 queued", "5 cancelled", "6 cancelled", "7 queued", "7 cancelled"], "アプリには cancelled で渡し、待ち行列から外して入力欄へ戻す")
        let notices = kinds.compactMap { kind -> String? in
            guard case .notice(let text) = kind else { return nil }
            return text
        }
        #expect(notices == [ConversationScreenText.promptDiscarded, ConversationScreenText.promptRefused])
        #expect(try store.conversation(id: conversation.id)?.recentMessages.contains(ids[0]) == false, "取り込まれなかった発言は、起き直した後の受け取りの控えに残さない")
        #expect(await conversation.received(ids[0]) == false)
    }

    @Test("止まった会話の名前は記録だけを替え、動いている会話は rename_session も送る。改行を含む名前と 200 字を超える名前は断る")
    func renameWhileStopped() async throws {
        let (conversation, host, store, _, _) = try await make()
        for rejected in ["1 行目\n2 行目", String(repeating: "題", count: 201)] {
            await #expect(throws: ConversationError.invalidTitle) { try await conversation.control(ConversationControlRequest(kind: .rename, value: rejected)) }
        }
        _ = try await conversation.control(ConversationControlRequest(kind: .rename, value: " 依存の版を上げる\n"))
        #expect(await host.requests.isEmpty)
        #expect(try store.conversation(id: conversation.id)?.customTitle == "依存の版を上げる")
        try await conversation.start(resume: false)
        _ = try await conversation.control(ConversationControlRequest(kind: .rename, value: "依存の版"))
        #expect((await host.written("rename_session").first?["request"] as? [String: Any])?["title"] as? String == "依存の版")
        #expect(try store.conversation(id: conversation.id)?.customTitle == "依存の版")
    }

    @Test("人が付けた名前は自動の題と別に持って優先して出し、CLI が送り返した同じ名前で自動の題を替えない。名前がある間の自動の題は CLI に送らない。空にすると名前を外し、自動の題に戻して CLI にも送る")
    func customTitleOverAutomatic() async throws {
        let (conversation, host, store, number, _) = try await make { number in
            ConversationRecord(taskNumber: number, agentSessionId: "s1", cwd: "/w", model: "haiku", title: "#\(number) 会話", runner: .none)
        }
        try await conversation.start(resume: false)
        _ = try await conversation.control(ConversationControlRequest(kind: .rename, value: "依存の版"))
        #expect(await conversation.snapshot().title == "依存の版")
        #expect(await conversation.snapshot().customTitle == "依存の版")
        await host.emit(#"{"type":"system","subtype":"session_title_changed","title":"依存の版","session_id":"s1"}"#)
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .running })
        #expect(try store.conversation(id: conversation.id)?.title == "#\(number) 会話")
        try await conversation.rename("#\(number) 題を変えた")
        #expect(await conversation.snapshot().title == "依存の版")
        _ = try await conversation.control(ConversationControlRequest(kind: .rename, value: " "))
        let record = try #require(try store.conversation(id: conversation.id))
        #expect(record.customTitle == nil && record.title == "#\(number) 題を変えた")
        #expect(await conversation.snapshot().title == "#\(number) 題を変えた")
        #expect(await conversation.snapshot().customTitle == nil)
        let sent = await host.written("rename_session").compactMap { ($0["request"] as? [String: Any])?["title"] as? String }
        #expect(sent == ["依存の版", "#\(number) 題を変えた"])
    }

    @Test("題の無い会話は、人の発言の後のターンの終わりに generate_session_title で題を作らせて記録に書く。作らせるのは 1 回だけで、/ で始まる発言は渡さない")
    func generatesTitle() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("generate_session_title", #"{"title":"灯台の歴史"}"#)
        let result = #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#
        _ = try await conversation.send(ConversationSendRequest(text: "/model", clientMessageID: "3b4e28ba-2fa1-11d2-883f-0016d3cca427"))
        await host.emit(result)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await host.written("generate_session_title").isEmpty)
        _ = try await conversation.send(ConversationSendRequest(text: "灯台の歴史を調べて", clientMessageID: "4b4e28ba-2fa1-11d2-883f-0016d3cca427"))
        await host.emit(result)
        #expect(await eventually { await conversation.snapshot().title == "灯台の歴史" })
        #expect(try store.conversation(id: conversation.id)?.title == "灯台の歴史")
        let sent = await host.written("generate_session_title").compactMap { $0["request"] as? [String: Any] }
        #expect(sent.count == 1)
        #expect(sent.first?["description"] as? String == "灯台の歴史を調べて" && sent.first?["persist"] as? Bool == true)
        _ = try await conversation.send(ConversationSendRequest(text: "続けて", clientMessageID: "5b4e28ba-2fa1-11d2-883f-0016d3cca427"))
        await host.emit(result)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await host.written("generate_session_title").count == 1)
    }

    @Test("題か人の付けた名前がある会話には題を作らせない")
    func keepsExistingTitle() async throws {
        for (title, custom) in [("#1 会話", nil), (nil, "依存の版")] as [(String?, String?)] {
            let (conversation, host, _, _, _) = try await make { number in
                ConversationRecord(taskNumber: number, agentSessionId: "s1", cwd: "/w", model: "haiku", title: title, customTitle: custom, runner: .none)
            }
            try await conversation.start(resume: false)
            await host.setReply("generate_session_title", #"{"title":"灯台の歴史"}"#)
            _ = try await conversation.send(ConversationSendRequest(text: "灯台の歴史を調べて", clientMessageID: "6b4e28ba-2fa1-11d2-883f-0016d3cca427"))
            await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
            try await Task.sleep(for: .milliseconds(200))
            #expect(await host.written("generate_session_title").isEmpty)
        }
    }

    @Test("動いている会話の effort は apply_flag_settings で替え、記録にも書く")
    func effortWhileLive() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("apply_flag_settings", "{}")
        _ = try await conversation.control(ConversationControlRequest(kind: .setEffort, value: "max"))
        let sent = try #require(await host.written("apply_flag_settings").first?["request"] as? [String: Any])
        #expect((sent["settings"] as? [String: Any])?["effortLevel"] as? String == "max")
        #expect(try store.conversation(id: conversation.id)?.effort == "max")
    }

    @Test("MCP の繋ぎ直しと有効・無効は動いている会話だけ。名前と enabled を CLI に渡す")
    func mcpControls() async throws {
        let (conversation, host, _, _, _) = try await make()
        await #expect(throws: ConversationError.stopped(conversation.id)) {
            try await conversation.control(ConversationControlRequest(kind: .mcpReconnect, value: "github"))
        }
        try await conversation.start(resume: false)
        await host.setReply("mcp_reconnect", "{}")
        await host.setReply("mcp_toggle", "{}")
        _ = try await conversation.control(ConversationControlRequest(kind: .mcpReconnect, value: "github"))
        _ = try await conversation.control(ConversationControlRequest(kind: .mcpToggle, value: "github", enabled: false))
        #expect((await host.written("mcp_reconnect").first?["request"] as? [String: Any])?["serverName"] as? String == "github")
        let toggle = try #require(await host.written("mcp_toggle").first?["request"] as? [String: Any])
        #expect(toggle["serverName"] as? String == "github" && toggle["enabled"] as? Bool == false)
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .mcpToggle, value: "github")) }
    }

    @Test("mcp_status は決めた項目だけを返し、設定の env・headers と server の失敗の文を返さない")
    func mcpStatusRedacts() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply(
            "mcp_status",
            #"{"mcpServers":[{"name":"gh","status":"connected","scope":"user","config":{"type":"stdio","command":"gh-mcp","args":["--token","ghp_secretarg"],"env":{"GITHUB_TOKEN":"ghp_secretenv"}},"serverInfo":{"name":"github","version":"1.2.0"},"tools":[{"name":"a"},{"name":"b"}]},{"name":"api","status":"failed","config":{"type":"http","url":"https://x.example/mcp?key=qsecret","headers":{"Authorization":"Bearer hsecret"}},"error":"401 token esecret rejected"}]}"#
        )
        let response = try await conversation.control(ConversationControlRequest(kind: .mcpStatus))
        let json = try #require(response.payloadJSON)
        for secret in ["ghp_secretarg", "ghp_secretenv", "qsecret", "hsecret", "esecret", "gh-mcp", "x.example"] { #expect(!json.contains(secret)) }
        let status = try JSONDecoder().decode(ConversationMcpStatus.self, from: Data(json.utf8))
        #expect(
            status.mcpServers == [
                ConversationMcpServer(name: "gh", status: "connected", scope: "user", serverName: "github", serverVersion: "1.2.0", toolCount: 2, transport: "stdio"),
                ConversationMcpServer(name: "api", status: "failed", transport: "http"),
            ])
    }

    private static let elicitForm =
        #"{"type":"control_request","request_id":"e1","request":{"subtype":"elicitation","mcp_server_name":"github","message":"連絡先を入れてください","mode":"form","requested_schema":{"type":"object","properties":{"name":{"type":"string","minLength":1},"age":{"type":"integer","minimum":18},"agree":{"type":"boolean"}},"required":["name"]}}}"#
    private static let elicitURL =
        #"{"type":"control_request","request_id":"e2","request":{"subtype":"elicitation","mcp_server_name":"linear","message":"認証してください","mode":"url","url":"https://auth.example.com:8443/authorize?state=SECRET-STATE","elicitation_id":"el-9"}}"#

    @Test("MCP の問い（form）：欄の問いにし、schema に合わない答えは CLI に送らずに断り、合えば {action, content} を返す。答えの中身はログ・state・DB に出ない")
    func elicitationForm() async throws {
        let logs = Calls()
        let (conversation, host, store, _, _) = try await make(configure: { $0.logger = Logger(label: "test") { _ in CapturedLog(lines: logs) } })
        try await conversation.start(resume: false)
        await host.emit(Self.elicitForm)
        #expect(await eventually { await conversation.snapshot().pending.count == 1 })
        let request = try #require(await conversation.snapshot().pending.first)
        #expect(request.kind == .elicitation && request.elicitation?.serverName == "github" && request.elicitation?.message == "連絡先を入れてください")
        #expect(request.elicitation?.form?.fields.map(\.key) == ["name", "age", "agree"])
        #expect(await conversation.snapshot().phase == .waiting)
        await #expect(throws: ConversationError.invalid("必須の欄 name が無い")) {
            try await conversation.answer(ConversationAnswerRequest(requestID: "e1", action: .accept, content: ["age": .number(30)]))
        }
        await #expect(throws: ConversationError.invalid("欄 age の長さか範囲が外れている")) {
            try await conversation.answer(ConversationAnswerRequest(requestID: "e1", action: .accept, content: ["name": .string("x"), "age": .number(3)]))
        }
        await #expect(throws: ConversationError.self) { try await conversation.answer(ConversationAnswerRequest(requestID: "e1", allow: true)) }
        #expect(await host.controlResponses().isEmpty, "合わない答えは CLI に送らない")
        try await conversation.answer(
            ConversationAnswerRequest(requestID: "e1", action: .accept, content: ["name": .string("SECRET-ANSWER"), "age": .number(42), "agree": .bool(true)]))
        let response = try #require(await host.controlResponses().first)
        #expect(response["request_id"] as? String == "e1" && response["subtype"] as? String == "success")
        let body = try #require(response["response"] as? [String: Any])
        #expect(body["action"] as? String == "accept")
        let content = try #require(body["content"] as? [String: Any])
        #expect(content["name"] as? String == "SECRET-ANSWER" && (content["age"] as? NSNumber)?.intValue == 42 && content["agree"] as? Bool == true)
        #expect(await conversation.snapshot().pending.isEmpty)
        let state = String(decoding: try JSONEncoder().encode(await conversation.snapshot()), as: UTF8.self)
        let saved = String(decoding: try JSONEncoder().encode(try #require(try store.conversation(id: conversation.id))), as: UTF8.self)
        #expect(!state.contains("SECRET-ANSWER") && !saved.contains("SECRET-ANSWER"))
        #expect(!logs.all.isEmpty && !logs.all.contains { $0.contains("SECRET-ANSWER") })
        #expect(logs.all.contains { $0.contains("conversation elicitation") && $0.contains("github") && $0.contains("form") }, "ログは server の名前と種類だけ")
    }

    @Test("MCP の問い（url）：開く先の全文は state・DB・ログ・問いの文に載せず、［開く］の応答にだけ返す。受けたら action だけを返し、ターンの終わりに問いの行まで控えを切る")
    func elicitationURL() async throws {
        let logs = Calls()
        let (conversation, host, store, _, _) = try await make(configure: { $0.logger = Logger(label: "test") { _ in CapturedLog(lines: logs) } })
        try await conversation.start(resume: false)
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        await host.emit(Self.elicitURL)
        #expect(await eventually { await conversation.snapshot().pending.count == 1 })
        let asked = await host.seq
        let request = try #require(await conversation.snapshot().pending.first)
        #expect(request.elicitation?.link == Elicitation.Link(scheme: "https", host: "auth.example.com", port: 8443))
        #expect(request.elicitation?.elicitationID == "el-9" && request.elicitation?.allowedActions == [.accept, .decline, .cancel])
        let state = String(decoding: try JSONEncoder().encode(await conversation.snapshot()), as: UTF8.self)
        let saved = String(decoding: try JSONEncoder().encode(try #require(try store.conversation(id: conversation.id))), as: UTF8.self)
        #expect(!state.contains("SECRET-STATE") && !state.contains("/authorize") && !saved.contains("SECRET-STATE"))
        #expect(!request.lines.joined().contains("SECRET-STATE"))
        #expect(!(await conversation.noticeState.requests.flatMap(\.lines).joined().contains("SECRET-STATE")), "知らせに使う問いの文にも出さない")
        let opened = try await conversation.control(ConversationControlRequest(kind: .elicitationURL, value: "e2"))
        let url = try JSONDecoder().decode(ElicitationURLResponse.self, from: Data(try #require(opened.payloadJSON).utf8)).url
        #expect(url == "https://auth.example.com:8443/authorize?state=SECRET-STATE")
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .elicitationURL, value: "nope")) }
        await #expect(throws: ConversationError.invalid(ElicitationAnswerError.contentNotAllowed.description)) {
            try await conversation.answer(ConversationAnswerRequest(requestID: "e2", action: .accept, content: ["x": .string("y")]))
        }
        try await conversation.answer(ConversationAnswerRequest(requestID: "e2", action: .accept))
        let body = try #require(await host.controlResponses().first?["response"] as? [String: Any])
        #expect(body["action"] as? String == "accept" && body["content"] == nil)
        // 生成中なので答えた時点では切らず、ターンの終わりに問いの行より先まで切る
        #expect(await !host.requests.contains { $0.op == .trim })
        await host.emit(#"{"type":"system","subtype":"elicitation_complete","mcp_server_name":"linear","elicitation_id":"el-9"}"#)
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { (await host.requests.last { $0.op == .trim }?.through ?? 0) > asked })
        #expect(!logs.all.contains { $0.contains("SECRET-STATE") || $0.contains("/authorize") })
        #expect(await conversation.snapshot().pending.isEmpty)
    }

    @Test("MCP の問い：開けない URL と範囲の外の form は、断る・取り消すだけを受ける。知らない mode も同じ")
    func elicitationRefusable() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(
            #"{"type":"control_request","request_id":"e3","request":{"subtype":"elicitation","mcp_server_name":"x","message":"開いて","mode":"url","url":"http://evil.example.com/a"}}"#)
        await host.emit(
            #"{"type":"control_request","request_id":"e4","request":{"subtype":"elicitation","mcp_server_name":"x","message":"入れて","mode":"form","requested_schema":{"type":"object","properties":{"a":{"type":"array","items":{"type":"string"}}}}}}"#)
        await host.emit(#"{"type":"control_request","request_id":"e5","request":{"subtype":"elicitation","mcp_server_name":"x","message":"?","mode":"openai/form"}}"#)
        #expect(await eventually { await conversation.snapshot().pending.count == 3 })
        let pending = await conversation.snapshot().pending
        #expect(pending.map { $0.elicitation?.allowedActions ?? [] } == Array(repeating: [.decline, .cancel], count: 3))
        #expect(pending[0].elicitation?.link == nil && pending[1].elicitation?.form?.unsupported == true && pending[2].elicitation?.mode == .unknown)
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .elicitationURL, value: "e3")) }
        await #expect(throws: ConversationError.invalid("この問いには断るか取り消すしかできない")) {
            try await conversation.answer(ConversationAnswerRequest(requestID: "e4", action: .accept, content: [:]))
        }
        try await conversation.answer(ConversationAnswerRequest(requestID: "e3", action: .decline))
        try await conversation.answer(ConversationAnswerRequest(requestID: "e4", action: .cancel))
        let actions = await host.controlResponses().compactMap { ($0["response"] as? [String: Any])?["action"] as? String }
        #expect(actions == ["decline", "cancel"])
        #expect(await conversation.snapshot().pending.map(\.id) == ["e5"])
    }

    @Test("MCP の問い：会話が止まったら消える。CLI が取り下げた問いも消える")
    func elicitationGoneWhenStopped() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.elicitForm)
        await host.emit(Self.elicitURL)
        #expect(await eventually { await conversation.snapshot().pending.count == 2 })
        await host.emit(#"{"type":"control_cancel_request","request_id":"e1"}"#)
        #expect(await eventually { await conversation.snapshot().pending.map(\.id) == ["e2"] })
        await host.exit()
        #expect(await eventually { await conversation.snapshot().pending.isEmpty })
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .elicitationURL, value: "e2")) }
    }

    @Test("daemon が起き直したら、控えに残った MCP の問いを取り直し（開く先もメモリに戻す）、initialize の一覧に無くても消さない。ターンが終わったら、読み直しで得た問いは答え済みとして消す")
    func elicitationAfterRestart() async throws {
        let (conversation, host, _, _, _) = try await make()
        await host.setPending([], state: "idle")
        await host.keep(Self.elicitURL)
        await conversation.attach(process: AgentHostProcessInfo(key: conversation.id, pid: 42, alive: true, lastSeq: 1, firstSeq: 1, keptBytes: 10, startedAt: 0))
        #expect(await eventually { await host.written("initialize").count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await conversation.snapshot().pending.map(\.id) == ["e2"])
        let opened = try await conversation.control(ConversationControlRequest(kind: .elicitationURL, value: "e2"))
        #expect(opened.payloadJSON?.contains("SECRET-STATE") == true)
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().pending.isEmpty })
    }

    @Test("mcp_authenticate は認証の URL と 2 つの印だけを返し、空いていれば応答の行まで控えを切る。URL は会話の状態に載せない")
    func mcpAuthenticate() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply(
            "mcp_authenticate",
            #"{"authUrl":"https://auth.example.com/authorize?state=st1","requiresUserAction":true,"callbackExpected":true,"redirectScheme":"localhost","state":"st1","callbackPort":53123}"#
        )
        let response = try await conversation.control(ConversationControlRequest(kind: .mcpAuthenticate, value: "tbprobe"))
        #expect((await host.written("mcp_authenticate").first?["request"] as? [String: Any])?["serverName"] as? String == "tbprobe")
        let json = try #require(response.payloadJSON)
        #expect(!json.contains("53123") && !json.contains("redirectScheme"))
        #expect(
            try JSONDecoder().decode(ConversationMcpAuthentication.self, from: Data(json.utf8))
                == ConversationMcpAuthentication(authURL: "https://auth.example.com/authorize?state=st1", requiresUserAction: true, callbackExpected: true))
        let through = await host.seq
        #expect(await host.requests.last { $0.op == .trim }?.through == through)
        #expect(try store.conversation(id: conversation.id)?.trimmedThrough == through)
        let state = String(decoding: try JSONEncoder().encode(await conversation.snapshot()), as: UTF8.self)
        #expect(!state.contains("auth.example.com"))
        // 印が欠けた応答（CLI の形が変わった）は、認証が済んだとは読まずに失敗にする
        await host.setReply("mcp_authenticate", #"{"authUrl":"https://auth.example.com/authorize"}"#)
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .mcpAuthenticate, value: "tbprobe")) }
    }

    @Test("生成中の mcp_authenticate では控えを切らず、ターンの終わりに切る")
    func mcpAuthenticateWhileRunning() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .running })
        await host.setReply("mcp_authenticate", #"{"authUrl":"https://auth.example.com/authorize","requiresUserAction":true,"callbackExpected":true}"#)
        _ = try await conversation.control(ConversationControlRequest(kind: .mcpAuthenticate, value: "tbprobe"))
        let authenticated = await host.seq
        #expect(await !host.requests.contains { $0.op == .trim })
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { (await host.requests.last { $0.op == .trim }?.through ?? 0) > authenticated })
    }

    private static let loginReply =
        #"{"manualUrl":"https://claude.com/cai/oauth/authorize?code=true&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=lst1","automaticUrl":"https://claude.com/cai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A53999%2Fcallback&state=lst1"}"#

    /// 切り離して待っている `claude_oauth_wait_for_completion` に CLI として答える
    private func completeLogin(_ host: FakeHost, _ response: String) async throws {
        let wait = try #require(await host.written("claude_oauth_wait_for_completion").last?["request_id"] as? String)
        await host.emit(#"{"type":"control_response","response":{"request_id":"\#(wait)",\#(response)}}"#)
    }

    @Test("login はログインのページ 2 つを要求した端末にだけ返し、応答の行まで控えを切る。終わりは切り離した待ちで知り、会話の段階にだけ載せる")
    func login() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("claude_authenticate", Self.loginReply)
        let response = try await conversation.control(ConversationControlRequest(kind: .login))
        #expect((await host.written("claude_authenticate").first?["request"] as? [String: Any])?["loginWithClaudeAi"] as? Bool == true)
        let login = try JSONDecoder().decode(ConversationLogin.self, from: Data(try #require(response.payloadJSON).utf8))
        #expect(login.manualURL.hasPrefix("https://claude.com/cai/oauth/authorize?") && login.manualURL.contains("platform.claude.com"))
        #expect(login.automaticURL.contains("localhost%3A53999"))
        let through = await host.seq
        #expect(await host.requests.last { $0.op == .trim }?.through == through)
        #expect(try store.conversation(id: conversation.id)?.trimmedThrough == through)
        #expect(await conversation.snapshot().login == .waiting)
        // 同じ流れの 2 回目は待ちを増やさない
        _ = try await conversation.control(ConversationControlRequest(kind: .login))
        #expect(await host.written("claude_oauth_wait_for_completion").count == 1)
        try await completeLogin(
            host, #""subtype":"success","response":{"account":{"email":"someone@example.com","organization":"org","subscriptionType":"max"}}"#)
        #expect(await eventually { await conversation.snapshot().login == .succeeded })
        let completed = await host.seq
        #expect(await eventually { await host.requests.last { $0.op == .trim }?.through == completed })
        let state = String(decoding: try JSONEncoder().encode(await conversation.snapshot()), as: UTF8.self)
        for secret in ["claude.com", "lst1", "localhost", "someone@example.com"] { #expect(!state.contains(secret)) }
    }

    @Test("login のページが https でなければ失敗にし、待ちを始めない")
    func loginRejectsPages() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("claude_authenticate", #"{"manualUrl":"http://evil.example/a?state=s","automaticUrl":"https://claude.com/a?state=s"}"#)
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .login)) }
        await host.setRefusal("claude_authenticate", "Login blocked")
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .login)) }
        #expect(await host.written("claude_oauth_wait_for_completion").isEmpty)
        #expect(await conversation.snapshot().login == nil)
    }

    @Test("login_code はページに出たコードを code と state に分けて渡し、応答を待たない。形の違うコード・ほかの流れのコードは CLI に送らない")
    func loginCode() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        // 流れが無ければ断る
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .loginCode, code: "c1#lst1")) }
        await host.setReply("claude_authenticate", Self.loginReply)
        _ = try await conversation.control(ConversationControlRequest(kind: .login))
        for rejected in [nil, "", "c1", "c1#", "#lst1", "c1#lst1#x", "c 1#lst1", "c1#other"] {
            await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .loginCode, code: rejected)) }
        }
        #expect(await host.written("claude_oauth_callback").isEmpty)
        let response = try await conversation.control(ConversationControlRequest(kind: .loginCode, code: " c1#lst1\n"))
        #expect(response.payloadJSON == nil)
        let sent = try #require(await host.written("claude_oauth_callback").first?["request"] as? [String: Any])
        #expect(sent["authorizationCode"] as? String == "c1" && sent["state"] as? String == "lst1")
        #expect(await conversation.snapshot().login == .waiting)
        try await completeLogin(host, #""subtype":"error","error":"Token exchange failed""#)
        #expect(await eventually { await conversation.snapshot().login == .failed })
    }

    @Test("login の終わりは時間で切らずに待ち、応答にアカウントが無ければ失敗にする。会話が止まったら段階を消す")
    func loginWaitAndStop() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("claude_authenticate", Self.loginReply)
        _ = try await conversation.control(ConversationControlRequest(kind: .login))
        // 制御要求の上限（ここでは 2 秒）を過ぎても待ち続け、遅れて届いた応答の行も控えから切る
        try await Task.sleep(for: .milliseconds(2300))
        #expect(await conversation.snapshot().login == .waiting)
        try await completeLogin(host, #""subtype":"success","response":{}"#)
        #expect(await eventually { await conversation.snapshot().login == .failed })
        let completed = await host.seq
        #expect(await eventually { await host.requests.last { $0.op == .trim }?.through == completed })
        // もう一度始めた流れは、止めると消える
        _ = try await conversation.control(ConversationControlRequest(kind: .login))
        #expect(await conversation.snapshot().login == .waiting)
        await conversation.stop(.person)
        #expect(await conversation.snapshot().login == nil)
    }

    @Test("state の無いログインのページでは始めず、コードは 1 つの流れに 1 回だけ渡す")
    func loginStateAndSingleCode() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("claude_authenticate", #"{"manualUrl":"https://claude.com/cai/oauth/authorize","automaticUrl":"https://claude.com/cai/oauth/authorize"}"#)
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .login)) }
        #expect(await host.written("claude_oauth_wait_for_completion").isEmpty)
        await host.setReply("claude_authenticate", Self.loginReply)
        _ = try await conversation.control(ConversationControlRequest(kind: .login))
        _ = try await conversation.control(ConversationControlRequest(kind: .loginCode, code: "c1#lst1"))
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .loginCode, code: "c2#lst1")) }
        #expect(await host.written("claude_oauth_callback").count == 1)
    }

    @Test("mcp_oauth_callback は確かめた URL を渡してから繋ぎ直す。確かめに通らない URL は CLI に送らない")
    func mcpOAuthCallback() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("mcp_oauth_callback_url", "{}")
        await host.setReply("mcp_reconnect", "{}")
        for rejected in [nil, "https://evil.example/callback?code=a&state=b", "http://localhost:53123/callback?code=a"] {
            await #expect(throws: ConversationError.self) {
                try await conversation.control(ConversationControlRequest(kind: .mcpOAuthCallback, value: "tbprobe", callbackURL: rejected))
            }
        }
        #expect(await host.written("mcp_oauth_callback_url").isEmpty)
        _ = try await conversation.control(
            ConversationControlRequest(kind: .mcpOAuthCallback, value: "tbprobe", callbackURL: " http://localhost:53123/callback?code=c1&state=st1\n"))
        let subtypes = await host.written().compactMap { ($0["request"] as? [String: Any])?["subtype"] as? String }
        #expect(subtypes.suffix(2) == ["mcp_oauth_callback_url", "mcp_reconnect"])
        let sent = try #require(await host.written("mcp_oauth_callback_url").first?["request"] as? [String: Any])
        #expect(sent["serverName"] as? String == "tbprobe")
        #expect(sent["callbackUrl"] as? String == "http://localhost:53123/callback?code=c1&state=st1")
        #expect((await host.written("mcp_reconnect").first?["request"] as? [String: Any])?["serverName"] as? String == "tbprobe")
    }

    @Test("callback が断られても、その server が繋がっていれば成功で返す（応答だけが失われて送り直したとき）。繋がっていなければ CLI の文で失敗")
    func mcpOAuthCallbackRetried() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let callback = ConversationControlRequest(kind: .mcpOAuthCallback, value: "tbprobe", callbackURL: "http://localhost:53123/callback?code=c1&state=st1")
        await host.setRefusal("mcp_oauth_callback_url", "No active OAuth flow for server: tbprobe")
        await host.setReply("mcp_status", #"{"mcpServers":[{"name":"tbprobe","status":"connected","config":{"type":"http","url":"http://127.0.0.1:47821/mcp"}}]}"#)
        _ = try await conversation.control(callback)
        #expect(await host.written("mcp_reconnect").isEmpty)
        await host.setReply("mcp_status", #"{"mcpServers":[{"name":"tbprobe","status":"needs-auth","config":{"type":"http","url":"http://127.0.0.1:47821/mcp"}}]}"#)
        await #expect(throws: ConversationError.failed("No active OAuth flow for server: tbprobe")) { try await conversation.control(callback) }
    }

    @Test("mcp_clear_auth は server の名前を CLI に渡す。名前が空なら送らない")
    func mcpClearAuth() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("mcp_clear_auth", "{}")
        await #expect(throws: ConversationError.self) { try await conversation.control(ConversationControlRequest(kind: .mcpClearAuth, value: "")) }
        _ = try await conversation.control(ConversationControlRequest(kind: .mcpClearAuth, value: "tbprobe"))
        #expect(await host.written("mcp_clear_auth").map { ($0["request"] as? [String: Any])?["serverName"] as? String } == ["tbprobe"])
    }

    @Test("コンテキストの使用率は summary で取り、ターンの終わりにも取り直す")
    func contextUsage() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("get_context_usage", #"{"percentage":41.6,"totalTokens":83200,"maxTokens":200000}"#)
        _ = try await conversation.control(ConversationControlRequest(kind: .contextUsage))
        #expect((await host.written("get_context_usage").first?["request"] as? [String: Any])?["detail"] as? String == "summary")
        #expect(await conversation.snapshot().contextPercent == 42)
        await host.setReply("get_context_usage", #"{"percentage":57.2}"#)
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().contextPercent == 57 })
    }

    private static func initLine(
        _ session: String, model: String = "claude-haiku-5-5", capabilities: [String] = ["interrupt_cancel_queued_v1", "msg_lifecycle_v1"]
    ) -> String {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"system","subtype":"init","session_id":"\#(session)","model":"\#(model)","claude_code_version":"2.1.303","capabilities":[\#(list)]}"#
    }

    private static func resultLine(_ session: String, cost: Double, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"\#(session)","total_cost_usd":\#(cost),"usage":{"input_tokens":2,"output_tokens":3},"modelUsage":{"claude-haiku-5-5":{"inputTokens":\#(input),"outputTokens":\#(output),"cacheReadInputTokens":\#(cacheRead),"cacheCreationInputTokens":\#(cacheWrite),"costUSD":\#(cost)},"claude-sonnet-5-5":{"inputTokens":1,"outputTokens":1,"cacheReadInputTokens":0,"cacheCreationInputTokens":0}}}"#
    }

    @Test("会話の値：init のモデルと版、result の費用と modelUsage の和、ターンの後のコンテキストを取り、作り直しても記録から戻る")
    func stats() async throws {
        let (conversation, host, store, _, calls) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("get_context_usage", #"{"percentage":8.5,"totalTokens":51058,"maxTokens":600000}"#)
        await host.emit(Self.initLine("s1"))
        await host.emit(Self.resultLine("s1", cost: 0.009414, input: 4, output: 7, cacheRead: 46604, cacheWrite: 44718))
        #expect(await eventually { await conversation.snapshot().currentStats?.contextWindow == 600_000 })
        let stats = try #require(await conversation.snapshot().currentStats)
        #expect(stats.model == "claude-haiku-5-5" && stats.engineVersion == "2.1.303" && stats.costUSD == 0.009414)
        #expect(stats.tokens == ConversationStats.Tokens(input: 5, output: 8, cacheRead: 46604, cacheWrite: 44718), "サブエージェントのモデルも足す")
        #expect(stats.contextTokens == 51058)
        let saved = try #require(try store.conversation(id: conversation.id))
        #expect(saved.statsValue == stats)
        let reopened = await reopen(conversation.id, store: store, host: FakeHost(), calls: calls)
        #expect(await reopened.snapshot().currentStats == stats, "止まった会話でも記録から出す")
    }

    @Test("会話の値：/clear で Claude の会話が替わると前の値を出さず、取っている間に替わった応答は捨てる。新しい会話の result から数え直す")
    func statsFollowSession() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1"))
        await host.emit(Self.resultLine("s1", cost: 0.0035, input: 2, output: 4, cacheRead: 23302, cacheWrite: 16558))
        #expect(await eventually { await conversation.snapshot().currentStats?.costUSD == 0.0035 })
        await host.emit(#"{"type":"conversation_reset","new_conversation_id":"s2"}"#)
        #expect(await eventually { await conversation.snapshot().agentSessionID == "s2" })
        #expect(await conversation.snapshot().currentStats == nil, "/clear の前の費用を出さない")
        // /clear の前の会話の result が遅れて届いても、今の会話の値にしない
        await host.emit(Self.resultLine("s1", cost: 0.01, input: 9, output: 9, cacheRead: 9, cacheWrite: 9))
        await host.emit(Self.initLine("s2"))
        await host.emit(Self.resultLine("s2", cost: 0.0077, input: 2, output: 3, cacheRead: 13416, cacheWrite: 37704))
        #expect(await eventually { await conversation.snapshot().currentStats?.costUSD == 0.0077 })
        #expect(await conversation.snapshot().currentStats?.tokens?.cacheWrite == 37704)
    }

    @Test("コンテキストの内訳は区分の名前・トークン・種類と合計・上限だけを返し、応答の残り（tool や skill の一覧）は写さない")
    func contextBreakdown() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply(
            "get_context_usage",
            #"{"percentage":9,"totalTokens":51058,"maxTokens":600000,"autoCompactThreshold":567000,"categories":[{"name":"System prompt","tokens":2530,"kind":"used","color":"x"},{"name":"MCP tools (deferred)","tokens":306015,"kind":"deferred"},{"name":"Free space","tokens":515942,"kind":"free"},{"name":"新しい区分","tokens":1,"kind":"future"}],"mcpTools":[{"name":"secret_tool_name"}],"skills":[{"name":"secret-skill"}]}"#)
        let response = try await conversation.control(ConversationControlRequest(kind: .contextBreakdown))
        let json = try #require(response.payloadJSON)
        #expect(!json.contains("secret_tool_name") && !json.contains("secret-skill"))
        let breakdown = try WireJSON.decoder().decode(ConversationContextBreakdown.self, from: Data(json.utf8))
        #expect(breakdown.agentSessionID == "s1" && breakdown.totalTokens == 51058 && breakdown.maxTokens == 600_000 && breakdown.autoCompactThreshold == 567_000)
        #expect(breakdown.categories.map(\.kind) == [.used, .deferred, .free, .other])
        #expect(breakdown.categories.first == .init(name: "System prompt", tokens: 2530, kind: .used))
    }

    private static func messagesUsage(_ tokens: Int) -> String {
        #"{"percentage":9,"totalTokens":51058,"maxTokens":600000,"categories":[{"name":"System prompt","tokens":2530,"kind":"used"},{"name":"Messages","tokens":\#(tokens),"kind":"used"}]}"#
    }

    private static func compactions(_ host: FakeHost) async -> Int {
        await host.written().filter { $0["type"] as? String == "user" && ($0["message"] as? [String: Any])?["content"] as? String == "/compact" }.count
    }

    @Test("返事の後に 50 分空いた会話は、発言が 3 万トークン以上なら /compact を送る。圧縮のターンの後は、次の返事まで送らない")
    func idleCompaction() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, _, _, _) = try await make(configure: { $0.now = { clock.now } })
        try await conversation.start(resume: false)
        await host.setReply("get_context_usage", Self.messagesUsage(30_000))
        await host.emit(Self.resultLine("s1", cost: 0.001, input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        #expect(await eventually { await conversation.snapshot().currentStats?.costUSD == 0.001 })

        clock.advance(49 * 60)
        await conversation.compactIfIdle()
        #expect(await Self.compactions(host) == 0, "50 分より前は送らない")

        clock.advance(60)
        await conversation.compactIfIdle()
        #expect(await Self.compactions(host) == 1)

        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1","total_cost_usd":0.0015}"#)
        #expect(await eventually { await conversation.snapshot().currentStats?.costUSD == 0.0015 })
        clock.advance(50 * 60)
        await conversation.compactIfIdle()
        #expect(await Self.compactions(host) == 1, "圧縮のターンの終わりからは数えない")

        await host.emit(Self.resultLine("s1", cost: 0.002, input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        #expect(await eventually { await conversation.snapshot().currentStats?.costUSD == 0.002 })
        clock.advance(50 * 60)
        await conversation.compactIfIdle()
        #expect(await Self.compactions(host) == 2, "人の次の返事からはまた数える")
    }

    @Test("空いた会話の圧縮は、発言が 3 万トークン未満・56 分を過ぎた・誤りで終わったターンでは送らず、送らなかった空きでは送り直さない")
    func idleCompactionSkips() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, _, _, _) = try await make(configure: { $0.now = { clock.now } })
        try await conversation.start(resume: false)

        await host.setReply("get_context_usage", Self.messagesUsage(29_999))
        await host.emit(Self.resultLine("s1", cost: 0.001, input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        #expect(await eventually { await conversation.snapshot().currentStats?.costUSD == 0.001 })
        clock.advance(50 * 60)
        await conversation.compactIfIdle()
        await host.setReply("get_context_usage", Self.messagesUsage(80_000))
        clock.advance(60)
        await conversation.compactIfIdle()
        #expect(await Self.compactions(host) == 0, "小さいと分かった空きでは、後で大きくなっても送らない")

        await host.emit(Self.resultLine("s1", cost: 0.002, input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        #expect(await eventually { await conversation.snapshot().currentStats?.costUSD == 0.002 })
        clock.advance(57 * 60)
        await conversation.compactIfIdle()
        #expect(await Self.compactions(host) == 0, "56 分を過ぎるとキャッシュが切れかけで、圧縮が書き直しになる")

        await host.emit(#"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s1","total_cost_usd":0.003}"#)
        #expect(await eventually { await conversation.snapshot().currentStats?.costUSD == 0.003 })
        clock.advance(50 * 60)
        await conversation.compactIfIdle()
        #expect(await Self.compactions(host) == 0, "返事の無いターンからは数えない")
    }

    @Test("rate_limit_event の窓と、間をあけた get_usage の窓をマシンの利用枠に入れる（get_usage の utilization は 0〜100）")
    func usageReports() async throws {
        let reports = Reports()
        let claims = Reports()
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.reportUsage = { report in await reports.add(report) }
            $0.claimUsageRefresh = { _ in await claims.claim() }
        })
        try await conversation.start(resume: false)
        await host.setReply("get_context_usage", #"{"percentage":9,"totalTokens":51058,"maxTokens":600000}"#)
        await host.setReply(
            "get_usage", #"{"rate_limits":{"five_hour":{"utilization":56,"resets_at":"2026-10-19T16:59:59.607442+00:00"},"seven_day":null}}"#)
        await host.emit(
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1792429200,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.56,"resetsAt":1792429200}}}}"#)
        #expect(await eventually { await reports.count == 1 })
        let event = try #require(await reports.all.first)
        #expect(abs((event.fiveHour?.usedPercent ?? 0) - 56) < 0.001 && event.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_792_429_200))
        #expect(event.context.agentSessionID == "s1")
        await host.emit(Self.resultLine("s1", cost: 0.001, input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        #expect(await eventually { await reports.count == 2 })
        let polled = try #require(await reports.all.last)
        #expect(polled.fiveHour?.usedPercent == 56 && polled.sevenDay == nil)
        #expect(polled.fiveHour?.resetsAt.map { abs($0.timeIntervalSince1970 - 1_792_429_199.607) < 0.01 } == true)
        // 間をあける前の 2 回目のターンでは引かない
        await host.emit(Self.resultLine("s1", cost: 0.002, input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await reports.count == 2)
        #expect(await host.written("get_usage").count == 1)
    }

    @Test("ターンを終えていなくても、見回りで空いている会話の利用枠を取り直す。間引きの答えが false なら引かない")
    func refreshesUsageWhenIdle() async throws {
        let reports = Reports()
        let claims = Reports()
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.reportUsage = { report in await reports.add(report) }
            $0.claimUsageRefresh = { _ in await claims.claim() }
        })
        try await conversation.start(resume: false)
        await host.setReply(
            "get_usage", #"{"rate_limits":{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":100,"resets_at":"2026-10-31T05:00:00.161301+00:00"}}}"#)
        await conversation.refreshUsage()
        let report = try #require(await reports.all.first)
        #expect(report.sevenDay?.usedPercent == 100)
        await conversation.refreshUsage()
        #expect(await host.written("get_usage").count == 1)
    }

    @Test("rewind_files：dry run は dry_run を付けて送り、変わるファイルと行の数を返す。CLI が断った文を返す。止まっていれば 409")
    func rewindFiles() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("rewind_files", #"{"canRewind":true,"filesChanged":["/w/メモ.txt"],"insertions":1,"deletions":2}"#)
        let dry = try await conversation.rewindFiles(userMessageID: "u-1", dryRun: true)
        #expect(dry == ConversationRewindResponse(canRewind: true, filesChanged: ["/w/メモ.txt"], insertions: 1, deletions: 2))
        let request = await host.written("rewind_files").first?["request"] as? [String: Any]
        #expect(request?["user_message_id"] as? String == "u-1" && request?["dry_run"] as? Bool == true)
        await host.setReply("rewind_files", #"{"canRewind":true,"skippedLinks":1}"#)
        #expect(try await conversation.rewindFiles(userMessageID: "u-1", dryRun: false) == ConversationRewindResponse(canRewind: true, skippedLinks: 1))
        #expect((await host.written("rewind_files").last?["request"] as? [String: Any])?["dry_run"] == nil)
        await host.setReply("rewind_files", #"{"canRewind":false,"error":"No file checkpoint found for this message."}"#)
        #expect(try await conversation.rewindFiles(userMessageID: "u-0", dryRun: true).error == "No file checkpoint found for this message.")
        await conversation.stop(.person)
        await #expect(throws: ConversationError.stopped(conversation.id)) { try await conversation.rewindFiles(userMessageID: "u-1", dryRun: true) }
    }

    @Test("コマンドの一覧は initialize の応答と commands_changed で置き換わり、止まった後も残る")
    func commands() async throws {
        let (conversation, host, _, _, _) = try await make()
        await host.setCommands(
            #"[{"name":"clear","description":"会話を消す","argumentHint":"","builtin":true,"aliases":["reset","new"]},{"name":"review","description":"PR を見る","argumentHint":"<PR>"},{"description":"名前なし"}]"#
        )
        try await conversation.start(resume: false)
        #expect(
            await conversation.commands == [
                ConversationCommand(name: "clear", description: "会話を消す", builtin: true, aliases: ["reset", "new"]),
                ConversationCommand(name: "review", description: "PR を見る", argumentHint: "<PR>"),
            ])
        await host.emit(#"{"type":"system","subtype":"commands_changed","commands":[{"name":"deploy","description":"出す","aliases":[]}]}"#)
        #expect(await eventually { await conversation.commands == [ConversationCommand(name: "deploy", description: "出す")] })
        var seen = false
        for await event in await conversation.events(after: 0) {
            if case .commands(let list) = event.kind, list.map(\.name) == ["deploy"] {
                seen = true
                break
            }
        }
        #expect(seen)
        await conversation.stop(.person)
        #expect(await conversation.commands?.map(\.name) == ["deploy"])
    }

    @Test("差分の要約：起こした後・ターンの終わり・ファイルを書くツールの結果で取り直す。取れなければ前の要約を残す。読むだけのツールでは取り直さない")
    func diffSummary() async throws {
        let answers = DiffAnswers([
            ConversationDiffSummary(isRepo: true, branch: "main", files: 1, insertions: 2), nil,
            ConversationDiffSummary(isRepo: true, branch: "main", files: 2, insertions: 5, deletions: 1),
        ])
        let (conversation, host, _, _, _) = try await make(diff: { cwd in await answers.next(cwd) })
        try await conversation.start(resume: false)
        #expect(await eventually { await conversation.snapshot().diff?.files == 1 })
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        #expect(await eventually { await answers.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await conversation.snapshot().diff?.files == 1, "取れなければ前の要約を残す")

        await host.emit(
            #"{"type":"assistant","message":{"id":"msg_r","role":"assistant","content":[{"type":"tool_use","id":"toolu_r","name":"Read","input":{}}]},"parent_tool_use_id":null,"uuid":"a-r","session_id":"s1"}"#)
        await host.emit(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_r","content":"x"}]},"parent_tool_use_id":null,"uuid":"u-r","session_id":"s1"}"#)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await answers.count == 2, "読むだけのツールでは取り直さない")
        await host.emit(
            #"{"type":"assistant","message":{"id":"msg_w","role":"assistant","content":[{"type":"tool_use","id":"toolu_w","name":"Write","input":{}}]},"parent_tool_use_id":null,"uuid":"a-w","session_id":"s1"}"#)
        await host.emit(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_w","content":"ok"}]},"parent_tool_use_id":null,"uuid":"u-w","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().diff?.files == 2 })
        #expect(await answers.cwds.allSatisfy { $0 == "/w" })
    }

    /// 利用枠の上限で断られたターン（`rate_limit_event` の rejected の後の error の result）
    private func rejectTurn(_ host: FakeHost, resetsAt: Date, status: String = "rejected") async {
        await host.emit(
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(status)","resetsAt":\#(Int(resetsAt.timeIntervalSince1970)),"rateLimitType":"five_hour"},"session_id":"s1"}"#)
        await host.emit(#"{"type":"result","subtype":"success","is_error":true,"stop_reason":"end_turn","session_id":"s1"}"#)
    }

    @Test("利用枠の上限で断られて終わったら、戻る時刻の 1 分後まで待ち、過ぎたら続きを 1 回だけ送る")
    func continuesAfterUsageLimit() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _, _) = try await make(configure: { context in
            context.now = { clock.now }
            context.continuesAtUsageLimit = { _, _ in true }
        })
        try await conversation.start(resume: false)
        let resets = clock.now.addingTimeInterval(3600)
        await rejectTurn(host, resetsAt: resets)
        #expect(await eventually { await conversation.snapshot().limitResumeAt == resets.addingTimeInterval(60) })
        #expect(try store.conversation(id: conversation.id)?.limitResumeAt == resets.addingTimeInterval(60))
        // 時刻の前は送らず、ほかの配送も入れない
        await conversation.continueAfterLimit()
        #expect(try await conversation.deliver(text: "回答", uuid: "9b4e28ba-2fa1-11d2-883f-0016d3cca427", wake: .always) == .busy)
        #expect(await host.written().filter { $0["type"] as? String == "user" }.isEmpty)

        clock.advance(3661)
        async let resumed: Void = conversation.continueAfterLimit()
        #expect(await eventually { await host.written().contains { $0["type"] as? String == "user" } })
        let user = try #require(await host.written().first { $0["type"] as? String == "user" })
        #expect(((user["message"] as? [String: Any])?["content"] as? String) == ClaudeConversation.limitResumeText)
        let uuid = try #require(user["uuid"] as? String)
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"started"}"#)
        await resumed
        #expect(await conversation.snapshot().limitResumeAt == nil)
        await conversation.continueAfterLimit()
        #expect(await host.written().filter { $0["type"] as? String == "user" }.count == 1)
    }

    @Test("上限で待っている会話は、別のアカウントの引数を渡されたら、そのアカウントで同じ会話を起こし直してすぐ続きを送る。待っていない会話は替えない")
    func continuesOnAnotherAccount() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _, _) = try await make(configure: { context in
            context.now = { clock.now }
            context.continuesAtUsageLimit = { _, _ in true }
        })
        @Sendable func spawns() async -> [[String]] { await host.requests.filter { $0.op == .spawn }.compactMap(\.argv) }
        let sub = ["--settings", "/u/Library/Application Support/taskboard/claude-accounts/sub.json"]
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1"))
        await conversation.continueOnAccount(arguments: sub)
        #expect(try store.conversation(id: conversation.id)?.extraArguments != sub, "上限で待っていなければ替えない")

        await rejectTurn(host, resetsAt: clock.now.addingTimeInterval(7 * 86_400))
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })
        async let moved: Void = conversation.continueOnAccount(arguments: sub)
        #expect(await eventually { await spawns().count == 2 })
        let argv = try #require(await spawns().last)
        #expect(argv.firstIndex(of: "--resume").map { argv[$0 + 1] } == "s1")
        #expect(ClaudeAccount.name(inArguments: argv) == "sub")
        #expect(await eventually { await host.written().contains { $0["type"] as? String == "user" } })
        let user = try #require(await host.written().last { $0["type"] as? String == "user" })
        #expect(((user["message"] as? [String: Any])?["content"] as? String) == ClaudeConversation.limitResumeText)
        let uuid = try #require(user["uuid"] as? String)
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"started"}"#)
        await moved
        #expect(await conversation.snapshot().limitResumeAt == nil)
        #expect(try store.conversation(id: conversation.id)?.extraArguments == sub)
    }

    @Test("起こすときにアカウントを決め直し、引数と記録をそのアカウントにする")
    func decidesAccountAtLaunch() async throws {
        let main = ["--settings", "/u/Library/Application Support/taskboard/claude-accounts/main.json"]
        let (conversation, host, store, _, _) = try await make(configure: { context in
            context.launchArguments = { _, _ in main }
        })
        @Sendable func spawns() async -> [[String]] { await host.requests.filter { $0.op == .spawn }.compactMap(\.argv) }
        try await conversation.start(resume: false)
        #expect(await eventually { await spawns().count == 1 })
        #expect(ClaudeAccount.name(inArguments: try #require(await spawns().last)) == "main")
        #expect(try store.conversation(id: conversation.id)?.extraArguments == main)
    }

    @Test("上限で断られていない error と、続ける設定が切ってある会話は待たない")
    func noUsageLimitWait() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (allowed, allowedHost, _, _, _) = try await make(configure: { context in
            context.now = { clock.now }
            context.continuesAtUsageLimit = { _, _ in true }
        })
        try await allowed.start(resume: false)
        let allowedBefore = await allowed.lastSeq
        await rejectTurn(allowedHost, resetsAt: clock.now.addingTimeInterval(3600), status: "allowed")
        #expect(await eventually { await allowed.lastSeq > allowedBefore })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await allowed.snapshot().limitResumeAt == nil)

        let (off, offHost, _, _, _) = try await make(configure: { context in
            context.now = { clock.now }
            context.continuesAtUsageLimit = { _, _ in false }
        })
        try await off.start(resume: false)
        let offBefore = await off.lastSeq
        await rejectTurn(offHost, resetsAt: clock.now.addingTimeInterval(3600))
        #expect(await eventually { await off.lastSeq > offBefore })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await off.snapshot().limitResumeAt == nil)
    }

    @Test("上限の後の続きは、人が送る・取り消す・止めると消える")
    func usageLimitWaitCleared() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _, _) = try await make(configure: { context in
            context.now = { clock.now }
            context.continuesAtUsageLimit = { _, _ in true }
        })
        try await conversation.start(resume: false)
        let resets = clock.now.addingTimeInterval(3600)

        await rejectTurn(host, resetsAt: resets)
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })
        _ = try await conversation.send(ConversationSendRequest(text: "先に進めて", clientMessageID: "ab4e28ba-2fa1-11d2-883f-0016d3cca427"))
        #expect(await conversation.snapshot().limitResumeAt == nil)

        await rejectTurn(host, resetsAt: resets)
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })
        _ = try await conversation.control(ConversationControlRequest(kind: .cancelLimitResume))
        #expect(await conversation.snapshot().limitResumeAt == nil)

        await rejectTurn(host, resetsAt: resets)
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })
        await conversation.stop(.person)
        #expect(await conversation.snapshot().limitResumeAt == nil)
        #expect(try store.conversation(id: conversation.id)?.limitResumeAt == nil)
    }

    @Test("時刻を過ぎた後に人が送ったら、その書き込みを待つ間に見回りが来ても続きを送らない")
    func usageLimitWaitClearedBeforeSendWrites() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, _, _, _) = try await make(configure: { context in
            context.now = { clock.now }
            context.continuesAtUsageLimit = { _, _ in true }
        })
        try await conversation.start(resume: false)
        await rejectTurn(host, resetsAt: clock.now.addingTimeInterval(3600))
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })
        clock.advance(3661)

        await host.setWriteDelay(.milliseconds(300))
        async let sent = conversation.send(ConversationSendRequest(text: "先に進めて", clientMessageID: "bb4e28ba-2fa1-11d2-883f-0016d3cca427"))
        try await Task.sleep(for: .milliseconds(100))
        await conversation.continueAfterLimit()
        _ = try await sent
        let users = await host.written().filter { $0["type"] as? String == "user" }
        #expect(users.count == 1)
        #expect(((users.first?["message"] as? [String: Any])?["content"] as? String) == "先に進めて")
    }

    @Test("時刻を過ぎた後に回答・知らせが先に入ったら、上限の後の続きは消え、送らない")
    func usageLimitWaitClearedByDelivery() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _, _) = try await make(configure: { context in
            context.now = { clock.now }
            context.continuesAtUsageLimit = { _, _ in true }
        })
        try await conversation.start(resume: false)
        await rejectTurn(host, resetsAt: clock.now.addingTimeInterval(3600))
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })
        clock.advance(3661)

        let uuid = "cb4e28ba-2fa1-11d2-883f-0016d3cca427"
        async let delivered = conversation.deliver(text: "知らせ", uuid: uuid, wake: .always)
        #expect(await eventually { await host.written().contains { $0["type"] as? String == "user" } })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"started"}"#)
        #expect(try await delivered == .delivered)
        #expect(await conversation.snapshot().limitResumeAt == nil)
        #expect(try store.conversation(id: conversation.id)?.limitResumeAt == nil)
        await conversation.continueAfterLimit()
        let users = await host.written().filter { $0["type"] as? String == "user" }
        #expect(users.count == 1)
        #expect(((users.first?["message"] as? [String: Any])?["content"] as? String) == "知らせ")
    }

    @Test("画像でない添付は、パスを uploaded_files の形で本文の頭に書く。無いファイル・相対パスは送らずに断る")
    func sendsFiles() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let file = FileManager.default.temporaryDirectory.appending(path: "claude-file-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let path = file.path(percentEncoded: false)
        _ = try await conversation.send(ConversationSendRequest(text: "読んで", files: [path]))
        let users = await host.written().filter { $0["type"] as? String == "user" }
        #expect(((users.last?["message"] as? [String: Any])?["content"] as? String) == MentionedFiles.compose("読んで", paths: [path], engine: .claude))
        for bad in [path + ".missing", "relative.pdf"] {
            await #expect(throws: ConversationError.self) { try await conversation.send(ConversationSendRequest(text: "x", files: [bad])) }
        }
        #expect(await host.written().filter { $0["type"] as? String == "user" }.count == 1)
    }

    @Test("添付が無くて送れなかった発言は、上限の後の続きを消さない")
    func usageLimitWaitKeptWhenAttachmentMissing() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, _, _, _) = try await make(configure: { context in
            context.now = { clock.now }
            context.continuesAtUsageLimit = { _, _ in true }
        })
        try await conversation.start(resume: false)
        await rejectTurn(host, resetsAt: clock.now.addingTimeInterval(3600))
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })
        await #expect(throws: ConversationError.self) {
            try await conversation.send(
                ConversationSendRequest(text: "これを見て", attachments: ["missing"], clientMessageID: "cb4e28ba-2fa1-11d2-883f-0016d3cca427"))
        }
        #expect(await conversation.snapshot().limitResumeAt != nil)
    }

    // MARK: ネットワークが戻った後の続き

    /// 回線が切れて終わったターン（本物の控えの最後の送り直しと result）
    private func offlineTurn(_ host: FakeHost, refused: Bool = false) async {
        await host.emit(ClaudeOfflineWire.lastRetry)
        await host.emit(refused ? ClaudeOfflineWire.refusedResult : ClaudeOfflineWire.droppedResult)
    }

    private func users(_ host: FakeHost) async -> [[String: Any]] {
        await host.written().filter { $0["type"] as? String == "user" }
    }

    /// 見回りが送った続きを CLI が受けた（モデルに渡った）ことにする
    private func acceptLast(_ host: FakeHost) async throws {
        let uuid = try #require(await users(host).last?["uuid"] as? String)
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"started"}"#)
    }

    @Test("繋がらずに終わったら印を記録に残し、繋がっていて間を過ぎたときだけ続きを送る")
    func continuesAfterNetwork() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _, _) = try await make(configure: { $0.now = { clock.now } })
        try await conversation.start(resume: false)
        await offlineTurn(host)
        #expect(await eventually { await conversation.snapshot().networkResume == true })
        let saved = try #require(try store.conversation(id: conversation.id))
        #expect(saved.networkResumeAt == clock.now.addingTimeInterval(30) && saved.networkResumeTries == 0)
        #expect(await conversation.snapshot().line(taskTitle: nil).contains("接続が戻ったら続きを送る"))

        // 繋がっていない間と、間を過ぎる前は送らない
        clock.advance(31)
        await conversation.continueAfterNetwork(online: false, returned: false)
        clock.advance(-30)
        await conversation.continueAfterNetwork(online: true, returned: false)
        #expect(await users(host).isEmpty)
        // 印は止まって待つ間も残る（自動で止めない）
        #expect(!(await conversation.isResting))

        clock.advance(30)
        async let resumed: Void = conversation.continueAfterNetwork(online: true, returned: false)
        #expect(await eventually { await !self.users(host).isEmpty })
        #expect(((await users(host).first?["message"] as? [String: Any])?["content"] as? String) == ClaudeConversation.networkResumeText)
        try await acceptLast(host)
        await resumed
        #expect(await conversation.snapshot().networkResume == nil)
        #expect(try store.conversation(id: conversation.id)?.networkResumeTries == 1)
        await conversation.continueAfterNetwork(online: true, returned: false)
        #expect(await users(host).count == 1, "送った続きは 1 回だけ")

        // 続きもまた繋がらずに終わった：間を広げて印を付け直す。誤りでなく終われば印と数を消す
        await offlineTurn(host, refused: true)
        #expect(await eventually { await conversation.snapshot().networkResume == true })
        #expect(try store.conversation(id: conversation.id)?.networkResumeAt == clock.now.addingTimeInterval(300))
        await host.emit(ClaudeOfflineWire.completedResult)
        #expect(await eventually { await conversation.snapshot().networkResume == nil })
        #expect(try store.conversation(id: conversation.id)?.networkResumeTries == 0)
    }

    @Test("続きを 3 回送っても繋がらなければ止め、経路が切れて戻ったら数え直してすぐ送る")
    func networkResumeGivesUp() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _, _) = try await make(configure: { $0.now = { clock.now } })
        try await conversation.start(resume: false)
        for sent in 1...3 {
            await offlineTurn(host)
            #expect(await eventually { await conversation.snapshot().networkResume == true })
            clock.advance(901)
            async let resumed: Void = conversation.continueAfterNetwork(online: true, returned: false)
            #expect(await eventually { await self.users(host).count == sent })
            try await acceptLast(host)
            await resumed
        }
        await offlineTurn(host)
        #expect(await eventually { await conversation.snapshot().networkResume == true })
        clock.advance(3600)
        await conversation.continueAfterNetwork(online: true, returned: false)
        #expect(await users(host).count == 3, "試し切ったら、経路が戻るまで送らない")
        #expect(await conversation.snapshot().networkResume == true, "印は残す")

        async let resumed: Void = conversation.continueAfterNetwork(online: true, returned: true)
        #expect(await eventually { await self.users(host).count == 4 })
        try await acceptLast(host)
        await resumed
        #expect(try store.conversation(id: conversation.id)?.networkResumeTries == 1)
    }

    @Test("ネットワークの続きの印は記録に残り、人が送る・回答が入る・取り消す・止めると消える")
    func networkResumeCleared() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _, _) = try await make(configure: { $0.now = { clock.now } })
        try await conversation.start(resume: false)

        await offlineTurn(host)
        #expect(await eventually { await conversation.snapshot().networkResume == true })
        _ = try await conversation.send(ConversationSendRequest(text: "先に進めて", clientMessageID: "db4e28ba-2fa1-11d2-883f-0016d3cca427"))
        #expect(await conversation.snapshot().networkResume == nil)

        await offlineTurn(host)
        #expect(await eventually { await conversation.snapshot().networkResume == true })
        let uuid = "eb4e28ba-2fa1-11d2-883f-0016d3cca427"
        async let delivered = conversation.deliver(text: "回答", uuid: uuid, wake: .always)
        #expect(await eventually { await self.users(host).count == 2 })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"started"}"#)
        #expect(try await delivered == .delivered)
        #expect(await conversation.snapshot().networkResume == nil)

        await offlineTurn(host)
        #expect(await eventually { await conversation.snapshot().networkResume == true })
        _ = try await conversation.control(ConversationControlRequest(kind: .cancelLimitResume))
        #expect(await conversation.snapshot().networkResume == nil)

        await offlineTurn(host)
        #expect(await eventually { await conversation.snapshot().networkResume == true })
        let saved = try #require(try store.conversation(id: conversation.id))
        #expect(Conversation(record: saved, machine: machine).networkResume == true, "止まった会話の形（記録から組む）にも印がある")
        await conversation.stop(.person)
        #expect(try store.conversation(id: conversation.id)?.networkResumeAt == nil)
        clock.advance(60)
        await conversation.continueAfterNetwork(online: true, returned: true)
        #expect(await users(host).count == 2)
    }

    @Test("定期起動の回には、ネットワークの続きの印を付けない")
    func networkResumeSkipped() async throws {
        let (scheduled, scheduledHost, _, _, _) = try await make(record: { task in
            var record = ConversationRecord(taskNumber: task, agentSessionId: "s1", cwd: "/w", model: "haiku", runner: .none)
            record.purpose = Conversation.Purpose.schedule.rawValue
            return record
        })
        try await scheduled.start(resume: false)
        let before = await scheduled.lastSeq
        await offlineTurn(scheduledHost)
        #expect(await eventually { await scheduled.lastSeq > before })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await scheduled.snapshot().networkResume == nil)
    }

    // MARK: 利用枠の上限の前に区切る

    private static let pause = MachineSettings.UsagePause(fiveHourPercent: 90, sevenDayPercent: 99)

    /// 窓を載せた `rate_limit_event`（上限には達していない）の後に、誤りでないターンの終わり
    private func usageTurn(_ host: FakeHost, fiveHour: (Double, Date)? = nil, sevenDay: (Double, Date)? = nil) async {
        var windows: [String] = []
        if let (used, resets) = fiveHour { windows.append(#""five_hour":{"utilization":\#(used),"resetsAt":\#(Int(resets.timeIntervalSince1970))}"#) }
        if let (used, resets) = sevenDay { windows.append(#""seven_day":{"utilization":\#(used),"resetsAt":\#(Int(resets.timeIntervalSince1970))}"#) }
        await host.emit(
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{\#(windows.joined(separator: ","))}},"session_id":"s1"}"#)
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
    }

    /// ターンの終わりまで読んだ（区切らなかったことを確かめる前に待つ）
    private func settled(_ conversation: ClaudeConversation, after seq: Int) async -> Bool {
        let done = await eventually { await conversation.lastSeq > seq }
        try? await Task.sleep(for: .milliseconds(50))
        return done
    }

    private func pausingConversation(_ clock: TestClock) async throws -> (ClaudeConversation, FakeHost, Store, Calls) {
        let (conversation, host, store, _, calls) = try await make(configure: { context in
            context.now = { clock.now }
            context.usagePause = { Self.pause }
        })
        try await conversation.start(resume: false)
        return (conversation, host, store, calls)
    }

    @Test("ターンの終わりに 5 時間の窓が閾値以上なら区切り、戻る時刻の 1 分後まで待つ。閾値の手前では区切らない。待つ間はほかの配送を入れない")
    func usagePauseThreshold() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _) = try await pausingConversation(clock)
        let resets = clock.now.addingTimeInterval(2 * 3600)

        let before = await conversation.lastSeq
        await usageTurn(host, fiveHour: (0.899, resets))
        #expect(await settled(conversation, after: before))
        #expect(await conversation.snapshot().limitResumeAt == nil, "89.9% は区切らない")

        await usageTurn(host, fiveHour: (0.9, resets))
        #expect(await eventually { await conversation.snapshot().limitResumeAt == resets.addingTimeInterval(60) })
        #expect(await conversation.snapshot().limitPaused)
        let saved = try #require(try store.conversation(id: conversation.id))
        #expect(saved.limitPaused && saved.limitResumeAt == resets.addingTimeInterval(60))
        #expect(try await conversation.deliver(text: "回答", uuid: "1c4e28ba-2fa1-11d2-883f-0016d3cca427", wake: .always) == .busy)
    }

    @Test("戻るまで 1 時間より長ければ、待つ前に /compact を送る。1 時間ちょうどなら送らない")
    func usagePauseCompactsBeyondCacheTTL() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (short, shortHost, _, _) = try await pausingConversation(clock)
        await usageTurn(shortHost, fiveHour: (0.95, clock.now.addingTimeInterval(3600)))
        #expect(await eventually { await short.snapshot().limitResumeAt != nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await Self.compactions(shortHost) == 0)

        let (long, longHost, _, _) = try await pausingConversation(clock)
        await usageTurn(longHost, fiveHour: (0.95, clock.now.addingTimeInterval(3601)))
        #expect(await eventually { await Self.compactions(longHost) == 1 })
        #expect(await long.snapshot().limitResumeAt != nil, "圧縮を送っても待ちは残す")
    }

    @Test("圧縮のターンの終わりでは区切るかを見ない。その次の返事の終わりからはまた見る")
    func usagePauseSkipsCompactionTurn() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, _, _) = try await pausingConversation(clock)
        let resets = clock.now.addingTimeInterval(2 * 3600)
        await usageTurn(host, fiveHour: (0.95, resets))
        #expect(await eventually { await Self.compactions(host) == 1 })
        // 人が待ちを取り消してから、圧縮のターンが終わる（窓はまだ閾値を越えている）
        _ = try await conversation.control(ConversationControlRequest(kind: .cancelLimitResume))
        let before = await conversation.lastSeq
        await usageTurn(host, fiveHour: (0.95, resets))
        #expect(await settled(conversation, after: before))
        #expect(await conversation.snapshot().limitResumeAt == nil, "圧縮のターンの終わりでは区切らない")

        await usageTurn(host, fiveHour: (0.95, resets))
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })
        #expect(await eventually { await Self.compactions(host) == 2 })
    }

    @Test("両方の窓が閾値を越えたら、戻るのが遅い方まで待つ。7 日の窓が閾値の手前なら 5 時間の窓で待つ")
    func usagePauseBothWindows() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fiveHour = clock.now.addingTimeInterval(2 * 3600)
        let sevenDay = clock.now.addingTimeInterval(3 * 86400)
        let (both, bothHost, _, _) = try await pausingConversation(clock)
        await usageTurn(bothHost, fiveHour: (0.95, fiveHour), sevenDay: (0.995, sevenDay))
        #expect(await eventually { await both.snapshot().limitResumeAt == sevenDay.addingTimeInterval(60) })

        let (one, oneHost, _, _) = try await pausingConversation(clock)
        await usageTurn(oneHost, fiveHour: (0.95, fiveHour), sevenDay: (0.98, sevenDay))
        #expect(await eventually { await one.snapshot().limitResumeAt == fiveHour.addingTimeInterval(60) })

        let (week, weekHost, _, _) = try await pausingConversation(clock)
        await usageTurn(weekHost, fiveHour: (0.5, fiveHour), sevenDay: (0.99, sevenDay))
        #expect(await eventually { await week.snapshot().limitResumeAt == sevenDay.addingTimeInterval(60) })
    }

    @Test("区切った待ちは、時刻を過ぎたら続きを送らずに消し、溜まった配送を流す（入力待ちに入ったときと同じ知らせ）")
    func usagePauseEnds() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, calls) = try await pausingConversation(clock)
        let resets = clock.now.addingTimeInterval(1800)
        await usageTurn(host, fiveHour: (0.95, resets))
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })

        await conversation.continueAfterLimit()
        #expect(await conversation.snapshot().limitResumeAt != nil, "時刻の前は解かない")
        let idleBefore = calls.all.filter { $0 == "idle:\(conversation.id)" }.count
        clock.advance(1861)
        await conversation.continueAfterLimit()
        #expect(await conversation.snapshot().limitResumeAt == nil)
        #expect(await !conversation.snapshot().limitPaused)
        #expect(try store.conversation(id: conversation.id)?.limitPaused == false)
        #expect(await eventually { calls.all.filter { $0 == "idle:\(conversation.id)" }.count == idleBefore + 1 })
        #expect(await host.written().filter { $0["type"] as? String == "user" }.isEmpty, "続きの発言は送らない")
    }

    @Test("daemon が起き直しても、区切った待ちは上限の待ちと見分け、続きを送らずに解く")
    func usagePauseSurvivesRestart() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, calls) = try await pausingConversation(clock)
        let resets = clock.now.addingTimeInterval(1800)
        await usageTurn(host, fiveHour: (0.95, resets))
        #expect(await eventually { await conversation.snapshot().limitResumeAt != nil })

        let newHost = FakeHost()
        let reopened = await reopen(conversation.id, store: store, host: newHost, calls: calls, configure: { $0.now = { clock.now } })
        #expect(await reopened.snapshot().limitPaused)
        #expect(await reopened.snapshot().limitResumeAt == resets.addingTimeInterval(60))
        clock.advance(1861)
        await reopened.continueAfterLimit()
        #expect(await reopened.snapshot().limitResumeAt == nil)
        #expect(await newHost.written().filter { $0["type"] as? String == "user" }.isEmpty)
    }

    @Test("区切る設定が無い会話と、誤りで終わったターンは区切らない")
    func usagePauseOff() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (off, offHost, _, _, _) = try await make(configure: { $0.now = { clock.now } })
        try await off.start(resume: false)
        let offBefore = await off.lastSeq
        await usageTurn(offHost, fiveHour: (0.99, clock.now.addingTimeInterval(7200)))
        #expect(await settled(off, after: offBefore))
        #expect(await off.snapshot().limitResumeAt == nil)

        let (errored, erroredHost, _, _) = try await pausingConversation(clock)
        let before = await errored.lastSeq
        await erroredHost.emit(
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.99,"resetsAt":\#(Int(clock.now.timeIntervalSince1970) + 7200)}}},"session_id":"s1"}"#)
        await erroredHost.emit(#"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s1"}"#)
        #expect(await settled(errored, after: before))
        #expect(await errored.snapshot().limitResumeAt == nil)
    }

    @Test("同じミリ秒に 2 つ目の知らせが残っても、時刻は前より後になり、1 つ目を届けた印で 2 つ目を消さない")
    func noticeTimesAdvance() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (conversation, host, store, _, _) = try await make(
            record: { task in
                var record = ConversationRecord(taskNumber: task, agentSessionId: "s1", cwd: "/w", model: "haiku", runner: .none)
                record.parentConversationId = "p1"
                record.notifyParent = true
                return record
            }, configure: { context in context.now = { clock.now } })
        try await conversation.start(resume: false)
        let endTurn = #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#
        await host.emit(endTurn)
        #expect(await eventually { (try? store.conversation(id: conversation.id))?.parentNoticeTurns == 1 })
        let first = try #require(try store.conversation(id: conversation.id)?.parentNoticeAt)
        await host.emit(endTurn)
        #expect(await eventually { (try? store.conversation(id: conversation.id))?.parentNoticeTurns == 2 })
        let second = try #require(try store.conversation(id: conversation.id)?.parentNoticeAt)
        #expect(second > first)
        await conversation.noticeDelivered(at: first)
        #expect(try store.conversation(id: conversation.id)?.parentNoticeAt == second)
        #expect(try store.conversation(id: conversation.id)?.parentNoticeTurns == 2)
    }

    // MARK: 読む画面とその場の操作（K4。応答は 2.1.303 の実物の形）

    private func request(_ host: FakeHost, _ subtype: String) async -> [String: Any]? {
        await host.written(subtype).last?["request"] as? [String: Any]
    }

    @Test("書き出しは本文と CLI が出すファイル名を返す。読むだけの 4 つは要る欄だけを写し、hook の中身や規則の読み下しの部品は写さない（書き換えには中身のハッシュの鍵と外せるかの印だけ）")
    func readouts() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("export_conversation", #"{"text":"\n❯ こんにちは\n\n⏺ はい\n","default_filename":"2026-10-20-070946-hello.txt"}"#)
        let export = try WireJSON.decoder().decode(
            ConversationExport.self, from: Data(try #require(try await conversation.control(.init(kind: .exportConversation)).payloadJSON).utf8))
        #expect(export == ConversationExport(text: "\n❯ こんにちは\n\n⏺ はい\n", defaultFilename: "2026-10-20-070946-hello.txt"))

        await host.setReply(
            "list_permission_rules",
            #"{"state":{"rules":[{"behavior":"allow","source":"userSettings","rule":"Bash(npm run:*)","description":{"prefix":"Any Bash command starting with","emphasis":"npm run"},"editability":"persistent"},{"behavior":"deny","source":"policySettings","rule":"WebFetch","editability":"readonly"}],"workspaceDirectories":[{"path":"/w/sub","source":"session"}],"originalCwd":"/w","managedOnly":false}}"#)
        let rules = try WireJSON.decoder().decode(
            ConversationPermissionRules.self, from: Data(try #require(try await conversation.control(.init(kind: .permissionRules)).payloadJSON).utf8))
        #expect(
            rules
                == ConversationPermissionRules(
                    rules: [
                        .init(behavior: "allow", source: "userSettings", rule: "Bash(npm run:*)", editable: true),
                        .init(behavior: "deny", source: "policySettings", rule: "WebFetch", editable: false),
                    ], directories: [.init(path: "/w/sub", source: "session")]))

        await host.setReply(
            "get_hooks_listing",
            #"{"events":[{"name":"PreToolUse","summary":"Before tool execution","supportsMatcher":true,"hookCount":1}],"hooks":[{"event":"PreToolUse","matcher":"Bash","source":"userSettings","sourceLabel":"User settings (~/.claude/settings.json)","type":"command","displayText":"check","commandText":"python3 check.py","contentLabel":"Command","timeout":5,"editable":{"config":{"secret":"x"}}}],"eventCatalog":[],"policy":{}}"#)
        let hooksJSON = try #require(try await conversation.control(.init(kind: .hooks)).payloadJSON)
        // CLI の editable の表（中身）は写さず、書き換えられるかの真偽だけを載せる
        #expect(!hooksJSON.contains("config") && !hooksJSON.contains("secret") && !hooksJSON.contains("User settings"))
        var hooks = try WireJSON.decoder().decode(ConversationHooks.self, from: Data(hooksJSON.utf8)).hooks
        #expect(hooks.first?.editKey?.count == 64)
        hooks[0].editKey = nil
        #expect(hooks == [.init(event: "PreToolUse", matcher: "Bash", source: "userSettings", type: "command", command: "python3 check.py", timeoutSeconds: 5, editable: true)])

        await host.setReply(
            "get_memory_dialog",
            #"{"files":[{"kind":"user","path":"/u/.claude/CLAUDE.md","label":"User instructions","description":"","exists":true},{"kind":"project","path":"/w/CLAUDE.md","label":"Project","description":"","exists":false}],"folders":[],"auto_memory":{"enabled":false}}"#)
        let memory = try WireJSON.decoder().decode(
            ConversationMemory.self, from: Data(try #require(try await conversation.control(.init(kind: .memory)).payloadJSON).utf8))
        #expect(memory.files == [.init(kind: "user", path: "/u/.claude/CLAUDE.md", exists: true), .init(kind: "project", path: "/w/CLAUDE.md", exists: false)])

        await host.setReply(
            "get_skills_dialog",
            #"{"skills":[{"name":"plugin:docs","display_name":"docs","description":"文書","source":"plugin","tokens":342,"state":"on","advertised":true,"handles":{}}]}"#)
        let skills = try WireJSON.decoder().decode(
            ConversationSkills.self, from: Data(try #require(try await conversation.control(.init(kind: .skills)).payloadJSON).utf8))
        #expect(skills.skills == [.init(name: "plugin:docs", displayName: "docs", description: "文書", source: "plugin", tokens: 342, state: "on")])

        // 形の違う応答は、空の一覧と読まずに失敗にする
        await host.setReply("get_skills_dialog", #"{"rows":[]}"#)
        await #expect(throws: ConversationError.self) { try await conversation.control(.init(kind: .skills)) }
    }

    @Test("裏のタスクは始まりの行の説明と種類を持って並べ、終わったら外す。出力と停止は id を渡し、id が空なら送らない")
    func backgroundTasks() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(#"{"type":"system","subtype":"task_started","task_id":"b1","description":"Run sleep 300","task_type":"local_bash","session_id":"s1"}"#)
        await host.emit(#"{"type":"system","subtype":"task_started","task_id":"b2","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().backgroundTasks == 2 })
        func list() async throws -> ConversationBackgroundTasks {
            try WireJSON.decoder().decode(
                ConversationBackgroundTasks.self, from: Data(try #require(try await conversation.control(.init(kind: .listBackgroundTasks)).payloadJSON).utf8))
        }
        #expect(try await list() == ConversationBackgroundTasks(tasks: [.init(id: "b1", type: "local_bash", description: "Run sleep 300"), .init(id: "b2")]))
        #expect(await host.written("list_background_tasks").isEmpty, "一覧は daemon が持っていて CLI に聞かない")

        await host.setReply("get_task_output", #"{"output":"\n[killed]\n","total_bytes":10,"truncated":false}"#)
        let output = try WireJSON.decoder().decode(
            ConversationTaskOutput.self, from: Data(try #require(try await conversation.control(.init(kind: .taskOutput, value: "b1")).payloadJSON).utf8))
        #expect(output == ConversationTaskOutput(output: "\n[killed]\n", totalBytes: 10, truncated: false))
        #expect(await request(host, "get_task_output")?["task_id"] as? String == "b1")
        await host.setReply("stop_task", "{}")
        _ = try await conversation.control(.init(kind: .stopTask, value: "b1"))
        #expect(await request(host, "stop_task")?["task_id"] as? String == "b1")
        await #expect(throws: ConversationError.self) { try await conversation.control(.init(kind: .stopTask, value: "")) }
        #expect(await host.written("stop_task").count == 1)

        await host.emit(#"{"type":"system","subtype":"task_notification","task_id":"b1","status":"killed","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().backgroundTasks == 1 })
        #expect(try await list().tasks.map(\.id) == ["b2"])
    }

    @Test("裏のタスクの様子：裏で動いているものと、終わったものの終わり方を載せる。前景で待っている task は載せず、プロセスが終わったら動いていたものは終わり方の分からない終了にする")
    func backgroundTaskStates() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        @Sendable func states() async -> [ConversationBackgroundTaskState]? { await conversation.snapshot().backgroundTaskStates }
        #expect(await states() == [])

        await host.emit(Self.taskStarted("b1", tool: "u1", backgrounded: true))
        await host.emit(Self.taskStarted("f1", tool: "u2"))
        await host.emit(#"{"type":"system","subtype":"task_started","task_id":"b2","session_id":"s1"}"#)
        await host.emit(Self.taskStarted("b3", tool: "u3", backgrounded: true))
        await host.emit(Self.taskStarted("b4", tool: "u4", backgrounded: true))
        #expect(await eventually { await states() == [.init(id: "b1", status: .running), .init(id: "b2", status: .running), .init(id: "b3", status: .running), .init(id: "b4", status: .running)] })

        await host.emit(#"{"type":"system","subtype":"task_notification","task_id":"b1","status":"completed","session_id":"s1"}"#)
        await host.emit(#"{"type":"system","subtype":"task_updated","task_id":"f1","patch":{"status":"completed"},"session_id":"s1"}"#)
        await host.emit(#"{"type":"system","subtype":"task_updated","task_id":"b2","patch":{"status":"killed"},"session_id":"s1"}"#)
        await host.emit(#"{"type":"system","subtype":"task_notification","task_id":"b3","status":"failed","session_id":"s1"}"#)
        #expect(await eventually {
            await states() == [.init(id: "b4", status: .running), .init(id: "b1", status: .completed), .init(id: "b2", status: .stopped), .init(id: "b3", status: .failed)]
        }, "前景で待っていた f1 は終わっても載せない")

        // 前景から裏に回したものは載せる
        await host.emit(Self.taskStarted("f2", tool: "u5"))
        await host.emit(#"{"type":"system","subtype":"task_updated","task_id":"f2","patch":{"is_backgrounded":true},"session_id":"s1"}"#)
        #expect(await eventually { await states()?.first { $0.id == "f2" }?.status == .running })

        await host.exit()
        #expect(await eventually {
            await states() == [.init(id: "b1", status: .completed), .init(id: "b2", status: .stopped), .init(id: "b3", status: .failed), .init(id: "b4", status: .ended), .init(id: "f2", status: .ended)]
        })
    }

    @Test("終わった裏のタスクは新しい順に 100 件まで覚える。CLI の一覧から知らせなしに消えたものは終わり方の分からない終了にし、後から知らせが来たら直す")
    func endedBackgroundTasksLimit() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        for n in 0...100 {
            await host.emit(Self.taskStarted("t\(n)", tool: "u\(n)", backgrounded: true))
            await host.emit(#"{"type":"system","subtype":"task_notification","task_id":"t\#(n)","status":"completed","session_id":"s1"}"#)
        }
        #expect(await eventually { await conversation.snapshot().backgroundTaskStates?.last?.id == "t100" })
        let ended = await conversation.snapshot().backgroundTaskStates ?? []
        #expect(ended.count == 100)
        #expect(ended.first?.id == "t1")

        await host.emit(Self.taskStarted("x", tool: "ux", backgrounded: true))
        await host.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[],"session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().backgroundTaskStates?.last == .init(id: "x", status: .ended) })
        await host.emit(#"{"type":"system","subtype":"task_notification","task_id":"x","status":"stopped","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().backgroundTaskStates?.last == .init(id: "x", status: .stopped) })
    }

    @Test("圧縮の間は様子に圧縮中（自動なら要約の字数）を載せ、compact_boundary・status: null・result・終了で消す。失敗は会話に知らせの行を残す")
    func compaction() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let notices = NoticeLog()
        let stream = await conversation.events(after: 0)
        let reader = Task { for await event in stream { if case .notice(let text) = event.kind { await notices.add(text) } } }
        defer { reader.cancel() }
        let compacting = #"{"type":"system","subtype":"status","status":"compacting","session_id":"s1"}"#

        await host.emit(compacting)
        #expect(await eventually { await conversation.snapshot().compaction != nil })
        #expect(await conversation.snapshot().compaction?.outputChars == nil)
        await host.emit(#"{"type":"system","subtype":"status","status":"compacting","compact_output_chars":420,"session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().compaction?.outputChars == 420 })
        await host.emit(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":180000},"session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().compaction == nil })

        await host.emit(compacting)
        #expect(await eventually { await conversation.snapshot().compaction != nil })
        await host.emit(#"{"type":"system","subtype":"status","status":null,"compact_result":"failed","compact_error":"Conversation too short","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().compaction == nil })
        #expect(await eventually { await notices.all == ["会話を圧縮できませんでした"] })

        await host.emit(compacting)
        #expect(await eventually { await conversation.snapshot().compaction != nil })
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"session_id":"s1","result":""}"#)
        #expect(await eventually { await conversation.snapshot().compaction == nil })

        await host.emit(compacting)
        #expect(await eventually { await conversation.snapshot().compaction != nil })
        await host.exit()
        #expect(await eventually { await conversation.snapshot().compaction == nil })
        #expect(await notices.all.first == "会話を圧縮できませんでした", "成功した圧縮では知らせない")
    }

    @Test("compact_boundary は前後のトークン数の区切りの行で流し、直後の要約の本文（isSynthetic の user）は流さない。その後の差し込みの文は流す")
    func compactionDivider() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.emit(Self.initLine("s1"))
        let stream = await conversation.events(after: 0)
        let reading = Task {
            var seen: [ChatMessage] = []
            for await event in stream {
                if case .messages(let messages, _) = event.kind { seen += messages }
            }
            return seen
        }
        // 2.1.310 の /compact の後に届く行
        await host.emit(
            #"{"type":"system","subtype":"compact_boundary","session_id":"s1","uuid":"d93e6e00","compact_metadata":{"trigger":"manual","pre_tokens":51832,"post_tokens":15968,"cumulative_dropped_tokens":35864,"duration_ms":4142},"logical_parent_uuid":"3c743c20"}"#)
        await host.emit(
            #"{"type":"user","session_id":"s1","parent_tool_use_id":null,"uuid":"fa788f8f","isReplay":false,"isSynthetic":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}"#)
        await host.emit(
            #"{"type":"user","session_id":"s1","parent_tool_use_id":null,"uuid":"e1","isSynthetic":true,"message":{"role":"user","content":"差し込みの文"}}"#)
        try await Task.sleep(for: .milliseconds(300))
        reading.cancel()
        let seen = await reading.value
        #expect(seen.map(\.text) == ["会話を圧縮しました（51,832→15,968トークン）", "差し込みの文"])
        #expect(seen.first?.id == "d93e6e00" && seen.first?.isCompactSummary == true, "transcript の区切りと同じ id")
    }

    @Test("生成中に api_retry が来たら様子に送り直し（回・上限・次に送る時刻）を載せ、主の流れの stream・発言・result、生成中でなくなること、終了で消す")
    func apiRetry() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        let running = #"{"type":"system","subtype":"session_state_changed","state":"running","session_id":"s1"}"#
        let retry = #"{"type":"system","subtype":"api_retry","attempt":3,"max_retries":10,"retry_delay_ms":12000,"error_status":null,"error":"unknown","session_id":"s1"}"#
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"続き"}},"api_message_id":"msg_1"}"#

        await host.emit(running)
        await host.emit(retry)
        #expect(await eventually { await conversation.snapshot().apiRetry != nil })
        let shown = try #require(await conversation.snapshot().apiRetry)
        #expect(shown.attempt == 3 && shown.maxRetries == 10 && shown.status == nil && shown.kind == "unknown")
        #expect(abs(shown.retryAt.timeIntervalSinceNow - 12) < 5, "受けた時刻 + 12 秒")
        // 回が進むたびに替わる
        await host.emit(#"{"type":"system","subtype":"api_retry","attempt":4,"max_retries":10,"retry_delay_ms":500,"error_status":529,"error":"overloaded","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().apiRetry?.attempt == 4 })
        #expect(await conversation.snapshot().apiRetry?.status == 529)

        // サブエージェントの中の stream では消さない
        await host.emit(#"{"type":"stream_event","event":{"type":"message_start","message":{"model":"m"}},"api_message_id":"msg_sub","parent_tool_use_id":"toolu_x"}"#)
        await host.emit(retry)
        #expect(await eventually { await conversation.snapshot().apiRetry?.attempt == 3 })
        await host.emit(delta)
        #expect(await eventually { await conversation.snapshot().apiRetry == nil })

        await host.emit(retry)
        #expect(await eventually { await conversation.snapshot().apiRetry != nil })
        await host.emit(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"こんにちは"}]},"uuid":"a1","parent_tool_use_id":null}"#)
        #expect(await eventually { await conversation.snapshot().apiRetry == nil })

        await host.emit(retry)
        #expect(await eventually { await conversation.snapshot().apiRetry != nil })
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"session_id":"s1","result":""}"#)
        #expect(await eventually { await conversation.snapshot().apiRetry == nil })

        await host.emit(running)
        await host.emit(retry)
        #expect(await eventually { await conversation.snapshot().apiRetry != nil })
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().apiRetry == nil })

        await host.emit(running)
        await host.emit(retry)
        #expect(await eventually { await conversation.snapshot().apiRetry != nil })
        await host.exit()
        #expect(await eventually { await conversation.snapshot().apiRetry == nil })
    }

    @Test("daemon が起き直して控えを読み直す間の api_retry は、様子に載せない（古い送り直しを今のものとして出さない）。その後に届いた行は載せる")
    func apiRetryNotFromReplay() async throws {
        let (conversation, host, _, _, _) = try await make()
        let retry = #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":1000,"error_status":null,"error":"unknown","session_id":"s1"}"#
        await host.keep(#"{"type":"system","subtype":"session_state_changed","state":"running","session_id":"s1"}"#)
        await host.keep(retry)
        await host.setPending([], state: "running")
        await conversation.attach(process: AgentHostProcessInfo(key: conversation.id, pid: 42, alive: true, lastSeq: 2, firstSeq: 1, keptBytes: 10, startedAt: 0))
        #expect(await eventually { await conversation.snapshot().phase == .running })
        #expect(await conversation.snapshot().apiRetry == nil)
        await host.emit(retry)
        #expect(await eventually { await conversation.snapshot().apiRetry != nil })
    }

    @Test("生成中に CLI から行が来ないまま stall を超えると、様子に止まりの時刻を載せ、行が来たら消す。結果の来ていないツールの間と、生成中でない間は数えない")
    func stall() async throws {
        let (conversation, host, _, _, _) = try await make(configure: { $0.timing.stall = .milliseconds(200) })
        try await conversation.start(resume: false)
        let running = #"{"type":"system","subtype":"session_state_changed","state":"running","session_id":"s1"}"#
        await host.emit(running)
        #expect(await eventually { await conversation.snapshot().stalledSince != nil })
        await host.emit(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"続き"}},"api_message_id":"msg_1"}"#)
        #expect(await eventually { await conversation.snapshot().stalledSince == nil })

        // ツールの実行中（長い Bash）は数えない
        await host.emit(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_b","name":"Bash","input":{"command":"make"}}]},"uuid":"a1","parent_tool_use_id":null}"#)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await conversation.snapshot().stalledSince == nil)
        await host.emit(#"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_b","type":"tool_result","content":"ok"}]},"uuid":"u1","parent_tool_use_id":null}"#)
        #expect(await eventually { await conversation.snapshot().stalledSince != nil })

        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().stalledSince == nil })
        try await Task.sleep(for: .milliseconds(400))
        #expect(await conversation.snapshot().stalledSince == nil, "空いている間は止まりにしない")
    }

    @Test("中断に CLI が応えてもターンが終わらなければ、止めて --resume で起こし直し、待ち行列にあった発言を同じ uuid で 1 回だけ入れ直して知らせる")
    func interruptEscalation() async throws {
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.timing.interruptAnswer = .milliseconds(300)
            $0.timing.interruptResult = .milliseconds(300)
        })
        try await conversation.start(resume: false)
        let notices = NoticeLog()
        let stream = await conversation.events(after: 0)
        let reader = Task { for await event in stream { if case .notice(let text) = event.kind { await notices.add(text) } } }
        defer { reader.cancel() }
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .running })

        let uuid = UUID().uuidString.lowercased()
        @Sendable func userLines() async -> Int { await host.written().filter { $0["type"] as? String == "user" && $0["uuid"] as? String == uuid }.count }
        let sending = Task { try await conversation.send(ConversationSendRequest(text: "いまなにやってる？", clientMessageID: uuid)) }
        #expect(await eventually { await userLines() == 1 })
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"queued","session_id":"s1"}"#)
        _ = try await sending.value

        await host.setReply("interrupt", #"{"still_queued":[]}"#)
        let response = try await conversation.control(ConversationControlRequest(kind: .interrupt))
        #expect(response.payloadJSON == #"{"restarted":true}"#)
        let spawns = await host.requests.filter { $0.op == .spawn }
        #expect(spawns.count == 2 && spawns.last?.argv?.contains("--resume") == true)
        #expect(await userLines() == 2, "起こし直した CLI に入れ直す")
        #expect(await conversation.received(uuid), "待ち行列の発言を取り消さない")
        #expect(await eventually { await notices.all == ["応答がなかったため、Claude Codeを再起動しました"] })

        // 入れ直した発言が始まった後は、もう一度起こし直しても入れない
        await host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"started","session_id":"s1"}"#)
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .running })
        _ = try await conversation.control(ConversationControlRequest(kind: .interrupt))
        #expect(await host.requests.filter { $0.op == .spawn }.count == 3)
        #expect(await userLines() == 2)
    }

    @Test("中断に CLI が応えてターンが終われば、起こし直さない")
    func interruptAnswered() async throws {
        let (conversation, host, _, _, _) = try await make(configure: {
            $0.timing.interruptAnswer = .milliseconds(300)
            $0.timing.interruptResult = .milliseconds(300)
        })
        try await conversation.start(resume: false)
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running","session_id":"s1"}"#)
        #expect(await eventually { await conversation.snapshot().phase == .running })
        let response = try await conversation.control(ConversationControlRequest(kind: .interrupt))
        #expect(response.payloadJSON?.contains("restarted") != true)
        #expect(await host.requests.filter { $0.op == .spawn }.count == 1)
        #expect(await host.written("interrupt").first.flatMap { ($0["request"] as? [String: Any])?["cancel_queued"] as? Bool } == true)
    }

    @Test("脇の質問は前後の空白を落として送り、答えの文だけを返す。空の質問は送らない")
    func sideQuestion() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("side_question", #"{"response":"sleep を頼みました。","synthetic":false}"#)
        let answer = try WireJSON.decoder().decode(
            ConversationSideAnswer.self,
            from: Data(try #require(try await conversation.control(.init(kind: .sideQuestion, value: "  何を頼んだ？\n")).payloadJSON).utf8))
        #expect(answer == ConversationSideAnswer(response: "sleep を頼みました。"))
        #expect(await request(host, "side_question")?["question"] as? String == "何を頼んだ？")
        await #expect(throws: ConversationError.self) { try await conversation.control(.init(kind: .sideQuestion, value: " \n")) }
        #expect(await host.written("side_question").count == 1)
    }

    @Test("作業フォルダの追加は register_repo_root に渡し、CLI の断りはそのまま失敗にする。絶対パスでなければ送らない")
    func addDirectory() async throws {
        let (conversation, host, _, _, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply("register_repo_root", #"{"directory":"/private/w/sub"}"#)
        let added = try WireJSON.decoder().decode(
            ConversationDirectoryAdded.self, from: Data(try #require(try await conversation.control(.init(kind: .addDirectory, value: "/w/sub")).payloadJSON).utf8))
        #expect(added == ConversationDirectoryAdded(directory: "/private/w/sub"))
        #expect(await request(host, "register_repo_root")?["directory"] as? String == "/w/sub")
        await host.setRefusal("register_repo_root", "register_repo_root: /other is not a subdirectory of the session's working directory")
        await #expect(throws: ConversationError.self) { try await conversation.control(.init(kind: .addDirectory, value: "/other")) }
        await #expect(throws: ConversationError.self) { try await conversation.control(.init(kind: .addDirectory, value: "sub")) }
        #expect(await host.written("register_repo_root").count == 2)
    }

    @Test("作業フォルダの変更は ok のときだけ記録の作業フォルダを替える。needs_trust と rejected は記録を変えず、CLI の文（パス）は写さない")
    func setCwd() async throws {
        let (conversation, host, store, _, _) = try await make()
        try await conversation.start(resume: false)
        func change(_ path: String) async throws -> ConversationCwdChange {
            try WireJSON.decoder().decode(
                ConversationCwdChange.self, from: Data(try #require(try await conversation.control(.init(kind: .setCwd, value: path)).payloadJSON).utf8))
        }
        await host.setReply("set_cwd", #"{"status":"needs_trust","directory":"/Users/u/new"}"#)
        #expect(try await change("~/new") == ConversationCwdChange(outcome: .needsTrust, directory: "/Users/u/new"))
        #expect(await request(host, "set_cwd")?["path"] as? String == "~/new")
        #expect(await request(host, "set_cwd")?["trust_accepted"] == nil, "信頼をアプリが代わりに与えない")
        #expect(try store.conversation(id: conversation.id)?.cwd == "/w")

        await host.setReply("set_cwd", #"{"status":"rejected","reason":"not_found","message":"Couldn't find a directory at /secret/path."}"#)
        let rejected = try #require(try await conversation.control(.init(kind: .setCwd, value: "/secret/path")).payloadJSON)
        #expect(!rejected.contains("Couldn't") && !rejected.contains("/secret/path"))
        #expect(try WireJSON.decoder().decode(ConversationCwdChange.self, from: Data(rejected.utf8)) == ConversationCwdChange(outcome: .rejected, reason: "not_found"))
        #expect(try store.conversation(id: conversation.id)?.cwd == "/w")

        await host.setReply("set_cwd", #"{"status":"ok","cwd":"/private/tmp/b","changed":true,"transcript_relocated":true}"#)
        #expect(try await change("/tmp/b") == ConversationCwdChange(outcome: .moved, directory: "/private/tmp/b"))
        #expect(try store.conversation(id: conversation.id)?.cwd == "/private/tmp/b")
        #expect(await conversation.snapshot().cwd == "/private/tmp/b")
        await #expect(throws: ConversationError.self) { try await conversation.control(.init(kind: .setCwd, value: "relative")) }
    }

}

private actor DiffAnswers {
    private var answers: [ConversationDiffSummary?]
    private(set) var count = 0
    private(set) var cwds: [String] = []

    init(_ answers: [ConversationDiffSummary?]) { self.answers = answers }

    func next(_ cwd: String) -> ConversationDiffSummary? {
        count += 1
        cwds.append(cwd)
        return answers.isEmpty ? nil : answers.removeFirst()
    }

}

/// 利用枠の報告と、get_usage を引いてよいかの答え（1 回目だけ true）
private actor Reports {
    private(set) var all: [ClaudeUsageReport] = []
    private var claimed = false
    var count: Int { all.count }
    func add(_ report: ClaudeUsageReport) { all.append(report) }
    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}

extension ClaudeConversationTests {
    @Test("見張り盤の値：ターンの始まりの時刻、使っているツール（始まりと終わり）、最後の応答の頭を記録に残し、daemon の入れ替えの後も出す")
    func turnActivity() async throws {
        let tools = Calls()
        let (conversation, host, store, _, calls) = try await make(configure: { $0.publishTool = { tools.add("\($0):\($1 ?? "-")") } })
        try await conversation.start(resume: false)
        let id = conversation.id
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        #expect(await eventually { await conversation.snapshot().turnStartedAt != nil })
        await host.emit(Self.toolUse("toolu_1", "Bash"))
        #expect(await eventually { tools.all == ["\(id):Bash"] })
        await host.emit(Self.toolResult("toolu_1"))
        #expect(await eventually { tools.all == ["\(id):Bash", "\(id):-"] })
        let long = String(repeating: "あ", count: 230)
        await host.emit(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"途中の文"}]},"uuid":"a-t1","parent_tool_use_id":null}"#)
        await host.emit(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(long)"}]},"uuid":"a-t2","parent_tool_use_id":null}"#)
        await host.emit(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"サブエージェントの文"}]},"uuid":"a-t3","parent_tool_use_id":"toolu_x"}"#)
        await host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#)
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)
        #expect(await eventually { await conversation.snapshot().lastReply != nil })
        let snapshot = await conversation.snapshot()
        #expect(snapshot.lastReply?.text == String(repeating: "あ", count: 200), "主の流れの最後の応答の頭")
        let record = try #require(try store.conversation(id: id))
        #expect(record.lastReply == snapshot.lastReply?.text && record.lastReplyAt == snapshot.lastReply?.at)
        #expect(record.turnStartedAt == snapshot.turnStartedAt)
        // 次のターン：応答の無いまま終わったら、前の応答を残す
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        await host.emit(#"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s1"}"#)
        await host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)
        #expect(await eventually { calls.all.filter { $0 == "idle:\(id)" }.count == 2 })
        #expect(await conversation.snapshot().lastReply == snapshot.lastReply)
        // 止まった会話の形（記録から組む）にも出る
        let stopped = Conversation(record: try #require(try store.conversation(id: id)), machine: machine)
        #expect(stopped.lastReply == snapshot.lastReply && stopped.turnStartedAt != nil)
    }
}
