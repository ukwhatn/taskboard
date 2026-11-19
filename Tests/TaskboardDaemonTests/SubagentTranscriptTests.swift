import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// 実物（Claude Code 2.1.303）の行の形。サブエージェントの transcript の行はみな isSidechain と agentId を持つ
private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func user(_ uuid: String, _ content: Any, sidechain: Bool = false) -> String {
    var object: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": "2026-10-19T07:01:11.206Z", "message": ["role": "user", "content": content]]
    if sidechain { object.merge(["isSidechain": true, "agentId": "a1"]) { $1 } }
    return line(object)
}

private func assistant(_ uuid: String, _ blocks: [[String: Any]], sidechain: Bool = false) -> String {
    var object: [String: Any] = ["type": "assistant", "uuid": uuid, "timestamp": "2026-10-19T07:01:12.000Z", "message": ["role": "assistant", "content": blocks]]
    if sidechain { object.merge(["isSidechain": true, "agentId": "a1"]) { $1 } }
    return line(object)
}

private func agentCall(_ id: String) -> [String: Any] {
    ["type": "tool_use", "id": id, "name": "Agent", "input": ["description": "a.txt を読む", "prompt": "a.txt を読んで", "subagent_type": "general-purpose"]]
}

private func lines(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

/// 一時の projects の下に、親の transcript とサブエージェントの置き場を作る
private struct Session {
    let projects: URL
    let id = "3fbeedaf-6436-414e-a913-ec3c64516da3"
    var transcript: URL { projects.appending(path: "-w/\(id).jsonl") }
    var subagents: URL { projects.appending(path: "-w/\(id)/subagents") }

    init(parent: [String]) throws {
        projects = FileManager.default.temporaryDirectory.appending(path: "tb-subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projects.appending(path: "-w/\(id)/subagents"), withIntermediateDirectories: true)
        try lines(parent).write(to: transcript)
    }

    func agent(_ agentID: String, toolUseID: String, _ body: [String], parentAgentID: String? = nil) throws {
        var meta: [String: Any] = ["agentType": "general-purpose", "description": "a.txt を読む", "toolUseId": toolUseID, "spawnDepth": parentAgentID == nil ? 1 : 2]
        if let parentAgentID { meta["parentAgentId"] = parentAgentID }
        try lines(body).write(to: subagents.appending(path: "agent-\(agentID).jsonl"))
        try JSONSerialization.data(withJSONObject: meta).write(to: subagents.appending(path: "agent-\(agentID).meta.json"))
    }

    func append(_ agentID: String, _ more: [String]) throws {
        let handle = try FileHandle(forWritingTo: subagents.appending(path: "agent-\(agentID).jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: lines(more))
        try handle.close()
    }

    func remove() { try? FileManager.default.removeItem(at: projects) }
}

private func describe(_ messages: [ChatMessage]) -> [String] {
    messages.map { "\($0.parentToolID ?? "-"):\($0.role.rawValue):\($0.kind.rawValue):\($0.text)" }
}

@Suite("サブエージェントの transcript を Agent の呼び出しに結ぶ")
struct SubagentTranscriptTests {
    private static let parent = [
        user("p1", "サブエージェントに読ませて"),
        assistant("p2", [agentCall("toolu_agent")]),
        user("p3", [["type": "tool_result", "tool_use_id": "toolu_agent", "content": "Async agent launched successfully."]]),
    ]

    private static let child = [
        user("c1", "a.txt を読んで", sidechain: true),
        line(["type": "attachment", "uuid": "c1x", "isSidechain": true, "attachment": ["type": "date"]]),
        assistant("c2", [["type": "tool_use", "id": "toolu_read", "name": "Read", "input": ["file_path": "/w/a.txt"]], agentCall("toolu_nested")], sidechain: true),
        user("c3", [["type": "tool_result", "tool_use_id": "toolu_read", "content": "1\thello"]], sidechain: true),
    ]

    @Test("meta の toolUseId で呼び出しに結び、行の uuid を id に、呼び出しの id を parentToolID にする。入れ子の呼び出しも続けて結び、ファイルの札は外す")
    func linksByToolUseID() throws {
        let session = try Session(parent: Self.parent)
        defer { session.remove() }
        try session.agent("a1", toolUseID: "toolu_agent", Self.child)
        try session.agent("a2", toolUseID: "toolu_nested", [assistant("n1", [["type": "text", "text": "入れ子の返事"]], sidechain: true)], parentAgentID: "a1")
        try session.agent("a3", toolUseID: "toolu_other", [assistant("o1", [["type": "text", "text": "別の呼び出し"]], sidechain: true)])

        var cursor = TranscriptCursor()
        let main = cursor.feed(lines(Self.parent))
        #expect(main.allSatisfy { !$0.isSubagent })
        var transcripts = SubagentTranscripts(transcript: session.transcript)
        let children = transcripts.read(after: main)
        #expect(describe(children) == [
            "toolu_agent:user:text:a.txt を読んで", "toolu_agent:assistant:toolUse:/w/a.txt", "toolu_agent:assistant:toolUse:a.txt を読む",
            "toolu_agent:user:toolResult:1\thello", "toolu_nested:assistant:text:入れ子の返事",
        ])
        #expect(children.map(\.id) == ["c1", "c2#0", "c2#1", "c3#0", "n1#0"])
        #expect(children.allSatisfy { $0.files == nil })
        #expect(transcripts.read(after: []).isEmpty, "読んだ分は 2 回返さない")
    }

    @Test("読み始めたサブエージェントは伸びた分を返し、後から置き場に出来たサブエージェントは出来たときに初めから読む")
    func followsGrowthAndLateFiles() throws {
        let session = try Session(parent: Self.parent)
        defer { session.remove() }
        var transcripts = SubagentTranscripts(transcript: session.transcript)
        var cursor = TranscriptCursor()
        #expect(transcripts.read(after: cursor.feed(lines(Self.parent))).isEmpty, "まだ置き場に無い")

        try session.agent("a1", toolUseID: "toolu_agent", [user("c1", "a.txt を読んで", sidechain: true)])
        #expect(describe(transcripts.read(after: [])) == ["toolu_agent:user:text:a.txt を読んで"])
        try session.append("a1", [assistant("c4", [["type": "text", "text": "hello でした"]], sidechain: true)])
        #expect(describe(transcripts.read(after: [])) == ["toolu_agent:assistant:text:hello でした"])
    }

    @Test("サブエージェントの transcript の、行の uuid を持たない印は、呼び出しの id を前に付けて親の印と重ねない")
    func positionalIDs() {
        let message = ChatMessage(id: "large-3", role: .user, kind: .notice, text: "大きい出力（1.2MB）を省きました")
        #expect(message.inSubagent("toolu_agent").id == "toolu_agent/large-3")
        #expect(ChatMessage(id: "c1", role: .user, kind: .text, text: "x").inSubagent("toolu_agent").id == "c1")
    }

    @Test("チャットの tail は求めたときだけ、backlog と append にサブエージェントの発言を足す")
    func tailIncludesWhenAsked() async throws {
        let session = try Session(parent: Self.parent)
        defer { session.remove() }
        try session.agent("a1", toolUseID: "toolu_agent", [user("c1", "a.txt を読んで", sidechain: true)])

        for includes in [false, true] {
            let tail = TranscriptTail(projects: session.projects, interval: .milliseconds(30), includesSubagents: includes) { session.id }
            let received = Received()
            let task = Task { try await tail.run { await received.add($0) } }
            #expect(await received.wait { $0.count >= 1 })
            if case .backlog(_, let messages) = await received.items.first {
                #expect(messages.contains { $0.isSubagent } == includes)
            } else {
                Issue.record("backlog が無い")
            }
            if includes {
                try session.append("a1", [assistant("c4", [["type": "text", "text": "hello でした"]], sidechain: true)])
                #expect(await received.wait { $0.count >= 2 })
                if case .append(let more) = await received.items.last { #expect(describe(more) == ["toolu_agent:assistant:text:hello でした"]) }
            }
            task.cancel()
        }
    }

    @Test("会話の履歴は求めたときだけ、ページの中の呼び出しのサブエージェントの発言を後ろに足す。cursor は親の transcript の位置のまま")
    func historyIncludesWhenAsked() throws {
        let session = try Session(parent: Self.parent)
        defer { session.remove() }
        try session.agent("a1", toolUseID: "toolu_agent", Self.child)
        let record = ConversationRecord(taskNumber: nil, agentSessionId: session.id, cwd: "/w", runner: .host)

        let plain = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record, projects: session.projects), before: nil, limit: 2)
        let asked = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record, projects: session.projects), before: nil, limit: 2, subagents: true)
        #expect(!plain.messages.contains { $0.isSubagent })
        #expect(asked.messages.prefix(plain.messages.count).map(\.id) == plain.messages.map(\.id))
        #expect(asked.messages.filter(\.isSubagent).count == 4 && asked.nextCursor == plain.nextCursor)
    }
}

private actor Received {
    var items: [ChatFrame] = []
    func add(_ frame: ChatFrame) { items.append(frame) }

    func wait(_ condition: @Sendable ([ChatFrame]) -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition(items) { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
}
