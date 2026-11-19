import Darwin
import Foundation
import TaskboardKit
import TestSupport
import Testing

@testable import TaskboardDaemon

/// 委譲先の知らせに載せる最後の返事（`ConversationService.latestReply`）
@Suite("会話の最後の返事（偽物の host・偽物の codex）", .serialized)
struct ConversationReplyTests {
    private static let page = #"{"data":[{"turnId":"t2","item":{"type":"commandExecution","id":"c2","command":"ls","status":"completed","aggregatedOutput":"x","exitCode":0},"completedAtMs":5},{"turnId":"t2","item":{"type":"agentMessage","id":"a2b","text":"二つ目の最後"},"completedAtMs":4},{"turnId":"t2","item":{"type":"reasoning","id":"r2","summary":[],"content":[]},"completedAtMs":3},{"turnId":"t2","item":{"type":"agentMessage","id":"a2a","text":"二つ目の途中"},"completedAtMs":2},{"turnId":"t2","item":{"type":"userMessage","id":"u2","clientId":null,"content":[{"type":"text","text":"二"}]},"completedAtMs":1},{"turnId":"t1","item":{"type":"agentMessage","id":"a1","text":"一つ目"},"completedAtMs":0}],"nextCursor":null}"#

    /// `thread/items/list` に頁を返す偽の口。呼ばれた method と params を覚える。`hang` なら返事を返さずに待つ
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String]
        private(set) var calls: [(method: String, params: [String: Any])] = []
        var hang = false
        var failure: (any Error)?

        init(pages: [String]) { self.pages = pages }

        func call(_ method: String, _ params: any Encodable & Sendable) async throws -> CodexRPCLine {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any] ?? [:]
            let (page, hang, failure) = lock.withLock { () -> (String, Bool, (any Error)?) in
                calls.append((method, object))
                return (pages.count > 1 ? pages.removeFirst() : pages[0], self.hang, self.failure)
            }
            if hang { try await Task.sleep(for: .seconds(60)) }
            if let failure { throw failure }
            return CodexRPCLine(Data(#"{"id":"0-1","result":\#(page)}"#.utf8))!
        }

        var recorded: [(method: String, params: [String: Any])] { lock.withLock { calls } }
    }

    private func makeWorld(
        replyLimit: Duration? = .milliseconds(400), oneShotLimit: Duration? = nil, oneShot: OneShot? = nil, server: FakeThreadServer? = nil,
        script: SharedExecutable? = nil
    ) async throws -> (ServiceWorld, URL) {
        let bin = FileManager.default.temporaryDirectory.appending(path: "tb-reply-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appending(path: "codex")
        if let script {
            _ = try script.link(in: bin, as: "codex")
        } else {
            try Data("#!/bin/sh\n".utf8).write(to: codex)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        }
        let shell = try SharedExecutable(
            name: "tb-test-codex-login-shell.sh",
            script: "#!/bin/sh\nprintf '\\n\(LoginShellEnvironment.marker)\\n'\nPATH=\"$(dirname \"$0\")\" exec /usr/bin/env -0\n"
        ).link(in: bin, as: "login-shell")
        let world = try await ServiceWorld.make {
            $0.shell = shell.path
            if let replyLimit { $0.timing.noticeReply = replyLimit }
            if let oneShotLimit { $0.timing.control = oneShotLimit }
            if let oneShot { $0.codexOneShot = { method, params in try await oneShot.call(method, params) } }
        }
        try VerifiedCLI.record(.init(version: "0.162.1", path: codex.path, capabilities: [], verifiedAt: Date()), .codex, supportDirectory: world.directory)
        // 渡したときだけ codex の偽物に替える（替えると、親の Claude の会話の initialize に偽の host が答えない）
        if let server { await world.host.setResponder(server.respond) }
        return (world, bin)
    }

    private func stoppedCodex(_ world: ServiceWorld, thread: String = "th-9", parent: String? = nil) throws -> ConversationRecord {
        var record = ConversationRecord(taskNumber: world.task, engine: .codex, agentSessionId: thread, cwd: world.directory.path, runner: .none)
        record.parentConversationId = parent
        return try world.store.createConversation(record)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("codex：最後の turn の最後の返事を返す。途中の文・考え・コマンド・人の発言と前の turn は返さない")
    func codexLastReply() async throws {
        let oneShot = OneShot(pages: [Self.page])
        let (world, bin) = try await makeWorld(oneShot: oneShot)
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let record = try stoppedCodex(world)
        #expect(await world.service.latestReply(record.id) == "二つ目の最後")
        let call = try #require(oneShot.recorded.first)
        #expect(call.method == "thread/items/list" && call.params["threadId"] as? String == "th-9" && call.params["sortDirection"] as? String == "desc")
    }

    @Test("codex：最後の turn に返事が無ければ、前の turn の返事に戻らず nil（Claude の transcript の読み方と同じ）")
    func codexTurnWithoutReply() async throws {
        let page =
            #"{"data":[{"turnId":"t2","item":{"type":"commandExecution","id":"c2","command":"ls","status":"completed","aggregatedOutput":"x","exitCode":0}},{"turnId":"t2","item":{"type":"userMessage","id":"u2","clientId":null,"content":[{"type":"text","text":"二"}]}},{"turnId":"t1","item":{"type":"agentMessage","id":"a1","text":"一つ目"}}],"nextCursor":null}"#
        let (world, bin) = try await makeWorld(oneShot: OneShot(pages: [page]))
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        #expect(await world.service.latestReply(try stoppedCodex(world).id) == nil)
    }

    @Test("codex：turn が頁をまたいでも最後の返事を見つける。上限（2,000 字）で切る")
    func codexAcrossPagesAndLimit() async throws {
        let long = String(repeating: "あ", count: OrchestratorReplyReader.limit + 500)
        let first =
            #"{"data":[{"turnId":"t2","item":{"type":"commandExecution","id":"c2","command":"ls","status":"completed","aggregatedOutput":"x","exitCode":0}}],"nextCursor":"older"}"#
        let second =
            #"{"data":[{"turnId":"t2","item":{"type":"agentMessage","id":"a2","text":"\#(long)"}},{"turnId":"t2","item":{"type":"userMessage","id":"u2","clientId":null,"content":[{"type":"text","text":"二"}]}}],"nextCursor":null}"#
        let oneShot = OneShot(pages: [first, second])
        let (world, bin) = try await makeWorld(oneShot: oneShot)
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let reply = try #require(await world.service.latestReply(try stoppedCodex(world).id))
        #expect(reply == String(long.prefix(OrchestratorReplyReader.limit)))
        #expect(oneShot.recorded.map { $0.params["cursor"] as? String } == [nil, "older"])
    }

    @Test("codex：thread が無い会話・口が断った・時間切れは nil。時間切れは上限の直後に返る")
    func codexUnreadable() async throws {
        let oneShot = OneShot(pages: [Self.page])
        let (world, bin) = try await makeWorld(oneShot: oneShot)
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let fresh = try world.store.createConversation(ConversationRecord(id: "fresh", taskNumber: nil, engine: .codex, agentSessionId: "fresh", cwd: "/w", runner: .none))
        #expect(await world.service.latestReply(fresh.id) == nil)
        #expect(oneShot.recorded.isEmpty)

        let record = try stoppedCodex(world)
        oneShot.failure = ConversationError.failed("断られた")
        #expect(await world.service.latestReply(record.id) == nil)

        oneShot.failure = nil
        oneShot.hang = true
        let start = ContinuousClock.now
        #expect(await world.service.latestReply(record.id) == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(await world.service.latestReply("no-such-conversation") == nil)
    }

    @Test("Claude：今までどおり transcript の最後の文を上限で切って返す。transcript が無ければ nil")
    func claudeFromTranscript() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let child = try await world.service.start(world.request())
        #expect(await world.service.latestReply(child.id) == nil)
        let long = String(repeating: "い", count: OrchestratorReplyReader.limit + 10)
        try world.append(child.agentSessionID, [("u1", "user", "調べて"), ("a1", "assistant", "途中"), ("a2", "assistant", long)])
        #expect(await world.service.latestReply(child.id) == String(long.prefix(OrchestratorReplyReader.limit)))
    }

    @Test("codex の委譲先がターンを終えると、親に届く知らせに codex の最後の返事が入る")
    func noticeCarriesCodexReply() async throws {
        let (world, bin) = try await makeWorld(oneShot: OneShot(pages: [Self.page]))
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let parent = try await world.service.start(world.request())
        let child = try stoppedCodex(world, parent: parent.id)
        try markNotice(world, child.id)
        await world.service.connected(restarted: false)
        let notices = ConversationNotices(conversations: world.service, state: world.state)
        async let delivered: Void = notices.deliver(child.id)
        let notice = try #require(await waitForNotice(world))
        #expect(notice.text.contains(TaskboardNotice.delegateTurnHead) && notice.text.contains("二つ目の最後"))
        #expect(!notice.text.contains("返事を読めなかった"))
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(notice.uuid)","state":"started"}"#, key: parent.id)
        await delivered
    }

    @Test("codex の返事を読めなくても、知らせは上限の直後に固定の文で届く（止めない・遅らせない）")
    func noticeNotDelayed() async throws {
        let oneShot = OneShot(pages: [Self.page])
        oneShot.hang = true
        let (world, bin) = try await makeWorld(oneShot: oneShot)
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let parent = try await world.service.start(world.request())
        let child = try stoppedCodex(world, parent: parent.id)
        try markNotice(world, child.id)
        await world.service.connected(restarted: false)
        let notices = ConversationNotices(conversations: world.service, state: world.state)
        let start = ContinuousClock.now
        async let delivered: Void = notices.deliver(child.id)
        let notice = try #require(await waitForNotice(world))
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(notice.text.contains("返事を読めなかった"))
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(notice.uuid)","state":"started"}"#, key: parent.id)
        await delivered
    }

    @Test("動いている会話が生成中なら、先頭の生成中の turn を飛ばして終わった turn の返事を返す")
    func skipsGeneratingTurn() async throws {
        let server = FakeThreadServer()
        server.setTurnLines(FakeThreadServer.started)
        server.setResults(
            "thread/items/list",
            [
                #"{"data":[{"turnId":"t3","item":{"type":"agentMessage","id":"a3","text":"三つ目の途中"}},{"turnId":"t3","item":{"type":"userMessage","id":"u3","clientId":null,"content":[{"type":"text","text":"三"}]}},{"turnId":"t2","item":{"type":"agentMessage","id":"a2","text":"二つ目の最後"}},{"turnId":"t2","item":{"type":"userMessage","id":"u2","clientId":null,"content":[{"type":"text","text":"二"}]}}],"nextCursor":null}"#
            ])
        let (world, bin) = try await makeWorld(server: server)
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let started = try await world.service.start(ConversationStartRequest(cwd: world.directory.path, taskNumber: world.task, engine: .codex))
        #expect(await world.service.latestReply(started.id) == "三つ目の途中")
        _ = try await world.service.send(started.id, ConversationSendRequest(text: "続けて"))
        #expect(await eventually { await world.service.noticeState(started.id)?.busy == true })
        #expect(await world.service.latestReply(started.id) == "二つ目の最後")
    }

    // MARK: 使い捨ての codex の process

    /// 起動したら pid を残し、initialize と thread/items/list にだけ答え、受けた行を残す偽の codex
    private static let answeringCodex = SharedExecutable(
        name: "tb-test-codex-answering.sh",
        script: """
        #!/bin/sh
        PATH=/usr/bin:/bin
        dir="$(dirname "$0")"
        echo $$ > "$dir/pid"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$dir/received"
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\("[^"]*"\\).*/\\1/p')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake"}}\\n' "$id" ;;
            *'"method":"thread/items/list"'*) printf '{"id":%s,"result":%s}\\n' "$id" "$(cat "$dir/page.json")" ;;
          esac
        done
        """)

    /// 起動したら pid を残し、何にも答えず、SIGTERM も無視する偽の codex
    private static let stuckCodex = SharedExecutable(
        name: "tb-test-codex-stuck.sh",
        script: """
        #!/bin/sh
        PATH=/usr/bin:/bin
        echo $$ > "$(dirname "$0")/pid"
        trap '' TERM
        while :; do sleep 1; done
        """)

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func pid(in bin: URL) async -> pid_t? {
        let file = bin.appending(path: "pid")
        for _ in 0..<200 {
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test("使い捨ての codex には、initialize・initialized・thread/items/list だけを送り（モデルを呼ばない）、読み終えたら終わらせる")
    func disposableCodexSendsOnlyReads() async throws {
        // 並べて回すと、起こして initialize に答えるまでが ServiceWorld の 2 秒（timing.control）を超えることがある。上限は本番の既定にする
        let (world, bin) = try await makeWorld(replyLimit: .seconds(30), oneShotLimit: .seconds(30), script: Self.answeringCodex)
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        try Data(Self.page.utf8).write(to: bin.appending(path: "page.json"))
        let record = try stoppedCodex(world)
        #expect(await world.service.latestReply(record.id) == "二つ目の最後")
        let received = try String(contentsOf: bin.appending(path: "received"), encoding: .utf8).split(separator: "\n")
        let methods = try received.map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])["method"] as? String
        }
        #expect(methods == ["initialize", "initialized", "thread/items/list"])
        let pid = try #require(await pid(in: bin))
        #expect(await eventually { !alive(pid) })
    }

    @Test("上限で諦めても、SIGTERM に応えない使い捨ての codex を残さない（SIGKILL で終わらせる）")
    func disposableCodexKilledAfterGivingUp() async throws {
        // 初めの読みはログインシェルの環境を取ってから codex を起こす。並べて回すと 400 ms では起こす前に諦めることがある
        let (world, bin) = try await makeWorld(replyLimit: .seconds(3), script: Self.stuckCodex)
        defer {
            world.cleanUp()
            try? FileManager.default.removeItem(at: bin)
        }
        let record = try stoppedCodex(world)
        let start = ContinuousClock.now
        #expect(await world.service.latestReply(record.id) == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
        let pid = try #require(await pid(in: bin))
        #expect(alive(pid))
        for _ in 0..<400 where alive(pid) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!alive(pid))
    }

    // MARK: 知らせの材料

    private func markNotice(_ world: ServiceWorld, _ child: String) throws {
        _ = try world.store.updateConversation(id: child) {
            $0.notifyParent = true
            $0.parentNoticeTurns = 1
            $0.parentNoticeAt = Date()
        }
    }

    private func waitForNotice(_ world: ServiceWorld) async -> (uuid: String, text: String)? {
        for _ in 0..<250 {
            let found = await world.host.written().compactMap { line -> (String, String)? in
                guard line["type"] as? String == "user", let uuid = line["uuid"] as? String,
                    let text = (line["message"] as? [String: Any])?["content"] as? String, text.contains(TaskboardNotice.delegateTurnHead)
                else { return nil }
                return (uuid, text)
            }.first
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
