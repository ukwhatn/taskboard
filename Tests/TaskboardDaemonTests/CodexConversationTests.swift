import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// thread を持つ codex app-server の偽物。こちらの要求に、method ごとの応答と、turn/start の後の通知を返す（行の形は 0.162.1 の実測）
final class FakeThreadServer: @unchecked Sendable {
    private let lock = NSLock()
    private var turns = 0
    private var thread = "th-1"
    /// turn/start の後に流す通知。`$TURN` は turn の id、`$CLIENT` は送った uuid、`$THREAD` は thread の id
    private var turnLines: [String] = FakeThreadServer.reply("こんにちは")
    private var usdMicros = 250_000

    func setThread(_ id: String) { lock.withLock { thread = id } }
    /// 次の thread/resume をこの回数だけ「書き手がいる」で断る
    private var resumeRefusals = 0
    func refuseResume(times: Int) { lock.withLock { resumeRefusals = times } }
    func setTurnLines(_ lines: [String]) { lock.withLock { turnLines = lines } }
    /// method の応答を差し替える。1 回ごとに頭から使い、最後の 1 つは使い続ける。`$THREAD` は thread の id。`noReply` は応答しない（テストが後から流す）
    private var results: [String: [String]] = [:]
    func setResults(_ method: String, _ jsons: [String]) { lock.withLock { results[method] = jsons } }

    /// turn が始まり、人の発言・返事の差分・返事・トークン・終わりを流す
    static func reply(_ text: String) -> [String] {
        [
            #"{"method":"turn/started","params":{"threadId":"$THREAD","turn":{"id":"$TURN","status":"inProgress","error":null,"durationMs":null}}}"#,
            #"{"method":"item/started","params":{"threadId":"$THREAD","turnId":"$TURN","item":{"type":"userMessage","id":"u-$TURN","clientId":"$CLIENT","content":[{"type":"text","text":"送った文","text_elements":[]}]}}}"#,
            #"{"method":"item/completed","params":{"threadId":"$THREAD","turnId":"$TURN","item":{"type":"userMessage","id":"u-$TURN","clientId":"$CLIENT","content":[{"type":"text","text":"送った文","text_elements":[]}]}}}"#,
            #"{"method":"item/started","params":{"threadId":"$THREAD","turnId":"$TURN","item":{"type":"agentMessage","id":"a-$TURN","text":""}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"$THREAD","turnId":"$TURN","itemId":"a-$TURN","delta":"こん"}}"#,
            #"{"method":"item/completed","params":{"threadId":"$THREAD","turnId":"$TURN","item":{"type":"agentMessage","id":"a-$TURN","text":"\#(text)"}}}"#,
            #"{"method":"thread/tokenUsage/updated","params":{"threadId":"$THREAD","turnId":"$TURN","tokenUsage":{"total":{"totalTokens":26992,"inputTokens":26945,"cachedInputTokens":12288,"cacheWriteInputTokens":0,"outputTokens":47,"reasoningOutputTokens":0},"last":{"totalTokens":25840,"inputTokens":25800,"cachedInputTokens":12288,"cacheWriteInputTokens":0,"outputTokens":40,"reasoningOutputTokens":0},"modelContextWindow":258400}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"$THREAD","turn":{"id":"$TURN","status":"completed","error":null,"durationMs":1200}}}"#,
        ]
    }

    static let noReply = "<no reply>"

    static let started = [#"{"method":"turn/started","params":{"threadId":"$THREAD","turn":{"id":"$TURN","status":"inProgress","error":null,"durationMs":null}}}"#]

    func respond(_ line: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let method = object["method"] as? String,
            let id = object["id"] as? String
        else { return [] }
        let params = object["params"] as? [String: Any] ?? [:]
        return lock.withLock {
            func result(_ json: String) -> String { #"{"id":"\#(id)","result":\#(json)}"# }
            if var queue = results[method], let next = queue.first {
                if queue.count > 1 { queue.removeFirst() }
                results[method] = queue
                if next == Self.noReply { return [] }
                return [next.hasPrefix(#"{"error""#) ? next.replacingOccurrences(of: "$ID", with: id) : result(next.replacingOccurrences(of: "$THREAD", with: thread))]
            }
            switch method {
            case "initialize":
                return [result(#"{"userAgent":"taskboard/0.162.1 (Mac OS 26.7.1; arm64)"}"#)]
            case "thread/start":
                return [result(#"{"thread":{"id":"\#(thread)","cliVersion":"0.162.1","name":null},"model":"gpt-6.1-sol","reasoningEffort":"medium"}"#)]
            case "thread/resume":
                let resumed = params["threadId"] as? String ?? thread
                if resumeRefusals > 0 {
                    resumeRefusals -= 1
                    return [#"{"id":"\#(id)","error":{"code":-32600,"message":"thread \#(resumed) already has an active writer"}}"#]
                }
                thread = resumed
                return [result(#"{"thread":{"id":"\#(resumed)","cliVersion":"0.162.1","name":null},"model":"gpt-6.1-sol","reasoningEffort":"medium"}"#)]
            case "turn/start":
                turns += 1
                let turn = "turn-\(turns)"
                let client = params["clientUserMessageId"] as? String ?? ""
                return [result(#"{"turn":{"id":"\#(turn)","status":"inProgress","error":null,"durationMs":null}}"#)]
                    + turnLines.map {
                        $0.replacingOccurrences(of: "$TURN", with: turn).replacingOccurrences(of: "$CLIENT", with: client).replacingOccurrences(
                            of: "$THREAD", with: thread)
                    }
            case "turn/interrupt":
                let turn = params["turnId"] as? String ?? ""
                return [
                    result("{}"),
                    #"{"method":"turn/completed","params":{"threadId":"\#(thread)","turn":{"id":"\#(turn)","status":"interrupted","error":null,"durationMs":300}}}"#,
                ]
            case "thread/queue/list":
                return [result(#"{"data":[],"nextCursor":null}"#)]
            case "account/usage/read":
                return [result(#"{"threadUsage":{"threadId":"\#(thread)","estimatedUsageUsdMicros":\#(usdMicros)}}"#)]
            default:
                return [result("{}")]
            }
        }
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ConversationEvent.Kind] = []
    func add(_ value: ConversationEvent.Kind) { lock.withLock { values.append(value) } }
    var all: [ConversationEvent.Kind] { lock.withLock { values } }

    var messages: [ChatMessage] {
        all.flatMap { kind -> [ChatMessage] in
            if case .messages(let messages, _) = kind { return messages }
            return []
        }
    }
}

@Suite("codex の会話（偽の app-server）", .serialized)
struct CodexConversationTests {
    private let machine = MachineID(rawValue: "m-codex")

    private struct World {
        let conversation: CodexConversation
        let host: FakeHost
        let server: FakeThreadServer
        let store: Store
        let events: Events
        let id: String
        let context: CodexConversation.Context
        let logs: LogLines
    }

    private func make(
        agentSessionID: String? = nil, permissionMode: String? = nil, configure: (inout CodexConversation.Context) -> Void = { _ in }
    ) async throws -> World {
        let logs = LogLines()
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        let id = UUID().uuidString.lowercased()
        let saved = try store.createConversation(
            ConversationRecord(
                id: id, taskNumber: task.number, engine: .codex, agentSessionId: agentSessionID ?? id, cwd: "/w", permissionMode: permissionMode,
                runner: .none))
        let host = FakeHost()
        let server = FakeThreadServer()
        await host.setResponder(server.respond)
        var context = CodexConversation.Context(
            shared: ConversationContext(
                machine: machine, store: store, host: host, launch: { EngineLaunch(executable: "/x/codex", environment: ["PATH": "/usr/bin"]) },
                attachments: nil, guide: { _ in "案内" }, becameIdle: { _ in }, logger: logs.logger))
        var timing = ConversationTiming()
        timing.control = .seconds(2)
        timing.mcpStatus = .milliseconds(400)
        timing.stopResult = .milliseconds(300)
        timing.stopInput = .milliseconds(300)
        timing.stopTerm = .milliseconds(300)
        timing.deltaBatch = .milliseconds(5)
        timing.replay = .seconds(2)
        context.timing = timing
        context.writerRetryDelay = .milliseconds(10)
        context.epoch = "e1"
        context.taskboardMCP = .init(command: "/x/taskboard", args: ["mcp"])
        configure(&context)
        let conversation = CodexConversation(record: saved, context: context)
        await host.connect(conversation.inbox, key: id)
        let events = Events()
        let stream = await conversation.events(after: 0)
        Task { for await event in stream { events.add(event.kind) } }
        return World(conversation: conversation, host: host, server: server, store: store, events: events, id: id, context: context, logs: logs)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func sent(_ host: FakeHost, _ method: String) async -> [[String: Any]] {
        await host.written().filter { $0["method"] as? String == method }
    }

    private func params(_ host: FakeHost, _ method: String) async -> [String: Any]? {
        await sent(host, method).last?["params"] as? [String: Any]
    }

    @Test("起こす：握手の後に thread を始め、thread の ID を会話 ID にする。案内と taskboard の MCP を thread に入れ、権限の既定は確認なし")
    func startsThread() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let methods = await world.host.written().compactMap { $0["method"] as? String }
        #expect(Array(methods.prefix(3)) == ["initialize", "initialized", "thread/start"])
        let start = await params(world.host, "thread/start")
        #expect(start?["approvalPolicy"] as? String == "never")
        #expect(start?["sandbox"] as? String == "danger-full-access")
        #expect(start?["developerInstructions"] as? String == "案内")
        let mcp = (start?["config"] as? [String: Any])?["mcp_servers.taskboard"] as? [String: Any]
        #expect(mcp?["command"] as? String == "/x/taskboard")
        #expect((mcp?["env"] as? [String: String])?["TASKBOARD_CONVERSATION_ID"] == world.id)
        let spawn = await world.host.requests.first { $0.op == .spawn }
        #expect(spawn?.argv == ["/x/codex", "app-server"])
        #expect(spawn?.env?["TASKBOARD_CONVERSATION_ID"] == world.id)
        #expect(try world.store.conversation(id: world.id)?.agentSessionId == "th-1")
        let snapshot = await world.conversation.snapshot()
        #expect(snapshot.agentSessionID == "th-1")
        #expect(snapshot.stats?.engineVersion == "0.162.1")
        #expect(snapshot.stats?.model == "gpt-6.1-sol")
        #expect(await world.conversation.isIdle)
    }

    @Test("戻す：thread のある会話は thread/resume で戻し、会話 ID はそのまま")
    func resumesThread() async throws {
        let world = try await make(agentSessionID: "01a155e3-fd51-7280-b5d9-1aa7373b5880")
        try await world.conversation.start(resume: true)
        #expect(await sent(world.host, "thread/start").isEmpty)
        let resume = await params(world.host, "thread/resume")
        #expect(resume?["threadId"] as? String == "01a155e3-fd51-7280-b5d9-1aa7373b5880")
        #expect(resume?["excludeTurns"] as? Bool == true)
        #expect(try world.store.conversation(id: world.id)?.agentSessionId == "01a155e3-fd51-7280-b5d9-1aa7373b5880")
    }

    @Test("戻す：ほかの process が thread の書き手のうち（端末の TUI が終わりきる前）は、間をおいて試し直す")
    func retriesWhileAnotherWriterHoldsThread() async throws {
        let world = try await make(agentSessionID: "01a155e3-fd51-7280-b5d9-1aa7373b5880")
        world.server.refuseResume(times: 2)
        try await world.conversation.start(resume: true)
        #expect(await sent(world.host, "thread/resume").count == 3)
        #expect(await world.conversation.isIdle)
    }

    @Test("画像でない添付は、パスを Files mentioned by the user の形で本文の頭に書く。無いファイル・相対パスは送らずに断る")
    func sendsFiles() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let file = FileManager.default.temporaryDirectory.appending(path: "codex-file-\(UUID().uuidString).md")
        try Data("中身".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let path = file.path(percentEncoded: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "読んで", files: [path]))
        let turn = await params(world.host, "turn/start")
        #expect((turn?["input"] as? [[String: Any]])?.first?["text"] as? String == MentionedFiles.compose("読んで", paths: [path], engine: .codex))
        for bad in [path + ".missing", "relative.md"] {
            await #expect(throws: ConversationError.self) { try await world.conversation.send(ConversationSendRequest(text: "x", files: [bad])) }
        }
        #expect(await sent(world.host, "turn/start").count == 1)
    }

    @Test("待っている発言の取り消しと今すぐ送る：待ち行列に入れていない発言には、取り消せない・待っているものは無いと返し、codex に何も送らない")
    func nothingQueued() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let cancel = try await world.conversation.control(ConversationControlRequest(kind: .cancelQueued, value: UUID().uuidString))
        #expect(try JSONDecoder().decode(ConversationQueuedCancel.self, from: Data(try #require(cancel.payloadJSON).utf8)).cancelled == false)
        let now = try await world.conversation.control(ConversationControlRequest(kind: .sendNow, value: UUID().uuidString))
        #expect(try JSONDecoder().decode(ConversationSendNow.self, from: Data(try #require(now.payloadJSON).utf8)).outcome == .nothingWaiting)
        for method in ["thread/queue/delete", "thread/queue/start", "turn/steer"] { #expect(await sent(world.host, method).isEmpty, "\(method)") }
    }

    @Test("送る：turn/start に uuid と権限を載せ、人の発言・返事・ターンの終わりを流し、費用とコンテキストを取る")
    func sendsAndStreams() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let uuid = UUID().uuidString.lowercased()
        #expect(try await world.conversation.send(ConversationSendRequest(text: "送った文", clientMessageID: uuid)) == .accepted)
        let turn = await params(world.host, "turn/start")
        #expect(turn?["clientUserMessageId"] as? String == uuid)
        #expect(turn?["approvalPolicy"] as? String == "never")
        #expect(turn?["sandboxPolicy"] == nil)
        #expect((turn?["input"] as? [[String: Any]])?.first?["text"] as? String == "送った文")
        #expect(await eventually { world.events.all.contains { if case .turn = $0 { true } else { false } } })
        let messages = world.events.messages
        #expect(messages.contains { $0.id == uuid && $0.role == .user && $0.text == "送った文" })
        #expect(messages.contains { $0.id == "a-turn-1" && $0.role == .assistant && $0.text == "こんにちは" })
        #expect(await world.conversation.received(uuid))
        #expect(try await world.conversation.send(ConversationSendRequest(text: "送った文", clientMessageID: uuid)) == .duplicate)
        #expect(await eventually { await world.conversation.snapshot().stats?.costUSD == 0.25 })
        let snapshot = await world.conversation.snapshot()
        #expect(snapshot.phase == .idle)
        // 入力の 26,945 は cached の 12,288 を含む
        #expect(snapshot.stats?.tokens == ConversationStats.Tokens(input: 14_657, output: 47, cacheRead: 12_288, cacheWrite: 0))
        #expect(snapshot.contextPercent == 10)
        #expect(try world.store.conversation(id: world.id)?.recentMessages.contains(uuid) == true)
    }

    @Test("記録に前の agent host の行の番号が残っていても、起こした後のターンの終わりを数えて起こした側への知らせを残す")
    func countsTurnsAfterHostRestart() async throws {
        let world = try await make()
        // 前の host で数えた最後の行の番号。起き直した host は 1 から振り直すので、新しい子の行はこれより小さい
        _ = try world.store.updateConversation(id: world.id) {
            $0.notifyParent = true
            $0.parentNoticeSeq = 1000
        }
        try await world.conversation.start(resume: false)
        #expect(try await world.conversation.send(ConversationSendRequest(text: "送った文", clientMessageID: UUID().uuidString.lowercased())) == .accepted)
        #expect(await eventually { (try? world.store.conversation(id: world.id))??.parentNoticeTurns == 1 })
    }

    @Test("ターンが失敗したら、会話に「応答できませんでした」の印を出す（codex の誤りの文は画面に出さずログへ）")
    func failedTurnLeavesNotice() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "頼む", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(
            #"{"method":"turn/completed","params":{"threadId":"th-1","turn":{"id":"turn-1","status":"failed","error":{"message":"stream disconnected before completion"},"durationMs":10}}}"#)
        #expect(await eventually { world.events.all.contains { if case .turn(let turn) = $0 { turn.isError } else { false } } })
        let notices = world.events.messages.filter { $0.kind == .notice }
        #expect(notices.map(\.text) == ["応答できませんでした。時間をおいて、やり直してください。"])
        #expect(!notices.contains { $0.text.contains("stream disconnected") })
        // 空きにするのは、ターンの終わりを知らせてから host の控えを捨てる往復（trim）の後
        #expect(await eventually { await world.conversation.snapshot().phase == .idle })
    }

    @Test("承認：server の要求を問いにし、答えを要求の id で返し、serverRequest/resolved で消す")
    func approvals() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "触る", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(
            #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"th-1","turnId":"turn-1","itemId":"exec-1","command":"/bin/zsh -lc 'touch a.txt'","cwd":"/w","availableDecisions":["accept","acceptForSession",{"acceptWithExecpolicyAmendment":{}},"decline"]}}"#
        )
        #expect(await eventually { await world.conversation.snapshot().pending.count == 1 })
        let request = try #require(await world.conversation.snapshot().pending.first)
        #expect(request.id == "codex-0")
        #expect(request.kind == .permission)
        #expect(request.toolName == "Bash")
        #expect(request.waiting.permission?.summary == "touch a.txt")
        #expect(await world.conversation.snapshot().phase == .waiting)
        try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-0", allow: true))
        let reply = await world.host.written().last { ($0["id"] as? Int) == 0 }
        #expect((reply?["result"] as? [String: Any])?["decision"] as? String == "accept")
        await world.host.emit(#"{"method":"serverRequest/resolved","params":{"threadId":"th-1","requestId":0}}"#)
        #expect(await eventually { await world.conversation.snapshot().pending.isEmpty })
        #expect(await world.conversation.snapshot().phase == .running)
        await #expect(throws: ConversationError.self) { try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-0", allow: false)) }
    }

    @Test("MCP の問い（form）：mcpServer/elicitation/request を問いにし、合わない答えは送らず、合う答えを action と content で返す。答えは state に残さない")
    func elicitationForm() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "使う", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(
            #"{"method":"mcpServer/elicitation/request","id":4,"params":{"threadId":"th-1","turnId":"turn-1","serverName":"github","mode":"form","message":"連絡先を入れてください","requestedSchema":{"type":"object","properties":{"name":{"type":"string","minLength":1},"age":{"type":"integer","minimum":18}},"required":["name"]}}}"#
        )
        #expect(await eventually { await world.conversation.snapshot().pending.count == 1 })
        let request = try #require(await world.conversation.snapshot().pending.first)
        #expect(request.id == "codex-4" && request.kind == .elicitation && request.elicitation?.serverName == "github")
        #expect(request.elicitation?.form?.fields.map(\.key) == ["name", "age"])
        #expect(await world.conversation.snapshot().phase == .waiting)
        await #expect(throws: ConversationError.invalid("必須の欄 name が無い")) {
            try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-4", action: .accept, content: ["age": .number(30)]))
        }
        #expect(await world.host.written().last { ($0["id"] as? Int) == 4 && $0["method"] == nil } == nil, "合わない答えは送らない")
        try await world.conversation.answer(
            ConversationAnswerRequest(requestID: "codex-4", action: .accept, content: ["name": .string("SECRET-ANSWER"), "age": .number(42)]))
        let reply = try #require(await world.host.written().last { ($0["id"] as? Int) == 4 && $0["method"] == nil })
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["action"] as? String == "accept")
        let content = try #require(result["content"] as? [String: Any])
        #expect(content["name"] as? String == "SECRET-ANSWER" && (content["age"] as? NSNumber)?.intValue == 42)
        #expect(await world.conversation.snapshot().pending.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(await world.conversation.snapshot()), as: UTF8.self).contains("SECRET-ANSWER"))
    }

    @Test("MCP の問い（url）：開く先の全文は state に載せず［開く］の応答にだけ返し、受けたら action だけを返す。別の thread の問いは断る")
    func elicitationURL() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "使う", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(
            #"{"method":"mcpServer/elicitation/request","id":5,"params":{"threadId":"th-1","serverName":"linear","mode":"url","message":"認証してください","url":"https://auth.example.com:8443/authorize?state=SECRET-STATE","elicitationId":"el-9"}}"#
        )
        await world.host.emit(
            #"{"method":"mcpServer/elicitation/request","id":6,"params":{"threadId":"th-other","serverName":"linear","mode":"form","message":"x","requestedSchema":{"type":"object","properties":{}}}}"#
        )
        #expect(await eventually { await world.conversation.snapshot().pending.count == 1 })
        #expect(await eventually { await world.host.written().contains { ($0["id"] as? Int) == 6 && $0["error"] != nil } })
        let request = try #require(await world.conversation.snapshot().pending.first)
        #expect(request.elicitation?.link == Elicitation.Link(scheme: "https", host: "auth.example.com", port: 8443))
        #expect(!String(decoding: try JSONEncoder().encode(await world.conversation.snapshot()), as: UTF8.self).contains("SECRET-STATE"))
        let opened = try await world.conversation.control(ConversationControlRequest(kind: .elicitationURL, value: "codex-5"))
        let url = try JSONDecoder().decode(ElicitationURLResponse.self, from: Data(try #require(opened.payloadJSON).utf8)).url
        #expect(url == "https://auth.example.com:8443/authorize?state=SECRET-STATE")
        try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-5", action: .accept))
        let reply = try #require(await world.host.written().last { ($0["id"] as? Int) == 5 && $0["method"] == nil })
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["action"] as? String == "accept" && result["content"] == nil)
    }

    @Test("承認の選択肢：コマンドの要求の availableDecisions（文字列の答えだけ）を問いに載せ、選んだ答えをそのまま返す。出していない答えは断り、選択肢の無い要求は許可か拒否")
    func approvalDecisions() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "触る", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(
            #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"th-1","turnId":"turn-1","itemId":"exec-1","command":"/bin/zsh -lc 'npm test'","cwd":"/w","availableDecisions":["accept","acceptForSession",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["npm","test"]}},"cancel"]}}"#
        )
        await world.host.emit(
            #"{"method":"item/fileChange/requestApproval","id":1,"params":{"threadId":"th-1","turnId":"turn-1","itemId":"patch-1","reason":"書き込み"}}"#)
        #expect(await eventually { await world.conversation.snapshot().pending.count == 2 })
        let pending = await world.conversation.snapshot().pending
        #expect(pending.map(\.decisions) == [[.accept, .acceptForSession, .cancel], nil])

        // 出していない答え・選択肢の無い要求への選択肢は、codex に何も送らずに断る
        let before = await world.host.written().count
        await #expect(throws: ConversationError.self) {
            try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-0", allow: false, decision: .decline))
        }
        await #expect(throws: ConversationError.self) {
            try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-1", allow: true, decision: .acceptForSession))
        }
        #expect(await world.host.written().count == before)

        try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-0", allow: true, decision: .acceptForSession))
        try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-1", allow: false))
        let written = await world.host.written()
        #expect((written.last { ($0["id"] as? Int) == 0 }?["result"] as? [String: Any])?["decision"] as? String == "acceptForSession")
        #expect((written.last { ($0["id"] as? Int) == 1 }?["result"] as? [String: Any])?["decision"] as? String == "decline")
    }

    @Test("答えられない server の要求は method が無いとして断る。子の thread の通知は会話に混ぜない")
    func refusesUnknownAndIgnoresChildren() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        await world.host.emit(#"{"method":"item/tool/call","id":3,"params":{"threadId":"th-1","turnId":"turn-1","callId":"c1","tool":"x","arguments":{}}}"#)
        #expect(await eventually { await world.host.written().contains { ($0["id"] as? Int) == 3 && $0["error"] != nil } })
        let refusal = await world.host.written().first { ($0["id"] as? Int) == 3 }
        #expect((refusal?["error"] as? [String: Any])?["code"] as? Int == CodexRPC.methodNotFound)
        await world.host.emit(
            #"{"method":"item/completed","params":{"threadId":"child-1","turnId":"c1","item":{"type":"agentMessage","id":"child-msg","text":"子の返事"}}}"#)
        await world.host.emit(
            #"{"method":"item/completed","params":{"threadId":"th-1","turnId":"turn-1","item":{"type":"agentMessage","id":"own-msg","text":"返事"}}}"#)
        #expect(await eventually { world.events.messages.contains { $0.id == "own-msg" } })
        #expect(!world.events.messages.contains { $0.id == "child-msg" })
    }

    private static let userInputRequest =
        #"{"method":"item/tool/requestUserInput","id":7,"params":{"threadId":"th-1","turnId":"turn-1","itemId":"ui-1","isBlocking":true,"questions":[{"id":"scope","header":"範囲","question":"どこまで直しますか","isOther":true,"isSecret":false,"options":[{"label":"全部","description":"全ファイル"},{"label":"一部","description":""}]},{"id":"token","header":"鍵","question":"トークンを入れてください","isOther":false,"isSecret":true,"options":null}]}}"#

    @Test("問い：request_user_input を質問の問いにし（選択肢なし・秘密の旗つき）、合わない答えは送らず、合う答えを label と自由記述で返す。秘密の答えは state にもログにも残さない")
    func userInput() async throws {
        let world = try await make(permissionMode: "plan")
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "直す", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(Self.userInputRequest)
        await world.host.emit(
            #"{"method":"item/tool/requestUserInput","id":8,"params":{"threadId":"th-other","turnId":"t","itemId":"x","isBlocking":true,"questions":[{"id":"a","header":"h","question":"q","options":null}]}}"#)
        #expect(await eventually { await world.conversation.snapshot().pending.count == 1 })
        #expect(await eventually { await world.host.written().contains { ($0["id"] as? Int) == 8 && $0["error"] != nil } })
        let request = try #require(await world.conversation.snapshot().pending.first)
        #expect(request.id == "codex-7" && request.kind == .question && request.toolUseID == "ui-1")
        let questions = try #require(request.waiting.questions)
        #expect(questions.map(\.id) == ["scope", "token"])
        #expect(questions[0].header == "範囲" && questions[0].options.map(\.label) == ["全部", "一部"])
        #expect(questions[0].options.map(\.description) == ["全ファイル", nil])
        #expect(questions[1].options.isEmpty && questions[1].isSecret && !questions[0].isSecret)
        #expect(await world.conversation.snapshot().phase == .waiting)

        // 選択肢に無い label と、答えが 1 つも無いのは、codex に何も送らずに断る
        let before = await world.host.written().count
        await #expect(throws: ConversationError.self) {
            try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-7", answers: [AskAnswer(questionID: "scope", selected: ["無い"])]))
        }
        await #expect(throws: ConversationError.self) {
            try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-7", answers: [AskAnswer(questionID: "scope", selected: [])]))
        }
        #expect(await world.host.written().count == before)

        try await world.conversation.answer(
            ConversationAnswerRequest(
                requestID: "codex-7",
                answers: [AskAnswer(questionID: "scope", selected: ["全部"], freeText: " 急ぎで "), AskAnswer(questionID: "token", selected: [], freeText: "SECRET-TOKEN")]))
        let reply = try #require(await world.host.written().last { ($0["id"] as? Int) == 7 && $0["method"] == nil })
        let result = try #require((reply["result"] as? [String: Any])?["answers"] as? [String: [String: [String]]])
        #expect(result["scope"]?["answers"] == ["全部", "急ぎで"])
        #expect(result["token"]?["answers"] == ["SECRET-TOKEN"])
        #expect(await world.conversation.snapshot().pending.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(await world.conversation.snapshot()), as: UTF8.self).contains("SECRET-TOKEN"))
        #expect(!world.logs.joined.contains("SECRET-TOKEN"))
        await #expect(throws: ConversationError.self) {
            try await world.conversation.answer(ConversationAnswerRequest(requestID: "codex-7", answers: [AskAnswer(questionID: "scope", selected: ["全部"])]))
        }
    }

    @Test("問い：答えずに進んだ（serverRequest/resolved）ら問いが消えて、ターンの実行中に戻る")
    func userInputResolvedWithoutAnswer() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "直す", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(Self.userInputRequest.replacingOccurrences(of: #""isBlocking":true"#, with: #""isBlocking":false"#))
        #expect(await eventually { await world.conversation.snapshot().pending.count == 1 })
        await world.host.emit(#"{"method":"serverRequest/resolved","params":{"threadId":"th-1","requestId":7}}"#)
        #expect(await eventually { await world.conversation.snapshot().pending.isEmpty })
        #expect(await world.conversation.snapshot().phase == .running)
    }

    @Test("問い：daemon が起き直したら、控えを読み直して答えていない問いを問いに戻し、そこへ答えを返せる")
    func userInputSurvivesRestart() async throws {
        let first = try await make()
        first.server.setTurnLines(FakeThreadServer.started)
        try await first.conversation.start(resume: false)
        _ = try await first.conversation.send(ConversationSendRequest(text: "直す", clientMessageID: UUID().uuidString.lowercased()))
        await first.host.emit(Self.userInputRequest)
        #expect(await eventually { await first.conversation.snapshot().pending.count == 1 })

        let record = try #require(try first.store.conversation(id: first.id))
        let second = CodexConversation(record: record, context: first.context)
        await first.host.connect(second.inbox, key: first.id)
        let lastSeq = await first.host.seq
        await second.attach(
            process: AgentHostProcessInfo(key: first.id, pid: 42, alive: true, exit: nil, lastSeq: lastSeq, firstSeq: 1, keptBytes: 0, startedAt: 0))
        let snapshot = await second.snapshot()
        #expect(snapshot.pending.map(\.id) == ["codex-7"] && snapshot.pending.first?.kind == .question)
        #expect(snapshot.pending.first?.waiting.questions?.last?.isSecret == true)
        try await second.answer(ConversationAnswerRequest(requestID: "codex-7", answers: [AskAnswer(questionID: "scope", selected: ["一部"])]))
        let reply = await first.host.written().last { ($0["id"] as? Int) == 7 && $0["method"] == nil }
        #expect(((reply?["result"] as? [String: Any])?["answers"] as? [String: Any])?["scope"] != nil)
    }

    @Test("Plan モード：権限が plan のときだけ turn/start に collaborationMode plan（model・effort は settings に同じ値、指示は null）を載せ、ほかは default。モードを替えると次の turn から替わる")
    func collaborationModes() async throws {
        let world = try await make(permissionMode: "plan")
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "1", clientMessageID: UUID().uuidString.lowercased()))
        let first = try #require(await params(world.host, "turn/start")?["collaborationMode"] as? [String: Any])
        #expect(first["mode"] as? String == "plan")
        let settings = try #require(first["settings"] as? [String: Any])
        #expect(settings["model"] as? String == "gpt-6.1-sol" && settings["reasoning_effort"] as? String == "medium")
        #expect(settings.keys.contains("developer_instructions") && settings["developer_instructions"] is NSNull)
        #expect(await eventually { await world.conversation.isIdle })

        _ = try await world.conversation.control(ConversationControlRequest(kind: .setModel, value: "gpt-6-astra"))
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setEffort, value: "high"))
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setPermissionMode, value: "acceptEdits"))
        _ = try await world.conversation.send(ConversationSendRequest(text: "2", clientMessageID: UUID().uuidString.lowercased()))
        let second = try #require(await params(world.host, "turn/start")?["collaborationMode"] as? [String: Any])
        #expect(second["mode"] as? String == "default")
        #expect((second["settings"] as? [String: Any])?["model"] as? String == "gpt-6-astra")
        #expect((second["settings"] as? [String: Any])?["reasoning_effort"] as? String == "high")
    }

    @Test("Plan モード：古い codex が collaborationMode を断ったら、欄なしで送り直して発言を落とさず、その子の間は載せない")
    func collaborationModeRefused() async throws {
        let world = try await make(permissionMode: "plan")
        world.server.setResults(
            "turn/start",
            [
                #"{"error":{"code":-32602,"message":"unknown field `collaborationMode`"},"id":"$ID"}"#,
                #"{"turn":{"id":"turn-1","status":"inProgress","error":null,"durationMs":null}}"#,
            ])
        try await world.conversation.start(resume: false)
        let uuid = UUID().uuidString.lowercased()
        #expect(try await world.conversation.send(ConversationSendRequest(text: "1", clientMessageID: uuid)) == .accepted)
        let starts = await sent(world.host, "turn/start")
        #expect(starts.count == 2)
        #expect((starts[0]["params"] as? [String: Any])?["collaborationMode"] != nil)
        #expect((starts[1]["params"] as? [String: Any])?["collaborationMode"] == nil)
        #expect(await world.conversation.received(uuid))
        _ = try await world.conversation.send(ConversationSendRequest(text: "2", clientMessageID: UUID().uuidString.lowercased()))
        let third = try #require(await sent(world.host, "turn/start").last)
        #expect((third["params"] as? [String: Any])?["collaborationMode"] == nil)
    }

    @Test("plan の item：生成中の差分と完成した本文を assistant の発言として流す。履歴の読み直しの写しも同じ")
    func planItem() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "計画して", clientMessageID: UUID().uuidString.lowercased()))
        await world.host.emit(#"{"method":"item/started","params":{"threadId":"th-1","turnId":"turn-1","item":{"type":"plan","id":"plan-1","text":""}}}"#)
        await world.host.emit(#"{"method":"item/plan/delta","params":{"threadId":"th-1","turnId":"turn-1","itemId":"plan-1","delta":"1. 調べる"}}"#)
        await world.host.emit(
            #"{"method":"turn/plan/updated","params":{"threadId":"th-1","turnId":"turn-1","explanation":null,"plan":[{"step":"調べる","status":"inProgress"}]}}"#)
        await world.host.emit(
            #"{"method":"item/completed","params":{"threadId":"th-1","turnId":"turn-1","item":{"type":"plan","id":"plan-1","text":"1. 調べる\n2. 直す"}}}"#)
        #expect(await eventually { world.events.messages.contains { $0.id == "plan-1" } })
        let plan = try #require(world.events.messages.first { $0.id == "plan-1" })
        #expect(plan.role == .assistant && plan.kind == .text && plan.text == "1. 調べる\n2. 直す")
        #expect(world.events.all.contains { if case .delta = $0 { true } else { false } })
        let listed = try JSONDecoder().decode(CodexItem.self, from: Data(#"{"type":"plan","id":"p","text":"本文"}"#.utf8))
        #expect(CodexItems.messages(listed, at: nil).map(\.text) == ["本文"])
    }

    @Test("止める：生成中なら turn を止めてから入力を閉じる。止めた理由を記録に残す")
    func stops() async throws {
        let world = try await make()
        world.server.setTurnLines(FakeThreadServer.started)
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.send(ConversationSendRequest(text: "長い仕事", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await eventually { await world.conversation.snapshot().phase == .running })
        await world.conversation.stop(.person)
        #expect(await params(world.host, "turn/interrupt")?["turnId"] as? String == "turn-1")
        let ops = await world.host.ops()
        #expect(ops.contains(.closeInput))
        #expect(await eventually { await !world.conversation.isLive })
        #expect(try world.store.conversation(id: world.id)?.stopCause == .person)
        // 知らせは子が終わった後の片付けの最後に出る（isLive は子が終わった時点で false になる）
        #expect(await eventually { world.events.all.contains { if case .notice("停止しました") = $0 { true } else { false } } })
    }

    @Test("daemon が起き直した：控えを読み直して、答えていない承認を問いに戻す。前の daemon の要求への応答と、解決した要求は戻さない")
    func reattaches() async throws {
        let first = try await make()
        first.server.setTurnLines(FakeThreadServer.started)
        try await first.conversation.start(resume: false)
        _ = try await first.conversation.send(ConversationSendRequest(text: "触る", clientMessageID: UUID().uuidString.lowercased()))
        await first.host.emit(
            #"{"method":"item/fileChange/requestApproval","id":0,"params":{"threadId":"th-1","turnId":"turn-1","itemId":"patch-1","reason":"書き込み"}}"#)
        await first.host.emit(
            #"{"method":"item/commandExecution/requestApproval","id":1,"params":{"threadId":"th-1","turnId":"turn-1","itemId":"exec-2","command":"ls"}}"#)
        await first.host.emit(#"{"method":"serverRequest/resolved","params":{"threadId":"th-1","requestId":1}}"#)
        #expect(await eventually { await first.conversation.snapshot().pending.map(\.id) == ["codex-0"] })

        // 新しい daemon：同じ host の控えから読み直す
        let record = try #require(try first.store.conversation(id: first.id))
        let second = CodexConversation(record: record, context: first.context)
        await first.host.connect(second.inbox, key: first.id)
        let lastSeq = await first.host.seq
        await second.attach(
            process: AgentHostProcessInfo(key: first.id, pid: 42, alive: true, exit: nil, lastSeq: lastSeq, firstSeq: 1, keptBytes: 0, startedAt: 0))
        let snapshot = await second.snapshot()
        #expect(snapshot.pending.map(\.id) == ["codex-0"])
        #expect(snapshot.pending.first?.toolName == "Edit")
        #expect(snapshot.phase == .waiting)
        try await second.answer(ConversationAnswerRequest(requestID: "codex-0", allow: false))
        let reply = await first.host.written().last { ($0["id"] as? Int) == 0 }
        #expect((reply?["result"] as? [String: Any])?["decision"] as? String == "decline")
    }

    @Test("モデルと effort：空いていれば thread/settings/update だけ、生成中なら turn/settings/update も送る。断られても targetUnavailable でも成功にし、記録は替える。止まった会話は記録だけ")
    func settingsUpdates() async throws {
        let world = try await make()
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setModel, value: "gpt-6-astra"))
        #expect(await sent(world.host, "thread/settings/update").isEmpty)
        #expect(try world.store.conversation(id: world.id)?.model == "gpt-6-astra")

        try await world.conversation.start(resume: false)
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setModel, value: "gpt-6.1-sol"))
        let idle = try #require(await params(world.host, "thread/settings/update"))
        #expect(idle["threadId"] as? String == "th-1" && idle["model"] as? String == "gpt-6.1-sol")
        #expect(!idle.keys.contains("effort"))
        #expect(await sent(world.host, "turn/settings/update").isEmpty)

        world.server.setTurnLines(FakeThreadServer.started)
        _ = try await world.conversation.send(ConversationSendRequest(text: "1", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await eventually { await world.conversation.snapshot().phase == .running })
        world.server.setResults("turn/settings/update", [#"{"status":"applied"}"#])
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setEffort, value: "high"))
        let thread = try #require(await params(world.host, "thread/settings/update"))
        #expect(thread["effort"] as? String == "high" && !thread.keys.contains("model"))
        let turn = try #require(await params(world.host, "turn/settings/update"))
        #expect(turn["threadId"] as? String == "th-1" && turn["turnId"] as? String == "turn-1" && turn["effort"] as? String == "high")

        // feature の無い codex の断りと targetUnavailable は、次の turn から効くとして成功にする
        world.server.setResults(
            "turn/settings/update",
            [#"{"error":{"code":-32600,"message":"turn settings updates require the step_model_switching feature"},"id":"$ID"}"#, #"{"status":"targetUnavailable"}"#])
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setEffort, value: "low"))
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setModel, value: "gpt-6-astra"))
        #expect(await sent(world.host, "turn/settings/update").count == 3)
        let record = try #require(try world.store.conversation(id: world.id))
        #expect(record.effort == "low" && record.model == "gpt-6-astra")
    }

    @Test("モデルと effort は起動と同じく名前の形だけを見る（Claude の 5 つに無い ultra も受ける）。形の違う名前は断って記録を替えない")
    func settingNames() async throws {
        let world = try await make()
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setModel, value: "gpt-6-astra"))
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setEffort, value: "ultra"))
        for value in ["ex tra", "", "gpt/6", "高"] {
            await #expect(throws: ConversationError.self) { _ = try await world.conversation.control(ConversationControlRequest(kind: .setModel, value: value)) }
            await #expect(throws: ConversationError.self) { _ = try await world.conversation.control(ConversationControlRequest(kind: .setEffort, value: value)) }
        }
        let record = try #require(try world.store.conversation(id: world.id))
        #expect(record.model == "gpt-6-astra" && record.effort == "ultra")
    }

    @Test("制御：モデル・effort・権限は次の turn に入る（sandbox は替えた後の 1 回だけ）。題は thread/name/set")
    func controls() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setModel, value: "gpt-6-astra"))
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setEffort, value: "high"))
        _ = try await world.conversation.control(ConversationControlRequest(kind: .setPermissionMode, value: "plan"))
        _ = try await world.conversation.send(ConversationSendRequest(text: "1", clientMessageID: UUID().uuidString.lowercased()))
        let first = await params(world.host, "turn/start")
        #expect(first?["model"] as? String == "gpt-6-astra")
        #expect(first?["effort"] as? String == "high")
        #expect(first?["approvalPolicy"] as? String == "on-request")
        #expect((first?["sandboxPolicy"] as? [String: Any])?["type"] as? String == "readOnly")
        #expect(await eventually { await world.conversation.isIdle })
        _ = try await world.conversation.send(ConversationSendRequest(text: "2", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await sent(world.host, "turn/start").count == 2)
        #expect(await params(world.host, "turn/start")?["sandboxPolicy"] == nil)
        _ = try await world.conversation.control(ConversationControlRequest(kind: .rename, value: "新しい題"))
        let name = await params(world.host, "thread/name/set")
        #expect(name?["threadId"] as? String == "th-1" && name?["name"] as? String == "新しい題")
        #expect(try world.store.conversation(id: world.id)?.customTitle == "新しい題")
        #expect(await world.conversation.snapshot().title == "新しい題")
    }

    @Test("権限のモードを codex の承認の方針と sandbox に読み替える")
    func permissions() {
        #expect(CodexPermissions(mode: nil) == CodexPermissions(mode: "bypassPermissions"))
        #expect(CodexPermissions(mode: "bypassPermissions").approvalPolicy == "never")
        #expect(CodexPermissions(mode: "bypassPermissions").sandbox == "danger-full-access")
        #expect(CodexPermissions(mode: "plan").sandbox == "read-only")
        #expect(CodexPermissions(mode: "default").approvalPolicy == "on-request")
        #expect(CodexPermissions(mode: "acceptEdits").sandbox == "workspace-write")
        #expect(CodexPermissions(mode: "manual").approvalPolicy == "untrusted")
        #expect(CodexConversation.unwrapShell("/bin/zsh -lc 'touch a.txt'") == "touch a.txt")
        #expect(CodexConversation.unwrapShell("ls -la") == "ls -la")
    }

    @Test("item の写し：コマンドは呼び出しと結果の組、拒否は誤り、ファイルの変更は差分つき、人の発言の id は送った uuid")
    func items() throws {
        func item(_ json: String) throws -> CodexItem { try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8)) }
        let done = CodexItems.messages(
            try item(#"{"type":"commandExecution","id":"e1","command":"ls","aggregatedOutput":"a\nb","exitCode":0,"status":"completed"}"#), at: nil)
        #expect(done.map(\.id) == ["e1", "e1-result"])
        #expect(done.first?.toolName == "Bash" && done.last?.text == "a\nb" && done.last?.isError == false)
        let declined = CodexItems.messages(try item(#"{"type":"commandExecution","id":"e2","command":"rm x","status":"declined"}"#), at: nil)
        #expect(declined.last?.isError == true)
        let running = CodexItems.messages(try item(#"{"type":"commandExecution","id":"e3","command":"sleep 9","status":"inProgress"}"#), at: nil)
        #expect(running.map(\.id) == ["e3"])
        let patch = CodexItems.messages(
            try item(
                #"{"type":"fileChange","id":"p1","status":"completed","changes":[{"path":"/w/a.txt","kind":{"type":"add"},"diff":"@@ -0,0 +1 @@\n+hi\n"}]}"#),
            at: nil)
        #expect(patch.last?.files?.first?.path == "/w/a.txt" && patch.last?.files?.first?.action == .created && patch.last?.files?.first?.added == 1)
        let user = CodexItems.messages(
            try item(#"{"type":"userMessage","id":"u1","clientId":"ABC","content":[{"type":"text","text":"やあ"},{"type":"localImage","path":"/a.png"}]}"#),
            at: nil)
        #expect(user.map(\.id) == ["abc", "u1-images"])
        #expect(try item(#"{"type":"somethingNew","id":"x"}"#) == .other(id: "x", type: "somethingNew"))
    }

    @Test("item の写し（0.162.1 の型）：画像を見たのは Read の組、動的なツールは結果の文つきの組、画像の生成は保存先か失敗の組、レビューの始まりと終わりは印の行")
    func moreItems() throws {
        func messages(_ json: String) throws -> [ChatMessage] {
            CodexItems.messages(try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8)), at: nil)
        }
        let view = try messages(#"{"type":"imageView","id":"v1","path":"/w/shot.png"}"#)
        #expect(view.map(\.id) == ["v1", "v1-result"])
        #expect(view.first?.toolName == "Read" && view.first?.text == "/w/shot.png" && view.last?.isError == false)

        let tool = try messages(
            #"{"type":"dynamicToolCall","id":"d1","namespace":"browser","tool":"open","arguments":{"query":"猫"},"status":"completed","contentItems":[{"type":"inputText","text":"開いた"},{"type":"inputImage","imageUrl":"data:x"},{"type":"inputText","text":"2 件目"}],"success":true,"durationMs":12}"#)
        #expect(tool.first?.toolName == "browser.open" && tool.first?.text == #"{"query":"猫"}"#)
        #expect(tool.last?.text == "開いた\n2 件目" && tool.last?.isError == false)
        let unsuccessful = try messages(
            #"{"type":"dynamicToolCall","id":"d2","namespace":null,"tool":"lookup","arguments":{},"status":"completed","contentItems":null,"success":false,"durationMs":null}"#)
        #expect(unsuccessful.first?.toolName == "lookup" && unsuccessful.last?.isError == true)
        let calling = try messages(
            #"{"type":"dynamicToolCall","id":"d3","namespace":null,"tool":"lookup","arguments":{},"status":"inProgress","contentItems":null,"success":null,"durationMs":null}"#)
        #expect(calling.map(\.id) == ["d3"])

        let image = try messages(
            #"{"type":"imageGeneration","id":"g1","status":"completed","revisedPrompt":"夕焼けの海","result":"iVBORw0KGgo=","failure":null,"savedPath":"/w/.codex/images/g1.png"}"#)
        #expect(image.first?.toolName == "ImageGeneration" && image.first?.text == "夕焼けの海")
        #expect(image.last?.text == "/w/.codex/images/g1.png" && image.last?.isError == false)
        let limited = try messages(
            #"{"type":"imageGeneration","id":"g2","status":"failed","revisedPrompt":null,"result":"","failure":{"type":"usageLimitExceeded","limitId":"images","resetsAt":null}}"#)
        #expect(limited.last?.isError == true && limited.last?.text == "画像を生成できませんでした。利用枠の上限に達しています。")
        let generating = try messages(#"{"type":"imageGeneration","id":"g3","status":"generating","revisedPrompt":null,"result":"","failure":null}"#)
        #expect(generating.map(\.id) == ["g3"])

        let entered = try messages(#"{"type":"enteredReviewMode","id":"r1","review":"current changes"}"#)
        #expect(entered.map(\.kind) == [.notice] && entered.first?.text == "コードレビューを始めました（current changes）")
        // 指摘の本文は続く agentMessage で届くので、終わりの印には入れない
        let exited = try messages(#"{"type":"exitedReviewMode","id":"r2","review":"[P1] 誤り"}"#)
        #expect(exited.map(\.kind) == [.notice] && exited.first?.text == "コードレビューが終わりました")

        let exported = CodexControls.export(
            try [
                #"{"type":"enteredReviewMode","id":"r1","review":"current changes"}"#, #"{"type":"imageView","id":"v1","path":"/w/shot.png"}"#,
                #"{"type":"imageGeneration","id":"g1","status":"completed","revisedPrompt":"海","result":"aGk=","failure":null,"savedPath":"/w/g1.png"}"#,
                #"{"type":"exitedReviewMode","id":"r2","review":"[P1] 誤り"}"#,
            ].map { try JSONDecoder().decode(CodexItem.self, from: Data($0.utf8)) })
        #expect(
            exported == """
                ⏺ Code review(current changes)

                ⏺ Read(/w/shot.png)

                ⏺ ImageGeneration(海)
                  ⎿  /w/g1.png

                """)
    }
}

// MARK: 読む画面とその場の操作（応答の行の形は 0.162.1 の実測）

extension CodexConversationTests {
    private func payload<T: Decodable>(_ response: ConversationControlResponse, as type: T.Type) throws -> T {
        try WireJSON.decoder().decode(type, from: Data(try #require(response.payloadJSON).utf8))
    }

    private func control(_ world: World, _ kind: ConversationControlRequest.Kind, _ value: String? = nil) async throws -> ConversationControlResponse {
        try await world.conversation.control(ConversationControlRequest(kind: kind, value: value))
    }

    private static let opened = #"{"thread":{"id":"$THREAD","cliVersion":"0.162.1","name":null},"model":"gpt-6.1-sol","reasoningEffort":"medium","cwd":"/w","runtimeWorkspaceRoots":["/w"],"instructionSources":["/Users/u/.codex/AGENTS.md","/w/AGENTS.md"],"approvalPolicy":"never","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite","writableRoots":["/w/out"],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":true},"activePermissionProfile":null}"#

    @Test("読むだけのシート：メモリは thread を開いた応答の指示のファイル、hook と skill は今の作業フォルダの一覧。codex だけの欄も写し、読めなかったファイルも返す")
    func readonlySheets() async throws {
        let world = try await make()
        world.server.setResults("initialize", [#"{"userAgent":"taskboard/0.162.1","codexHome":"/Users/u/.codex"}"#])
        world.server.setResults("thread/start", [Self.opened])
        world.server.setResults("hooks/list", [
            #"{"data":[{"cwd":"/w","hooks":[{"key":"/Users/u/.codex/hooks.json:session_start:0:0","eventName":"sessionStart","handlerType":"command","command":"bash ~/.codex/state.sh session","async":false,"matcher":null,"timeoutSec":10,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"/Users/u/.codex/hooks.json","source":"user","pluginId":null,"displayOrder":0,"enabled":true,"isManaged":false,"currentHash":"sha256:76ab","trustStatus":"trusted"},{"key":"k2","eventName":"preToolUse","handlerType":"mcpTool","server":"guard","tool":"check","async":true,"matcher":"Bash","timeoutSec":30,"statusMessage":"確かめています","sourcePath":"/w/.codex/hooks.json","source":"project","pluginId":"p1","displayOrder":1,"enabled":false,"isManaged":true,"currentHash":"h","trustStatus":"untrusted"}],"warnings":["古い書き方"],"errors":[{"path":"/w/.codex/bad.json","message":"読めない"}]}]}"#,
        ])
        world.server.setResults("skills/list", [
            #"{"data":[{"cwd":"/w","skills":[{"name":"commit","description":"変更をコミットする","path":"/Users/u/.claude/skills/commit/SKILL.md","scope":"user","enabled":true,"pluginId":null,"interface":{"displayName":"コミット","shortDescription":"短い説明"}},{"name":"lint","description":"整える","shortDescription":"古い説明","path":"/w/.codex/skills/lint/SKILL.md","scope":"repo","enabled":false,"pluginId":"tools"}],"errors":[{"path":"/w/.codex/skills/x/SKILL.md","message":"front matter が無い"}]}]}"#,
        ])
        try await world.conversation.start(resume: false)

        let memory = try payload(try await control(world, .memory), as: ConversationMemory.self)
        #expect(memory.files == [.init(kind: "user", path: "/Users/u/.codex/AGENTS.md", exists: true), .init(kind: "project", path: "/w/AGENTS.md", exists: true)])

        let hooks = try payload(try await control(world, .hooks), as: ConversationHooks.self)
        #expect((await params(world.host, "hooks/list"))?["cwds"] as? [String] == ["/w"])
        // 書き換えと信頼に使う鍵は、管理者の hook には付けない
        #expect(hooks.hooks.map { $0.editKey?.count } == [64, nil])
        // config/read の user の層が読めないので、書き換えられるかは載せない
        #expect(hooks.hooks.map(\.editable) == [nil, nil])
        let bare: [ConversationHooks.Hook] = hooks.hooks.map {
            var hook = $0
            hook.editKey = nil
            hook.editable = nil
            return hook
        }
        #expect(
            bare == [
                .init(
                    event: "SessionStart", matcher: "", source: "user", type: "command", command: "bash ~/.codex/state.sh session", enabled: true, trust: "trusted",
                    sourcePath: "/Users/u/.codex/hooks.json", timeoutSeconds: 10, isAsync: false, managed: false),
                .init(
                    event: "PreToolUse", matcher: "Bash", source: "project", plugin: "p1", type: "mcpTool", command: "guard/check", enabled: false, trust: "untrusted",
                    sourcePath: "/w/.codex/hooks.json", timeoutSeconds: 30, isAsync: true, statusMessage: "確かめています", managed: true),
            ])
        #expect(hooks.problems == [.init(path: "/w/.codex/bad.json", message: "読めない")])
        #expect(hooks.warnings == ["古い書き方"])

        let skills = try payload(try await control(world, .skills), as: ConversationSkills.self)
        #expect(
            skills.skills == [
                .init(
                    name: "commit", displayName: "コミット", description: "変更をコミットする", source: "user", state: "on", path: "/Users/u/.claude/skills/commit/SKILL.md",
                    shortDescription: "短い説明"),
                .init(
                    name: "lint", displayName: "lint", description: "整える", source: "repo", state: "off", path: "/w/.codex/skills/lint/SKILL.md", plugin: "tools",
                    shortDescription: "古い説明"),
            ])
        #expect(skills.problems == [.init(path: "/w/.codex/skills/x/SKILL.md", message: "front matter が無い")])
    }

    @Test("権限のシート：今の会話に効いている値を session で先に置き、設定の値を層の名前つきで続ける。MCP のヘッダなど権限でない値は写さない。thread/settings/updated で session の値が替わる")
    func permissionSheet() async throws {
        let world = try await make()
        world.server.setResults("thread/start", [Self.opened])
        world.server.setResults("config/read", [
            #"{"config":{"approval_policy":"on-request","approvals_reviewer":null,"sandbox_mode":"workspace-write","sandbox_workspace_write":{"network_access":true,"writable_roots":["/tmp/a"]},"mcp_servers":{"ctx":{"url":"https://mcp.example","http_headers":{"KEY":"secret-header-value"}}},"projects":{"/w":{"trust_level":"trusted"},"/":{"trust_level":"untrusted"}}},"origins":{"approval_policy":{"name":{"type":"user","file":"/Users/u/.codex/config.toml"},"version":"sha256:1"},"sandbox_workspace_write.writable_roots.0":{"name":{"type":"project","dotCodexFolder":"/w/.codex"},"version":"sha256:2"},"projects./w.trust_level":{"name":{"type":"user","file":"/Users/u/.codex/config.toml"},"version":"sha256:3"},"mcp_servers.ctx.http_headers.KEY":{"name":{"type":"user","file":"/Users/u/.codex/config.toml"},"version":"sha256:4"}}}"#,
        ])
        try await world.conversation.start(resume: false)
        let response = try await control(world, .permissionRules)
        #expect((await params(world.host, "config/read"))?["cwd"] as? String == "/w")
        #expect(response.payloadJSON?.contains("secret-header-value") == false)
        let rules = try payload(response, as: ConversationPermissionRules.self)
        #expect(rules.rules.isEmpty)
        #expect(rules.directories == [.init(path: "/w", source: "session"), .init(path: "/w/out", source: "session"), .init(path: "/tmp/a", source: "project")])
        #expect(
            rules.settings == [
                .init(key: "approval_policy", value: "never", source: "session"), .init(key: "approvals_reviewer", value: "user", source: "session"),
                .init(key: "sandbox_mode", value: "workspace-write", source: "session"),
                .init(key: "sandbox_workspace_write.network_access", value: "false", source: "session"),
                .init(key: "sandbox_workspace_write.exclude_tmpdir_env_var", value: "false", source: "session"),
                .init(key: "sandbox_workspace_write.exclude_slash_tmp", value: "true", source: "session"),
                .init(key: "approval_policy", value: "on-request", source: "user"), .init(key: "sandbox_mode", value: "workspace-write", source: "config"),
                .init(key: "sandbox_workspace_write.network_access", value: "true", source: "config"),
                .init(key: "projects./w.trust_level", value: "trusted", source: "user"),
            ])

        await world.host.emit(
            #"{"method":"thread/settings/updated","params":{"threadId":"th-1","threadSettings":{"cwd":"/w","approvalPolicy":"untrusted","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly","networkAccess":true},"activePermissionProfile":{"id":":workspace","extends":null}}}}"#)
        #expect(
            await eventually {
                guard let response = try? await self.control(world, .permissionRules) else { return false }
                let updated = try? self.payload(response, as: ConversationPermissionRules.self)
                return updated?.settings?.filter { $0.source == "session" } == [
                    .init(key: "approval_policy", value: "untrusted", source: "session"), .init(key: "approvals_reviewer", value: "user", source: "session"),
                    .init(key: "sandbox_mode", value: "read-only", source: "session"),
                    .init(key: "sandbox_workspace_write.network_access", value: "true", source: "session"),
                    .init(key: "default_permissions", value: ":workspace", source: "session"),
                ] && updated?.directories.first { $0.path == "/w/out" } == nil
            })
    }

    @Test("圧縮：contextCompaction の item が始まると様子に圧縮中を載せ、終わるか turn が終わると消す（字数は無い）")
    func compaction() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let started = #"{"method":"item/started","params":{"threadId":"th-1","turnId":"t1","item":{"type":"contextCompaction","id":"cc-1"}}}"#
        await world.host.emit(started)
        #expect(await eventually { await world.conversation.snapshot().compaction != nil })
        #expect(await world.conversation.snapshot().compaction?.outputChars == nil)
        await world.host.emit(#"{"method":"item/completed","params":{"threadId":"th-1","turnId":"t1","item":{"type":"contextCompaction","id":"cc-1"}}}"#)
        #expect(await eventually { await world.conversation.snapshot().compaction == nil })

        await world.host.emit(started)
        #expect(await eventually { await world.conversation.snapshot().compaction != nil })
        await world.host.emit(#"{"method":"turn/completed","params":{"threadId":"th-1","turn":{"id":"t1","status":"completed","error":null,"durationMs":10}}}"#)
        #expect(await eventually { await world.conversation.snapshot().compaction == nil })
    }

    @Test("圧縮：compact は空いているときだけ thread/compact/start を送る。生成中と止まった会話は断って送らない。thread/compacted でも圧縮中の様子を消す")
    func compactControl() async throws {
        let idle = try await make()
        try await idle.conversation.start(resume: false)
        #expect(try await control(idle, .compact).payloadJSON == nil)
        #expect(await sent(idle.host, "thread/compact/start").count == 1)
        #expect(await params(idle.host, "thread/compact/start")?["threadId"] as? String == "th-1")
        await idle.host.emit(#"{"method":"item/started","params":{"threadId":"th-1","turnId":"t1","item":{"type":"contextCompaction","id":"cc-1"}}}"#)
        #expect(await eventually { await idle.conversation.snapshot().compaction != nil })
        await idle.host.emit(#"{"method":"thread/compacted","params":{"threadId":"th-1","turnId":"t1"}}"#)
        #expect(await eventually { await idle.conversation.snapshot().compaction == nil })

        let busy = try await make()
        busy.server.setTurnLines(FakeThreadServer.started)
        try await busy.conversation.start(resume: false)
        _ = try await busy.conversation.send(ConversationSendRequest(text: "長い仕事", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await eventually { await busy.conversation.snapshot().phase == .running })
        await #expect(throws: ConversationError.self) { _ = try await control(busy, .compact) }
        #expect(await sent(busy.host, "thread/compact/start").isEmpty)

        let stopped = try await make()
        await #expect(throws: ConversationError.self) { _ = try await control(stopped, .compact) }
        #expect(await sent(stopped.host, "thread/compact/start").isEmpty)
    }

    @Test("レビュー：review は空いているときだけ review/start を送る。値が無ければ未コミットの変更、あれば指示を custom で渡す。生成中と止まった会話は断る")
    func reviewControl() async throws {
        let idle = try await make()
        try await idle.conversation.start(resume: false)
        #expect(try await control(idle, .review).payloadJSON == nil)
        let plain = try #require(await params(idle.host, "review/start"))
        #expect(plain["threadId"] as? String == "th-1")
        #expect((plain["target"] as? [String: Any])?["type"] as? String == "uncommittedChanges")
        #expect(plain["delivery"] == nil)
        _ = try await control(idle, .review, "認証の所だけ見て")
        let custom = try #require(await sent(idle.host, "review/start").last?["params"] as? [String: Any])
        let target = try #require(custom["target"] as? [String: Any])
        #expect(target["type"] as? String == "custom" && target["instructions"] as? String == "認証の所だけ見て")

        let busy = try await make()
        busy.server.setTurnLines(FakeThreadServer.started)
        try await busy.conversation.start(resume: false)
        _ = try await busy.conversation.send(ConversationSendRequest(text: "長い仕事", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await eventually { await busy.conversation.snapshot().phase == .running })
        await #expect(throws: ConversationError.self) { _ = try await control(busy, .review) }
        #expect(await sent(busy.host, "review/start").isEmpty)

        let stopped = try await make()
        await #expect(throws: ConversationError.self) { _ = try await control(stopped, .review) }
        #expect(await sent(stopped.host, "review/start").isEmpty)
    }

    @Test("新しい thread：new_thread は子を起こし直して thread/start を送り、会話 ID を新しい thread にする。前の thread も会話のタスクに結んだまま。控えを捨てる。生成中は断る")
    func newThreadControl() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let task = try #require(try world.store.conversation(id: world.id)?.taskNumber)
        world.server.setThread("th-2")
        #expect(try await control(world, .newThread).payloadJSON == nil)
        #expect(await sent(world.host, "thread/start").count == 2)
        #expect(await sent(world.host, "thread/resume").isEmpty)
        #expect(try world.store.conversation(id: world.id)?.agentSessionId == "th-2")
        #expect(await world.conversation.snapshot().agentSessionID == "th-2")
        #expect(await world.conversation.isLive)
        #expect(try world.store.taskNumber(linkedToSession: "th-1") == task)
        #expect(try world.store.taskNumber(linkedToSession: "th-2") == task)
        #expect(try world.store.taskNumber(linkedToSession: world.id) == nil)
        #expect(world.events.all.contains { if case .reset = $0 { true } else { false } })

        let busy = try await make()
        busy.server.setTurnLines(FakeThreadServer.started)
        try await busy.conversation.start(resume: false)
        _ = try await busy.conversation.send(ConversationSendRequest(text: "長い仕事", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await eventually { await busy.conversation.snapshot().phase == .running })
        await #expect(throws: ConversationError.self) { _ = try await control(busy, .newThread) }
        #expect(await sent(busy.host, "thread/start").count == 1)
        #expect(await busy.conversation.isLive)
    }

    @Test("裏のタスク：一覧は頁をたどって processId を id にし、出力はターンの後も届く outputDelta の末尾（頭が揃っているか分からないので、いつも切れているとする）、止めるは terminate")
    func backgroundTerminals() async throws {
        let world = try await make()
        world.server.setResults("thread/backgroundTerminals/list", [
            #"{"data":[{"itemId":"call_1","processId":"49646","command":"for i in $(seq 1 60); do echo tick $i; sleep 1; done","cwd":"/w","osPid":null,"cpuPercent":null,"rssKb":null}],"nextCursor":"c2"}"#,
            #"{"data":[{"itemId":"call_2","processId":"7","command":"npm run dev","cwd":"/w/app","osPid":123,"cpuPercent":1.5,"rssKb":2048}],"nextCursor":null}"#,
            #"{"data":[],"nextCursor":null}"#,
        ])
        world.server.setResults("thread/backgroundTerminals/terminate", [#"{"terminated":false}"#])
        try await world.conversation.start(resume: false)
        await world.host.emit(
            #"{"method":"item/started","params":{"threadId":"th-1","turnId":"t1","item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc 'for i in $(seq 1 60); do echo tick $i; sleep 1; done'","cwd":"/w","processId":"49646","source":"unifiedExecStartup","status":"inProgress","aggregatedOutput":null,"exitCode":null}}}"#)
        for delta in ["tick 1\n", "tick 2\n"] {
            await world.host.emit(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"th-1","turnId":"t1","itemId":"call_1","delta":"\#(delta.replacingOccurrences(of: "\n", with: "\\n"))"}}"#)
        }
        // 始まりの知らせを見ていない item（daemon が起き直した後など）
        await world.host.emit(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"th-1","turnId":"t0","itemId":"call_2","delta":"ready\n"}}"#)
        // 別の thread の出力は混ぜない
        await world.host.emit(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"th-child","turnId":"t9","itemId":"call_1","delta":"child\n"}}"#)

        let list = try payload(try await control(world, .listBackgroundTasks), as: ConversationBackgroundTasks.self)
        #expect(
            list
                == ConversationBackgroundTasks(tasks: [
                    .init(id: "49646", type: "background_terminal", description: "for i in $(seq 1 60); do echo tick $i; sleep 1; done", cwd: "/w"),
                    .init(id: "7", type: "background_terminal", description: "npm run dev", cwd: "/w/app", pid: 123, cpuPercent: 1.5, memoryKB: 2048),
                ]))
        let pages = await sent(world.host, "thread/backgroundTerminals/list").compactMap { $0["params"] as? [String: Any] }
        #expect(pages.map { $0["cursor"] as? String } == [nil, "c2"])
        #expect(pages.allSatisfy { $0["threadId"] as? String == "th-1" })

        #expect(
            await eventually {
                guard let response = try? await self.control(world, .taskOutput, "49646") else { return false }
                return (try? self.payload(response, as: ConversationTaskOutput.self)) == ConversationTaskOutput(output: "tick 1\ntick 2\n", totalBytes: 14, truncated: true)
            })
        #expect(try payload(try await control(world, .taskOutput, "7"), as: ConversationTaskOutput.self) == ConversationTaskOutput(output: "ready\n", totalBytes: 6, truncated: true))

        _ = try await control(world, .stopTask, "49646")
        let terminate = await params(world.host, "thread/backgroundTerminals/terminate")
        #expect(terminate?["threadId"] as? String == "th-1" && terminate?["processId"] as? String == "49646")

        // 終わった item の出力は捨てる。一覧にも無いタスクの出力は断る
        await world.host.emit(
            #"{"method":"item/completed","params":{"threadId":"th-1","turnId":"t1","item":{"type":"commandExecution","id":"call_1","command":"x","cwd":"/w","processId":"49646","status":"failed","aggregatedOutput":"tick 1\ntick 2\n","exitCode":-1}}}"#)
        #expect(
            await eventually {
                do {
                    _ = try await self.control(world, .taskOutput, "49646")
                    return false
                } catch let error as ConversationError {
                    return error.code == .invalidRequest
                } catch { return false }
            })
    }

    @Test("書き出し：thread の item を古い順に全部の頁で読み、Claude Code の書き出しと同じ記号の文にする。考えている途中は入れない。ファイル名は時刻と最初の指示")
    func exports() async throws {
        let world = try await make()
        world.server.setResults("thread/items/list", [
            #"{"data":[{"turnId":"t1","item":{"type":"userMessage","id":"u1","clientId":null,"content":[{"type":"text","text":"一覧を見せて","text_elements":[]}]}},{"turnId":"t1","item":{"type":"reasoning","id":"r1","summary":[],"content":[]}},{"turnId":"t1","item":{"type":"commandExecution","id":"c1","command":"/bin/zsh -lc 'ls'","cwd":"/w","status":"completed","aggregatedOutput":"a.txt\nb.txt\n","exitCode":0}}],"nextCursor":"n2"}"#,
            #"{"data":[{"turnId":"t1","item":{"type":"fileChange","id":"f1","changes":[{"path":"/w/a.txt","kind":{"type":"update"},"diff":"@@ -1 +1 @@\n-a\n+b\n"}],"status":"completed"}},{"turnId":"t1","item":{"type":"agentMessage","id":"a1","text":"2 件あります。\n終わり"}},{"turnId":"t1","item":{"type":"mcpToolCall","id":"m1","server":"taskboard","tool":"health","arguments":{},"status":"completed","result":"ok","error":null}}],"nextCursor":null}"#,
        ])
        try await world.conversation.start(resume: false)
        let export = try payload(try await control(world, .exportConversation), as: ConversationExport.self)
        #expect(
            export.text == """
                > 一覧を見せて

                ⏺ Bash(ls)
                  ⎿  a.txt
                     b.txt

                ⏺ Update(/w/a.txt)
                  ⎿  @@ -1 +1 @@
                     -a
                     +b

                ⏺ 2 件あります。
                  終わり

                ⏺ taskboard - health({})
                  ⎿  ok

                """)
        #expect(export.defaultFilename.hasSuffix("-一覧を見せて.txt"))
        let pages = await sent(world.host, "thread/items/list").compactMap { $0["params"] as? [String: Any] }
        #expect(pages.map { $0["cursor"] as? String } == [nil, "n2"])
        #expect(pages.allSatisfy { $0["sortDirection"] as? String == "asc" && $0["threadId"] as? String == "th-1" })
    }

    @Test("/cd：codex はパスを確かめないので daemon がフォルダかを確かめ、実体のパスで thread/settings/update に渡して記録の作業フォルダを替える。無い・フォルダでないは送らずに rejected")
    func changesDirectory() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "codex-cd-\(UUID().uuidString)").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: base + "/sub", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: base + "/file.txt", contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: base) }
        // 一時の置き場は /var の下にあり、実体は /private/var
        let real = (base.hasPrefix("/var/") ? "/private" + base : base) + "/sub"
        let world = try await make()
        try await world.conversation.start(resume: false)

        let missing = try payload(try await control(world, .setCwd, base + "/nope"), as: ConversationCwdChange.self)
        #expect(missing == ConversationCwdChange(outcome: .rejected, reason: "not_found"))
        let file = try payload(try await control(world, .setCwd, base + "/file.txt"), as: ConversationCwdChange.self)
        #expect(file == ConversationCwdChange(outcome: .rejected, reason: "not_a_directory"))
        #expect(await sent(world.host, "thread/settings/update").isEmpty)
        #expect(try world.store.conversation(id: world.id)?.cwd == "/w")
        do {
            _ = try await control(world, .setCwd, "sub")
            Issue.record("相対パスを受けた")
        } catch let error as ConversationError {
            #expect(error.code == .invalidRequest)
        }

        let moved = try payload(try await control(world, .setCwd, base + "/sub/"), as: ConversationCwdChange.self)
        #expect(moved == ConversationCwdChange(outcome: .moved, directory: real))
        let update = await params(world.host, "thread/settings/update")
        #expect(update?["threadId"] as? String == "th-1" && update?["cwd"] as? String == real)
        #expect(try world.store.conversation(id: world.id)?.cwd == real)
        #expect(await world.conversation.snapshot().cwd == real)
    }

    @Test("/login：device code のページとコードを応答にだけ返し、応答の行まで控えを切る。終わりは同じ loginId の account/login/completed で知る。始め直すと前の流れを取り消し、https でないページは取り消して断る")
    func logsIn() async throws {
        let world = try await make()
        world.server.setResults("account/login/start", [
            #"{"type":"chatgptDeviceCode","loginId":"L1","verificationUrl":"https://auth.openai.com/codex/device","userCode":"ABCD-12345"}"#,
            #"{"type":"chatgptDeviceCode","loginId":"L2","verificationUrl":"https://auth.openai.com/codex/device","userCode":"WXYZ-67890"}"#,
            #"{"type":"chatgptDeviceCode","loginId":"L3","verificationUrl":"http://auth.example/device","userCode":"QQQQ-00000"}"#,
        ])
        world.server.setResults("account/login/cancel", [#"{"status":"canceled"}"#])
        try await world.conversation.start(resume: false)

        let first = try payload(try await control(world, .login), as: ConversationLogin.self)
        #expect(
            first
                == ConversationLogin(manualURL: "https://auth.openai.com/codex/device", automaticURL: "https://auth.openai.com/codex/device", userCode: "ABCD-12345"))
        #expect((await params(world.host, "account/login/start"))?["type"] as? String == "chatgptDeviceCode")
        #expect(await world.host.requests.contains { $0.op == .trim && ($0.through ?? 0) > 0 })
        let state = await world.conversation.snapshot()
        #expect(state.login == .waiting)
        #expect(String(decoding: try WireJSON.encoder().encode(state), as: UTF8.self).contains("ABCD-12345") == false)

        let second = try payload(try await control(world, .login), as: ConversationLogin.self)
        #expect(second.userCode == "WXYZ-67890")
        #expect((await params(world.host, "account/login/cancel"))?["loginId"] as? String == "L1")

        // 取り消した流れの終わりの知らせは見ない
        await world.host.emit(#"{"method":"account/login/completed","params":{"loginId":"L1","success":false,"error":"Login was not completed","onboardingEntrypoint":null}}"#)
        await world.host.emit(#"{"method":"account/login/completed","params":{"loginId":"L2","success":true,"error":null,"onboardingEntrypoint":null}}"#)
        #expect(await eventually { await world.conversation.snapshot().login == .succeeded })

        do {
            _ = try await control(world, .login)
            Issue.record("https でないページを返した")
        } catch let error as ConversationError {
            #expect(error.code == .sessionCommandFailed)
        }
        #expect((await params(world.host, "account/login/cancel"))?["loginId"] as? String == "L3")
    }

    private func edit(_ world: World, _ edit: ConversationSettingsEdit) async throws -> ConversationSettingsEditResult {
        try payload(try await world.conversation.control(ConversationControlRequest(kind: .editSettings, edit: edit)), as: ConversationSettingsEditResult.self)
    }

    private func rejection(_ body: () async throws -> Any) async -> ConversationError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? ConversationError
        }
    }

    private static func userLayer(_ version: String, _ config: String = "{}") -> String {
        #"{"config":{"mcp_servers":{"ctx":{"command":"/bin/ctx"}}},"origins":{},"layers":[{"name":{"type":"project","dotCodexFolder":"/w/.codex"},"version":"sha256:p","config":{}},{"name":{"type":"user","file":"/Users/u/.codex/config.toml"},"version":"\#(version)","config":\#(config)}]}"#
    }

    private static func writeError(_ code: String) -> String {
        #"{"error":{"code":-32600,"data":{"config_write_error_code":"\#(code)"},"message":"English detail from codex"},"id":"$ID"}"#
    }

    @Test("設定の書き込み：user の層の版を expectedVersion に渡し、reloadUserConfig で書く。版の衝突は 1 回だけ読み直して書き直し、続けば conflict。断りは理由の種類だけで codex の文を入れない")
    func editSettingsWrites() async throws {
        let world = try await make()
        world.server.setResults("config/read", [Self.userLayer("sha256:v1"), Self.userLayer("sha256:v2")])
        world.server.setResults("config/batchWrite", [
            Self.writeError("configVersionConflict"), #"{"status":"ok","version":"sha256:v3","filePath":"/Users/u/.codex/config.toml","overriddenMetadata":null}"#,
        ])
        try await world.conversation.start(resume: false)
        let result = try await edit(world, .permissionSetting(key: "sandbox_workspace_write.network_access", value: "true"))
        #expect(result == .init(needsRestart: true))
        #expect((await params(world.host, "config/read"))?["includeLayers"] as? Bool == true)
        let writes = await sent(world.host, "config/batchWrite").compactMap { $0["params"] as? [String: Any] }
        #expect(writes.map { $0["expectedVersion"] as? String } == ["sha256:v1", "sha256:v2"])
        #expect(writes.last?["reloadUserConfig"] as? Bool == true)
        let edits = writes.last?["edits"] as? [[String: Any]]
        #expect(edits?.count == 1 && edits?.first?["keyPath"] as? String == "sandbox_workspace_write.network_access" && edits?.first?["value"] as? Bool == true)

        // 承認の方針は、taskboard の会話では開くときに渡す権限のモードが勝つ
        world.server.setResults("config/batchWrite", [#"{"status":"ok","version":"sha256:v4","filePath":"/Users/u/.codex/config.toml","overriddenMetadata":null}"#])
        #expect(try await edit(world, .permissionSetting(key: "approval_policy", value: "never")) == .init(overriddenBy: "permission_mode"))

        for (code, reason) in [("configVersionConflict", "conflict"), ("configValidationError", "invalid")] {
            world.server.setResults("config/batchWrite", [Self.writeError(code)])
            let error = await rejection { try await self.edit(world, .permissionSetting(key: "approvals_reviewer", value: "user")) }
            #expect(error?.code == .sessionCommandFailed && error?.params["reason"] == reason, "\(code)")
            #expect(error?.description.contains("English") == false)
        }
        // codex の文は書いた値を引用しうるので、ログにも出さない
        #expect(!world.logs.joined.contains("English") && world.logs.joined.contains("conversation settings rejected"))
    }

    @Test("MCP の server を切り替えたら、config/mcpServer/reload で動いている thread の server を起こし直す。ユーザーの設定に無い server は書かない")
    func editSettingsMCPServer() async throws {
        let world = try await make()
        world.server.setResults("config/read", [Self.userLayer("sha256:v1", #"{"mcp_servers":{"ctx":{"command":"/bin/ctx"}}}"#)])
        world.server.setResults("config/batchWrite", [#"{"status":"ok","version":"sha256:v2","filePath":"/Users/u/.codex/config.toml","overriddenMetadata":null}"#])
        try await world.conversation.start(resume: false)
        #expect(try await edit(world, .mcpServer(name: "ctx", enabled: false)) == .init())
        let edits = (await params(world.host, "config/batchWrite"))?["edits"] as? [[String: Any]]
        #expect(edits?.first?["keyPath"] as? String == "mcp_servers.ctx.enabled" && edits?.first?["value"] as? Bool == false)
        #expect(await sent(world.host, "config/mcpServer/reload").count == 1)

        let error = await rejection { try await self.edit(world, .mcpServer(name: "taskboard", enabled: false)) }
        #expect(error?.params["reason"] == "not_found")
        #expect(await sent(world.host, "config/batchWrite").count == 1)
    }

    @Test("skill：一覧で名前からパスを引いて skills/config/write に渡し、中身の無い config/batchWrite で動いている thread に読み直させる")
    func editSettingsSkill() async throws {
        let world = try await make()
        world.server.setResults("skills/list", [#"{"data":[{"cwd":"/w","skills":[{"name":"lint","path":"/w/.codex/skills/lint/SKILL.md","scope":"repo","enabled":true}]}]}"#])
        world.server.setResults("skills/config/write", [#"{"effectiveEnabled":false}"#])
        try await world.conversation.start(resume: false)
        #expect(try await edit(world, .skill(name: "lint", state: "off")) == .init())
        let written = await params(world.host, "skills/config/write")
        #expect(written?["enabled"] as? Bool == false && written?["path"] as? String == "/w/.codex/skills/lint/SKILL.md" && written?["name"] == nil)
        let reload = await params(world.host, "config/batchWrite")
        #expect((reload?["edits"] as? [Any])?.isEmpty == true && reload?["reloadUserConfig"] as? Bool == true)
        #expect(await sent(world.host, "config/read").isEmpty)

        world.server.setResults("skills/config/write", [Self.writeError("configLayerReadonly")])
        let error = await rejection { try await self.edit(world, .skill(name: "lint", state: "on")) }
        #expect(error?.params["reason"] == "locked" && error?.description.contains("English") == false)
        #expect(await sent(world.host, "config/batchWrite").count == 1)
    }

    @Test("hook の信頼：読む画面の editKey で今の一覧から hook を引き、今の中身の hash で信頼する。一覧に無い鍵（中身が替わった）は not_found で書かない。Claude だけの書き込みは engine_unsupported")
    func editSettingsHookState() async throws {
        let world = try await make()
        let listing = #"{"data":[{"cwd":"/w","hooks":[{"key":"/Users/u/.codex/config.toml:stop:0:0","eventName":"stop","handlerType":"command","command":"echo a","async":false,"matcher":null,"timeoutSec":600,"sourcePath":"/Users/u/.codex/config.toml","source":"user","displayOrder":0,"enabled":true,"isManaged":false,"currentHash":"sha256:cur","trustStatus":"untrusted"}],"warnings":[],"errors":[]}]}"#
        world.server.setResults("hooks/list", [listing])
        world.server.setResults("config/read", [Self.userLayer("sha256:v1")])
        world.server.setResults("config/batchWrite", [#"{"status":"ok","version":"sha256:v2","filePath":"/Users/u/.codex/config.toml","overriddenMetadata":null}"#])
        try await world.conversation.start(resume: false)
        let key = try #require(try payload(try await control(world, .hooks), as: ConversationHooks.self).hooks.first?.editKey)
        #expect(try await edit(world, .hookState(editKey: key, enabled: nil, trusted: true)) == .init())
        let edits = (await params(world.host, "config/batchWrite"))?["edits"] as? [[String: Any]]
        let state = edits?.first?["value"] as? [String: Any]
        #expect(edits?.first?["keyPath"] as? String == "hooks.state")
        #expect((state?["/Users/u/.codex/config.toml:stop:0:0"] as? [String: Any])?["trusted_hash"] as? String == "sha256:cur")

        let stale = await rejection { try await self.edit(world, .hookState(editKey: String(repeating: "0", count: 64), enabled: nil, trusted: true)) }
        #expect(stale?.params["reason"] == "not_found")
        let claudeOnly = await rejection { try await self.edit(world, .memory(autoMemory: false, autoDream: nil)) }
        #expect(claudeOnly?.code == .engineUnsupported)
        #expect(await sent(world.host, "config/batchWrite").count == 1)
    }

    private static let pluginList = #"{"marketplaces":[{"name":"tbmkt","path":"/m/.claude-plugin/marketplace.json","plugins":[{"id":"plain@tbmkt","name":"plain","installed":true,"enabled":true,"localVersion":"1.0.1","source":{"type":"local","path":"/m/plugins/plain"},"interface":{"shortDescription":"短い"}},{"id":"other@tbmkt","name":"other","installed":false,"enabled":false,"source":{"type":"local","path":"/m/plugins/other"}}]},{"name":"openai-curated-remote","path":null,"plugins":[{"id":"gmail@openai-curated-remote","name":"gmail","installed":false,"enabled":false,"source":{"type":"remote"},"interface":{"shortDescription":"Mail"}}]}],"marketplaceLoadErrors":[]}"#

    @Test("plugin を入れる：一覧で id から引き、ファイルの marketplace は marketplacePath、目録だけの marketplace は remoteMarketplaceName で入れる。ログインが要るアプリの名前を返す。更新は入れ直し")
    func installsCodexPlugin() async throws {
        let world = try await make()
        world.server.setResults("plugin/list", [Self.pluginList])
        world.server.setResults("plugin/install", [#"{"authPolicy":"ON_INSTALL","appsNeedingAuth":[{"id":"app-1","name":"Gmail"}]}"#, #"{"authPolicy":"ON_INSTALL","appsNeedingAuth":[]}"#])
        try await world.conversation.start(resume: false)
        #expect(try await edit(world, .plugin(op: .install, id: "gmail@openai-curated-remote")) == .init(appsNeedingAuth: ["Gmail"]))
        let remote = await params(world.host, "plugin/install")
        #expect(remote?["pluginName"] as? String == "gmail" && remote?["remoteMarketplaceName"] as? String == "openai-curated-remote" && remote?["marketplacePath"] == nil)
        #expect(try await edit(world, .plugin(op: .update, id: "plain@tbmkt")) == .init())
        let local = await params(world.host, "plugin/install")
        #expect(local?["pluginName"] as? String == "plain" && local?["marketplacePath"] as? String == "/m/.claude-plugin/marketplace.json")
        #expect((await params(world.host, "plugin/list"))?["cwds"] as? [String] == ["/w"])

        for (bad, expected) in [
            (ConversationSettingsEdit.plugin(op: .update, id: "other@tbmkt"), "not_found"), (.plugin(op: .install, id: "nope@tbmkt"), "not_found"),
            (.plugin(op: .uninstall, id: "other@tbmkt"), "not_found"), (.plugin(op: .enable, id: "other@tbmkt"), "not_found"),
        ] {
            let error = await rejection { try await self.edit(world, bad) }
            #expect(error?.params["reason"] == expected, "\(bad)")
        }
        for bad in [ConversationSettingsEdit.plugin(op: .purge, id: "plain@tbmkt"), .plugin(op: .install, id: "plain@tbmkt", scope: .project), .plugin(op: .install, id: "plain@tbmkt", acceptCommand: "x")] {
            #expect(await rejection { try await self.edit(world, bad) }?.code == .invalidRequest, "\(bad)")
        }
        let installs = await sent(world.host, "plugin/install").count
        let uninstalls = await sent(world.host, "plugin/uninstall").count
        #expect(installs == 2 && uninstalls == 0)
    }

    @Test("plugin の有効と無効は config の plugins の表に upsert する（id の点で鍵が切れないように）。marketplace を外すときは、codex が plugin を残すので先に入れた plugin を外す")
    func togglesPluginAndRemovesMarketplace() async throws {
        let world = try await make()
        world.server.setResults("plugin/list", [Self.pluginList])
        world.server.setResults("config/read", [Self.userLayer("sha256:v1")])
        world.server.setResults("config/batchWrite", [#"{"status":"ok","version":"sha256:v2","filePath":"/Users/u/.codex/config.toml","overriddenMetadata":null}"#])
        world.server.setResults("marketplace/remove", [#"{"marketplaceName":"tbmkt","installedRoot":null}"#])
        try await world.conversation.start(resume: false)
        #expect(try await edit(world, .plugin(op: .disable, id: "plain@tbmkt")) == .init())
        let edits = (await params(world.host, "config/batchWrite"))?["edits"] as? [[String: Any]]
        #expect(edits?.first?["keyPath"] as? String == "plugins" && edits?.first?["mergeStrategy"] as? String == "upsert")
        #expect(((edits?.first?["value"] as? [String: Any])?["plain@tbmkt"] as? [String: Any])?["enabled"] as? Bool == false)

        _ = try await edit(world, .marketplace(op: .remove, name: "tbmkt"))
        let order = await world.host.written().compactMap { $0["method"] as? String }.filter { $0 == "plugin/uninstall" || $0 == "marketplace/remove" }
        #expect(order == ["plugin/uninstall", "marketplace/remove"])
        #expect((await params(world.host, "plugin/uninstall"))?["pluginId"] as? String == "plain@tbmkt")

        // 途中で失敗したら、外せた分は戻さず、一覧を読み直してから失敗を返す
        world.server.setResults("marketplace/remove", [Self.writeError("other")])
        let lists = await sent(world.host, "plugin/list").count
        let error = await rejection { try await self.edit(world, .marketplace(op: .remove, name: "tbmkt")) }
        #expect(error?.code == .sessionCommandFailed)
        #expect(await sent(world.host, "plugin/list").count == lists + 2)
        #expect(world.logs.joined.contains("conversation plugins partially written") && !world.logs.joined.contains("English"))
    }

    @Test("plugin の一覧：入れたものと、入れていないものを文字で絞ったもの。marketplace はファイルのパスつき")
    func listsCodexPlugins() async throws {
        let world = try await make()
        world.server.setResults("plugin/list", [Self.pluginList])
        try await world.conversation.start(resume: false)
        let all = try payload(try await world.conversation.control(ConversationControlRequest(kind: .plugins)), as: ConversationPlugins.self)
        #expect(
            all.installed == [
                .init(id: "plain@tbmkt", name: "plain", marketplace: "tbmkt", description: "短い", version: "1.0.1", scope: "user", installed: true, enabled: true, source: "local")
            ])
        #expect(all.available.map(\.id) == ["other@tbmkt", "gmail@openai-curated-remote"] && all.availableTotal == 2)
        #expect(all.marketplaces == [.init(name: "tbmkt", source: "/m/.claude-plugin/marketplace.json"), .init(name: "openai-curated-remote")])
        let mail = try payload(try await world.conversation.control(ConversationControlRequest(kind: .plugins, value: "mail")), as: ConversationPlugins.self)
        #expect(mail.available.map(\.id) == ["gmail@openai-curated-remote"])
    }

    @Test("hook の書き換えられるか：daemon が置き換え・外すのと同じく、管理者のものでなくユーザーの config.toml（user の層のファイル）にある hook だけ。hooks.json の hook は有効と信頼だけ替えられる")
    func hookEditable() async throws {
        let world = try await make()
        world.server.setResults("config/read", [Self.userLayer("sha256:v1")])
        world.server.setResults("hooks/list", [
            #"{"data":[{"cwd":"/w","hooks":[{"key":"/Users/u/.codex/config.toml:stop:0:0","eventName":"stop","handlerType":"command","command":"a","sourcePath":"/Users/u/.codex/config.toml","source":"user","isManaged":false,"currentHash":"h1","trustStatus":"trusted"},{"key":"/Users/u/.codex/hooks.json:stop:0:0","eventName":"stop","handlerType":"command","command":"b","sourcePath":"/Users/u/.codex/hooks.json","source":"user","isManaged":false,"currentHash":"h2","trustStatus":"trusted"},{"key":"/etc/codex/config.toml:stop:0:0","eventName":"stop","handlerType":"command","command":"c","sourcePath":"/Users/u/.codex/config.toml","source":"system","isManaged":true,"currentHash":"h3","trustStatus":"managed"}],"warnings":[],"errors":[]}]}"#,
        ])
        try await world.conversation.start(resume: false)
        let hooks = try payload(try await control(world, .hooks), as: ConversationHooks.self).hooks
        #expect(hooks.map(\.editable) == [true, false, false])
        #expect(hooks.map { $0.editKey != nil } == [true, true, false])
        #expect((await params(world.host, "config/read"))?["includeLayers"] as? Bool == true)
    }

    @Test("MCP の server の一覧：設定の server と thread の実行中の状態を合わせ、有効・無効と層を載せる。状態は Claude の言葉に写す。設定のヘッダ・env・url の値は写さない")
    func mcpStatus() async throws {
        let world = try await make()
        world.server.setResults("config/read", [
            #"{"config":{"mcp_servers":{"ctx":{"url":"https://mcp.example/secret-path","http_headers":{"KEY":"secret-header-value"}},"off":{"command":"/bin/off","env":{"TOKEN":"secret-env"},"enabled":false},"repo":{"command":"/bin/repo"}}},"origins":{"mcp_servers.ctx.url":{"name":{"type":"user","file":"/Users/u/.codex/config.toml"},"version":"v"},"mcp_servers.off.command":{"name":{"type":"user","file":"/Users/u/.codex/config.toml"},"version":"v"},"mcp_servers.repo.command":{"name":{"type":"project","dotCodexFolder":"/w/.codex"},"version":"v"}}}"#,
        ])
        world.server.setResults("mcpServerStatus/list", [
            #"{"data":[{"name":"ctx","runtimeStatus":"connected","serverInfo":{"name":"Ctx","version":"1.2"},"tools":{"a":{},"b":{}},"authStatus":"unsupported"},{"name":"taskboard","runtimeStatus":"starting","tools":{}}],"nextCursor":"c2"}"#,
            #"{"data":[{"name":"off","runtimeStatus":"disabled","tools":{}},{"name":"repo","runtimeStatus":"authenticationRequired","tools":{}}],"nextCursor":null}"#,
        ])
        try await world.conversation.start(resume: false)
        let response = try await control(world, .mcpStatus)
        #expect(response.payloadJSON.map { $0.contains("secret") } == false)
        let status = try payload(response, as: ConversationMcpStatus.self)
        #expect(
            status.mcpServers == [
                .init(name: "ctx", status: "connected", scope: "user", serverName: "Ctx", serverVersion: "1.2", toolCount: 2, transport: "http", enabled: true),
                .init(name: "taskboard", status: "pending", toolCount: 0),
                .init(name: "off", status: "disabled", scope: "user", toolCount: 0, transport: "stdio", enabled: false),
                .init(name: "repo", status: "needs-auth", scope: "project", toolCount: 0, transport: "stdio", enabled: true),
            ])
        let pages = await sent(world.host, "mcpServerStatus/list").compactMap { $0["params"] as? [String: Any] }
        #expect(pages.map { $0["cursor"] as? String } == [nil, "c2"] && pages.allSatisfy { $0["threadId"] as? String == "th-1" })

        // 実行中の状態を読めない（見切った・断られた）ときは、設定だけで返す
        world.server.setResults("mcpServerStatus/list", [#"{"error":{"code":-32603,"message":"English detail"},"id":"$ID"}"#])
        let fallback = try payload(try await control(world, .mcpStatus), as: ConversationMcpStatus.self)
        #expect(
            fallback.mcpServers == [
                .init(name: "ctx", status: "pending", scope: "user", transport: "http", enabled: true),
                .init(name: "off", status: "disabled", scope: "user", transport: "stdio", enabled: false),
                .init(name: "repo", status: "pending", scope: "project", transport: "stdio", enabled: true),
            ])
        #expect(ConversationTiming().mcpStatus < .seconds(60))
    }

    @Test("MCP の server の実行中の状態は、全部の頁で 1 つの期限で待つ（頁ごとの期限にすると、遅い頁が続くと期限を何倍も超える）。過ぎたら設定だけで返す")
    func mcpStatusDeadlineIsOverall() async throws {
        let world = try await make()
        world.server.setResults("config/read", [#"{"config":{"mcp_servers":{"ctx":{"command":"/bin/ctx"}}},"origins":{},"layers":[]}"#])
        world.server.setResults("mcpServerStatus/list", [FakeThreadServer.noReply])
        try await world.conversation.start(resume: false)
        let clock = ContinuousClock()
        let started = clock.now
        let control = Task { try await self.control(world, .mcpStatus) }
        // 1 頁目は期限（400 ms）の 6 割ほどで次の頁つきで返り、2 頁目は返らない
        #expect(await eventually { await self.sent(world.host, "mcpServerStatus/list").count == 1 })
        try await Task.sleep(for: .milliseconds(250))
        let first = try #require(await sent(world.host, "mcpServerStatus/list").first?["id"] as? String)
        await world.host.emit(#"{"id":"\#(first)","result":{"data":[{"name":"ctx","runtimeStatus":"connected","tools":{}}],"nextCursor":"c2"}}"#)
        let status = try payload(try await control.value, as: ConversationMcpStatus.self)
        let elapsed = started.duration(to: clock.now)
        #expect(elapsed < .milliseconds(550), "\(elapsed)")
        #expect(await sent(world.host, "mcpServerStatus/list").count == 2)
        #expect(status.mcpServers == [.init(name: "ctx", status: "pending", transport: "stdio", enabled: true)])
    }

    @Test("MCP の server の層：有効・無効の鍵の出どころを優先し、無ければその server の鍵の出どころのうち最も優先される層（layers の並び）。鍵の辞書順では選ばない")
    func mcpStatusScopePriority() async throws {
        let world = try await make()
        world.server.setResults("config/read", [
            #"{"config":{"mcp_servers":{"ctx":{"command":"/bin/ctx","enabled":false},"both":{"args":["a"],"url":"https://x"}}},"origins":{"mcp_servers.ctx.command":{"name":{"type":"user","file":"/u/config.toml"},"version":"v"},"mcp_servers.ctx.enabled":{"name":{"type":"project","dotCodexFolder":"/w/.codex"},"version":"v"},"mcp_servers.both.args":{"name":{"type":"user","file":"/u/config.toml"},"version":"v"},"mcp_servers.both.url":{"name":{"type":"project","dotCodexFolder":"/w/.codex"},"version":"v"}},"layers":[{"name":{"type":"project","dotCodexFolder":"/w/.codex"},"version":"p","config":{}},{"name":{"type":"user","file":"/u/config.toml"},"version":"u","config":{}},{"name":{"type":"system","file":"/etc/codex/config.toml"},"version":"s","config":{}}]}"#,
        ])
        world.server.setResults("mcpServerStatus/list", [#"{"data":[],"nextCursor":null}"#])
        try await world.conversation.start(resume: false)
        let status = try payload(try await control(world, .mcpStatus), as: ConversationMcpStatus.self)
        #expect(status.mcpServers.map(\.name) == ["both", "ctx"])
        #expect(status.mcpServers.map(\.scope) == ["project", "project"])
        #expect((await params(world.host, "config/read"))?["includeLayers"] as? Bool == true)
    }

    @Test("marketplace を外す前の一覧の形が違う（marketplaces が無い・id や installed が無い）ときは、空とみなさず marketplace を外さない")
    func marketplaceRemovalNeedsReadableList() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        for list in [#"{}"#, #"{"marketplaces":[{"name":"tbmkt","plugins":[{"name":"x","installed":true}]}]}"#, #"{"marketplaces":[{"name":"tbmkt","plugins":[{"id":"x@tbmkt"}]}]}"#] {
            world.server.setResults("plugin/list", [list])
            let error = await rejection { try await self.edit(world, .marketplace(op: .remove, name: "tbmkt")) }
            #expect(error?.status == 502, "\(list)")
        }
        let removes = await sent(world.host, "marketplace/remove").count
        let uninstalls = await sent(world.host, "plugin/uninstall").count
        #expect(removes == 0 && uninstalls == 0)
    }

    @Test("codex に無い操作（脇の質問・作業フォルダの追加・ログインのコードを貼り返す・sandbox の読む画面）は engine_unsupported で断り、app-server に送らない")
    func refusesClaudeOnlyControls() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        let before = await world.host.written().count
        for kind in [ConversationControlRequest.Kind.sideQuestion, .addDirectory, .loginCode, .sandbox] {
            do {
                _ = try await control(world, kind, "x")
                Issue.record("\(kind) を受けた")
            } catch let error as ConversationError {
                #expect(error.code == .engineUnsupported && error.params["engine"] == "codex", "\(kind)")
            }
        }
        #expect(await world.host.written().count == before)
    }

    @Test("止まった会話の読む画面は、会話が止まっていると断る")
    func readoutsNeedLiveConversation() async throws {
        let world = try await make()
        for kind in [ConversationControlRequest.Kind.memory, .exportConversation, .listBackgroundTasks, .setCwd, .editSettings] {
            do {
                _ = try await control(world, kind, "/tmp")
                Issue.record("\(kind) を受けた")
            } catch let error as ConversationError {
                #expect(error.code == ConversationError.stopped(world.id).code, "\(kind)")
            }
        }
    }
}

@Suite("codex の応答の読み替え")
struct CodexControlsTests {
    @Test("出力の末尾は 8KiB までを文字の切れ目で残し、全体のバイト数を数える（日本語と英語）")
    func outputTail() {
        var ascii = CodexControls.OutputTail()
        ascii.append("tick 1\n")
        #expect(ascii.output == ConversationTaskOutput(output: "tick 1\n", totalBytes: 7, truncated: true))
        var japanese = CodexControls.OutputTail()
        japanese.append(String(repeating: "あ", count: 2000))
        japanese.append(String(repeating: "い", count: 1000) + "x")
        #expect(japanese.output.totalBytes == 9001)
        // 8192 バイトに収まる所で、3 バイトの文字を割らずに残す：x の 1 バイト + 3 バイトの文字 2730 個
        #expect(japanese.output.output.utf8.count == 8191)
        #expect(japanese.output.output.hasSuffix(String(repeating: "い", count: 1000) + "x"))
        #expect(japanese.output.output.hasPrefix("あ"))
        var empty = CodexControls.OutputTail()
        empty.append("")
        #expect(empty.output == ConversationTaskOutput(output: "", totalBytes: 0, truncated: true))
    }

    @Test("書き出しのファイル名：時刻と最初の指示の 1 行目（文字と数字だけ、50 字まで）。指示が無い・記号だけなら conversation")
    func exportFilename() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-20T05:30:09Z"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(CodexControls.exportFilename(firstPrompt: "Fix the login bug!\nmore", at: date, timeZone: utc) == "2026-10-20-053009-fix-the-login-bug.txt")
        #expect(CodexControls.exportFilename(firstPrompt: "一覧を見せて", at: date, timeZone: utc) == "2026-10-20-053009-一覧を見せて.txt")
        #expect(CodexControls.exportFilename(firstPrompt: nil, at: date, timeZone: utc) == "2026-10-20-053009-conversation.txt")
        #expect(CodexControls.exportFilename(firstPrompt: "!!!", at: date, timeZone: utc) == "2026-10-20-053009-conversation.txt")
        #expect(CodexControls.exportFilename(firstPrompt: String(repeating: "a", count: 80), at: date, timeZone: utc) == "2026-10-20-053009-" + String(repeating: "a", count: 50) + ".txt")
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(CodexControls.exportFilename(firstPrompt: "x", at: date, timeZone: tokyo) == "2026-10-20-143009-x.txt")
    }

    @Test("設定の値の文字：真偽は true・false、数はそのまま、表は詰めた JSON、null は無し")
    func settingText() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(#"{"b":true,"n":1,"s":"x","o":{"granular":{"rules":false}},"z":null}"#.utf8)) as? [String: Any])
        #expect(CodexControls.text(object["b"]) == "true")
        #expect(CodexControls.text(object["n"]) == "1")
        #expect(CodexControls.text(object["s"]) == "x")
        #expect(CodexControls.text(object["o"]) == #"{"granular":{"rules":false}}"#)
        #expect(CodexControls.text(object["z"]) == nil)
        #expect(CodexControls.text(nil) == nil)
    }

    @Test("ログインの答え：device code でないもの・https でないページ・コードが無いものは使わない")
    func loginAnswer() {
        let good: [String: Any] = ["type": "chatgptDeviceCode", "loginId": "L", "verificationUrl": "https://auth.openai.com/codex/device", "userCode": "AB-12"]
        #expect(CodexControls.login(good)?.loginID == "L")
        var browser = good
        browser["type"] = "chatgpt"
        #expect(CodexControls.login(browser) == nil)
        var spaced = good
        spaced["userCode"] = "AB 12"
        #expect(CodexControls.login(spaced) == nil)
        var missing = good
        missing["userCode"] = nil
        #expect(CodexControls.login(missing) == nil)
    }
}

// MARK: 裏のターミナルの数

extension CodexConversationTests {
    private static func command(_ event: String, item: String, turn: String) -> String {
        let status = event == "item/started" ? "inProgress" : "completed"
        return #"{"method":"\#(event)","params":{"threadId":"th-1","turnId":"\#(turn)","item":{"type":"commandExecution","id":"\#(item)","command":"/bin/zsh -lc 'npm run dev'","cwd":"/w","processId":"7","source":"unifiedExecStartup","status":"\#(status)","aggregatedOutput":null,"exitCode":null}}}"#
    }

    private static func turn(_ event: String, _ turn: String) -> String {
        #"{"method":"\#(event)","params":{"threadId":"th-1","turn":{"id":"\#(turn)","status":"\#(event == "turn/started" ? "inProgress" : "completed")","error":null,"durationMs":null}}}"#
    }

    @Test("裏のターミナルの数：ターンの後も終わっていないコマンドを数え、動いている間は idle でも止めない。生成中のコマンドは数えず、item/completed で外す")
    func countsBackgroundTerminals() async throws {
        let world = try await make()
        try await world.conversation.start(resume: false)
        await world.host.emit(Self.turn("turn/started", "t1"))
        await world.host.emit(Self.command("item/started", item: "c1", turn: "t1"))
        #expect(await eventually { await world.conversation.snapshot().phase == .running })
        #expect(await world.conversation.snapshot().backgroundTasks == 0)
        await world.host.emit(Self.turn("turn/completed", "t1"))
        #expect(await eventually { await world.conversation.snapshot().backgroundTasks == 1 })
        let state = await world.conversation.snapshot()
        #expect(state.backgroundTasksKnown && state.phase == .idle)
        #expect(await !world.conversation.isStoppable(before: .distantFuture))
        #expect(await !world.conversation.stopIfIdle(before: .distantFuture))
        #expect(await world.conversation.isLive)

        await world.host.emit(Self.command("item/completed", item: "c1", turn: "t1"))
        #expect(await eventually { await world.conversation.snapshot().backgroundTasks == 0 })
        #expect(await world.conversation.isStoppable(before: .distantFuture))
    }

    @Test("裏のターミナルの数：控えの行が落ちたら分からないとし、一覧を読み直して合わせる（知らなかったものを足し、一覧に無いものを外す）。分かるまで idle でも止めない")
    func reconcilesBackgroundAfterGap() async throws {
        let world = try await make()
        world.server.setResults("thread/backgroundTerminals/list", [
            #"{"data":[{"itemId":"c9","processId":"9","command":"sleep 99","cwd":"/w","osPid":null,"cpuPercent":null,"rssKb":null}],"nextCursor":null}"#,
        ])
        try await world.conversation.start(resume: false)
        await world.host.emit(Self.turn("turn/started", "t1"))
        await world.host.emit(Self.command("item/started", item: "c1", turn: "t1"))
        await world.host.emit(Self.turn("turn/completed", "t1"))
        #expect(await eventually { await world.conversation.snapshot().backgroundTasks == 1 })
        let listsBefore = await sent(world.host, "thread/backgroundTerminals/list").count
        await world.host.gap(through: await world.host.seq)
        #expect(await eventually { await self.sent(world.host, "thread/backgroundTerminals/list").count == listsBefore + 1 })
        #expect(
            await eventually {
                let state = await world.conversation.snapshot()
                return state.backgroundTasksKnown && state.backgroundTasks == 1
            })
        let output = try await world.conversation.control(ConversationControlRequest(kind: .listBackgroundTasks))
        #expect(try WireJSON.decoder().decode(ConversationBackgroundTasks.self, from: Data(try #require(output.payloadJSON).utf8)).tasks.map(\.id) == ["9"])
        // c1 は一覧に無いので外れ、c9 を数えている
        await world.host.emit(Self.command("item/completed", item: "c1", turn: "t1"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await world.conversation.snapshot().backgroundTasks == 1)
        await world.host.emit(Self.command("item/completed", item: "c9", turn: "t0"))
        #expect(await eventually { await world.conversation.snapshot().backgroundTasks == 0 })
    }

    @Test("裏のターミナルの数：daemon が起き直したら、控えを読み終えてから一覧で合わせる（控えの頭より前に始まったコマンドは控えに無い）")
    func reconcilesBackgroundAfterAttach() async throws {
        let first = try await make()
        first.server.setResults("thread/backgroundTerminals/list", [
            #"{"data":[{"itemId":"c-old","processId":"3","command":"npm run dev","cwd":"/w","osPid":null,"cpuPercent":null,"rssKb":null}],"nextCursor":null}"#,
        ])
        try await first.conversation.start(resume: false)
        let record = try #require(try first.store.conversation(id: first.id))
        let second = CodexConversation(record: record, context: first.context)
        await first.host.connect(second.inbox, key: first.id)
        let lastSeq = await first.host.seq
        await second.attach(
            process: AgentHostProcessInfo(key: first.id, pid: 42, alive: true, exit: nil, lastSeq: lastSeq, firstSeq: 1, keptBytes: 0, startedAt: 0))
        #expect(
            await eventually {
                let state = await second.snapshot()
                return state.backgroundTasksKnown && state.backgroundTasks == 1
            })
        #expect(await !second.isStoppable(before: .distantFuture))
    }
}

// MARK: コネクタの欄（切り替え・再接続・認証・解除）

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

/// 会話を作った後にできる host へ行を流す（会話の Context の偽物から使う）
private final class LateHost: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FakeHost?
    var host: FakeHost? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func emit(_ line: String) async { await host?.emit(line) }
}

extension CodexConversationTests {
    private static let authorizationURL =
        "https://auth.example/authorize?client_id=c&redirect_uri=http%3A%2F%2F127.0.0.1%3A47828%2Fcallback&state=S1"
    private static let callbackURL = "http://127.0.0.1:47828/callback?code=C1&state=S1"

    private static func loginCompleted(_ loginId: String, success: Bool) -> String {
        #"{"method":"mcpServer/oauthLogin/completed","params":{"name":"ctx","threadId":null,"loginId":"\#(loginId)","success":\#(success)}}"#
    }

    @Test("コネクタの切り替えはユーザーの設定に書いて読み直させ、再接続は全部を読み直させる。名前の無い要求は断る")
    func connectorToggleAndReconnect() async throws {
        let world = try await make()
        world.server.setResults("config/read", [Self.userLayer("sha256:v1", #"{"mcp_servers":{"ctx":{"command":"/bin/ctx"}}}"#)])
        world.server.setResults("config/batchWrite", [#"{"status":"ok","version":"sha256:v2","filePath":"/Users/u/.codex/config.toml","overriddenMetadata":null}"#])
        try await world.conversation.start(resume: false)
        let toggled = try await world.conversation.control(ConversationControlRequest(kind: .mcpToggle, value: "ctx", enabled: false))
        #expect(toggled.payloadJSON == nil)
        let edits = (await params(world.host, "config/batchWrite"))?["edits"] as? [[String: Any]]
        #expect(edits?.first?["keyPath"] as? String == "mcp_servers.ctx.enabled" && edits?.first?["value"] as? Bool == false)
        #expect(await sent(world.host, "config/mcpServer/reload").count == 1)
        _ = try await control(world, .mcpReconnect, "ctx")
        #expect(await sent(world.host, "config/mcpServer/reload").count == 2)
        for request in [ConversationControlRequest(kind: .mcpToggle, value: "ctx"), ConversationControlRequest(kind: .mcpReconnect)] {
            let error = await rejection { try await world.conversation.control(request) }
            #expect(error?.code == .invalidRequest, "\(request.kind)")
        }
        #expect(await sent(world.host, "config/mcpServer/reload").count == 2)
    }

    @Test("コネクタの認証：会話の app-server で始めて認証のページを返し、応答の行まで控えを切る。loginId を返さない古い codex は codex_outdated")
    func connectorAuthenticate() async throws {
        let world = try await make()
        world.server.setResults("mcpServer/oauth/login", [
            #"{"authorizationUrl":"\#(Self.authorizationURL)","loginId":"L1"}"#,
            #"{"authorizationUrl":"\#(Self.authorizationURL)"}"#,
        ])
        try await world.conversation.start(resume: false)
        let authentication = try payload(try await control(world, .mcpAuthenticate, "ctx"), as: ConversationMcpAuthentication.self)
        #expect(authentication == ConversationMcpAuthentication(authURL: Self.authorizationURL, requiresUserAction: true, callbackExpected: true))
        let login = await params(world.host, "mcpServer/oauth/login")
        #expect(login?["name"] as? String == "ctx" && login?["timeoutSecs"] as? Int == 600)
        #expect(await world.host.requests.contains { $0.op == .trim && ($0.through ?? 0) > 0 })
        #expect(!world.logs.joined.contains("auth.example"))

        let error = await rejection { try await self.control(world, .mcpAuthenticate, "ctx") }
        #expect(error?.code == .codexOutdated)
    }

    @Test("ほかの端末で受けた戻り先は、待っている認証の redirect と同じものだけをこのマシンで 1 度開き、codex が認証を終えて読み直してから返す。失敗と、待ちの無い送り直しは断る")
    func connectorCallback() async throws {
        let opened = Recorder()
        let codex = LateHost()
        let world = try await make { context in
            context.openCallback = { url in
                opened.add(url.absoluteString)
                // codex の待ち受けが戻り先を受けて token を取り、終わりを知らせる
                await codex.emit(Self.loginCompleted(opened.all.count == 1 ? "L1" : "L2", success: opened.all.count == 1))
            }
        }
        codex.host = world.host
        world.server.setResults("mcpServer/oauth/login", [
            #"{"authorizationUrl":"\#(Self.authorizationURL)","loginId":"L1"}"#,
            #"{"authorizationUrl":"\#(Self.authorizationURL)","loginId":"L2"}"#,
        ])
        try await world.conversation.start(resume: false)
        _ = try await control(world, .mcpAuthenticate, "ctx")

        func callback(_ url: String) async -> ConversationError? {
            await rejection { try await world.conversation.control(ConversationControlRequest(kind: .mcpOAuthCallback, value: "ctx", callbackURL: url)) }
        }
        #expect(await callback("http://127.0.0.1:9999/callback?code=C1&state=S1")?.code == .invalidRequest)
        #expect(await callback("http://127.0.0.1:47828/callback?code=C1&state=other")?.code == .invalidRequest)
        #expect(opened.all.isEmpty)
        #expect(await callback(Self.callbackURL) == nil)
        #expect(opened.all == [Self.callbackURL])
        #expect(await sent(world.host, "config/mcpServer/reload").count == 1)
        // 応答だけが失われて送り直した：もう待っていない
        #expect(await callback(Self.callbackURL)?.code == .sessionCommandFailed)
        #expect(opened.all.count == 1)

        // codex が認証に失敗した
        _ = try await control(world, .mcpAuthenticate, "ctx")
        #expect(await callback(Self.callbackURL)?.code == .sessionCommandFailed)
        #expect(await sent(world.host, "config/mcpServer/reload").count == 1)
    }

    @Test("この Mac の会話は codex が戻り先を自分で受ける：認証が終わったら、制御を待たずに全部を読み直させる")
    func connectorLoginCompletedHere() async throws {
        let world = try await make()
        world.server.setResults("mcpServer/oauth/login", [#"{"authorizationUrl":"\#(Self.authorizationURL)","loginId":"L1"}"#])
        try await world.conversation.start(resume: false)
        _ = try await control(world, .mcpAuthenticate, "ctx")
        // 照らし合わせない知らせ（ほかの認証）は見ない
        await world.host.emit(Self.loginCompleted("other", success: true))
        await world.host.emit(Self.loginCompleted("L1", success: true))
        #expect(await eventually { await self.sent(world.host, "config/mcpServer/reload").count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sent(world.host, "config/mcpServer/reload").count == 1)
    }

    @Test("コネクタの認証の解除：設定にある名前だけ codex mcp logout に渡し、会話の app-server に読み直させる。断られたら失敗")
    func connectorClearAuth() async throws {
        let names = Recorder()
        let refuse = Recorder()
        let world = try await make { context in
            context.logoutConnector = { name in
                names.add(name)
                if !refuse.all.isEmpty { throw CodexMachine.LogoutError.refused }
            }
        }
        world.server.setResults("config/read", [#"{"config":{"mcp_servers":{"ctx":{"url":"https://mcp.example"}}},"origins":{},"layers":[]}"#])
        try await world.conversation.start(resume: false)
        _ = try await control(world, .mcpClearAuth, "ctx")
        #expect(names.all == ["ctx"])
        #expect(await sent(world.host, "config/mcpServer/reload").count == 1)

        #expect(await rejection { try await self.control(world, .mcpClearAuth, "nope") }?.code == .invalidRequest)
        #expect(names.all == ["ctx"])
        refuse.add("on")
        #expect(await rejection { try await self.control(world, .mcpClearAuth, "ctx") }?.code == .sessionCommandFailed)
        #expect(await sent(world.host, "config/mcpServer/reload").count == 1)
    }
}
