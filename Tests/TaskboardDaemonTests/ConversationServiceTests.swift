import Foundation
import Logging
import TaskboardKit
import Testing
import TestSupport

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-service")

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

/// 偽物の worktree。`<cwd>/.wt/<branch>` に切ったことにする
actor FakeWorktrees {
    private(set) var made: [(cwd: String, branch: String)] = []

    func create(_ cwd: String, _ spec: LaunchRequest.WorktreeSpec) -> String {
        made.append((cwd, spec.branch))
        return "\(cwd)/.wt/\(spec.branch)"
    }
}

/// ServiceWorld のログインシェルの代わり（会話を起こすたびにログインシェルの環境を取る）。transcript の置き場（CLAUDE_CONFIG_DIR）を symlink のあるフォルダに向ける
enum FakeLoginShell {
    static let executable = SharedExecutable(
        name: "tb-test-login-shell.sh",
        script: "#!/bin/sh\nprintf '\\n\(LoginShellEnvironment.marker)\\n'\nCLAUDE_CONFIG_DIR=\"$(dirname \"$0\")/claude\" exec /usr/bin/env -0\n")
}

/// 偽物の host に繋いだ service。host の知らせは 1 本の流れで順に `route` へ回す（本物の `run` と同じ）
struct ServiceWorld {
    let service: ConversationService
    let host: FakeHost
    let store: Store
    let state: DaemonState
    let reservations: SessionReservations
    let worktrees: FakeWorktrees
    let directory: URL
    let task: Int
    let pump: Task<Void, Never>

    static func make(
        verified: Bool = true, slots: ConversationSlots = ConversationSlots(soft: 32, hard: 64),
        configure: (inout ConversationService.Environment) -> Void = { _ in }
    ) async throws -> ServiceWorld {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        await state.upsert(task)
        let directory = FileManager.default.temporaryDirectory.appending(path: "tb-service-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if verified {
            try VerifiedCLI.record(
                .init(version: "2.1.302", path: "/bin/sh", capabilities: ClaudeConversation.requiredCapabilities, verifiedAt: Date()), .claude,
                supportDirectory: directory)
        }
        var timing = ConversationTiming()
        timing.accept = .milliseconds(300)
        timing.control = .seconds(2)
        timing.stopResult = .milliseconds(300)
        timing.stopInput = .milliseconds(300)
        timing.stopTerm = .milliseconds(300)
        let reservations = SessionReservations()
        let shell = try FakeLoginShell.executable.link(in: directory, as: "login-shell")
        var environment = ConversationService.Environment(
            machine: machine, store: store, state: state, supportDirectory: directory, reservations: reservations, hooks: nil, attachments: nil,
            logger: Logger(label: "test"), shell: shell.path, timing: timing)
        environment.slots = slots
        let worktrees = FakeWorktrees()
        environment.createWorktree = { cwd, spec in await worktrees.create(cwd, spec) }
        configure(&environment)
        let host = FakeHost()
        await host.setFollowsKeys()
        let service = ConversationService(environment, host: host)
        await service.shells.hostConnected(version: AgentHostWire.protocolVersion)
        let (stream, continuation) = AsyncStream<AgentHostNotice>.makeStream()
        await host.connect(continuation, key: "")
        let pump = Task { for await notice in stream { await service.route(notice) } }
        return ServiceWorld(
            service: service, host: host, store: store, state: state, reservations: reservations, worktrees: worktrees, directory: directory,
            task: task.number, pump: pump)
    }

    func request(prompt: String? = nil, resume: String? = nil, bound: Bool = true) -> ConversationStartRequest {
        ConversationStartRequest(cwd: directory.path, taskNumber: bound ? task : nil, model: "haiku", prompt: prompt, resumeAgentSessionID: resume)
    }

    var projects: URL { directory.appending(path: "claude/projects") }

    /// その Claude の会話 ID の transcript に行を足す（`(uuid, 種類, 本文)`。親は前の行）
    func append(_ session: String, _ lines: [(String, String, String)]) throws {
        let dir = projects.appending(path: "-w")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(session).jsonl")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var parent = TranscriptLines.last(in: url)?.uuid
        for (uuid, type, body) in lines {
            var object: [String: Any] = [
                "type": type, "uuid": uuid, "parentUuid": parent ?? NSNull(), "sessionId": session, "isSidechain": false,
                "timestamp": "2026-10-19T00:00:00.000Z",
            ]
            object["message"] = type == "user" ? ["role": "user", "content": body] : ["role": "assistant", "content": [["type": "text", "text": body]]]
            text += String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
            parent = uuid
        }
        try Data(text.utf8).write(to: url)
    }

    /// その Claude の会話 ID の transcript を、渡した行で書く（CLI が写した transcript の代わり）
    func write(_ session: String, _ lines: [String]) throws {
        let dir = projects.appending(path: "-w")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appending(path: "\(session).jsonl"))
    }

    func cleanUp() {
        pump.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

extension ConversationStartRequest {
    fileprivate func withModel(_ model: String) -> ConversationStartRequest {
        var copy = self
        copy.model = model
        return copy
    }
}

@Suite("ConversationService（偽物の host）", .serialized)
struct ConversationServiceTests {
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("題を渡さずにタスクから起こした会話は「#番号 タスクの題」になる。渡した題はそのまま、タスクの無い会話は題なし")
    func titleFromTask() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        #expect(try await world.service.start(world.request()).title == "#\(world.task) 会話")
        #expect(try await world.service.start(world.request(bound: false)).title == nil)
        var named = world.request()
        named.title = "調べもの"
        #expect(try await world.service.start(named).title == "調べもの")
    }

    /// CLI 2.1.304 の initialize の `models` の形（数を減らしたもの）
    static let listedModels = #"""
        [{"value":"default","resolvedModel":"claude-opus-5-5[1m]","displayName":"Default (recommended)","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
         {"value":"opus","resolvedModel":"claude-opus-5-5[1m]","displayName":"Opus 5.5","description":"For complex work","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
         {"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet 5.5","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
         {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","supportsThinkingOff":true},
         {"value":"","resolvedModel":"x","displayName":"名前の無い項目"}]
        """#

    @Test("initialize の答えのモデルの一覧を記録して GET の値にし（default と名前の無い項目は落とす）、後の起動とモデルの切り替えはその一覧で確かめる")
    func recordsClaudeModels() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        #expect(await world.service.claudeMachine().models == nil)
        await world.host.setModels(Self.listedModels)
        await world.host.setReply("set_model", "{}")
        let first = try await world.service.start(world.request())
        #expect(first.model == "claude-haiku-5-5", "一覧を受ける前は控えの一覧で確かめる")
        let info = await world.service.claudeMachine()
        #expect(info.models?.map(\.value) == ["opus", "sonnet", "claude-haiku-4-5-20251001"])
        #expect(info.version == "2.1.304" && info.readAt != nil)
        #expect(info.models?.first?.description == "For complex work")
        #expect(info.models?.last?.efforts == nil, "supportsEffort が無いモデルは effort を選べない")
        var sonnet = world.request()
        sonnet.model = "sonnet"
        #expect(try await world.service.start(sonnet).model == "claude-sonnet-5-5")
        var listed = world.request()
        listed.model = "claude-haiku-4-5-20251001"
        #expect(try await world.service.start(listed).model == "claude-haiku-4-5-20251001")
        for name in ["fable", "haiku"] {
            var unlisted = world.request()
            unlisted.model = name
            await #expect(throws: ConversationError.self, "\(name) は一覧に無い") { try await world.service.start(unlisted) }
        }
        _ = try await world.service.control(first.id, ConversationControlRequest(kind: .setModel, value: "sonnet"))
        #expect(try world.store.conversation(id: first.id)?.model == "claude-sonnet-5-5")
        let file = ClaudeModelRecord.file(supportDirectory: world.directory)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    }

    /// 偽の codex を確かめた版として記録した world（`verified` が false なら記録しない。`bin` は呼んだ側が消す）
    private func codexWorld(
        verified: Bool = true, _ configure: @escaping (inout ConversationService.Environment) -> Void = { _ in }
    ) async throws -> (ServiceWorld, URL) {
        let bin = FileManager.default.temporaryDirectory.appending(path: "tb-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let shell = try SharedExecutable(
            name: "tb-test-codex-login-shell.sh",
            script: "#!/bin/sh\nprintf '\\n\(LoginShellEnvironment.marker)\\n'\nPATH=\"$(dirname \"$0\")\" exec /usr/bin/env -0\n"
        ).link(in: bin, as: "login-shell")
        let world = try await ServiceWorld.make {
            $0.shell = shell.path
            configure(&$0)
        }
        if verified {
            try VerifiedCLI.record(.init(version: "0.162.1", path: codex.path, capabilities: [], verifiedAt: Date()), .codex, supportDirectory: world.directory)
        }
        await world.host.setResponder(FakeThreadServer().respond)
        return (world, bin)
    }

    @Test("codex の会話：確かめた版の codex を app-server で起こし、thread の ID を会話 ID にしてタスクに結ぶ。Claude のモデル名の決まりは当てない")
    func startsCodex() async throws {
        let (world, bin) = try await codexWorld()
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let started = try await world.service.start(
            ConversationStartRequest(cwd: world.directory.path, taskNumber: world.task, model: "gpt-6.1-sol", effort: "xhigh", engine: .codex))
        #expect(started.engine == .codex)
        #expect(started.agentSessionID == "th-1")
        #expect(started.model == "gpt-6.1-sol")
        #expect(await world.host.requests.first { $0.op == .spawn }?.argv == [bin.appending(path: "codex").path, "app-server"])
        #expect(try world.store.conversation(id: started.id)?.engine == "codex")
        #expect(try world.store.task(linkedToSession: "th-1")?.number == world.task)
        #expect(try world.store.task(linkedToSession: started.id) == nil)
        await #expect(throws: ConversationError.self) {
            try await world.service.start(ConversationStartRequest(cwd: world.directory.path, model: "gpt 6", engine: .codex))
        }
    }

    @Test("確かめた版の codex が無ければ、codex の会話を起こさずに 409 codex_unverified で断る")
    func codexNeedsVerifiedVersion() async throws {
        let (world, bin) = try await codexWorld(verified: false)
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        do {
            _ = try await world.service.start(ConversationStartRequest(cwd: world.directory.path, taskNumber: world.task, engine: .codex))
            Issue.record("起こした")
        } catch let error as ConversationError {
            #expect(error.status == 409 && error.code == .codexUnverified)
        }
        #expect(!(await world.host.requests.contains { $0.op == .spawn }))
    }

    /// 止まった codex の会話の要求に答える偽の口。thread/items/list は新しい順の 1 頁、thread/fork は写した thread
    private final class CodexOneShotFake: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(method: String, params: [String: Any])] = []
        static let page = #"{"data":[{"turnId":"t2","item":{"type":"agentMessage","id":"a2","text":"二つ目"},"completedAtMs":1792442400000},{"turnId":"t2","item":{"type":"userMessage","id":"u2","clientId":"B2B2B2B2-0000-4000-8000-000000000002","content":[{"type":"text","text":"二"}]},"completedAtMs":1792442399000},{"turnId":"t1","item":{"type":"agentMessage","id":"a1","text":"一つ目"},"completedAtMs":1792442300000}],"nextCursor":"c-older","backwardsCursor":null}"#

        func call(_ method: String, _ params: any Encodable & Sendable) throws -> CodexRPCLine {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any] ?? [:]
            lock.withLock { calls.append((method, object)) }
            let result: String
            switch method {
            case "thread/items/list": result = Self.page
            case "thread/fork": result = #"{"thread":{"id":"th-fork","cliVersion":"0.162.1"},"model":"gpt-6.1-sol"}"#
            default: result = "{}"
            }
            return CodexRPCLine(Data(#"{"id":"0-1","result":\#(result)}"#.utf8))!
        }

        var recorded: [(method: String, params: [String: Any])] { lock.withLock { calls } }
    }

    @Test("codex の会話の巻き戻し・取り消し・やり直しは、engine が持たない操作として断る")
    func codexRewindUnsupported() async throws {
        let (world, bin) = try await codexWorld()
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let stopped = try world.store.createConversation(
            ConversationRecord(taskNumber: world.task, engine: .codex, agentSessionId: "th-9", cwd: world.directory.path, runner: .none))
        let operations: [@Sendable () async throws -> Void] = [
            { _ = try await world.service.rewind(stopped.id, ConversationRewindRequest(messageID: "u1", expectedAgentSessionID: "th-9", files: true, dryRun: true)) },
            { _ = try await world.service.undoRewind(stopped.id, ConversationSessionGuard(expectedAgentSessionID: "th-9")) },
            { _ = try await world.service.redoRewind(stopped.id, ConversationSessionGuard(expectedAgentSessionID: "th-9")) },
        ]
        for operation in operations {
            do {
                try await operation()
                Issue.record("巻き戻しが断られなかった")
            } catch let error as ConversationError {
                #expect(error.code == .engineUnsupported && error.params["engine"] == "codex")
            }
        }
    }

    @Test("codex の会話の履歴：止まった会話は 1 本だけ起こした app-server で新しい順に読み、頁の中は古い順。人の発言は送った uuid。thread を作っていない会話は空")
    func codexHistory() async throws {
        let fake = CodexOneShotFake()
        let (world, bin) = try await codexWorld { $0.codexOneShot = { method, params in try fake.call(method, params) } }
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let stopped = try world.store.createConversation(
            ConversationRecord(taskNumber: world.task, engine: .codex, agentSessionId: "th-9", cwd: world.directory.path, runner: .none))
        let page = try await world.service.history(stopped.id, before: "c-newer", limit: 3)
        #expect(page.messages.map(\.id) == ["a1", "b2b2b2b2-0000-4000-8000-000000000002", "a2"])
        #expect(page.messages.map(\.role) == [.assistant, .user, .assistant])
        #expect(page.nextCursor == "c-older")
        #expect(page.agentSessionID == "th-9")
        let call = try #require(fake.recorded.last)
        #expect(call.method == "thread/items/list")
        #expect(call.params["threadId"] as? String == "th-9" && call.params["cursor"] as? String == "c-newer")
        #expect(call.params["sortDirection"] as? String == "desc" && call.params["limit"] as? Int == 3)

        let fresh = try world.store.createConversation(ConversationRecord(id: "fresh", taskNumber: nil, engine: .codex, agentSessionId: "fresh", cwd: "/w", runner: .none))
        #expect(try await world.service.history(fresh.id, before: nil, limit: 50).messages.isEmpty)
        #expect(fake.recorded.count == 1)
    }

    /// thread ごとの thread/items/list の応答（本物の記録の result）。無い thread は codex と同じく断る
    private final class CodexThreadsFake: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String: Any]] = []
        let results: [String: String]

        init(_ results: [String: String]) { self.results = results }

        func call(_ method: String, _ params: any Encodable & Sendable) throws -> CodexRPCLine {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any] ?? [:]
            lock.withLock { calls.append(object) }
            guard method == "thread/items/list", let result = results[object["threadId"] as? String ?? ""] else {
                return CodexRPCLine(Data(#"{"id":"0-1","error":{"code":-32600,"message":"no rollout found"}}"#.utf8))!
            }
            return CodexRPCLine(Data(#"{"id":"0-1","result":\#(result)}"#.utf8))!
        }

        var recorded: [[String: Any]] { lock.withLock { calls } }
    }

    @Test("codex の会話の履歴の subagents：頁の中の subAgentActivity の started の子と孫の thread を読み、起こした行の下に写す。読めない子は空のまま、求めなければ読まない（本物の記録）")
    func codexHistorySubagents() async throws {
        let recording = try CodexWireRecording("subagent")
        let child = "01a16d78-e090-7400-a384-a1c8128b4ae8"
        let grandchild = "01a16d78-f9eb-79d0-af89-da932d48dc41"
        let fake = CodexThreadsFake(recording.items)
        let (world, bin) = try await codexWorld { $0.codexOneShot = { method, params in try fake.call(method, params) } }
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let stopped = try world.store.createConversation(
            ConversationRecord(taskNumber: world.task, engine: .codex, agentSessionId: recording.mainThread, cwd: world.directory.path, runner: .none))
        let main = [
            "msg_0f81a88f8d66fb87016adc89670ad487d0898d818592325b0f:-", "call_O3KXOjoPe58EGQSezfXFhaeU:-", "call_xzTmKXAMFrcgAnatbUGZf8v1:-",
            "call_xzTmKXAMFrcgAnatbUGZf8v1-result:-", "subagent-completed-01a16d78-e0b7-7ab3-92ca-fb0be4c3b898:-", "call_iMgxyLxGAxXJrN9XcnwmJk3D:-",
            "call_iMgxyLxGAxXJrN9XcnwmJk3D-result:-", "msg_0f81a88f8d66fb87016adc898488fc87d09c46ce03891a8a4a:-",
        ]
        let page = try await world.service.history(stopped.id, before: nil, limit: 50, subagents: true)
        #expect(
            page.messages.filter { $0.role == .assistant || $0.kind == .toolResult }.map { "\($0.id):\($0.parentToolID ?? "-")" } == main + [
                "\(child)/msg_021fe218c8666b63016adc897496dc87d0b07ed8b3f697641f:\(child)", "\(child)/call_ujGVpdwUsVtfZk8VZtLWPwt8:\(child)",
                "\(child)/subagent-completed-01a16d78-fa10-7992-8e1d-4e33f8ac31f7:\(child)", "\(child)/call_gaMpA99lR9YQaRfbkkMAYyV6:\(child)",
                "\(child)/call_gaMpA99lR9YQaRfbkkMAYyV6-result:\(child)", "\(child)/msg_021fe218c8666b63016adc898069f087d0b8f8c89502ef49eb:\(child)",
                "\(grandchild)/exec-7ebc611f-39cf-4c68-b116-557dc1883b5a:\(child)/\(grandchild)",
                "\(grandchild)/exec-7ebc611f-39cf-4c68-b116-557dc1883b5a-result:\(child)/\(grandchild)",
                "\(grandchild)/msg_019b3807f19f7c0d016adc897d946c87d0903929deaf18066f:\(child)/\(grandchild)",
            ])
        // 子の行は始まりと終わりを子の thread で組にし、孫の行は子の thread で分けた toolID
        #expect(page.messages.filter { $0.toolID == child }.map(\.kind) == [.toolUse, .toolResult])
        #expect(page.messages.first { $0.id == "\(child)/call_ujGVpdwUsVtfZk8VZtLWPwt8" }?.toolID == "\(child)/\(grandchild)")
        #expect(fake.recorded.compactMap { $0["threadId"] as? String } == [recording.mainThread, child, grandchild])
        #expect(fake.recorded.dropFirst().allSatisfy { $0["limit"] as? Int == 200 && $0["cursor"] == nil && $0["sortDirection"] as? String == "desc" })

        let plain = try await world.service.history(stopped.id, before: nil, limit: 50)
        #expect(plain.messages.filter { $0.role == .assistant || $0.kind == .toolResult }.map { "\($0.id):\($0.parentToolID ?? "-")" } == main)
        #expect(fake.recorded.count == 4)
    }

    @Test("codex の会話の履歴の subagents：子の thread が読めない（記録が消えた）ときは、子の行の下を空にして頁を返す")
    func codexHistoryMissingSubagent() async throws {
        let recording = try CodexWireRecording("subagent")
        let fake = CodexThreadsFake(recording.items.filter { $0.key == recording.mainThread })
        let (world, bin) = try await codexWorld { $0.codexOneShot = { method, params in try fake.call(method, params) } }
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let stopped = try world.store.createConversation(
            ConversationRecord(taskNumber: world.task, engine: .codex, agentSessionId: recording.mainThread, cwd: world.directory.path, runner: .none))
        let page = try await world.service.history(stopped.id, before: nil, limit: 50, subagents: true)
        #expect(page.messages.contains { $0.id == "call_O3KXOjoPe58EGQSezfXFhaeU" && $0.kind == .toolUse })
        #expect(page.messages.allSatisfy { $0.parentToolID == nil })
        #expect(fake.recorded.compactMap { $0["threadId"] as? String } == [recording.mainThread, "01a16d78-e090-7400-a384-a1c8128b4ae8"])
    }

    @Test("codex の会話のフォーク：発言の turn まで thread/fork で写し、新しい会話はその thread を戻して起こす。同じ requestID の 2 回目は同じ会話")
    func codexFork() async throws {
        let fake = CodexOneShotFake()
        let (world, bin) = try await codexWorld { $0.codexOneShot = { method, params in try fake.call(method, params) } }
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let source = try world.store.createConversation(
            ConversationRecord(
                taskNumber: world.task, engine: .codex, agentSessionId: "th-9", cwd: world.directory.path, model: "gpt-6-astra", permissionMode: "plan",
                title: "元", runner: .none))
        let forked = try await world.service.fork(source.id, ConversationForkRequest(requestID: "f1", messageID: "b2b2b2b2-0000-4000-8000-000000000002"))
        let fork = try #require(fake.recorded.last { $0.method == "thread/fork" })
        #expect(fork.params["threadId"] as? String == "th-9" && fork.params["lastTurnId"] as? String == "t2")
        #expect(fork.params["sandbox"] as? String == "read-only")
        #expect(forked.engine == .codex && forked.agentSessionID == "th-fork" && forked.forkSource == source.id)
        #expect(forked.forkAt == "b2b2b2b2-0000-4000-8000-000000000002")
        #expect(forked.title == "元" && forked.model == "gpt-6-astra" && forked.taskNumber == world.task)
        let resume = await world.host.written().last { $0["method"] as? String == "thread/resume" }
        #expect((resume?["params"] as? [String: Any])?["threadId"] as? String == "th-fork")
        #expect(try await world.service.fork(source.id, ConversationForkRequest(requestID: "f1")).id == forked.id)
        await #expect(throws: ConversationError.self) {
            try await world.service.fork(source.id, ConversationForkRequest(requestID: "f2", messageID: "no-such-message"))
        }
    }

    @Test("会話の ID の紐づけを外す・結ぶと、動いている会話の記録と state の会話に載る（止まっている会話も state に載る）")
    func rebindReachesConversation() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        @Sendable func shown(_ id: String) async -> Conversation? { await world.state.allConversations().first { $0.id == id } }
        let live = try await world.service.start(world.request())
        _ = try world.store.unlinkSession(task: world.task, sessionID: live.agentSessionID)
        #expect(await eventually { (try? await world.service.get(live.id))?.taskNumber == nil })
        #expect(await eventually { await shown(live.id)?.taskNumber == nil })
        _ = try world.store.linkSession(task: world.task, agent: "claude", sessionID: live.agentSessionID, cwd: world.directory.path, label: "")
        #expect(await eventually { (try? await world.service.get(live.id))?.taskNumber == world.task })
        #expect(await eventually { await shown(live.id)?.taskNumber == world.task })

        let stopped = try world.store.createConversation(
            ConversationRecord(taskNumber: world.task, agentSessionId: UUID().uuidString.lowercased(), cwd: world.directory.path, runner: .none))
        _ = try world.store.unlinkSession(task: world.task, sessionID: stopped.agentSessionId)
        #expect(await eventually { await shown(stopped.id).map { $0.taskNumber == nil } == true })
    }

    @Test("タスクの題が変わると、動いている会話のうち題を付けていないか自動の題（#番号 ）のままの会話だけ付け直す。人が付けた題は残す。名前を付けた会話は自動の題だけ替わり、名前を出し続ける")
    func taskRetitled() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let automatic = try await world.service.start(world.request())
        var named = world.request()
        named.title = "人が付けた題"
        let human = try await world.service.start(named)
        let renamed = try await world.service.start(world.request())
        _ = try await world.service.control(renamed.id, ConversationControlRequest(kind: .rename, value: "名前"))
        #expect(try world.store.conversation(id: automatic.id)?.title == "#\(world.task) 会話")
        var task = try #require(try world.store.task(number: world.task))
        task.title = "題を変えた"
        await world.service.taskRetitled(task)
        #expect(try world.store.conversation(id: automatic.id)?.title == "#\(world.task) 題を変えた")
        #expect(try world.store.conversation(id: human.id)?.title == "人が付けた題")
        #expect(try world.store.conversation(id: renamed.id)?.title == "#\(world.task) 題を変えた")
        #expect(try await world.service.get(renamed.id).title == "名前")
    }

    @Test("daemon が自分で起こす口: Claude Code の引数を会話の項目に読み替える。Codex は Codex の会話。読み替えられない引数は名前だけ添えて断る（値は出さない）")
    func launchRequest() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let standard = ["--dangerously-skip-permissions", "--model", "claude-opus-5-5[1m]", "--effort", "medium"]
        let claude = try await world.service.launchRequest(kind: .claude, agentArgs: standard, cwd: "/w", taskNumber: world.task)
        #expect(claude.model == "claude-opus-5-5[1m]" && claude.effort == "medium" && claude.permissionMode == "bypassPermissions" && claude.extraArgs == nil)
        #expect(claude.cwd == "/w" && claude.taskNumber == world.task && claude.engine != .codex)
        let codex = try await world.service.launchRequest(kind: .codex, agentArgs: [], cwd: "/w", taskNumber: nil)
        #expect(codex.engine == .codex)
        await #expect(throws: ConversationError.invalid("会話に渡せない引数がある: --resume --plugin-dir")) {
            try await world.service.launchRequest(kind: .claude, agentArgs: ["--resume=6f1d2b8e", "--plugin-dir", "/tmp"], cwd: "/w", taskNumber: nil)
        }
    }

    @Test("止まったセッションの再開は会話で戻す。会話に渡せない引数で起こしたセッションは断る")
    func resumeDispatch() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let cwd = world.directory.path
        func link(_ agent: String, _ session: String, _ args: [String]) async throws {
            await world.state.upsert(try world.store.linkSession(task: world.task, agent: agent, sessionID: session, cwd: cwd, label: "", launchArgs: args))
        }
        let claude = "7c9d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5"
        let plugin = "8d0e3f4a-5b6c-4d7e-9f80-a1b2c3d4e5f6"
        try await link("claude", claude, ["--model", "opus"])
        try await link("claude", plugin, ["--plugin-dir", "/tmp"])

        let resumed = try await world.service.resume(task: world.task, SessionResumeRequest(agentSessionID: claude))
        #expect(resumed.conversation?.agentSessionID == claude)
        await #expect(throws: ConversationError.self) {
            try await world.service.resume(task: world.task, SessionResumeRequest(agentSessionID: plugin))
        }
    }

    @Test("確かめた版の CLI が無ければ起こさず 409")
    func unverified() async throws {
        let world = try await ServiceWorld.make(verified: false)
        defer { world.cleanUp() }
        do {
            _ = try await world.service.start(world.request())
            Issue.record("起きてしまった")
        } catch let error as ConversationError {
            #expect(error.status == 409 && error.code == .claudeUnverified)
        }
        #expect(await world.host.requests.allSatisfy { $0.op != .spawn })
    }

    @Test("起こすと確かめた版の実行ファイルで spawn し、会話の ID をタスクに結ぶ。daemon の環境の CLAUDE_CODE_ と TASKBOARD_ は渡さない")
    func start() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        #expect(conversation.phase == .idle && conversation.runner == .host && conversation.taskNumber == world.task)
        let spawn = try #require(await world.host.requests.first { $0.op == .spawn })
        #expect(spawn.argv?.first == "/bin/sh" && spawn.key == conversation.id && spawn.cwd == world.directory.path)
        let env = spawn.env ?? [:]
        #expect(env["TASKBOARD_CONVERSATION_ID"] == conversation.id)
        #expect(
            env.keys.filter { $0.hasPrefix("CLAUDE_CODE_") }.sorted() == [
                "CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS", "CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL", "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING",
                "CLAUDE_CODE_ENABLE_TODO_TOOLS",
            ], "会話が足すものだけ")
        #expect(env.keys.filter { $0.hasPrefix("TASKBOARD_") }.sorted() == ["TASKBOARD_CONVERSATION_ID"])
        #expect(try world.store.task(number: world.task)?.sessions.map(\.sessionID) == [conversation.agentSessionID])
        #expect(await world.state.task(number: world.task)?.sessions.map(\.sessionID) == [conversation.agentSessionID], "state にも載せ直す")
        #expect(await world.service.conversationID(owning: conversation.agentSessionID) == conversation.id)
    }

    @Test("model は別名・完全な名前・[1m] 付きを、TUI の起動と同じ名前にそろえて記録と --model に入れる（一覧を受ける前は控えの一覧）。知らない名前は 400")
    func models() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let cases = [
            ("opus", "claude-opus-5-5[1m]"), ("claude-opus-5-5", "claude-opus-5-5[1m]"), ("claude-opus-5-5[1m]", "claude-opus-5-5[1m]"),
            ("fable", "claude-fable-5-1[1m]"), ("sonnet", "claude-sonnet-5"), ("haiku", "claude-haiku-5-5"),
        ]
        for (given, expected) in cases {
            var request = world.request(bound: false)
            request.model = given
            let conversation = try await world.service.start(request)
            #expect(conversation.model == expected)
            let spawn = try #require(await world.host.requests.last { $0.op == .spawn && $0.key == conversation.id })
            let argv = spawn.argv ?? []
            #expect(argv.firstIndex(of: "--model").map { argv[$0 + 1] } == expected)
            try await world.service.stop(conversation.id, cause: .person)
        }
        var unknown = world.request(bound: false)
        unknown.model = "gpt-5"
        await #expect(throws: ConversationError.invalid("model gpt-5 が無い。使える値: opus, sonnet, fable, haiku, claude-sonnet-5-5")) {
            try await world.service.start(unknown)
        }
    }

    @Test("起動の予約がある会話は、host で戻さない")
    func refusesRunningElsewhere() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let reserved = "6f1d2b8e-2c4a-4a8f-9c11-5d7e0a3b9f02"
        #expect(world.reservations.reserve(SessionReservations.key(.claude, reserved), owner: "launch-1"))
        await #expect(throws: ConversationError.running(reserved)) { try await world.service.start(world.request(resume: reserved)) }
        #expect(await world.host.requests.allSatisfy { $0.op != .spawn })
    }

    @Test("絶対の上限まで動いていれば 409（止められる会話が無いとき）。止めれば起こせる")
    func limit() async throws {
        let world = try await ServiceWorld.make(slots: ConversationSlots(soft: 2, hard: 3))
        defer { world.cleanUp() }
        // タスクに結ばれていない会話は自動では止めない
        var started: [Conversation] = []
        for _ in 0..<3 { started.append(try await world.service.start(world.request(bound: false))) }
        do {
            _ = try await world.service.start(world.request(bound: false))
            Issue.record("上限を超えて起きた")
        } catch let error as ConversationError {
            #expect(error.code == .conversationLimit && error.params["limit"] == "3")
        }
        #expect(world.service.slots.count == 3)
        try await world.service.stop(try #require(started.first).id, cause: .person)
        _ = try await world.service.start(world.request(bound: false))
    }

    @Test("目安を超えて起こすと、使っていない会話のうち最後に使ったのが一番古いものを止める")
    func makeRoom() async throws {
        let world = try await ServiceWorld.make(slots: ConversationSlots(soft: 2, hard: 4))
        defer { world.cleanUp() }
        let first = try await world.service.start(world.request())
        let second = try await world.service.start(world.request())
        let third = try await world.service.start(world.request())
        #expect(await eventually { world.service.slots.count == 2 })
        #expect(try world.store.conversation(id: first.id)?.lastExit == "使われていないので止めた")
        #expect(try world.store.conversation(id: second.id)?.runnerValue == .host)
        #expect(try world.store.conversation(id: third.id)?.runnerValue == .host)
    }

    @Test("画面に出た（購読を受けた）止まった会話は、目安まで空きがあれば起こす。defer の問い・巻き戻しの結果が分からない会話と、目安に達しているときは起こさない")
    func wakesForViewer() async throws {
        let world = try await ServiceWorld.make(slots: ConversationSlots(soft: 2, hard: 4))
        defer { world.cleanUp() }
        func stopped(_ change: (inout ConversationRecord) -> Void = { _ in }) throws -> String {
            var record = ConversationRecord(
                taskNumber: world.task, agentSessionId: UUID().uuidString.lowercased(), cwd: world.directory.path, model: "haiku", runner: .none)
            change(&record)
            return try world.store.createConversation(record).id
        }
        func subscribe(_ id: String) async -> Bool { await world.service.subscribe(id, key: UUID(), epoch: nil, after: 0, outbox: StreamOutbox()) }
        func spawned(_ id: String) async -> Bool { await world.host.requests.contains { $0.op == .spawn && $0.key == id } }

        let held = [try stopped { $0.deferred = "{}" }, try stopped { $0.rewindFilesPending = true }]
        for id in held { #expect(await subscribe(id)) }
        let plain = try stopped()
        #expect(await subscribe(plain))
        #expect(await eventually { (try? await world.service.get(plain))?.phase == .idle })
        for id in held { #expect(await !spawned(id)) }

        _ = try await world.service.start(world.request())
        let full = try stopped()
        #expect(await subscribe(full))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !spawned(full), "目安に達していれば、ほかの会話を止めてまで起こさない")
        #expect(world.service.slots.count == 2)
    }

    @Test("人が止めた会話は、画面に出ても起こさない（送れば起きる）。使われていないので止めた会話と、巻き戻すために止めた会話は起こす")
    func wakesForViewerAfterStop() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        func subscribe(_ id: String) async -> Bool { await world.service.subscribe(id, key: UUID(), epoch: nil, after: 0, outbox: StreamOutbox()) }
        @Sendable func spawns(_ id: String) async -> Int { await world.host.requests.filter { $0.op == .spawn && $0.key == id }.count }

        let stopped = try await world.service.start(world.request())
        try await world.service.stop(stopped.id, cause: .person)
        #expect(await subscribe(stopped.id))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await spawns(stopped.id) == 1)
        _ = try await world.service.send(stopped.id, ConversationSendRequest(text: "続き", clientMessageID: UUID().uuidString.lowercased()))
        #expect(await spawns(stopped.id) == 2)

        let idle = try world.store.createConversation(
            ConversationRecord(
                taskNumber: world.task, agentSessionId: UUID().uuidString.lowercased(), cwd: world.directory.path, model: "haiku", runner: .none,
                lastExit: ConversationStopCause.idle.lastExit))
        #expect(await subscribe(idle.id))
        #expect(await eventually { await spawns(idle.id) == 1 })

        let rewound = try await world.service.start(world.request())
        try world.append(rewound.agentSessionID, [("u1", "user", "はじめ"), ("a1", "assistant", "one"), ("u2", "user", "二つ目"), ("a2", "assistant", "two")])
        _ = try await world.service.rewind(
            rewound.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: rewound.agentSessionID, files: false, dryRun: false))
        #expect(await subscribe(rewound.id))
        #expect(await eventually { await spawns(rewound.id) == 2 })
    }

    @Test("人が止めた会話は、委譲先の知らせとリンクの知らせでは起こさない（回答は起こす）。使われていないので止めた会話は知らせで起こす")
    func deliveryWakePolicy() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        @Sendable func spawns(_ id: String) async -> Int { await world.host.requests.filter { $0.op == .spawn && $0.key == id }.count }

        let stopped = try await world.service.start(world.request())
        try await world.service.stop(stopped.id, cause: .person)
        #expect(await world.service.deliver(conversationID: stopped.id, text: "知らせ", uuid: UUID().uuidString, kind: .delegateNotice) == .busy)
        #expect(await world.service.deliver(conversationID: stopped.id, text: "知らせ", uuid: UUID().uuidString, kind: .linkNotice(actionable: false)) == .busy)
        #expect(await spawns(stopped.id) == 1)
        _ = await world.service.deliver(conversationID: stopped.id, text: "回答", uuid: UUID().uuidString, kind: .feedback)
        #expect(await spawns(stopped.id) == 2)

        let idle = try world.store.createConversation(
            ConversationRecord(
                taskNumber: world.task, agentSessionId: UUID().uuidString.lowercased(), cwd: world.directory.path, model: "haiku", runner: .none,
                lastExit: ConversationStopCause.idle.lastExit))
        #expect(await world.service.deliver(conversationID: idle.id, text: "知らせ", uuid: UUID().uuidString, kind: .linkNotice(actionable: false)) == .busy)
        #expect(await spawns(idle.id) == 0)
        _ = await world.service.deliver(conversationID: idle.id, text: "知らせ", uuid: UUID().uuidString, kind: .delegateNotice)
        #expect(await spawns(idle.id) == 1)
    }

    @Test("taskboard が止めた会話（起こした側を終了して止めた委譲先）は、人が止めた会話と違い、画面に出ると起き、委譲先とリンクの知らせでも起きる")
    func stoppedByTaskboardWakes() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        @Sendable func spawns(_ id: String) async -> Int { await world.host.requests.filter { $0.op == .spawn && $0.key == id }.count }
        let lead = try await world.service.start(world.request())
        var record = ConversationRecord(
            taskNumber: world.task, agentSessionId: UUID().uuidString.lowercased(), cwd: world.directory.path, model: "haiku", runner: .none)
        record.parentConversationId = lead.id
        let viewed = try world.store.createConversation(record).id
        record.id = UUID().uuidString.lowercased()
        record.agentSessionId = UUID().uuidString.lowercased()
        let notified = try world.store.createConversation(record).id
        _ = try await world.service.resume(viewed)
        _ = try await world.service.resume(notified)
        #expect(await eventually { (try? await world.service.get(notified))?.phase == .idle })

        try await world.service.close(lead.id)
        #expect(await eventually { (try? await world.service.get(notified))?.phase == .stopped })
        #expect(await eventually { (try? await world.service.get(viewed))?.phase == .stopped })
        #expect(try world.store.conversation(id: viewed)?.lastExit == "taskboard が止めた")
        #expect(await world.service.subscribe(viewed, key: UUID(), epoch: nil, after: 0, outbox: StreamOutbox()))
        #expect(await eventually { await spawns(viewed) == 2 })
        _ = await world.service.deliver(conversationID: notified, text: "知らせ", uuid: UUID().uuidString, kind: .delegateNotice)
        #expect(await spawns(notified) == 2)
    }

    @Test("人の停止と終了は、常駐が入っているオーケストレーターの会話を 409 で断る（TUI と同じ）。常駐を切れば止められる。taskboard の停止は常駐でも止める")
    func residentOrchestratorStop() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let orchestrator = try await world.service.start(world.request(bound: false), purpose: .orchestrator)
        _ = try world.store.updateSettings(MachineSettingsUpdate(orchestratorEnabled: true))
        let resident = ConversationError.orchestratorResident
        await #expect(throws: resident) { try await world.service.stop(orchestrator.id, cause: .person) }
        await #expect(throws: resident) { try await world.service.close(orchestrator.id) }
        #expect(await world.service.isLive(orchestrator.id))

        try await world.service.stop(orchestrator.id, cause: .taskboard)
        #expect(await !world.service.isLive(orchestrator.id))
        #expect(try world.store.conversation(id: orchestrator.id)?.lastExit == "taskboard が止めた")

        _ = try world.store.updateSettings(MachineSettingsUpdate(orchestratorEnabled: false))
        try await world.service.close(orchestrator.id)
        #expect(try world.store.conversation(id: orchestrator.id) == nil)
    }

    @Test("ターンの後の終了：生成中の会話は入力待ちに入ってから終了し、静かな会話はすぐ終了する。人が止めた会話は、再開して入力待ちに入っても終了しない")
    func closeAfterTurn() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        func run(_ id: String) async throws {
            let sent = ConversationSendRequest(text: "片付けて終わる")
            async let accepted = world.service.send(id, sent)
            await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(sent.clientMessageID)","state":"started"}"#, key: id)
            _ = try await accepted
            await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#, key: id)
            #expect(await eventually { (try? await world.service.get(id))?.phase == .running })
        }
        func finishTurn(_ id: String) async {
            await world.host.emit(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","session_id":"s1"}"#, key: id)
            await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#, key: id)
        }

        let busy = try await world.service.start(world.request())
        try await run(busy.id)
        try await world.service.closeAfterTurn(busy.id)
        #expect(try await !world.service.get(busy.id).isClosed, "ターンの途中では終了しない")
        await finishTurn(busy.id)
        #expect(await eventually { (try? await world.service.get(busy.id))?.isClosed == true })
        #expect(try world.store.conversation(id: busy.id) != nil, "記録は残す")

        let resting = try await world.service.start(world.request())
        #expect(await eventually { (try? await world.service.get(resting.id))?.phase == .idle })
        try await world.service.closeAfterTurn(resting.id)
        #expect(try await world.service.get(resting.id).isClosed)

        let stopped = try await world.service.start(world.request())
        try await run(stopped.id)
        try await world.service.closeAfterTurn(stopped.id)
        try await world.service.stop(stopped.id, cause: .person)
        _ = try await world.service.resume(stopped.id)
        #expect(await eventually { (try? await world.service.get(stopped.id))?.phase == .idle })
        #expect(try await !world.service.get(stopped.id).isClosed)
    }

    @Test("止める：動いている結ばれていない会話は記録も消す。止まっている会話は、結ばれていなくても記録を残す（2 回止めても同じ）")
    func stopKeepsStoppedRecords() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let unbound = try await world.service.start(world.request(bound: false))
        try await world.service.stop(unbound.id, cause: .person)
        #expect(try world.store.conversation(id: unbound.id) == nil)

        let bound = try await world.service.start(world.request())
        try await world.service.stop(bound.id, cause: .person)
        try await world.service.stop(bound.id, cause: .person)
        #expect(try world.store.conversation(id: bound.id)?.lastExit == "止めた")

        let restarted = try world.store.createConversation(
            ConversationRecord(
                taskNumber: nil, agentSessionId: UUID().uuidString.lowercased(), cwd: world.directory.path, model: "haiku", runner: .none,
                lastExit: ConversationStopCause.hostRestarted.lastExit))
        try await world.service.stop(restarted.id, cause: .person)
        #expect(try world.store.conversation(id: restarted.id)?.lastExit == "agent host が起き直した")
    }

    @Test("終了：動いていれば止めて、記録は残して終了の印を付ける。シェルを閉じ、画面で開いても起こさない。再開すれば戻る。委譲先は、空いていれば止め、生成中なら動かしたまま")
    func close() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let lead = try await world.service.start(world.request())
        _ = try await world.service.shell(lead.id)
        func delegate() throws -> String {
            var record = ConversationRecord(
                taskNumber: world.task, agentSessionId: UUID().uuidString.lowercased(), cwd: world.directory.path, model: "haiku", runner: .none)
            record.parentConversationId = lead.id
            return try world.store.createConversation(record).id
        }
        let resting = try delegate()
        let running = try delegate()
        let stopped = try delegate()
        _ = try await world.service.resume(resting)
        _ = try await world.service.resume(running)
        await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#, key: running)
        #expect(await eventually { (try? await world.service.get(running))?.phase == .running })
        #expect(await eventually { (try? await world.service.get(resting))?.phase == .idle })

        try await world.service.close(lead.id)
        let closed = try await world.service.get(lead.id)
        #expect(closed.phase == .stopped && closed.isClosed)
        #expect(try world.store.conversation(id: lead.id)?.lastExit == "終了した")
        #expect(try world.store.conversation(id: lead.id)?.shellId == nil)
        #expect(await world.host.shells.isEmpty)
        #expect(await eventually { (try? await world.service.get(resting))?.phase == .stopped })
        #expect(try await !world.service.get(resting).isClosed)
        #expect(try await world.service.get(running).phase == .running)

        // 画面で開いても起こさない
        let spawns = await world.host.requests.filter { $0.op == .spawn }.count
        let outbox = StreamOutbox()
        #expect(await world.service.subscribe(lead.id, key: UUID(), epoch: nil, after: 0, outbox: outbox))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == spawns)
        outbox.finish()

        // 止まっている会話も終了できる。タスクに結ばれていない会話も同じ。再開すると終了の印が外れる
        try await world.service.close(stopped)
        #expect(try await world.service.get(stopped).isClosed)
        let unbound = try await world.service.start(world.request(bound: false))
        try await world.service.close(unbound.id)
        #expect(try await world.service.get(unbound.id).isClosed)
        _ = try await world.service.resume(lead.id)
        #expect(try await !world.service.get(lead.id).isClosed)
    }

    @Test("消す：動いている会話は 409。止めてから消すと、取得・送る・消すは 404、購読は missing で、host から遅れて届いた知らせで作り直さない。タスクとの結びは残す")
    func delete() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        await #expect(throws: ConversationError.live(conversation.id)) { try await world.service.delete(conversation.id) }
        #expect(try world.store.conversation(id: conversation.id) != nil)

        try await world.service.stop(conversation.id, cause: .person)
        #expect(try world.store.conversation(id: conversation.id) != nil, "タスクに結ばれた会話は止めても記録を残す")
        try await world.service.delete(conversation.id)
        #expect(try world.store.conversation(id: conversation.id) == nil)

        let notFound = ConversationService.notFound(conversation.id)
        await #expect(throws: notFound) { try await world.service.get(conversation.id) }
        await #expect(throws: notFound) {
            try await world.service.send(conversation.id, ConversationSendRequest(text: "x", clientMessageID: UUID().uuidString.lowercased()))
        }
        await #expect(throws: notFound) { try await world.service.delete(conversation.id) }
        let outbox = StreamOutbox()
        #expect(await !world.service.subscribe(conversation.id, key: UUID(), epoch: nil, after: 0, outbox: outbox))
        outbox.finish()
        var frames: [StreamServerFrame] = []
        for await frame in outbox.frames { frames.append(try WireJSON.decoder().decode(StreamServerFrame.self, from: frame.data)) }
        #expect(frames == [.unsubscribed(conversation: conversation.id, reason: StreamServerFrame.missing)])

        await world.service.route(AgentHostNotice(event: .exit, key: conversation.id, exit: AgentHostExit(status: 0, signal: nil)))
        #expect(await !world.service.isLive(conversation.id))
        #expect(try world.store.conversation(id: conversation.id) == nil)
        #expect(try world.store.task(number: world.task)?.sessions.map(\.sessionID) == [conversation.agentSessionID])
    }

    @Test("繋がったら、記録の無い子は止め、host の一覧に無い記録は止まったことにし、生きている子は引き取る。空いている会話はターンの終わりとして知らせる")
    func connected() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let alive = try world.store.createConversation(ConversationRecord(taskNumber: world.task, agentSessionId: "s-alive", cwd: "/w", runner: .host))
        let gone = try world.store.createConversation(ConversationRecord(taskNumber: world.task, agentSessionId: "s-gone", cwd: "/w", runner: .host))
        await world.host.setProcesses([
            AgentHostProcessInfo(key: alive.id, pid: 10, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1),
            AgentHostProcessInfo(key: "orphan", pid: 11, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1),
        ])
        let seen = Seen()
        await world.service.onIdle { seen.add($0) }
        await world.service.connected(restarted: false)
        let requests = await world.host.requests
        #expect(requests.contains { $0.op == .signal && $0.key == "orphan" && $0.signal == "TERM" })
        #expect(!requests.contains { $0.op == .signal && $0.key == alive.id })
        #expect(try world.store.conversation(id: gone.id)?.runnerValue == Conversation.Runner.none)
        #expect(try world.store.conversation(id: gone.id)?.lastExit == "agent host に無い")
        let snapshot = try await world.service.get(alive.id)
        #expect(snapshot.runner == .host && snapshot.phase == .idle)
        #expect(world.reservations.owner(of: ClaudeConversation.reservationKey("s-alive")) == alive.id, "引き取った会話の ID を予約する")
        #expect(seen.all == [alive.id])
        #expect(await world.service.idleConversations().map(\.id) == [alive.id])
        #expect(await world.service.deliver(conversationID: "nope", text: "x", uuid: UUID().uuidString, kind: .feedback) == nil)
    }

    @Test("繋がったときの引き取りは並べて待つ：控えを読み終えない会話が何本あっても、待つのは読み直しの上限の 1 回分")
    func connectedAttachesInParallel() async throws {
        let world = try await ServiceWorld.make { $0.timing.replay = .seconds(1) }
        defer { world.cleanUp() }
        var processes: [AgentHostProcessInfo] = []
        for index in 0..<3 {
            let record = try world.store.createConversation(
                ConversationRecord(taskNumber: world.task, agentSessionId: "s-\(index)", cwd: "/w", runner: .host))
            // 控えの終わり（lastSeq 5）まで host が送らないので、引き取りは上限まで待つ
            processes.append(
                AgentHostProcessInfo(key: record.id, pid: Int32(10 + index), alive: true, exit: nil, lastSeq: 5, firstSeq: 1, keptBytes: 0, startedAt: 1))
        }
        await world.host.setProcesses(processes)
        let elapsed = await ContinuousClock().measure { await world.service.connected(restarted: false) }
        #expect(elapsed < .milliseconds(2500), "1 本ずつ待つと 3 秒かかる")
        for process in processes { #expect(try await world.service.get(process.key).runner == .host) }
    }

    @Test("起き直した直後、host と突き合わせる前に回答が届いても、host で生きている子は起こし直さずに引き取って入れる。後から繋がっても引き取り直さない")
    func deliverBeforeConnected() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let alive = try world.store.createConversation(ConversationRecord(taskNumber: world.task, agentSessionId: "s-alive", cwd: "/w", runner: .host))
        await world.host.setProcesses([AgentHostProcessInfo(key: alive.id, pid: 10, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1)])
        _ = await world.service.deliver(conversationID: alive.id, text: "回答です", uuid: UUID().uuidString, kind: .feedback)
        await world.service.connected(restarted: false)
        let requests = await world.host.requests
        #expect(!requests.contains { $0.op == .spawn })
        #expect(requests.filter { $0.op == .subscribe && $0.key == alive.id }.count == 2, "引き取りの購読と、繋がったときの受け直し")
        #expect(try world.store.conversation(id: alive.id)?.runnerValue == .host)
        #expect(try await world.service.get(alive.id).phase != .stopped)
    }

    @Test("突き合わせの前に作った会話の記録も、host の一覧に生きている子があれば繋がったときに引き取る")
    func connectedAdoptsMadeConversation() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let alive = try world.store.createConversation(ConversationRecord(taskNumber: world.task, agentSessionId: "s-alive", cwd: "/w", runner: .host))
        await world.host.setProcesses([AgentHostProcessInfo(key: alive.id, pid: 10, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1)])
        _ = try await world.service.control(alive.id, ConversationControlRequest(kind: .setEffort, value: "high"))
        await world.service.connected(restarted: false)
        #expect(await world.host.requests.contains { $0.op == .subscribe && $0.key == alive.id })
        #expect(try await world.service.get(alive.id).phase == .idle)
    }

    @Test("host で生きている子の記録が止まった扱い（起こせなかった）でも、繋がったときに引き取って記録を直す")
    func connectedRepairsStoppedRecord() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        var record = ConversationRecord(taskNumber: world.task, agentSessionId: "s-alive", cwd: "/w", runner: .none)
        record.lastExit = "起こせなかった"
        let alive = try world.store.createConversation(record)
        await world.host.setProcesses([AgentHostProcessInfo(key: alive.id, pid: 10, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1)])
        await world.service.connected(restarted: false)
        let repaired = try #require(try world.store.conversation(id: alive.id))
        #expect(repaired.runnerValue == .host && repaired.lastExit == nil)
        #expect(!(await world.host.requests.contains { $0.op == .signal && $0.key == alive.id }))
    }

    @Test("記録が止まった扱い（起こせなかった）でも、host で生きている子があれば、回答の配達は起こし直さずに引き取る")
    func deliverAdoptsAfterFailedStart() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        var record = ConversationRecord(taskNumber: world.task, agentSessionId: "s-alive", cwd: "/w", runner: .none)
        record.lastExit = "起こせなかった"
        let alive = try world.store.createConversation(record)
        await world.host.setProcesses([AgentHostProcessInfo(key: alive.id, pid: 10, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1)])
        _ = await world.service.deliver(conversationID: alive.id, text: "回答です", uuid: UUID().uuidString, kind: .feedback)
        #expect(!(await world.host.requests.contains { $0.op == .spawn }))
        let repaired = try #require(try world.store.conversation(id: alive.id))
        #expect(repaired.runnerValue == .host && repaired.lastExit == nil)
        #expect(try await world.service.get(alive.id).runner == .host)
    }

    @Test("起こし損ねた会話（読み始めたが止まっている）も、host で生きている子があれば繋がったときに引き取る")
    func connectedAdoptsHalfStarted() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let record = try world.store.createConversation(ConversationRecord(taskNumber: world.task, agentSessionId: "s-alive", cwd: "/w", runner: .none))
        await world.host.setFailing([.spawn])
        #expect(await world.service.deliver(conversationID: record.id, text: "回答です", uuid: UUID().uuidString, kind: .feedback) == nil)
        await world.host.setFailing([])
        await world.host.setProcesses([AgentHostProcessInfo(key: record.id, pid: 10, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1)])
        await world.service.connected(restarted: false)
        #expect(try await world.service.get(record.id).runner == .host)
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == 1)
    }

    @Test("突き合わせの間に起こした会話は、最初の一覧に無くても止めない（一覧を取り直して、まだ無い会話だけを止まったことにする）")
    func connectedSparesConversationsStartedDuringReconcile() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let started = try await world.service.start(world.request())
        let process = AgentHostProcessInfo(key: started.id, pid: 42, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1)
        await world.host.queueLists([[], [process]])
        await world.service.connected(restarted: false)
        #expect(try await world.service.get(started.id).runner == .host)
        #expect(try world.store.conversation(id: started.id)?.lastExit == nil)

        await world.host.queueLists([[], []])
        await world.service.connected(restarted: false)
        #expect(try await world.service.get(started.id).runner == Conversation.Runner.none)
        #expect(try world.store.conversation(id: started.id)?.runnerValue == Conversation.Runner.none)
    }

    @Test("この版が知らない engine の記録（新しい版の daemon が書いたもの）は起こさず、止まった会話として出し、host の子にも触らない")
    func otherEnginesAreListedButNotRun() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        var made = ConversationRecord(taskNumber: world.task, agentSessionId: "thread-1", cwd: "/w", runner: .host)
        made.engine = "gemini"
        let record = try world.store.createConversation(made)
        await world.host.setProcesses([AgentHostProcessInfo(key: record.id, pid: 10, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1)])
        await world.service.connected(restarted: false)
        #expect(!(await world.host.requests.contains { $0.key == record.id }), "子を止めも引き取りもしない")
        let listed = try await world.service.get(record.id)
        #expect(listed.engine == .unknown && listed.phase == .stopped && listed.agentSessionID == "thread-1")
        await #expect(throws: ConversationError.unsupportedEngine(record.id, "gemini")) {
            _ = try await world.service.send(record.id, ConversationSendRequest(text: "続き", clientMessageID: UUID().uuidString.lowercased()))
        }
        #expect(await world.service.deliver(conversationID: record.id, text: "回答です", uuid: UUID().uuidString, kind: .feedback) == nil)
        #expect(!(await world.host.requests.contains { $0.op == .spawn }))
    }

    // MARK: フォーク

    private func argument(_ argv: [String], after flag: String) -> String? {
        argv.firstIndex(of: flag).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
    }

    @Test("途中の発言からフォークすると、同じタスク・設定の会話をフォークの引数で起こし、履歴はその発言までを返す（日本語と英語）。#n は落とす")
    func fork() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        var request = world.request()
        request.effort = "high"
        let source = try await world.service.start(request)
        try world.append(source.agentSessionID, [("u1", "user", "はじめの発言"), ("a1", "assistant", "first answer"), ("u2", "user", "二つ目"), ("a2", "assistant", "二つ目の答え")])

        let fork = try await world.service.fork(source.id, ConversationForkRequest(requestID: "r-1", messageID: "a1#0"))
        #expect(fork.id != source.id && fork.agentSessionID != source.agentSessionID)
        #expect(fork.taskNumber == world.task && fork.forkSource == source.id && fork.forkPending && fork.forkAt == "a1")
        #expect(fork.model == "claude-haiku-5-5" && fork.effort == "high")
        let spawn = try #require(await world.host.requests.last { $0.op == .spawn && $0.key == fork.id })
        let argv = spawn.argv ?? []
        #expect(argument(argv, after: "--resume") == source.agentSessionID && argv.contains("--fork-session"))
        #expect(argument(argv, after: "--session-id") == fork.agentSessionID && argument(argv, after: "--resume-session-at") == "a1")
        #expect(spawn.env?["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1")
        #expect(try world.store.task(number: world.task)?.sessions.map(\.sessionID).contains(fork.agentSessionID) == true)

        let history = try await world.service.history(fork.id, before: nil, limit: 50)
        #expect(history.messages.map(\.text) == ["はじめの発言", "first answer"] && history.agentSessionID == fork.agentSessionID)

        // 同じ requestID の 2 回目は、作った会話を返す
        let again = try await world.service.fork(source.id, ConversationForkRequest(requestID: "r-1", messageID: "u2"))
        #expect(again.id == fork.id)
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == 2)

        await #expect(throws: ConversationError.messageNotFound("missing")) {
            try await world.service.fork(source.id, ConversationForkRequest(requestID: "r-2", messageID: "missing#1"))
        }
    }

    @Test("札の中身は今の Claude の会話 ID の transcript から探し、フォーク後でまだ無ければ写す元から。codex の会話と無い会話は 404")
    func fileContent() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let source = try await world.service.start(world.request())
        let dir = world.projects.appending(path: "-w")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_r1","type":"tool_result","content":"1\tlet a = 1"}]},"uuid":"u1","toolUseResult":{"type":"text","file":{"filePath":"/w/a.swift","content":"let a = 1\n","numLines":1,"startLine":1,"totalLines":1}}}"#
        try Data((#"{"type":"queue-operation"}"# + "\n" + line + "\n").utf8).write(to: dir.appending(path: "\(source.agentSessionID).jsonl"))
        #expect(try await world.service.file(source.id, toolID: "toolu_r1", at: nil, path: nil, part: .content) == .text("let a = 1\n"))

        let fork = try await world.service.fork(source.id, ConversationForkRequest(requestID: "r-file"))
        #expect(try await world.service.file(fork.id, toolID: "toolu_r1", at: nil, path: nil, part: .content) == .text("let a = 1\n"), "写す前は元の transcript")

        func kind(_ body: () async throws -> TranscriptFiles.Body) async -> String? {
            do {
                _ = try await body()
                return nil
            } catch let error as ConversationError {
                return error.params["kind"]
            } catch {
                return "\(error)"
            }
        }
        #expect(await kind { try await world.service.file(source.id, toolID: "toolu_none", at: nil, path: nil, part: .content) } == "file")
        let codex = try world.store.createConversation(ConversationRecord(id: "cx", taskNumber: nil, engine: .codex, agentSessionId: "th-1", cwd: "/w", runner: .none))
        #expect(await kind { try await world.service.file(codex.id, toolID: "toolu_r1", at: nil, path: nil, part: .content) } == "file")
        #expect(await kind { try await world.service.file("missing", toolID: "toolu_r1", at: nil, path: nil, part: .content) } == "conversation")
    }

    @Test("人の発言の画像も同じ transcript から uuid で探す。codex の会話と無い会話は 404")
    func imageContent() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let source = try await world.service.start(world.request())
        let dir = world.projects.appending(path: "-w")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2])
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"見て"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png.base64EncodedString())"}}]},"uuid":"e1a2b3c4-0000-4000-8000-000000000001"}"#
        try Data((line + "\n").utf8).write(to: dir.appending(path: "\(source.agentSessionID).jsonl"))
        #expect(try await world.service.image(source.id, lineID: "e1a2b3c4-0000-4000-8000-000000000001", index: 0, at: nil) == .image(png, contentType: "image/png"))

        func kind(_ body: () async throws -> TranscriptFiles.Body) async -> String? {
            do {
                _ = try await body()
                return nil
            } catch let error as ConversationError {
                return error.params["kind"]
            } catch {
                return "\(error)"
            }
        }
        #expect(await kind { try await world.service.image(source.id, lineID: "e1a2b3c4-0000-4000-8000-000000000001", index: 1, at: nil) } == "file")
        let codex = try world.store.createConversation(ConversationRecord(id: "cx", taskNumber: nil, engine: .codex, agentSessionId: "th-1", cwd: "/w", runner: .none))
        #expect(await kind { try await world.service.image(codex.id, lineID: "e1a2b3c4-0000-4000-8000-000000000001", index: 0, at: nil) } == "file")
        #expect(await kind { try await world.service.image("missing", lineID: "e1a2b3c4-0000-4000-8000-000000000001", index: 0, at: nil) } == "conversation")
    }

    @Test("発言を省くと作る時点の末尾から分け、元に発言が増えた後に起こし直しても同じ地点。transcript ができたら --resume <新> で起こす")
    func forkTail() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let source = try await world.service.start(world.request())
        try world.append(source.agentSessionID, [("u1", "user", "one"), ("a1", "assistant", "一")])
        let fork = try await world.service.fork(source.id, ConversationForkRequest(requestID: "r-tail"))
        #expect(try world.store.conversation(id: fork.id)?.pendingForkAt == "a1")
        try world.append(source.agentSessionID, [("u2", "user", "two"), ("a2", "assistant", "二")])

        try await world.service.stop(fork.id, cause: .person)
        _ = try await world.service.resume(fork.id)
        var spawn = try #require(await world.host.requests.last { $0.op == .spawn && $0.key == fork.id })
        #expect(argument(spawn.argv ?? [], after: "--resume-session-at") == "a1", "送らずに止まったフォークは、次もフォークの引数で起こす")
        #expect(try await world.service.history(fork.id, before: nil, limit: 50).messages.map(\.text) == ["one", "一"])

        // フォークした会話に transcript ができた（CLI が写した）
        try world.append(fork.agentSessionID, [("u1", "user", "one"), ("a1", "assistant", "一"), ("u3", "user", "三")])
        try await world.service.stop(fork.id, cause: .person)
        let resumed = try await world.service.resume(fork.id)
        spawn = try #require(await world.host.requests.last { $0.op == .spawn && $0.key == fork.id })
        let argv = spawn.argv ?? []
        #expect(argument(argv, after: "--resume") == fork.agentSessionID && !argv.contains("--fork-session") && !argv.contains("--resume-session-at"))
        #expect(!resumed.forkPending && resumed.forkSource == source.id && resumed.forkAt == "a1", "写した後もフォークの地点は残る")
        #expect(try world.store.conversation(id: fork.id)?.pendingForkSessionId == nil)
        #expect(try await world.service.history(fork.id, before: nil, limit: 50).messages.map(\.text) == ["one", "一", "三"])
    }

    // MARK: 巻き戻し

    private func frames(_ outbox: StreamOutbox) async -> [StreamServerFrame] {
        outbox.finish()
        var frames: [StreamServerFrame] = []
        for await frame in outbox.frames { if let decoded = try? WireJSON.decoder().decode(StreamServerFrame.self, from: frame.data) { frames.append(decoded) } }
        return frames
    }

    private func hasReset(_ frames: [StreamServerFrame]) -> Bool {
        frames.contains { frame in
            if case .conversation(let event) = frame, case .reset = event.kind { return true }
            return false
        }
    }

    @Test("巻き戻し（ファイルも）：会話を止めてから記録を新しい ID に替え、<id>-rewind の補助のプロセスで rewind_files を送り、reset を流して本文を返す。次に送ると前の ID から親の行でフォークする")
    func rewindWithFiles() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let old = conversation.agentSessionID
        try world.append(old, [("u1", "user", "はじめ"), ("a1", "assistant", "one"), ("u2", "user", "二つ目を書いて"), ("a2", "assistant", "書いた")])
        await world.host.setReply("rewind_files", #"{"canRewind":true,"filesChanged":["a.txt"],"insertions":1,"deletions":2,"skippedLinks":1}"#)
        let outbox = StreamOutbox()
        #expect(await world.service.subscribe(conversation.id, key: UUID(), epoch: nil, after: 0, outbox: outbox))

        let response = try await world.service.rewind(
            conversation.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: old, files: true, dryRun: false))
        #expect(response.draft == "二つ目を書いて" && response.filesChanged == ["a.txt"] && response.skippedLinks == 1)
        let after = try #require(response.conversation)
        #expect(after.agentSessionID != old && after.phase == .stopped && after.canUndoRewind && !after.rewindIncomplete && after.forkPending)
        let record = try #require(try world.store.conversation(id: conversation.id))
        #expect(record.previousSessionId == old && record.pendingForkSessionId == old && record.pendingForkAt == "a1" && !record.rewindFilesPending)
        #expect(try world.store.task(number: world.task)?.sessions.map(\.sessionID).contains(after.agentSessionID) == true)

        let helperKey = "\(conversation.id)-rewind"
        let requests = await world.host.requests
        let stopIndex = try #require(requests.firstIndex { $0.op == .closeInput && $0.key == conversation.id })
        let spawnIndex = try #require(requests.firstIndex { $0.op == .spawn && $0.key == helperKey })
        #expect(stopIndex < spawnIndex, "会話のプロセスを止めてから補助のプロセスを起こす")
        let spawn = requests[spawnIndex]
        #expect(argument(spawn.argv ?? [], after: "--resume") == old)
        #expect(spawn.env?["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1" && spawn.env?["TASKBOARD_CONVERSATION_ID"] == conversation.id)
        #expect(requests.contains { $0.op == .closeInput && $0.key == helperKey })
        let rewinds = await world.host.written("rewind_files")
        #expect(rewinds.count == 1 && (rewinds.first?["request"] as? [String: Any])?["user_message_id"] as? String == "u2")
        #expect((rewinds.first?["request"] as? [String: Any])?["dry_run"] == nil)
        #expect(world.reservations.owner(of: ClaudeConversation.reservationKey(old)) == nil, "補助のプロセスが終わったら予約を外す")
        #expect(hasReset(await frames(outbox)))

        _ = try await world.service.send(conversation.id, ConversationSendRequest(text: "やり直し", clientMessageID: UUID().uuidString.lowercased()))
        let resumed = try #require(await world.host.requests.last { $0.op == .spawn && $0.key == conversation.id })
        let argv = resumed.argv ?? []
        #expect(argument(argv, after: "--resume") == old && argv.contains("--fork-session"))
        #expect(argument(argv, after: "--session-id") == after.agentSessionID && argument(argv, after: "--resume-session-at") == "a1")
    }

    @Test("要約の後へ巻き戻して送った後も、要約より前の発言を履歴で読める（CLI の写しを見て写し元を記録する）。要約より前の発言へは巻き戻さない")
    func rewindAcrossCompaction() async throws {
        typealias T = CompactedTranscripts
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let old = conversation.agentSessionID
        try world.write(old, T.sourceLines)
        await #expect(throws: ConversationError.invalid("要約より前の発言には戻せない")) {
            _ = try await world.service.rewind(conversation.id, ConversationRewindRequest(messageID: "u1", expectedAgentSessionID: old, files: false, dryRun: false))
        }
        // その場で圧縮した transcript は、要約の印が要約の直前の発言（a2）の後に並ぶ
        #expect(try await history(world, conversation.id) == ["最初の依頼", "最初の答え", "前の答えの続き", "会話を圧縮しました", "いまいくらやろ", "消える答え"])

        let response = try await world.service.rewind(
            conversation.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: old, files: false, dryRun: false))
        let next = try #require(response.conversation).agentSessionID
        let pendingAt = try world.store.conversation(id: conversation.id)?.pendingForkAt
        #expect(response.draft == "いまいくらやろ" && pendingAt == "i1")
        #expect(try await history(world, conversation.id) == ["最初の依頼", "最初の答え", "前の答えの続き", "会話を圧縮しました"], "送る前は写す元を地点まで読む")

        // 送った：CLI が要約の後だけを写した
        try world.write(next, T.forkLines)
        try await world.service.stop(conversation.id, cause: .person)
        _ = try await world.service.resume(conversation.id)
        #expect(try world.store.conversation(id: conversation.id)?.pendingForkSessionId == nil)
        let start = UInt64(T.sourceLines.prefix { !$0.contains(#""compact_boundary""#) }.reduce(0) { $0 + $1.utf8.count + 1 })
        #expect(try world.store.transcriptSource(of: next) == TranscriptSource(session: old, end: start))
        // 写しの頭の要約と、写した a2 の後に、写し元の要約より前（a2 は写しにもあるので 1 回だけ）
        #expect(try await history(world, conversation.id) == ["最初の依頼", "最初の答え", "会話を圧縮しました", "前の答えの続き", "今どないやろ", "新しい答え"])
        let dry = try await world.service.rewind(conversation.id, ConversationRewindRequest(messageID: "u4", expectedAgentSessionID: next, files: false, dryRun: true))
        #expect(dry.canRewind == true, "写しの頭の区切りより後へは戻せる")
    }

    /// 履歴を上へ読み切る（古い方のページで手元にある id は捨てる。アプリの `ConversationTimeline.mergeHistory` と同じ）
    private func history(_ world: ServiceWorld, _ id: String) async throws -> [String] {
        var messages: [ChatMessage] = []
        var cursor: String?
        for _ in 0..<20 {
            let page = try await world.service.history(id, before: cursor, limit: 2)
            let known = Set(messages.map(\.id))
            messages = page.messages.filter { !known.contains($0.id) } + messages
            cursor = page.nextCursor
            if cursor == nil { break }
        }
        return messages.map(\.text)
    }

    @Test("ファイルを戻したら差分の要約を取り直す（作業フォルダが変わってもツールの結果もターンの終わりも来ない）")
    func rewindRefreshesDiff() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", world.directory.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        let file = world.directory.appending(path: "a.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        // 同じフォルダにある偽の設定と transcript の置き場を数えない
        try "*\n!a.txt\n!.gitignore\n".write(to: world.directory.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try git("init", "-q")
        try git("add", "a.txt", ".gitignore")
        try git("commit", "-q", "-m", "init")
        let conversation = try await world.service.start(world.request())
        let old = conversation.agentSessionID
        try world.append(old, [("u1", "user", "はじめ"), ("a1", "assistant", "one")])
        await world.host.setReply("rewind_files", #"{"canRewind":true,"filesChanged":["a.txt"],"insertions":1,"deletions":0}"#)
        let service = world.service
        func files() async -> Int? { (try? await service.get(conversation.id))?.diff?.files }
        var settled = false
        for _ in 0..<150 where !settled {
            settled = await files() == 0
            if !settled { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(settled, "起こした後の差分は 0 ファイル")
        // CLI がファイルを戻したことにする（偽の host は書き換えない）
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)

        _ = try await world.service.rewind(
            conversation.id, ConversationRewindRequest(messageID: "u1", expectedAgentSessionID: old, files: true, dryRun: false))
        var refreshed = false
        for _ in 0..<150 where !refreshed {
            refreshed = await files() == 1
            if !refreshed { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(refreshed)
    }

    @Test("ファイルを戻す応答が無ければ、記録を巻き戻したまま rewindIncomplete。補助のプロセスが終わるまで予約は補助の key が持ち、送る・別の起動は断る。送ると帯が消える")
    func rewindUnknown() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let old = conversation.agentSessionID
        try world.append(old, [("u1", "user", "はじめ"), ("a1", "assistant", "one")])
        let helperKey = "\(conversation.id)-rewind"
        let service = world.service
        let rewinding = Task {
            try await service.rewind(conversation.id, ConversationRewindRequest(messageID: "u1", expectedAgentSessionID: old, files: true, dryRun: false))
        }
        #expect(await eventually { await world.host.written("rewind_files").count == 1 })
        #expect(world.reservations.owner(of: ClaudeConversation.reservationKey(old)) == helperKey)
        #expect(!world.reservations.reserve(ClaudeConversation.reservationKey(old), owner: "launch-1"), "その間に TUI で同じ会話を起こせない")
        do {
            _ = try await world.service.send(conversation.id, ConversationSendRequest(text: "x", clientMessageID: UUID().uuidString.lowercased()))
            Issue.record("巻き戻しの途中に送れた")
        } catch let error as ConversationError {
            #expect(error.code == .conversationBusy)
        }
        let response = try await rewinding.value
        let after = try #require(response.conversation)
        #expect(after.rewindIncomplete && after.agentSessionID != old && after.forkPending == false, "最初の発言まで戻すと新しい会話として始める")
        #expect(try world.store.conversation(id: conversation.id)?.rewindFilesPending == true)
        #expect(world.reservations.owner(of: ClaudeConversation.reservationKey(old)) == nil)

        _ = try await world.service.send(conversation.id, ConversationSendRequest(text: "続き", clientMessageID: UUID().uuidString.lowercased()))
        #expect(try world.store.conversation(id: conversation.id)?.rewindFilesPending == false)
        #expect(try await world.service.get(conversation.id).rewindIncomplete == false)
        let resumed = try #require(await world.host.requests.last { $0.op == .spawn && $0.key == conversation.id })
        #expect(argument(resumed.argv ?? [], after: "--session-id") == after.agentSessionID && !(resumed.argv ?? []).contains("--resume"))
    }

    @Test("CLI がファイルを戻すのを断ったら、記録を巻き戻す前に戻して失敗を返す（新しい ID はタスクに残さない）")
    func rewindRefused() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let old = conversation.agentSessionID
        try world.append(old, [("u1", "user", "はじめ"), ("a1", "assistant", "one"), ("u2", "user", "二つ目"), ("a2", "assistant", "two")])
        await world.host.setReply("rewind_files", #"{"canRewind":false,"error":"No file checkpoint found for this message."}"#)
        do {
            _ = try await world.service.rewind(conversation.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: old, files: true, dryRun: false))
            Issue.record("断られたのに巻き戻った")
        } catch let error as ConversationError {
            #expect(error.code == .sessionCommandFailed)
        }
        let record = try #require(try world.store.conversation(id: conversation.id))
        #expect(record.agentSessionId == old && record.previousSessionId == nil && record.pendingForkSessionId == nil && !record.rewindFilesPending)
        #expect(try world.store.task(number: world.task)?.sessions.map(\.sessionID) == [old])
        #expect(world.reservations.owner(of: ClaudeConversation.reservationKey(old)) == nil)
    }

    @Test("会話だけの巻き戻しと元に戻す：補助のプロセスを起こさない。元に戻すと前の ID に戻り、2 回目と古い ID の要求は 409。生成中・人の発言でない行・送っていない会話は断る")
    func rewindConversationOnly() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let old = conversation.agentSessionID
        try world.append(old, [("u1", "user", "はじめ"), ("a1", "assistant", "one"), ("u2", "user", "二つ目"), ("a2", "assistant", "two")])

        await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
        #expect(await eventually { (try? await world.service.get(conversation.id))?.phase == .running })
        do {
            _ = try await world.service.rewind(conversation.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: old, files: false, dryRun: false))
            Issue.record("生成中に巻き戻った")
        } catch let error as ConversationError {
            #expect(error.code == .conversationBusy)
        }
        await world.host.emit(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#)
        #expect(await eventually { (try? await world.service.get(conversation.id))?.phase == .idle })
        await #expect(throws: ConversationError.invalid("人が送った発言ではない")) {
            try await world.service.rewind(conversation.id, ConversationRewindRequest(messageID: "a1#0", expectedAgentSessionID: old, files: false, dryRun: false))
        }
        await #expect(throws: ConversationError.changed(conversation.id)) {
            try await world.service.rewind(conversation.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: "other", files: false, dryRun: false))
        }

        let response = try await world.service.rewind(
            conversation.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: old, files: false, dryRun: false))
        let rewound = try #require(response.conversation)
        #expect(rewound.canUndoRewind && rewound.agentSessionID != old && response.draft == "二つ目")
        #expect(await world.host.requests.allSatisfy { $0.key != "\(conversation.id)-rewind" })
        await #expect(throws: ConversationError.changed(conversation.id)) {
            try await world.service.rewind(conversation.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: old, files: false, dryRun: false))
        }
        await #expect(throws: ConversationError.notSent(conversation.id)) {
            try await world.service.rewind(
                conversation.id, ConversationRewindRequest(messageID: "u1", expectedAgentSessionID: rewound.agentSessionID, files: false, dryRun: false))
        }

        let undone = try await world.service.undoRewind(conversation.id, ConversationSessionGuard(expectedAgentSessionID: rewound.agentSessionID))
        #expect(undone.agentSessionID == old && !undone.canUndoRewind && !undone.forkPending)
        let record = try #require(try world.store.conversation(id: conversation.id))
        #expect(record.previousSessionId == nil && record.pendingForkSessionId == nil && record.pendingForkAt == nil)
        await #expect(throws: ConversationError.changed(conversation.id)) {
            try await world.service.undoRewind(conversation.id, ConversationSessionGuard(expectedAgentSessionID: old))
        }
    }

    @Test("元に戻した巻き戻しはやり直せる：巻き戻した先の ID とまだ送っていない印に戻り、もう一度元に戻せる。元に戻した後に送ると、やり直せなくなる（409）")
    func redoRewind() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let old = conversation.agentSessionID
        try world.append(old, [("u1", "user", "はじめ"), ("a1", "assistant", "one"), ("u2", "user", "二つ目"), ("a2", "assistant", "two")])
        let rewound = try #require(
            try await world.service.rewind(conversation.id, ConversationRewindRequest(messageID: "u2", expectedAgentSessionID: old, files: false, dryRun: false))
                .conversation)
        #expect(!rewound.canRedoRewind)
        let undone = try await world.service.undoRewind(conversation.id, ConversationSessionGuard(expectedAgentSessionID: rewound.agentSessionID))
        #expect(undone.agentSessionID == old && undone.canRedoRewind && !undone.canUndoRewind)
        await #expect(throws: ConversationError.changed(conversation.id)) {
            try await world.service.redoRewind(conversation.id, ConversationSessionGuard(expectedAgentSessionID: rewound.agentSessionID))
        }

        let redone = try await world.service.redoRewind(conversation.id, ConversationSessionGuard(expectedAgentSessionID: old))
        #expect(redone.agentSessionID == rewound.agentSessionID && redone.canUndoRewind && !redone.canRedoRewind && redone.forkPending)
        let record = try #require(try world.store.conversation(id: conversation.id))
        #expect(record.previousSessionId == old && record.pendingForkSessionId == old && record.pendingForkAt == "a1" && record.redoSessionId == nil)
        await #expect(throws: ConversationError.changed(conversation.id)) {
            try await world.service.redoRewind(conversation.id, ConversationSessionGuard(expectedAgentSessionID: rewound.agentSessionID))
        }

        let again = try await world.service.undoRewind(conversation.id, ConversationSessionGuard(expectedAgentSessionID: rewound.agentSessionID))
        #expect(again.canRedoRewind)
        _ = try await world.service.send(conversation.id, ConversationSendRequest(text: "別の続き", clientMessageID: UUID().uuidString.lowercased()))
        #expect(try await world.service.get(conversation.id).canRedoRewind == false)
        await #expect(throws: ConversationError.changed(conversation.id)) {
            try await world.service.redoRewind(conversation.id, ConversationSessionGuard(expectedAgentSessionID: old))
        }
    }

    @Test("dry run は会話を変えない。動いていれば会話のプロセスに、止まっていれば補助のプロセスに dry_run を送り、終わったら予約を外す")
    func rewindDryRun() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let old = conversation.agentSessionID
        try world.append(old, [("u1", "user", "はじめ"), ("a1", "assistant", "one")])
        await world.host.setReply("rewind_files", #"{"canRewind":true,"filesChanged":["a.txt"],"insertions":3,"deletions":0}"#)
        let request = ConversationRewindRequest(messageID: "u1", expectedAgentSessionID: old, files: true, dryRun: true)

        let live = try await world.service.rewind(conversation.id, request)
        #expect(live.filesChanged == ["a.txt"] && live.insertions == 3 && live.conversation == nil)
        #expect(await world.host.requests.contains { $0.op == .write && $0.key == conversation.id && ($0.data ?? "").contains("rewind_files") })

        try await world.service.stop(conversation.id, cause: .person)
        let stopped = try await world.service.rewind(conversation.id, request)
        #expect(stopped.canRewind == true && stopped.filesChanged == ["a.txt"])
        let helperWrites = await world.host.requests.filter { $0.op == .write && $0.key == "\(conversation.id)-rewind" }
        #expect(helperWrites.contains { ($0.data ?? "").contains(#""dry_run":true"#) })
        let record = try #require(try world.store.conversation(id: conversation.id))
        #expect(record.agentSessionId == old && record.previousSessionId == nil && !record.rewindFilesPending)
        #expect(world.reservations.owner(of: ClaudeConversation.reservationKey(old)) == nil)
    }

    @Test("繋いだ host に前の daemon の補助のプロセスが残っていれば、記録の無い子として扱わず、その会話が止め終えるまで予約を持つ")
    func orphanedRewindHelper() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let record = try world.store.createConversation(
            ConversationRecord(taskNumber: world.task, agentSessionId: "s-new", cwd: world.directory.path, runner: .none))
        _ = try world.store.updateConversation(id: record.id) {
            $0.previousSessionId = "s-old"
            $0.rewindFilesPending = true
        }
        let helperKey = "\(record.id)-rewind"
        await world.host.setProcesses([AgentHostProcessInfo(key: helperKey, pid: 12, alive: true, exit: nil, lastSeq: 0, firstSeq: 1, keptBytes: 0, startedAt: 1)])
        await world.service.connected(restarted: false)
        #expect(await eventually { await world.host.requests.contains { $0.op == .signal && $0.key == helperKey && $0.signal == "TERM" } })
        #expect(await eventually { world.reservations.owner(of: ClaudeConversation.reservationKey("s-old")) == nil })
        #expect(try await world.service.get(record.id).rewindIncomplete)
        #expect(await world.host.requests.allSatisfy { $0.op != .spawn })
    }

    // MARK: 事前起動

    private func prewarmRequest(_ world: ServiceWorld, model: String = "haiku") -> ConversationPrewarmRequest {
        ConversationPrewarmRequest(cwd: world.directory.path, model: model)
    }

    /// 事前起動の子が initialize まで済ませるのを待ち、その key を返す。host の一覧にも載せる（引き取りが `list` で引く）
    private func prewarmed(_ world: ServiceWorld, count: Int = 1) async throws -> String {
        #expect(await eventually { await world.host.requests.filter { $0.op == .spawn }.count == count })
        let key = try #require(await world.host.requests.last { $0.op == .spawn }?.key)
        #expect(await eventually { await world.host.written("initialize").count >= count })
        await world.host.setProcesses([AgentHostProcessInfo(key: key, pid: 42, alive: true, exit: nil, lastSeq: await world.host.seq, firstSeq: 1, keptBytes: 0, startedAt: 1)])
        return key
    }

    private func spawnedSession(_ world: ServiceWorld, _ key: String) async -> String? {
        guard let spawn = await world.host.requests.last(where: { $0.op == .spawn && $0.key == key }) else { return nil }
        return argument(spawn.argv ?? [], after: "--session-id")
    }

    @Test("事前起動：記録を作らずに会話の環境（hook が何もしない印つき）で起こして initialize まで済ませ、同じ条件の起動はその子を引き取る（起こし直さない）")
    func prewarmAdopted() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        try await world.service.prewarm(prewarmRequest(world))
        #expect(await eventually { await world.host.written("initialize").count == 1 })
        let spawn = try #require(await world.host.requests.first { $0.op == .spawn })
        let key = try #require(spawn.key)
        let session = try #require(argument(spawn.argv ?? [], after: "--session-id"))
        #expect(spawn.env?["TASKBOARD_CONVERSATION_ID"] == key, "settings.json の hook はこの印で何もしない（記録の無い会話 ID でタスクを作らない）")
        #expect(argument(spawn.argv ?? [], after: "--model") == "claude-haiku-5-5")
        #expect(try world.store.conversations().isEmpty, "記録は引き取るまで作らない")
        #expect(try world.store.task(number: world.task)?.sessions.isEmpty == true)
        #expect(world.reservations.owner(of: ClaudeConversation.reservationKey(session)) == key)
        #expect(world.service.slots.count == 1, "枠を持つ")
        try await world.service.prewarm(prewarmRequest(world))
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == 1, "同じ条件なら起こし直さない")
        await world.host.setProcesses([AgentHostProcessInfo(key: key, pid: 42, alive: true, exit: nil, lastSeq: await world.host.seq, firstSeq: 1, keptBytes: 0, startedAt: 1)])

        let conversation = try await world.service.start(world.request(prompt: "はじめ"))
        #expect(conversation.id == key && conversation.agentSessionID == session && conversation.runner == .host && conversation.taskNumber == world.task)
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == 1)
        #expect(await world.host.written("initialize").count == 2, "引き取ったら initialize を送り直す")
        #expect(
            await world.host.written("initialize").allSatisfy { ($0["request"] as? [String: Any])?["perTaskStopAffordance"] as? Bool == true },
            "宣言は最初の initialize だけが効くので、事前起動の子も宣言する")
        #expect(try world.store.task(number: world.task)?.sessions.map(\.sessionID) == [session])
        #expect(world.service.slots.count == 1)
        let users = await world.host.written().filter { $0["type"] as? String == "user" }
        #expect(users.count == 1 && ((users.first?["message"] as? [String: Any])?["content"] as? String)?.contains("はじめ") == true)
    }

    @Test("事前起動：違う条件の起動・新しい事前起動・時間切れでは、止め終えて枠と予約を返してから次を起こす（2 本が同時に枠を持たない）")
    func prewarmDiscarded() async throws {
        let world = try await ServiceWorld.make(slots: ConversationSlots(soft: 1, hard: 4)) {
            // 最初の launch（ログインシェルの環境を取る）より短いと、起こす前に時間切れで捨てる
            $0.prewarmLifetime = .milliseconds(1500)
        }
        defer { world.cleanUp() }
        try await world.service.prewarm(prewarmRequest(world))
        let first = try await prewarmed(world)
        let firstSession = try #require(await spawnedSession(world, first))
        // 目安が 1 なので、前の枠を返す前に取ろうとすると温められない
        try await world.service.prewarm(prewarmRequest(world, model: "sonnet"))
        let second = try await prewarmed(world, count: 2)
        let requests = await world.host.requests
        let closed = try #require(requests.firstIndex { $0.op == .closeInput && $0.key == first })
        let spawned = try #require(requests.lastIndex { $0.op == .spawn && $0.key == second })
        #expect(closed < spawned && first != second)
        #expect(world.reservations.owner(of: ClaudeConversation.reservationKey(firstSession)) == nil)

        // 時間切れで捨てる
        var expired = false
        for _ in 0..<250 where !expired {
            expired = await world.host.requests.contains { $0.op == .closeInput && $0.key == second }
            if !expired { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(expired)
        #expect(await eventually { world.service.slots.count == 0 })

        try await world.service.prewarm(prewarmRequest(world))
        let third = try await prewarmed(world, count: 3)
        let conversation = try await world.service.start(world.request(prompt: nil, resume: nil, bound: true).withModel("sonnet"))
        #expect(conversation.id != third)
        #expect(await world.host.requests.contains { $0.op == .closeInput && $0.key == third }, "違う条件の起動は事前起動を捨てる")
        #expect(world.service.slots.count == 1)
        #expect(try world.store.conversations().map(\.id) == [conversation.id], "捨てた事前起動の記録は残らない")
    }

    @Test("事前起動：起こしている途中の起動は起き終えるのを待って引き取る。host に繋ぎ直しただけなら止めない。host が起き直したら枠と予約を返す")
    func prewarmHost() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        await world.host.setWriteDelay(.milliseconds(300))
        try await world.service.prewarm(prewarmRequest(world))
        #expect(await eventually { await world.host.requests.contains { $0.op == .spawn } })
        let key = try #require(await world.host.requests.first { $0.op == .spawn }?.key)
        let service = world.service
        let request = world.request()
        let host = world.host
        let starting = Task {
            // initialize の応答（書き込みの後）より先に、host の一覧に載せておく
            await host.setProcesses([AgentHostProcessInfo(key: key, pid: 42, alive: true, exit: nil, lastSeq: 1, firstSeq: 1, keptBytes: 0, startedAt: 1)])
            return try await service.start(request)
        }
        await world.host.setWriteDelay(nil)
        let adopted = try await starting.value
        let spawnsAfterAdopt = await world.host.requests.filter { $0.op == .spawn }.count
        #expect(adopted.id == key && spawnsAfterAdopt == 1)
        try await world.service.stop(adopted.id, cause: .person)

        try await world.service.prewarm(prewarmRequest(world))
        let second = try await prewarmed(world, count: 2)
        await world.service.connected(restarted: false)
        #expect(await world.host.requests.allSatisfy { !($0.key == second && ($0.op == .signal || $0.op == .closeInput)) }, "繋ぎ直しただけなら止めない")
        let session = try #require(await spawnedSession(world, second))
        await world.host.setProcesses([])
        await world.service.connected(restarted: true)
        #expect(await eventually { world.reservations.owner(of: ClaudeConversation.reservationKey(session)) == nil })
        #expect(await eventually { world.service.slots.count == 0 })
        let fresh = try await world.service.start(world.request())
        let spawns = await world.host.requests.filter { $0.op == .spawn }.count
        #expect(fresh.id != second && spawns == 3)
    }

    // MARK: Run

    private func runUpdates(_ frames: [StreamServerFrame]) -> [ConversationRunUpdate] {
        frames.compactMap { frame in
            if case .conversation(let event) = frame, case .run(let update) = event.kind { return update }
            return nil
        }
    }

    @Test("Run：会話の作業フォルダで動かし、出力と状態を購読に流す。控えには積まない（購読し直しても流れてこない）。会話を消すと引けない")
    func run() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let outbox = StreamOutbox()
        #expect(await world.service.subscribe(conversation.id, key: UUID(), epoch: nil, after: 0, outbox: outbox))
        let run = try await world.service.startRun(conversation.id, ConversationRunRequest(code: "echo 実行; exit 0", language: "sh", messageID: "m1"))
        #expect(await eventually { (try? await world.service.run(conversation.id, run.id))?.status == .succeeded })
        let done = try await world.service.run(conversation.id, run.id)
        #expect(done.output == "実行\n" && done.exitCode == 0)
        try await Task.sleep(for: .milliseconds(100))
        let updates = runUpdates(await frames(outbox))
        #expect(updates.map(\.chunk).joined() == "実行\n" && updates.last?.status == .succeeded && updates.allSatisfy { $0.messageID == "m1" })

        let again = StreamOutbox()
        #expect(await world.service.subscribe(conversation.id, key: UUID(), epoch: nil, after: 0, outbox: again))
        #expect(runUpdates(await frames(again)).isEmpty, "控えに積まない")
        await #expect(throws: ConversationService.runNotFound("x")) { try await world.service.run(conversation.id, "x") }
        await #expect(throws: ConversationService.runNotFound("x")) { try await world.service.cancelRun(conversation.id, "x") }

        try await world.service.stop(conversation.id, cause: .person)
        try await world.service.delete(conversation.id)
        await #expect(throws: ConversationService.runNotFound(run.id)) { try await world.service.run(conversation.id, run.id) }
    }

    // MARK: ログインシェルの環境

    /// 遅いログインシェル（`seconds` 秒待ってから環境を出す。`fails` なら何も出さずに終わる）
    private func slowShell(_ directory: URL, seconds: Int, fails: Bool) throws -> String {
        let url = directory.appending(path: "slow-shell-\(UUID().uuidString.prefix(8))")
        let body = fails ? "sleep \(seconds); exit 1" : "sleep \(seconds); printf '\\n\(LoginShellEnvironment.marker)\\n'; /usr/bin/env -0"
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test("ログインシェルの環境は、一度取れたら古くなってもすぐ返して裏で取り直す（履歴の取得をシェルの起動で待たせない）")
    func loginEnvironmentServesStale() async throws {
        let clock = TestClock(Date())
        let shellDirectory = FileManager.default.temporaryDirectory.appending(path: "tb-slow-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shellDirectory) }
        let shell = try slowShell(shellDirectory, seconds: 2, fails: false)
        let world = try await ServiceWorld.make(configure: {
            $0.now = { clock.now }
            $0.shell = shell
        })
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        clock.advance(3600)
        let started = ContinuousClock.now
        _ = try await world.service.history(conversation.id, before: nil, limit: 10)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("ログインシェルの環境が取れなかったときも代わりの環境を控え、次の要求をまた待たせない")
    func loginEnvironmentFailureCached() async throws {
        let shellDirectory = FileManager.default.temporaryDirectory.appending(path: "tb-slow-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shellDirectory) }
        let shell = try slowShell(shellDirectory, seconds: 1, fails: true)
        let world = try await ServiceWorld.make(configure: { $0.shell = shell })
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let started = ContinuousClock.now
        _ = try await world.service.history(conversation.id, before: nil, limit: 10)
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    @Test("ログインシェルの環境が取れずに daemon の環境で代えた後は、次に会話を起こすときに取り直しを待ち、取れた環境で起こす")
    func loginEnvironmentFailureRetriedOnLaunch() async throws {
        let shellDirectory = FileManager.default.temporaryDirectory.appending(path: "tb-flaky-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shellDirectory) }
        // 呼ばれた回数を数え、最初の 2 回（-lic と -lc）は何も出さずに終わる
        let shell = shellDirectory.appending(path: "flaky-shell")
        let count = shellDirectory.appending(path: "count").path
        let script = """
            #!/bin/sh
            n=$(cat '\(count)' 2>/dev/null || echo 0); n=$((n + 1)); echo $n > '\(count)'
            [ $n -le 2 ] && exit 1
            printf '\\n\(LoginShellEnvironment.marker)\\n'; TB_FROM_SHELL=1 /usr/bin/env -0
            """
        try Data("\(script)\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let world = try await ServiceWorld.make(configure: { $0.shell = shell.path })
        defer { world.cleanUp() }

        _ = try await world.service.start(world.request())
        _ = try await world.service.start(world.request())
        let spawned = await world.host.requests.filter { $0.op == .spawn }.map { $0.env?["TB_FROM_SHELL"] }
        #expect(spawned == [nil, "1"])
    }

    // MARK: シェル

    @Test("シェル：会話の cwd で agent host にログインシェルを起こし、生きていれば同じシェルを返す。同時の 2 回で 1 つ。終われば記録から外し、次は起こし直す。会話を消すとシェルを閉じる")
    func shell() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        let key = "shell-\(conversation.id)"
        async let first = world.service.shell(conversation.id)
        async let second = world.service.shell(conversation.id)
        let (a, b) = try await (first, second)
        #expect(a == b && a.rawValue == key)
        let opened = await world.host.openedShells
        #expect(opened.count == 1 && opened.first?.cwd == world.directory.path && opened.first?.argv.last == "-l")
        #expect(try world.store.conversation(id: conversation.id)?.shellId == key)
        #expect(try await world.service.shell(conversation.id) == a)
        #expect(await world.host.openedShells.count == 1)

        await world.host.endShell(key)
        #expect(await eventually { (try? world.store.conversation(id: conversation.id))?.shellId == nil })
        #expect(try await world.service.shell(conversation.id).rawValue == key)
        #expect(await world.host.openedShells.count == 2)

        try await world.service.stop(conversation.id, cause: .person)
        try await world.service.delete(conversation.id)
        #expect(await world.host.shells.isEmpty)
        await #expect(throws: ConversationService.notFound(conversation.id)) { try await world.service.shell(conversation.id) }
    }

    @Test("host が起き直してシェルが無くなったら、繋がったときに記録から外す。生きているシェルは残す")
    func dropsShellsTheHostLost() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let lost = try await world.service.start(world.request())
        _ = try await world.service.shell(lost.id)
        await world.service.connected(restarted: false)
        #expect(try world.store.conversation(id: lost.id)?.shellId == ConversationShells.key(conversation: lost.id))

        await world.host.restart()
        let kept = try await world.service.start(world.request())
        _ = try await world.service.shell(kept.id)
        await world.service.connected(restarted: true)
        #expect(try world.store.conversation(id: lost.id)?.shellId == nil)
        #expect(try world.store.conversation(id: kept.id)?.shellId == ConversationShells.key(conversation: kept.id))
    }

    @Test("シェルを止める：シェルを閉じて記録から外し、次に開くと新しいシェル。シェルが無ければ何もしない")
    func stopShell() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        try await world.service.stopShell(conversation.id)
        #expect(await !world.host.requests.contains { $0.op == .shellClose })

        _ = try await world.service.shell(conversation.id)
        try await world.service.stopShell(conversation.id)
        #expect(await world.host.shells.isEmpty)
        #expect(try world.store.conversation(id: conversation.id)?.shellId == nil)
        _ = try await world.service.shell(conversation.id)
        #expect(await world.host.openedShells.count == 2)
        await #expect(throws: ConversationService.notFound("missing")) { try await world.service.stopShell("missing") }
    }

    @Test("足す引数は起こす引数に入り、記録に残る。会話に渡せない引数は断る")
    func extraArguments() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        var request = world.request()
        request.extraArgs = ["--disallowedTools", "Bash(rm:*)", "WebFetch"]
        let conversation = try await world.service.start(request)
        let argv = try #require(await world.host.requests.first { $0.op == .spawn }?.argv)
        let at = try #require(argv.firstIndex(of: "--disallowedTools"))
        #expect(Array(argv[at...].prefix(3)) == ["--disallowedTools", "Bash(rm:*)", "WebFetch"])
        #expect(try world.store.conversation(id: conversation.id)?.extraArguments == ["--disallowedTools", "Bash(rm:*)", "WebFetch"])

        var refused = world.request()
        refused.extraArgs = ["--dangerously-skip-permissions"]
        await #expect(throws: ConversationError.invalid("extra_args に会話へ渡せない引数がある")) { try await world.service.start(refused) }
    }

    @Test("worktree を頼むと、切った worktree で起こす。シェルは開いたときに worktree で起こす。起こせなければ記録を消す")
    func worktree() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        var request = world.request()
        request.worktree = LaunchRequest.WorktreeSpec(branch: "feature/e4")
        let conversation = try await world.service.start(request)
        let made = try #require(await world.worktrees.made.first)
        #expect(made.cwd == world.directory.path && made.branch == "feature/e4")
        #expect(conversation.cwd == world.directory.path + "/.wt/feature/e4")
        #expect(await world.host.requests.first { $0.op == .spawn }?.cwd == world.directory.path + "/.wt/feature/e4")
        #expect(try world.store.conversation(id: conversation.id)?.shellId == nil)
        _ = try await world.service.shell(conversation.id)
        #expect(await world.host.openedShells.map(\.cwd) == [world.directory.path + "/.wt/feature/e4"])

        await #expect(throws: ConversationError.invalid("戻す会話には worktree を切れない")) {
            var resume = world.request(resume: "6f1d2b8e-2c4a-4a8f-9c11-5d7e0a3b9f01")
            resume.worktree = LaunchRequest.WorktreeSpec(branch: "x")
            _ = try await world.service.start(resume)
        }

        await world.host.setFailing([.spawn])
        var failing = world.request()
        failing.worktree = LaunchRequest.WorktreeSpec(branch: "feature/fail")
        await #expect(throws: (any Error).self) { try await world.service.start(failing) }
        #expect(await world.worktrees.made.map(\.branch) == ["feature/e4", "feature/fail"])
        #expect(try world.store.conversations().count == 1)
    }

    @Test("オーケストレーターの会話は、枠を空けるためにも止めず、止めても記録を消さない")
    func orchestratorConversation() async throws {
        let world = try await ServiceWorld.make(slots: ConversationSlots(soft: 2, hard: 4))
        defer { world.cleanUp() }
        let orchestrator = try await world.service.start(world.request(), purpose: .orchestrator)
        let second = try await world.service.start(world.request())
        _ = try await world.service.start(world.request())
        #expect(await eventually { world.service.slots.count == 2 })
        #expect(await world.service.isLive(orchestrator.id))
        #expect(try world.store.conversation(id: second.id)?.lastExit == "使われていないので止めた")
        #expect(try world.store.conversation(id: orchestrator.id)?.lastExit == nil)
        #expect(await world.service.stopIdle(before: Date().addingTimeInterval(60)).contains(orchestrator.id) == false)

        let unbound = try await world.service.start(world.request(bound: false), purpose: .orchestrator)
        _ = try world.store.updateSettings(MachineSettingsUpdate(orchestratorEnabled: false))
        try await world.service.stop(unbound.id, cause: .person)
        #expect(try world.store.conversation(id: unbound.id) != nil)
    }
}

actor NoticeLog {
    private(set) var all: [String] = []
    func add(_ text: String) { all.append(text) }
}
