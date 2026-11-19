import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("フォークの地点：transcript の行を uuid で引く")
struct ConversationForkTests {
    private let source = "6f1d2b8e-0000-4000-8000-0000000000a1"
    private let pending = "6f1d2b8e-0000-4000-8000-0000000000b2"

    private func line(_ uuid: String, _ parent: String?, _ type: String, _ content: Any, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = [
            "type": type, "uuid": uuid, "parentUuid": parent ?? NSNull(), "isSidechain": false, "timestamp": "2026-10-19T00:00:00.000Z",
            "message": ["role": type, "content": content],
        ]
        object.merge(extra) { $1 }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func projects(_ files: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "tb-fork-\(UUID().uuidString)")
        let dir = root.appending(path: "-w")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (session, lines) in files {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appending(path: "\(session).jsonl"))
        }
        return root
    }

    private var lines: [String] {
        [
            line("u1", nil, "user", "はじめの発言"),
            line("a1", "u1", "assistant", [["type": "text", "text": "answer"]]),
            line("s1", "a1", "assistant", [["type": "text", "text": "sub"]], extra: ["isSidechain": true]),
            line("t1", "a1", "user", [["type": "tool_result", "tool_use_id": "x", "content": "ok"]]),
            line("m1", "t1", "user", "<command-name>/model</command-name>", extra: ["isMeta": true]),
            line("u2", "m1", "user", [["type": "text", "text": "second"], ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": ""]]]),
            line("a2", "u2", "assistant", [["type": "text", "text": "最後"]]),
        ]
    }

    @Test("行を uuid で引き、親と人の発言の本文を返す。ツールの結果・meta は本文が無い。サブエージェントの行は引かない。末尾はサブエージェントを除いた最後の行")
    func lines_() throws {
        let root = try projects([source: lines])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "-w/\(source).jsonl")
        let first = try #require(TranscriptLines.find("u1", in: url))
        #expect(first.parentUUID == nil && first.prompt == "はじめの発言" && first.type == "user")
        #expect(first.end == UInt64(lines[0].utf8.count + 1))
        #expect(TranscriptLines.find("u2", in: url)?.prompt == "second" && TranscriptLines.find("u2", in: url)?.parentUUID == "m1")
        #expect(TranscriptLines.find("t1", in: url)?.prompt == nil && TranscriptLines.find("m1", in: url)?.prompt == nil)
        #expect(TranscriptLines.find("a1", in: url)?.prompt == nil)
        #expect(TranscriptLines.find("s1", in: url) == nil && TranscriptLines.find("nope", in: url) == nil)
        #expect(TranscriptLines.last(in: url)?.uuid == "a2")
        #expect(TranscriptLines.find("a2", in: url)?.end == UInt64(lines.joined(separator: "\n").utf8.count + 1))
    }

    @Test("地点：#n を落とす。省けば末尾、生成中なら 409。履歴が無ければ 409、無い発言は 404")
    func point() throws {
        let root = try projects([source: lines])
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ConversationRecord(taskNumber: nil, agentSessionId: source, cwd: "/w", runner: .host)
        #expect(try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: "a1#0", generating: true) == ConversationFork(session: source, uuid: "a1"))
        #expect(try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: nil, generating: false) == ConversationFork(session: source, uuid: "a2"))
        #expect(throws: ConversationError.busy(record.id, "生成中（末尾からはフォークできない）")) {
            try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: nil, generating: true)
        }
        #expect(throws: ConversationError.messageNotFound("s1")) { try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: "s1", generating: false) }
        let empty = ConversationRecord(taskNumber: nil, agentSessionId: pending, cwd: "/w", runner: .host)
        #expect(throws: ConversationError.notSent(empty.id)) { try ConversationFork.point(in: TranscriptLineage(unrecorded: empty, projects: root), messageID: nil, generating: false) }
    }

    @Test("まだ送っていないフォークからのフォーク：写す元の transcript の、写す地点までで探す。後ろの行は 404。履歴も地点までを返す")
    func pendingSource() throws {
        let root = try projects([source: lines])
        defer { try? FileManager.default.removeItem(at: root) }
        var record = ConversationRecord(taskNumber: nil, agentSessionId: pending, cwd: "/w", runner: .host)
        record.pendingForkSessionId = source
        record.pendingForkAt = "a1"
        #expect(try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: nil, generating: true) == ConversationFork(session: source, uuid: "a1"))
        #expect(try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: "u1", generating: false) == ConversationFork(session: source, uuid: "u1"))
        #expect(throws: ConversationError.messageNotFound("u2")) { try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: "u2", generating: false) }

        let page = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record, projects: root), before: nil, limit: 1)
        #expect(page.messages.map(\.text) == ["answer"] && page.agentSessionID == pending)
        let cursor = try #require(page.nextCursor)
        #expect(cursor.hasPrefix("\(source)."), "cursor は写す元の会話 ID で作る")
        let rest = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record, projects: root), before: cursor, limit: 10)
        #expect(rest.messages.map(\.text) == ["はじめの発言"] && rest.nextCursor == nil)

        record.pendingForkAt = "gone"
        #expect(try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record, projects: root), before: nil, limit: 10).messages.isEmpty, "地点が読めなければ空")
    }

    @Test("巻き戻しの地点（戻す発言の親）は、たいてい system か attachment の行。送る前の履歴とフォークの地点は、その行までを読む")
    func pendingAtSystemLine() throws {
        // 巻き戻すと地点は人の発言の親の行になる。Stop hook の後の turn_duration・要約の直後の informational・hook の attachment が親だった（Studio の実物）
        let points = [
            #"{"type":"system","subtype":"turn_duration","uuid":"d1","parentUuid":"a1","isSidechain":false,"isMeta":true,"durationMs":10}"#,
            #"{"type":"attachment","uuid":"h1","parentUuid":"d1","isSidechain":false,"attachment":{"type":"hook_success"}}"#,
        ]
        let transcript = Array(lines[0...1]) + points + [line("u2", "h1", "user", "後の発言")]
        let root = try projects([source: transcript])
        defer { try? FileManager.default.removeItem(at: root) }
        for at in ["d1", "h1"] {
            var record = ConversationRecord(taskNumber: nil, agentSessionId: pending, cwd: "/w", runner: .host)
            record.pendingForkSessionId = source
            record.pendingForkAt = at
            let page = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record, projects: root), before: nil, limit: 10)
            #expect(page.messages.map(\.text) == ["はじめの発言", "answer"], "地点 \(at) より後の発言は出さない")
            #expect(try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: "u1", generating: false) == ConversationFork(session: source, uuid: "u1"))
            #expect(throws: ConversationError.messageNotFound("u2")) { try ConversationFork.point(in: TranscriptLineage(unrecorded: record, projects: root), messageID: "u2", generating: false) }
        }
    }
}
