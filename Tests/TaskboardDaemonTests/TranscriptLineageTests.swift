import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

extension TranscriptLineage {
    /// 写し元を記録していない会話（記録が無くても読める形だけを確かめる）
    init(unrecorded record: ConversationRecord, projects: URL) {
        self.init(record: record, projects: projects, recorded: { _ in nil })
    }
}

/// 要約の後へ巻き戻した会話の transcript（Studio #74 の 8c26dbcc と 2f1e1f84 と同じ行の形）
struct CompactedTranscripts {
    static let source = "8c26dbcc-0000-4000-8000-000000000001"
    static let fork = "2f1e1f84-0000-4000-8000-000000000002"
    static let again = "3a2b1c0d-0000-4000-8000-000000000003"

    static func object(_ fields: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: fields.merging(["isSidechain": false]) { old, _ in old }), as: UTF8.self)
    }

    static func user(_ uuid: String, _ parent: String?, _ text: String, extra: [String: Any] = [:]) -> String {
        object(
            ["type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": "2026-10-18T02:54:10.000Z", "message": ["role": "user", "content": text]]
                .merging(extra) { $1 })
    }

    static func assistant(_ uuid: String, _ parent: String?, _ text: String) -> String {
        object([
            "type": "assistant", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": "2026-10-18T02:56:42.000Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ])
    }

    static func system(_ uuid: String, _ parent: String?, _ subtype: String, extra: [String: Any] = [:]) -> String {
        object(["type": "system", "subtype": subtype, "uuid": uuid, "parentUuid": parent ?? NSNull(), "isMeta": true].merging(extra) { $1 })
    }

    static func meta(_ session: String) -> [String] {
        [##"{"type":"custom-title","customTitle":"#74 稼働計算","sessionId":"\##(session)"}"##, #"{"type":"mode","mode":"normal","sessionId":"\#(session)"}"#]
    }

    static var boundary: [String] {
        [
            system("b1", nil, "compact_boundary", extra: ["logicalParentUuid": "d1", "content": "Conversation compacted"]),
            user("c1", "b1", "This session is being continued from a previous conversation.", extra: ["isCompactSummary": true, "isVisibleInTranscriptOnly": true]),
        ]
    }

    /// 写しの頭：区切りから地点（i1）まで。CLI は要約の直前の a2・d1 も、親を要約に付け替えて写す（写し元では区切りより前にだけある）
    static var compacted: [String] { boundary + [assistant("a2", "c1", "前の答えの続き"), system("d1", "a2", "turn_duration"), system("i1", "d1", "informational")] }

    /// 写し元：最初の依頼から要約まで、要約の後の発言（u2 とその答え。u2 へ巻き戻すと消える）
    static var sourceLines: [String] {
        meta(source) + [
            user("u1", nil, "最初の依頼"),
            assistant("a1", "u1", "最初の答え"),
            assistant("a2", "a1", "前の答えの続き"),
            system("d1", "a2", "turn_duration"),
        ] + meta(source) + boundary + [
            system("i1", "c1", "informational"),
            user("u2", "i1", "いまいくらやろ"),
            assistant("a3", "u2", "消える答え"),
        ]
    }

    /// u2 へ巻き戻して送った後（i1 まで写し、新しい発言 u4 を足した）
    static var forkLines: [String] { meta(fork) + compacted + [user("u4", "i1", "今どないやろ"), assistant("a4", "u4", "新しい答え")] }

    static func write(_ files: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "tb-lineage-\(UUID().uuidString)")
        let dir = root.appending(path: "-Users-ukwhatn-workspace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (session, lines) in files {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appending(path: "\(session).jsonl"))
        }
        return root
    }

    static func url(_ session: String, in root: URL) -> URL { root.appending(path: "-Users-ukwhatn-workspace/\(session).jsonl") }

    /// 写し元の中の、区切りの行の頭
    static var boundaryStart: UInt64 {
        let lines = sourceLines
        let index = lines.firstIndex { $0.contains(#""compact_boundary""#) }!
        return UInt64(lines[..<index].reduce(0) { $0 + $1.utf8.count + 1 })
    }
}

@Suite("要約の後へ巻き戻した会話：写し元の transcript へ続けて読む")
struct TranscriptLineageTests {
    typealias T = CompactedTranscripts

    private func record(_ session: String, previous: String? = nil) -> ConversationRecord {
        var record = ConversationRecord(taskNumber: nil, agentSessionId: session, cwd: "/Users/ukwhatn/workspace", runner: .host)
        record.previousSessionId = previous
        return record
    }

    /// 履歴を cursor が尽きるまで上へ読む。アプリ（`ConversationTimeline.mergeHistory`）と同じく、古い方のページで手元にある id は捨てて前に足す
    /// （要約の直前の発言は、写し元と写しの両方に同じ uuid である）
    private func readAll(_ lineage: TranscriptLineage, limit: Int = 50) throws -> (texts: [String], pages: Int) {
        var cursor: String?
        var messages: [ChatMessage] = []
        var pages = 0
        repeat {
            let page = try ConversationHistory.read(lineage: lineage, before: cursor, limit: limit)
            let known = Set(messages.map(\.id))
            messages = page.messages.filter { !known.contains($0.id) } + messages
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 20
        return (messages.map(\.text), pages)
    }

    @Test("写しの頭の区切りを写し元で探し、区切りの行の頭を写し元の終わりにする。頭が区切りでなければ写し元は無い")
    func findsSource() throws {
        let root = try T.write([T.source: T.sourceLines, T.fork: T.forkLines, "plain": T.meta("plain") + [T.user("u9", nil, "はじめ")]])
        defer { try? FileManager.default.removeItem(at: root) }
        let base = T.url(T.source, in: root)
        #expect(TranscriptSource.find(fork: T.url(T.fork, in: root), source: T.source, at: base) == TranscriptSource(session: T.source, end: T.boundaryStart))
        #expect(TranscriptSource.find(fork: T.url("plain", in: root), source: T.source, at: base) == nil, "CLI が全部写した transcript")
        #expect(TranscriptSource.find(fork: T.url(T.fork, in: root), source: "plain", at: T.url("plain", in: root)) == nil, "写し元に区切りが無い")
    }

    @Test("写し元を記録した会話は、写しを読み終えたら写し元の区切りより前を読む。cursor は写し元の会話 ID で作る")
    func continuesIntoSource() throws {
        let root = try T.write([T.source: T.sourceLines, T.fork: T.forkLines])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = TranscriptSource(session: T.source, end: T.boundaryStart)
        let lineage = TranscriptLineage(record: record(T.fork), projects: root) { $0 == T.fork ? source : nil }
        let first = try ConversationHistory.read(lineage: lineage, before: nil, limit: 50)
        #expect(first.messages.map(\.text) == ["会話を圧縮しました", "前の答えの続き", "今どないやろ", "新しい答え"])
        #expect(first.nextCursor == "\(T.source).\(T.boundaryStart)" && first.agentSessionID == T.fork)
        let older = try ConversationHistory.read(lineage: lineage, before: first.nextCursor, limit: 50)
        #expect(older.messages.map(\.text) == ["最初の依頼", "最初の答え", "前の答えの続き"], "巻き戻しで消えた u2 より後は読まない")
        #expect(older.nextCursor == nil && older.agentSessionID == T.fork)
        #expect(try readAll(lineage, limit: 2).texts == ["最初の依頼", "最初の答え", "会話を圧縮しました", "前の答えの続き", "今どないやろ", "新しい答え"])
    }

    @Test("記録が無くても、頭が区切りで、巻き戻す前の会話 ID の transcript にその区切りがあれば読む（Studio #74）。どれかが欠ければ今の読み方のまま")
    func fallsBackToPrevious() throws {
        let root = try T.write([T.source: T.sourceLines, T.fork: T.forkLines, "other": T.meta("other") + [T.user("u9", nil, "別の会話")]])
        defer { try? FileManager.default.removeItem(at: root) }
        let recovered = TranscriptLineage(unrecorded: record(T.fork, previous: T.source), projects: root)
        #expect(try readAll(recovered).texts == ["最初の依頼", "最初の答え", "会話を圧縮しました", "前の答えの続き", "今どないやろ", "新しい答え"])

        let onlyFork = ["会話を圧縮しました", "前の答えの続き", "今どないやろ", "新しい答え"]
        #expect(try readAll(TranscriptLineage(unrecorded: record(T.fork), projects: root)).texts == onlyFork, "巻き戻す前の会話 ID が無い")
        #expect(try readAll(TranscriptLineage(unrecorded: record(T.fork, previous: "other"), projects: root)).texts == onlyFork, "前の transcript に区切りが無い")
        #expect(try readAll(TranscriptLineage(unrecorded: record(T.fork, previous: "gone"), projects: root)).texts == onlyFork, "前の transcript が無い")
        let plain = "9c8b7a65-0000-4000-8000-000000000004"
        try Data(((T.meta(plain) + [T.user("u9", nil, "全部写した")]).joined(separator: "\n") + "\n").utf8).write(to: T.url(plain, in: root))
        #expect(try readAll(TranscriptLineage(unrecorded: record(plain, previous: T.source), projects: root)).texts == ["全部写した"], "頭が区切りでない")
    }

    @Test("巻き戻しを重ねた会話は写し元を順にたどる。区切りより前に発言の無い写し元は飛ばす")
    func chainsSources() throws {
        // 2 回目の巻き戻し（u4 へ）：写しの写し。頭は同じ区切りなので、1 本目の写しの区切りより前には meta しか無い
        let againLines = T.meta(T.again) + T.compacted + [T.user("u5", "i1", "三回目")]
        let root = try T.write([T.source: T.sourceLines, T.fork: T.forkLines, T.again: againLines])
        defer { try? FileManager.default.removeItem(at: root) }
        let forkBoundary = UInt64(T.meta(T.fork).reduce(0) { $0 + $1.utf8.count + 1 })
        let sources = [T.again: TranscriptSource(session: T.fork, end: forkBoundary), T.fork: TranscriptSource(session: T.source, end: T.boundaryStart)]
        #expect(TranscriptSource.find(fork: T.url(T.again, in: root), source: T.fork, at: T.url(T.fork, in: root)) == sources[T.again])
        let lineage = TranscriptLineage(record: record(T.again, previous: T.fork), projects: root) { sources[$0] }
        let first = try ConversationHistory.read(lineage: lineage, before: nil, limit: 50)
        #expect(first.nextCursor == "\(T.fork).\(forkBoundary)")
        let older = try ConversationHistory.read(lineage: lineage, before: first.nextCursor, limit: 50)
        #expect(older.messages.map(\.text) == ["最初の依頼", "最初の答え", "前の答えの続き"] && older.nextCursor == nil)
        #expect(lineage.segments.map(\.session) == [T.again, T.fork, T.source])
    }

    @Test("写し元の発言からもフォークでき、札の中身も写し元から読む。巻き戻しで消えた発言・系列に無い会話 ID の cursor は読まない")
    func forkAndCursorFromSource() throws {
        let root = try T.write([T.source: T.sourceLines, T.fork: T.forkLines])
        defer { try? FileManager.default.removeItem(at: root) }
        let lineage = TranscriptLineage(unrecorded: record(T.fork, previous: T.source), projects: root)
        #expect(try ConversationFork.point(in: lineage, messageID: "u1", generating: false) == ConversationFork(session: T.source, uuid: "u1"))
        #expect(try ConversationFork.point(in: lineage, messageID: "u4", generating: false) == ConversationFork(session: T.fork, uuid: "u4"))
        #expect(throws: ConversationError.messageNotFound("u2")) { try ConversationFork.point(in: lineage, messageID: "u2", generating: false) }
        // `/clear` の前の会話 ID の cursor は、今と同じく末尾から読む
        let other = try ConversationHistory.read(lineage: lineage, before: "0aa11bb2-0000-4000-8000-000000000009.5", limit: 50)
        #expect(other.messages.last?.text == "新しい答え")
    }

    @Test("要約の区切りより前の行からは巻き戻さない：地点の後に区切りがあるか")
    func boundaryAfter() throws {
        let root = try T.write([T.source: T.sourceLines])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = T.url(T.source, in: root)
        let before = try #require(TranscriptLines.find("u1", in: url))
        let after = try #require(TranscriptLines.find("u2", in: url))
        #expect(TranscriptLines.hasBoundary(in: url, after: before.end))
        #expect(!TranscriptLines.hasBoundary(in: url, after: after.end))
        #expect(TranscriptLines.headBoundary(in: url) == nil && TranscriptLines.line("b1", in: url)?.start == T.boundaryStart)
    }

    @Test("頭の区切りは頭の行の分だけ読んで決める。読みの区切り（64KB）をまたぐ行・改行で終わらない末尾の行・本筋の前のサブエージェントの行も見る")
    func headBoundaryChunks() throws {
        let big = String(repeating: "あ", count: 40_000)  // 120KB
        let sidechain = #"{"type":"user","uuid":"s0","isSidechain":true,"message":{"role":"user","content":"\#(big)"}}"#
        let cases: [(String, [String], String?)] = [
            ("頭の meta が 64KB を超える", [#"{"type":"custom-title","customTitle":"\#(big)"}"#] + T.compacted, "b1"),
            ("本筋の前のサブエージェントの行", [sidechain] + T.compacted, "b1"),
            ("本筋の最初の行が大きい人の発言", [T.user("u0", nil, big)] + T.compacted, nil),
            ("区切りだけで改行が無い", [T.boundary[0]], "b1"),
            ("空", [], nil),
        ]
        let root = try T.write([:])
        defer { try? FileManager.default.removeItem(at: root) }
        for (note, lines, expected) in cases {
            let url = T.url("head", in: root)
            try Data(lines.joined(separator: "\n").utf8).write(to: url)
            #expect(TranscriptLines.headBoundary(in: url) == expected, "\(note)")
        }
    }
}
