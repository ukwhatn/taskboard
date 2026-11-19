import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func user(_ uuid: String, _ content: Any, extra: [String: Any] = [:]) -> String {
    line(["type": "user", "uuid": uuid, "timestamp": "2026-10-04T01:00:00.000Z", "message": ["role": "user", "content": content]].merging(extra) { $1 })
}

private func assistant(_ uuid: String, _ blocks: [[String: Any]]) -> String {
    line(["type": "assistant", "uuid": uuid, "timestamp": "2026-10-04T01:00:01.000Z", "message": ["role": "assistant", "content": blocks]])
}

private func messages(_ lines: [String]) -> [ChatMessage] {
    var cursor = TranscriptCursor()
    return cursor.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
}

@Suite("transcript をチャットにする")
struct TranscriptParserTests {
    @Test("人の文・返答・ツール呼び出しと結果を順に並べ、Claude Code が差し込む文（isMeta）は差し込んだ文の印を付けるか、印にするか捨てる")
    func conversation() {
        let result = messages([
            line(["type": "attachment", "uuid": "a0"]),
            user("u1", "ビルドして<system-reminder>内部の注意</system-reminder>"),
            assistant("a1", [
                ["type": "thinking", "thinking": "", "signature": "x"], ["type": "text", "text": "ビルドします"],
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift build", "description": "Build"]],
            ]),
            user("u2", [["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": "Build complete!"]], "is_error": false]]),
            user("u3", "<command-name>/commit</command-name>\n<command-args>--push</command-args>"),
            user("u4", "<local-command-caveat>Caveat</local-command-caveat>"),
            user("u5", "Base directory for this skill: /tmp/skills/commit", extra: ["isMeta": true, "sourceToolUseID": "t1"]),
            user("u6", "サブエージェント", extra: ["isSidechain": true]),
            line(["type": "system", "subtype": "compact_boundary", "uuid": "b7", "content": "Conversation compacted"]),
            user("u7", "要約", extra: ["isCompactSummary": true]),
            user("u8", [["type": "text", "text": "[Request interrupted by user]"]]),
            user("u9", "<task-notification>\n<summary>テストが終わった</summary>\n</task-notification>"),
            line(["type": "brand-new-kind", "uuid": "x"]),
        ])
        #expect(result.map { "\($0.role.rawValue):\($0.kind.rawValue):\($0.text)" } == [
            "user:text:ビルドして", "assistant:text:ビルドします", "assistant:toolUse:swift build", "user:toolResult:Build complete!",
            "user:text:/commit --push", "user:text:Base directory for this skill: /tmp/skills/commit", "user:notice:会話を圧縮しました",
            "user:notice:中断しました", "user:notice:テストが終わった",
        ])
        #expect(result.map(\.isInjected) == [false, false, false, false, false, true, false, false, false])
        #expect(result[2].toolName == "Bash" && result[2].toolID == "t1" && result[3].toolID == "t1")
        #expect(result[0].id == "u1" && result[1].id == "a1#1", "id は行の uuid + 行内の位置")
        #expect(result[0].at == Date(timeIntervalSince1970: 1_791_075_600))
    }

    @Test("要約の区切りの行を区切りの印にし、圧縮の前後のトークン数（transcript の compactMetadata、stream-json の compact_metadata）と自動かを文に入れる。数が揃わなければ数を出さない。要約の本文の行と、サブエージェントの区切りは出さない")
    func compactBoundary() {
        func boundary(_ uuid: String, _ extra: [String: Any]) -> String {
            line(["type": "system", "subtype": "compact_boundary", "uuid": uuid, "timestamp": "2026-10-04T01:00:02.000Z"].merging(extra) { $1 })
        }
        let result = messages([
            boundary("b1", ["compactMetadata": ["trigger": "manual", "preTokens": 51832, "postTokens": 15968, "durationMs": 4142]]),
            user("s1", "This session is being continued from a previous conversation.", extra: ["isCompactSummary": true, "isVisibleInTranscriptOnly": true]),
            boundary("b2", ["compact_metadata": ["trigger": "auto", "pre_tokens": 180000, "post_tokens": 20000]]),
            boundary("b3", ["compactMetadata": ["trigger": "auto", "preTokens": 180000]]),
            boundary("b4", ["isSidechain": true, "compactMetadata": ["trigger": "auto", "preTokens": 9000, "postTokens": 1000]]),
        ])
        #expect(result.map(\.text) == ["会話を圧縮しました（51,832→15,968トークン）", "会話を自動で圧縮しました（180,000→20,000トークン）", "会話を自動で圧縮しました"])
        #expect(result.map(\.id) == ["b1", "b2", "b3"], "id は区切りの行の uuid（生きている会話の区切りと同じ）")
        #expect(result.allSatisfy { $0.kind == .notice && $0.isCompactSummary })
    }

    @Test("API が誤りで終えた assistant の文は、transcript の isApiErrorMessage でも stream-json の is_api_error_message でも isError の文にする。付いていない行は誤りにしない")
    func apiErrorMessage() {
        let text = "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)"
        func assistantLine(_ extra: [String: Any]) -> String {
            line(
                ["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]].merging(extra) { $1 })
        }
        let transcript = messages([assistantLine(["isApiErrorMessage": true, "error": "unknown"])])
        #expect(transcript.map(\.text) == [text] && transcript.map(\.isError) == [true])

        let stream = ClaudeStreamParser.parse(Data(assistantLine(["is_api_error_message": true, "api_error_status": NSNull(), "api_error": "unknown"]).utf8))
        guard case .messages(let made, _, _) = stream else {
            Issue.record("発言にならない: \(stream)")
            return
        }
        #expect(made.map(\.isError) == [true])

        #expect(messages([assistantLine([:])]).map(\.isError) == [false])
        #expect(messages([assistantLine(["isApiErrorMessage": false])]).map(\.isError) == [false])
        // 誤りの印が付くのは assistant の文だけ。ツールの呼び出しには付けない
        let tool = messages([
            line([
                "type": "assistant", "uuid": "a2", "isApiErrorMessage": true,
                "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]],
            ])
        ])
        #expect(tool.map(\.isError) == [false])
    }

    @Test("ターンの途中に取り込まれた発言（attachment の queued_command）を、送った発言の uuid の人の文として読む。人でない差し込みは印を付け、裏の作業の知らせと別の種類の attachment は今までどおり")
    func absorbedMidTurn() {
        func queued(_ uuid: String, _ prompt: Any, mode: String = "prompt", origin: [String: Any]? = ["kind": "human"]) -> String {
            var attachment: [String: Any] = ["type": "queued_command", "prompt": prompt, "source_uuid": uuid, "commandMode": mode]
            if let origin { attachment["origin"] = origin }
            return line(["type": "attachment", "uuid": "line-\(uuid)", "timestamp": "2026-10-04T01:00:02.000Z", "attachment": attachment])
        }
        let result = messages([
            queued("s1", "途中で送った<system-reminder>内部</system-reminder>"),
            queued("s2", [["type": "text", "text": "画像つき"], ["type": "image", "source": ["type": "base64", "data": "AA=="]]], origin: nil),
            queued("s3", "<cross-session-message>知らせ</cross-session-message>", origin: ["kind": "peer"]),
            queued("s4", "<task-notification>\n<summary>終わった</summary>\n</task-notification>", mode: "task-notification", origin: ["kind": "task-notification"]),
            line(["type": "attachment", "uuid": "a9", "attachment": ["type": "edited_text_file", "filename": "/x"]]),
        ])
        #expect(result.map { "\($0.id):\($0.kind.rawValue):\($0.text)" } == [
            "s1:text:途中で送った", "s2#0:text:画像つき", "s3:text:<cross-session-message>知らせ</cross-session-message>",
        ])
        #expect(result.map(\.isInjected) == [false, false, true])
        #expect(result[1].images == [ChatImage(index: 0, bytes: 1, offset: UInt64(queued("s1", "途中で送った<system-reminder>内部</system-reminder>").utf8.count + 1))])
        #expect(result[1].lineID == "s2", "画像の口は送った発言の uuid で引く")
        #expect(result.allSatisfy { $0.role == .user } && result[0].at == Date(timeIntervalSince1970: 1_791_075_602))
    }

    @Test("人の発言の画像は、行の最初の文の発言に順番・種類・大きさ・行の位置を添える（base64 は載せない）。文の無い行は空の文の発言にする")
    func userImages() throws {
        let first = user("u0", "前の発言")
        let png = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]] as [String: Any]
        let jpeg = ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "/9j/4AAQ"]] as [String: Any]
        let withText = user("u1", [["type": "text", "text": "この画面を直して"], png, jpeg])
        // 2.1.304 は画像を添えた発言の直後に、画像の置き場を書いた差し込みの行を足す（縮小版と重なるので出さない）
        let companion = user("m1", [["type": "text", "text": "[Image: source: /private/tmp/claude-502/x/images/1.png]"]], extra: ["isMeta": true])
        let result = messages([first, withText, companion, user("u2", [png])])
        #expect(result.map { "\($0.id):\($0.kind.rawValue):\($0.text)" } == ["u0:text:前の発言", "u1#0:text:この画面を直して", "u2#0:text:"])
        let offset = UInt64(first.utf8.count + 1)
        #expect(result[1].images == [
            ChatImage(index: 0, mediaType: "image/png", bytes: 8, offset: offset), ChatImage(index: 1, mediaType: "image/jpeg", bytes: 6, offset: offset),
        ])
        #expect(result[2].images == [ChatImage(index: 0, mediaType: "image/png", bytes: 8, offset: offset + UInt64(withText.utf8.count + companion.utf8.count + 2))])
        #expect(result[0].images == nil && result.map(\.lineID) == ["u0", "u1", "u2"])
        let wire = String(decoding: try WireJSON.encoder().encode(result), as: UTF8.self)
        #expect(!wire.contains("iVBORw0KGgo") && !wire.contains("/9j/4AAQ"))
    }

    @Test("中身のある thinking は思考の印を付けた文として出す。署名だけで中身の空のものと空白だけのものは捨てる")
    func visibleThinking() {
        let result = messages([
            assistant("a1", [
                ["type": "thinking", "thinking": "", "signature": "x"],
                ["type": "thinking", "thinking": "原因はハーネス側でした。", "signature": "y"],
                ["type": "thinking", "thinking": " \n", "signature": "z"],
                ["type": "tool_use", "id": "t1", "name": "Edit", "input": ["file_path": "/tmp/a.md"]],
            ])
        ])
        #expect(result.map { "\($0.role.rawValue):\($0.kind.rawValue):\($0.text)" } == ["assistant:text:原因はハーネス側でした。", "assistant:toolUse:/tmp/a.md"])
        #expect(result.first?.id == "a1#1")
        #expect(result.map(\.isThinking) == [true, false])
    }

    @Test("thinking を含む 1 ターン（短い思考・長い思考・署名だけの思考・ツールの間の思考）を行にすると、思考は 1 行ずつで、呼び出しの間の思考は組に入る")
    func thinkingTurnRows() {
        let long = "原因は 2 つ考えられる。\n\n- 期限切れ\n- 保存の順番\n\n```swift\nstore.save(token)\n```"
        let result = messages([
            user("u1", "ログインを直して"),
            assistant("a1", [["type": "thinking", "thinking": "まずログを読む。", "signature": "s1"], ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "rg login logs/"]]]),
            user("u2", [["type": "tool_result", "tool_use_id": "t1", "content": "failed", "is_error": false]]),
            assistant("a2", [["type": "thinking", "thinking": long, "signature": "s2"], ["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "/tmp/a.swift"]]]),
            user("u3", [["type": "tool_result", "tool_use_id": "t2", "content": "ok", "is_error": false]]),
            assistant("a3", [["type": "thinking", "thinking": "", "signature": "s3"], ["type": "tool_use", "id": "t3", "name": "Edit", "input": ["file_path": "/tmp/a.swift"]]]),
            user("u4", [["type": "tool_result", "tool_use_id": "t3", "content": "done", "is_error": false]]),
            assistant("a4", [["type": "thinking", "thinking": "直したので確かめる。", "signature": "s4"], ["type": "text", "text": "直しました。"]]),
        ])
        let rows = ChatRows.rows(result, groupsTools: true).map { row -> String in
            switch row {
            case .message(let message): message.isThinking ? "思考:" + String(message.text.prefix(5)) : message.kind.rawValue
            case .tools(let members): "[" + members.map { $0.isThinking ? "思考" : $0.toolName ?? "?" }.joined(separator: " ") + "]"
            }
        }
        // 先頭の思考と返答の前の思考は 1 行、呼び出しの間の思考は組の中。署名だけの 3 つ目の思考は捨てる
        #expect(rows == ["text", "思考:まずログを", "[Bash 思考 Read Edit]", "思考:直したので", "text"])
        #expect(result.first { $0.id == "a2#0" }?.text == long)
    }

    @Test("tool result は 4 KB で切り、日本語の文字の途中で切らない。元のバイト数を残す")
    func clip() {
        let long = String(repeating: "あ", count: 2000)  // 6000 バイト
        let result = messages([user("u", [["type": "tool_result", "tool_use_id": "t", "content": long, "is_error": true]])])
        #expect(result.first?.text.utf8.count == 4095 && result.first?.text.allSatisfy { $0 == "あ" } == true)
        #expect(result.first?.fullBytes == 6000 && result.first?.isError == true)
        #expect(TranscriptParser.clip("ok").1 == nil)
    }

    @Test("1 MB を超える行は溜めずに読み飛ばして印を出す。行が読み取りの境目で切れても 1 行として読む")
    func largeAndSplitLines() {
        var cursor = TranscriptCursor()
        // 実物の鍵の並び（type → message → uuid）で組む。辞書から組むと鍵が辞書順になり、"type":"user" と tool_use_id が 1.3MB の後ろに行く
        // （読み飛ばす行は先頭 16KB と末尾 4KB しか見ない）
        let big = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"\#(String(repeating: "x", count: 1_300_000))"}]},"uuid":"big","timestamp":"2026-10-04T01:00:00.000Z"}"#
        let small = user("s", "あいう")
        let data = Data((big + "\n" + small + "\n").utf8)
        var out: [ChatMessage] = []
        var offset = 0
        // 300,007 バイトずつ流し、big の途中や行の境目で切れても崩れない
        while offset < data.count {
            let end = min(offset + 300_007, data.count)
            out += cursor.feed(data[offset..<end])
            offset = end
        }
        // tool_result の行は呼び出しに結ぶ（印の文は結果の欄に出る）
        #expect(out.map(\.kind) == [.toolResult, .text])
        #expect(out.first?.toolID == "t" && out.first?.files == nil)
        #expect(out.first?.text == "大きい出力（1.2MB）を省きました", "\(out.first?.text ?? "")")
        #expect(out.last?.text == "あいう")
        #expect(cursor.incompatible == 0)
    }

    @Test("user / assistant なのに message を読めない行だけを互換性の崩れとして数える")
    func incompatible() {
        var cursor = TranscriptCursor()
        _ = cursor.feed(Data((line(["type": "assistant", "uuid": "a", "message": ["content": "文字列"]]) + "\n" + line(["type": "user", "uuid": "b"]) + "\n" + line(["type": "unknown"]) + "\n{壊れた行\n").utf8))
        #expect(cursor.incompatible == 2)
    }
}

/// tail が送った frame を貯める
private actor Frames {
    var items: [ChatFrame] = []
    func add(_ frame: ChatFrame) { items.append(frame) }
}

private actor SessionBox {
    var id: String?
    init(_ id: String?) { self.id = id }
    func set(_ id: String?) { self.id = id }
}

@Suite("transcript の tail")
struct TranscriptTailTests {
    private func until(_ frames: Frames, timeout: Double = 5, _ condition: @escaping ([ChatFrame]) -> Bool) async -> [ChatFrame] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let items = await frames.items
            if condition(items) { return items }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await frames.items
    }

    @Test("直近の会話を backlog で送り、増えた分を append、session id が変われば別のファイルを backlog で送り直す。projects の外は開かない")
    func followsSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects")
        let dir = projects.appendingPathComponent("-Users-me-dev")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = "11111111-aaaa-bbbb-cccc-000000000001"
        let second = "11111111-aaaa-bbbb-cccc-000000000002"
        try (user("u1", "一つ目") + "\n").write(to: dir.appendingPathComponent("\(first).jsonl"), atomically: true, encoding: .utf8)
        try (user("v1", "別のセッション") + "\n").write(to: dir.appendingPathComponent("\(second).jsonl"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("outside.jsonl"), atomically: true, encoding: .utf8)

        let box = SessionBox(first)
        let tail = TranscriptTail(projects: projects, interval: .milliseconds(30)) { await box.id }
        #expect(tail.locate("../outside") == nil && tail.locate("missing-0000") == nil)
        let frames = Frames()
        let task = Task { try await tail.run { await frames.add($0) } }
        defer { task.cancel() }

        var items = await until(frames) { $0.count >= 1 }
        #expect(items.first == .backlog(sessionID: first, messages: messages([user("u1", "一つ目")])))

        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("\(first).jsonl"))
        try handle.seekToEnd()
        let half = Data((assistant("a1", [["type": "text", "text": "返事"]]) + "\n").utf8)
        try handle.write(contentsOf: half.prefix(10))
        try await Task.sleep(for: .milliseconds(120))
        try handle.write(contentsOf: half.dropFirst(10))
        try handle.close()
        items = await until(frames) { $0.count >= 2 }
        #expect(items.dropFirst().first.map { if case .append(let m) = $0 { m.map(\.text) } else { [] } } == ["返事"], "\(items)")

        await box.set(second)
        items = await until(frames) { $0.count >= 3 }
        if case .backlog(let id, let m) = items.last { #expect(id == second && m.map(\.text) == ["別のセッション"]) } else { Issue.record("\(items)") }

        await box.set(nil)
        items = await until(frames) { $0.count >= 4 }
        #expect(items.last == .unavailable(ChatFrame.UnavailableReason.notClaude.rawValue))
    }
}

@Suite("解いた transcript の持ち置き")
struct TranscriptCacheTests {
    @Test("2 回目からは増えた分だけを解き、縮んだファイルは初めから読み直す")
    func reusesAndRereads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (user("u1", "一つ目") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let cache = TranscriptCache()
        let first = try #require(await cache.snapshot(of: url))
        #expect(first.messages.map(\.text) == ["一つ目"])

        // 読んだ所を同じ長さの別の文に書き換えても、持っている分は解き直さない
        let rewritten = user("u1", "二つ目") + "\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.write(contentsOf: Data((assistant("a1", [["type": "text", "text": "返事"]]) + "\n").utf8))
        try handle.close()
        let second = try #require(await cache.snapshot(of: url))
        #expect(second.messages.map(\.text) == ["一つ目", "返事"])
        #expect(second.offset == (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64))

        try (user("v1", "書き直し") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(await cache.snapshot(of: url)?.messages.map(\.text) == ["書き直し"])
    }

    @Test("開けないファイルは nil")
    func missing() async {
        #expect(await TranscriptCache().snapshot(of: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl")) == nil)
    }
}

@Suite("transcript の題")
struct TranscriptSummaryTests {
    private func write(_ lines: [String]) throws -> (projects: URL, id: String) {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)")
        let dir = projects.appendingPathComponent("-Users-me-repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        return (projects.standardizedFileURL.resolvingSymlinksInPath(), id)
    }

    @Test("最後の題・最後の指示と、最後の発言のブランチと時刻を読む。添付の行の type と、発言の中の文字に惑わされない")
    func readsLatest() async throws {
        let (projects, id) = try write([
            #"{"type":"ai-title","aiTitle":"古い題","sessionId":"x"}"#,
            #"{"type":"last-prompt","lastPrompt":"古い指示","sessionId":"x"}"#,
            #"{"parentUuid":null,"cwd":"/r","gitBranch":"main","type":"user","timestamp":"2026-10-04T01:00:00.000Z","message":{"role":"user","content":"a"}}"#,
            #"{"type":"ai-title","aiTitle":"新しい題","sessionId":"x"}"#,
            #"{"parentUuid":"1","cwd":"/r","gitBranch":"feature/x","message":{"type":"message","content":"{\"type\":\"ai-title\",\"aiTitle\":\"偽\"}"},"type":"assistant","timestamp":"2026-10-04T02:30:00.500Z"}"#,
            #"{"parentUuid":"2","attachment":{"type":"date","date":"2026-10-04"},"type":"attachment"}"#,
            #"{"type":"last-prompt","lastPrompt":"新しい指示\n2 行目","sessionId":"x"}"#,
        ])
        let history = await TranscriptSummaryReader(projects: projects).history(sessionID: id)
        #expect(history.aiTitle == "新しい題")
        #expect(history.customTitle == nil)
        #expect(history.lastPrompt == "新しい指示\n2 行目")
        #expect(history.branch == "feature/x")
        #expect(history.updatedAt == Date(timeIntervalSince1970: 1_791_081_000.5))
        #expect(history.title(taskTitle: "タスク") == "新しい題")
    }

    @Test("付けた題がタスクの題を含むなら会話から付いた題を出し、どちらも無ければ最後の指示の 1 行目")
    func titlePreference() {
        #expect(SessionHistory(sessionID: "a", customTitle: "#12 ボードを直す", aiTitle: "列の修正").title(taskTitle: "ボードを直す") == "列の修正")
        #expect(SessionHistory(sessionID: "a", customTitle: "調査", aiTitle: "列の修正").title(taskTitle: "ボードを直す") == "調査")
        #expect(SessionHistory(sessionID: "a", lastPrompt: "1 行目\n2 行目").title(taskTitle: "") == "1 行目")
        #expect(SessionHistory(sessionID: "a").title(taskTitle: "") == nil)
    }

    @Test("末尾に題が無ければ広げて読み直す。transcript が無い ID と、UUID の形でない ID は空で返す")
    func widensAndRejects() async throws {
        let filler = String(repeating: "x", count: 1000)
        let lines = [#"{"type":"ai-title","aiTitle":"最初の題","sessionId":"x"}"#]
            + (0..<400).map { #"{"type":"attachment","attachment":{"type":"note","text":"\#(filler)\#($0)"}}"# }
        let (projects, id) = try write(lines)
        let reader = TranscriptSummaryReader(projects: projects)
        #expect(await reader.history(sessionID: id).aiTitle == "最初の題")
        #expect(await reader.history(sessionID: "00000000-0000-0000-0000-000000000000") == SessionHistory(sessionID: "00000000-0000-0000-0000-000000000000"))
        #expect(await reader.history(sessionID: "../x") == SessionHistory(sessionID: "../x"))
    }
}
