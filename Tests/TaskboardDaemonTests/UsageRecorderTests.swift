import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// transcript の追記を読んで貯め、`Store.usageHistory` で集めるまで。行の形は Claude Code 2.1.310 と Codex 0.162.1・0.145.0 の実物から取った
@Suite("利用状況の記録")
struct UsageRecorderTests {
    static let now = Date(timeIntervalSince1970: 1_792_900_800)  // 5 分の区切りの頭
    static func iso(_ offset: TimeInterval) -> String {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return now.addingTimeInterval(offset).formatted(style)
    }

    static func assistant(
        id: String, session: String = "s-1", offset: TimeInterval, input: Int = 2, write: Int = 100, read: Int = 1000, output: Int = 50, skill: String? = nil,
        sidechain: Bool = false, model: String = "claude-opus-5-5"
    ) -> String {
        let content = skill.map { #"[{"type":"tool_use","id":"toolu_1","name":"Skill","input":{"skill":"\#($0)"}}]"# } ?? #"[{"type":"text","text":"x"}]"#
        return #"{"parentUuid":"p","isSidechain":\#(sidechain),"message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":\#(content),"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"output_tokens":\#(output)}},"type":"assistant","uuid":"u-\#(id)","timestamp":"\#(iso(offset))","cwd":"/Users/me/dev/app","sessionId":"\#(session)"}"#
    }

    static func command(_ name: String, offset: TimeInterval) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-message>\#(name)</command-message>\n<command-name>/\#(name)</command-name>"},"uuid":"c","timestamp":"\#(iso(offset))","cwd":"/Users/me/dev/app","sessionId":"s-1"}"#
    }

    static func compact(offset: TimeInterval, trigger: String = "auto", pre: Int = 317_478, post: Int = 24_485) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"\#(trigger)","preTokens":\#(pre),"postTokens":\#(post)},"timestamp":"\#(iso(offset))","sessionId":"s-1"}"#
    }

    static func codex(_ type: String, _ payload: String, offset: TimeInterval) -> String {
        #"{"timestamp":"\#(iso(offset))","ordinal":1,"type":"\#(type)","payload":\#(payload)}"#
    }

    static func tokenCount(input: Int, cached: Int, output: Int, total: Int) -> String {
        #"{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":10,"total_tokens":\#(input + output)},"model_context_window":258400},"rate_limits":null}"#
    }

    struct Fixture {
        let root: URL
        let claude: URL
        let codex: URL
        let store: Store
        let state: DaemonState
        let recorder: UsageRecorder

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)")
            claude = root.appending(path: "projects")
            codex = root.appending(path: "sessions")
            try FileManager.default.createDirectory(at: claude.appending(path: "-Users-me-dev-app/s-1/subagents"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: claude.appending(path: "-Users-me-dev-app/tool-results"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: codex.appending(path: "2026/10/25"), withIntermediateDirectories: true)
            let machine = MachineID(rawValue: "m")
            store = try Store(inMemory: machine)
            state = DaemonState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
            let roots = UsageRecorder.Roots(claudeProjects: claude, codexSessions: codex)
            recorder = UsageRecorder(store: store, state: state, excludedCommands: ["exit", "clear"]) { roots }
        }

        var claudeFile: URL { claude.appending(path: "-Users-me-dev-app/s-1.jsonl") }
        var subagentFile: URL { claude.appending(path: "-Users-me-dev-app/s-1/subagents/agent-a1.jsonl") }
        var codexFile: URL { codex.appending(path: "2026/10/25/rollout-2026-10-25T12-47-01-01a1712b-3d47-7c31-8284-30128b844899.jsonl") }

        func append(_ url: URL, _ lines: [String], newline: Bool = true) throws {
            let text = lines.joined(separator: "\n") + (newline ? "\n" : "")
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
                try handle.close()
            } else {
                try Data(text.utf8).write(to: url)
            }
        }

        func history(_ from: TimeInterval = -86_400, _ to: TimeInterval = 3600) throws -> UsageHistory {
            try store.usageHistory(UsageHistoryQuery(from: UsageRecorderTests.now.addingTimeInterval(from), to: UsageRecorderTests.now.addingTimeInterval(to), bucketSeconds: 3600))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("初めて動いたときに今ある transcript は数えず、その後に足された行だけを数える")
    func startsAtEndOnFirstRun() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.append(f.claudeFile, [Self.assistant(id: "m-old", offset: -60)])
        try await f.recorder.scan(now: Self.now)
        #expect(try f.history().tokens.isEmpty)
        try f.append(f.claudeFile, [Self.assistant(id: "m-new", offset: 10)])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(60))
        let tokens = try f.history().tokens
        #expect(tokens.map(\.requests) == [1])
        #expect(tokens.first?.tokens == TokenCounts(input: 2, cacheWrite: 100, cacheRead: 1000, output: 50))
    }

    @Test("読み続けている transcript の末尾に足し直された前の会話（会話を戻したときに Claude Code が元の時刻のまま書く）は数えない。止まっていた間に書かれた行は数える")
    func skipsReplayedHistory() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.append(f.claudeFile, [Self.assistant(id: "m-1", offset: -4 * 3600)])
        try await f.recorder.scan(now: Self.now)
        try f.append(f.claudeFile, [Self.assistant(id: "m-2", offset: 30)])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(60))
        // 1 時間止まっていた間に書かれた応答と、その後に足し直された 4 時間前の応答
        try f.append(f.claudeFile, [Self.assistant(id: "m-3", offset: 1800), Self.assistant(id: "m-1", offset: -4 * 3600), Self.assistant(id: "m-0", offset: -5 * 3600)])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(3600))
        #expect(try f.history(-86_400, 7200).tokens.reduce(0) { $0 + $1.requests } == 2)
    }

    @Test("Claude Code: 同じ応答の行は 1 回、skill はモデルとコマンドで分け、組み込みのコマンドは数えない。圧縮の前後とタイトルも残す")
    func claudeLines() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.append(f.claudeFile, [])
        try await f.recorder.scan(now: Self.now)
        try f.append(
            f.claudeFile,
            [
                Self.assistant(id: "m-1", offset: 1, skill: "writing-code"),
                Self.assistant(id: "m-1", offset: 1),
                Self.assistant(id: "m-2", offset: 2, input: 3, write: 0, read: 200_000, output: 10),
                Self.command("ukwhatn-writing", offset: 3),
                Self.command("exit", offset: 4),
                Self.compact(offset: 5),
                #"{"type":"custom-title","customTitle":"線 36","sessionId":"s-1"}"#,
                #"{"type":"api-request-blob","sessionId":"s-1","message":{"content":"<command-name>/x</command-name> \"type\":\"assistant\""}}"#,
            ])
        // サブエージェントの応答は親のセッションのトークンに入るが、コンテキストの最大には入れない
        try f.append(f.subagentFile, [Self.assistant(id: "m-sub", offset: 6, input: 1, write: 0, read: 900_000, output: 1, sidechain: true)])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(60))
        let history = try f.history()
        #expect(history.tokens.reduce(0) { $0 + $1.requests } == 3)
        #expect(Set(history.skills.map { "\($0.name)/\($0.source.rawValue)/\($0.count)" }) == ["writing-code/model/1", "ukwhatn-writing/command/1"])
        #expect(history.compactions == [.init(at: Self.now.addingTimeInterval(5).rounded, engine: .claude, session: "s-1", trigger: .auto, before: 317_478, after: 24_485)])
        let session = try #require(history.sessions.first)
        #expect(session.title == "線 36")
        #expect(session.cwd == "/Users/me/dev/app")
        #expect(session.requests == 3)
        #expect(session.maxContext == 200_003)
        #expect(session.compactions == 1)
        #expect(history.sessionCount == 1)
    }

    @Test("動いている間に現れた transcript は頭から読むが、見つけた時刻より前に書かれた行（フォークで写した分）は数えない")
    func newFileSkipsCopiedHistory() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.append(f.claudeFile, [])
        try await f.recorder.scan(now: Self.now)
        let fork = f.claude.appending(path: "-Users-me-dev-app/s-2.jsonl")
        try f.append(fork, [Self.assistant(id: "m-copied", session: "s-2", offset: -86_000), Self.assistant(id: "m-fresh", session: "s-2", offset: 30)])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(60))
        #expect(try f.history().tokens.reduce(0) { $0 + $1.requests } == 1)
    }

    @Test("書きかけの最後の行は、改行が来るまで読まない")
    func waitsForNewline() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.append(f.claudeFile, [])
        try await f.recorder.scan(now: Self.now)
        let line = Self.assistant(id: "m-1", offset: 1)
        let half = line.index(line.startIndex, offsetBy: line.count / 2)
        try f.append(f.claudeFile, [String(line[..<half])], newline: false)
        try await f.recorder.scan(now: Self.now.addingTimeInterval(60))
        #expect(try f.history().tokens.isEmpty)
        try f.append(f.claudeFile, [String(line[half...])])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(120))
        #expect(try f.history().tokens.map(\.requests) == [1])
    }

    @Test("Codex: 同じ累計の token_count は 1 回、入力からキャッシュを分け、model と作業フォルダは turn_context から、圧縮の直前は前の応答の入力")
    func codexLines() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try await f.recorder.scan(now: Self.now)
        try f.append(
            f.codexFile,
            [
                Self.codex("turn_context", #"{"turn_id":"t","cwd":"/Users/me/dev/tool","model":"gpt-6-astra"}"#, offset: 1),
                Self.codex("event_msg", Self.tokenCount(input: 34_073, cached: 11_264, output: 521, total: 34_594), offset: 2),
                Self.codex("event_msg", Self.tokenCount(input: 34_073, cached: 11_264, output: 521, total: 34_594), offset: 3),
                Self.codex("event_msg", #"{"type":"token_count","info":null,"rate_limits":null}"#, offset: 4),
                Self.codex(
                    "response_item",
                    #"{"type":"custom_tool_call","name":"exec","input":"sed -n '1,320p' ~/.claude/skills/taskboard/SKILL.md; cat ~/.codex/skills/.system/imagegen/SKILL.md ~/.claude/skills/taskboard/SKILL.md"}"#,
                    offset: 5),
                Self.codex("compacted", #"{"message":"","replacement_history":[]}"#, offset: 6),
            ])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(60))
        let history = try f.history()
        #expect(history.tokens == [.init(at: Self.hour, engine: .codex, model: "gpt-6-astra", requests: 1, tokens: TokenCounts(input: 22_809, cacheWrite: 0, cacheRead: 11_264, output: 521))])
        #expect(Set(history.skills.map(\.name)) == ["taskboard", "imagegen"])
        #expect(history.compactions.map(\.before) == [34_073])
        #expect(history.compactions.map(\.trigger) == [nil])
        let session = try #require(history.sessions.first)
        #expect(session.session == "01a1712b-3d47-7c31-8284-30128b844899")
        #expect(session.cwd == "/Users/me/dev/tool")
    }

    @Test("5 分ごとに、その間に応答したセッションの数と今の利用枠を残す。窓の終わりを過ぎた利用枠は残さない")
    func samples() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.append(f.claudeFile, [])
        try await f.recorder.scan(now: Self.now)
        await f.state.record(
            ClaudeUsageReport(
                context: SessionContext(agentSessionID: "s-1", model: nil, effort: nil, usedPercent: nil, inputTokens: nil, windowSize: nil, at: Self.now),
                fiveHour: UsageWindow(usedPercent: 42, resetsAt: Self.now.addingTimeInterval(3600), windowSeconds: 18_000),
                sevenDay: UsageWindow(usedPercent: 57, resetsAt: Self.now.addingTimeInterval(-1), windowSeconds: 604_800)),
            now: Self.now)
        let other = f.claude.appending(path: "-Users-me-dev-app/s-3.jsonl")
        try f.append(f.claudeFile, [Self.assistant(id: "a", offset: 10)])
        try f.append(other, [Self.assistant(id: "b", session: "s-3", offset: 20)])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(60))
        let sample = try #require(try f.history(-60, 300).samples.first)
        #expect(sample.claudeActive == 2)
        #expect(sample.claudeFiveHour == 42)
        #expect(sample.claudeSevenDay == nil)
        #expect(try f.history().recordingSince == Self.now)
    }

    @Test("アカウントごとの利用枠は、観測した時刻ごとに 1 件だけ残す。観測が変わらない見回りは増やさず、窓の終わりを過ぎた値は残さない")
    func accountSamples() async throws {
        let f = try Fixture()
        defer { f.remove() }
        await f.state.setClaudeAccounts([ClaudeAccount(name: "sub")], defaultAccount: "sub")
        let reset = Self.now.addingTimeInterval(5 * 86_400)
        func report(_ percent: Double, at offset: TimeInterval) async {
            let at = Self.now.addingTimeInterval(offset)
            await f.state.record(
                ClaudeUsageReport(
                    context: SessionContext(agentSessionID: "s-1", model: nil, effort: nil, usedPercent: nil, inputTokens: nil, windowSize: nil, account: "sub", at: at),
                    fiveHour: nil, sevenDay: UsageWindow(usedPercent: percent, resetsAt: reset, windowSeconds: 604_800)),
                now: at)
        }
        await report(41, at: 0)
        try await f.recorder.scan(now: Self.now.addingTimeInterval(10))
        try await f.recorder.scan(now: Self.now.addingTimeInterval(310))
        await report(44, at: 600)
        try await f.recorder.scan(now: Self.now.addingTimeInterval(610))
        let samples = try f.store.usageAccountSamples(since: Self.now.addingTimeInterval(-60))
        #expect(samples.map(\.account) == ["sub", "sub"])
        #expect(samples.map(\.sevenDay) == [41, 44])
        #expect(samples.map(\.at) == [Self.now, Self.now.addingTimeInterval(600)])
        #expect(samples.first?.sevenDayResetsAt == reset)
    }

    @Test("90 日より古い記録と、無くなった transcript の読んだ位置を消す")
    func prunes() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.append(f.claudeFile, [])
        try await f.recorder.scan(now: Self.now)
        try f.append(f.claudeFile, [Self.assistant(id: "a", offset: 10)])
        try await f.recorder.scan(now: Self.now.addingTimeInterval(60))
        try FileManager.default.removeItem(at: f.claudeFile)
        try await f.recorder.scan(now: Self.now.addingTimeInterval(UsageHistory.retention + 7 * 3600))
        #expect(try f.store.usageCursors().isEmpty)
        let all = try f.store.usageHistory(
            UsageHistoryQuery(from: Self.now.addingTimeInterval(-86_400), to: Self.now.addingTimeInterval(UsageHistory.retention + 86_400), bucketSeconds: 604_800))
        #expect(all.tokens.isEmpty)
        #expect(all.sessions.isEmpty)
    }

    static var hour: Date { Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600) }
}

extension Date {
    /// DB は秒の整数で持つので、比べる値も秒に揃える
    fileprivate var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
