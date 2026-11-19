import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// 会話の記録の元を差し替える（transcript の並びと codex の履歴のページ）
private final class FakeSources: @unchecked Sendable {
    private let lock = NSLock()
    private var _segments: [String: [TranscriptLineage.Segment]] = [:]
    /// codex の thread の発言（古い順）
    private var _codex: [String: [ChatMessage]] = [:]
    private(set) var codexPages = 0
    static let pageSize = 2

    func setSegments(_ id: String, _ segments: [TranscriptLineage.Segment]) { lock.withLock { _segments[id] = segments } }
    func setCodex(_ thread: String, _ messages: [ChatMessage]) { lock.withLock { _codex[thread] = messages } }
    var pages: Int { lock.withLock { codexPages } }

    var sources: ConversationSearchIndex.Sources {
        ConversationSearchIndex.Sources(
            segments: { [self] record in lock.withLock { _segments[record.id] ?? [] } },
            codexHistory: { [self] record, before in
                lock.withLock {
                    codexPages += 1
                    // 新しい方から pageSize 件ずつ。cursor は次のページの末尾の位置
                    let all = _codex[record.agentSessionId] ?? []
                    let end = before.flatMap(Int.init) ?? all.count
                    let start = max(0, end - Self.pageSize)
                    return ConversationHistoryResponse(
                        messages: Array(all[start..<end]), nextCursor: start > 0 ? String(start) : nil, agentSessionID: record.agentSessionId)
                }
            })
    }
}

@Suite("会話の全文検索の索引を作る")
struct ConversationSearchIndexTests {
    private let machine = MachineID(rawValue: "m-test")
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-search-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL, _ lines: [String], trailingNewline: Bool = true) throws {
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: url)
    }

    private func append(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func found(_ index: ConversationSearchIndex, _ query: String) async throws -> [String] {
        try await index.search(query, limit: 20).hits.map(\.messageID)
    }

    private typealias T = CompactedTranscripts

    @Test("Claude の会話：人の発言と返答の文だけを載せ、増えた行を読み足す。書きかけの行は書き終えてから載せる")
    func claudeAppends() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(inMemory: machine)
        let record = try store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: "s1", cwd: "/w", runner: .none, createdAt: t0))
        let url = dir.appending(path: "s1.jsonl")
        let toolUse = T.object([
            "type": "assistant", "uuid": "a2", "parentUuid": "a1", "timestamp": "2026-10-18T02:56:43.000Z",
            "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "grep 索引の外"]]]],
        ])
        let thinking = T.object([
            "type": "assistant", "uuid": "a3", "parentUuid": "a2", "timestamp": "2026-10-18T02:56:44.000Z",
            "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "索引の外の思考", "signature": "x"]]],
        ])
        try write(url, [T.user("u1", nil, "索引を作りたい"), T.assistant("a1", "u1", "索引を作ります"), toolUse, thinking])
        let sources = FakeSources()
        sources.setSegments(record.id, [TranscriptLineage.Segment(session: "s1", url: url, end: .max)])
        let index = ConversationSearchIndex(store: store, sources: sources.sources)
        #expect(await index.building)
        await index.update()
        #expect(await !index.building)
        #expect(try await index.search("索引", limit: 20).hits.first?.matches == 2)
        #expect(try await found(index, "索引の外").isEmpty, "ツールの呼び出しと思考は載せない")

        // 書きかけの行（改行の前）は載せず、書き終えたら次の回に載せる。前に載せた発言は 2 度載せない
        let next = T.user("u2", "a3", "検索の欄も足す")
        try append(url, String(next.prefix(20)))
        await index.conversationIdle(record.id)
        await index.update()
        #expect(try await found(index, "検索の欄").isEmpty)
        try append(url, String(next.dropFirst(20)) + "\n")
        await index.conversationIdle(record.id)
        await index.update()
        #expect(try await found(index, "検索の欄").count == 1)
        #expect(try await index.search("索引", limit: 20).hits.first?.matches == 2)
    }

    @Test("巻き戻しで並びが替わったら、写し元の地点より後ろの発言と、並びから外れた transcript の発言を消す")
    func claudeLineageChanges() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(inMemory: machine)
        let record = try store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: "s1", cwd: "/w", runner: .none, createdAt: t0))
        let first = dir.appending(path: "s1.jsonl")
        let kept = T.user("u1", nil, "残る索引の発言")
        try write(first, [kept, T.user("u2", "u1", "巻き戻して消える索引の発言")])
        let sources = FakeSources()
        sources.setSegments(record.id, [TranscriptLineage.Segment(session: "s1", url: first, end: .max)])
        let index = ConversationSearchIndex(store: store, sources: sources.sources)
        await index.update()
        #expect(try await index.search("索引の発言", limit: 20).hits.first?.matches == 2)

        // u2 の前へ巻き戻した：新しい transcript s2 と、写し元 s1 の u1 の行まで
        let second = dir.appending(path: "s2.jsonl")
        try write(second, [T.assistant("a9", nil, "巻き戻した後の答え")])
        _ = try store.updateConversation(id: record.id) { $0.agentSessionId = "s2" }
        sources.setSegments(
            record.id,
            [TranscriptLineage.Segment(session: "s2", url: second, end: .max), TranscriptLineage.Segment(session: "s1", url: first, end: UInt64(kept.utf8.count + 1))])
        await index.update()
        #expect(try await index.search("索引の発言", limit: 20).hits.first?.matches == 1)
        #expect(try await found(index, "消える").isEmpty)
        #expect(try await found(index, "巻き戻した後").count == 1)

        // 写し元を外れた（`/clear` の後の新しい会話 ID だけ）
        sources.setSegments(record.id, [TranscriptLineage.Segment(session: "s2", url: second, end: .max)])
        _ = try store.updateConversation(id: record.id) { $0.title = "替えた" }
        await index.update()
        #expect(try await found(index, "残る").isEmpty)
    }

    @Test("起動の後の確かめで壊れた索引に気づき、空にして transcript から読み直す。作り直しの要求も同じ")
    func rebuildsBrokenIndex() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(inMemory: machine)
        let record = try store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: "s1", cwd: "/w", runner: .none, createdAt: t0))
        let url = dir.appending(path: "s1.jsonl")
        try write(url, [T.user("u1", nil, "索引を作りたい"), T.assistant("a1", "u1", "索引を作ります")])
        let sources = FakeSources()
        sources.setSegments(record.id, [TranscriptLineage.Segment(session: "s1", url: url, end: .max)])
        await ConversationSearchIndex(store: store, sources: sources.sources).update()

        // 本文にある行を FTS5 の索引からだけ抜く（trigger を通らない）
        try await store.database.write { db in
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM conversationSearchEntry WHERE text = '索引を作りたい'")
            try db.execute(sql: "INSERT INTO conversationSearchText(conversationSearchText, rowid, text) VALUES ('delete', ?, '索引を作りたい')", arguments: [id])
        }
        #expect(try !store.conversationSearchIntact())

        // daemon を起こし直した
        let index = ConversationSearchIndex(store: store, sources: sources.sources)
        await index.checkIntegrity()
        #expect(await index.building)
        await index.update()
        #expect(await !index.building)
        #expect(try store.conversationSearchIntact())
        #expect(try await index.search("索引", limit: 20).hits.first?.matches == 2, "2 度載せない")

        // 手で作り直す
        await index.requestRebuild()
        #expect(await index.building)
        await index.update()
        #expect(try await index.search("索引", limit: 20).hits.first?.matches == 2)
        #expect(try store.conversationSearchIntact())
    }

    @Test("codex の会話：新しい方から、載せた発言に当たるまで読む。ターンを終えて stats が替わったら読み足す")
    func codexAppends() async throws {
        let store = try Store(inMemory: machine)
        var created = ConversationRecord(taskNumber: nil, agentSessionId: "th-1", cwd: "/w", runner: .none, createdAt: t0)
        created.engine = Conversation.Engine.codex.rawValue
        let record = try store.createConversation(created)
        func message(_ id: String, _ role: ChatMessage.Role, _ text: String, kind: ChatMessage.Kind = .text) -> ChatMessage {
            ChatMessage(id: id, role: role, kind: kind, text: text, at: t0)
        }
        let sources = FakeSources()
        var thread = [
            message("i1", .user, "codex で索引を作る"), message("i2", .assistant, "ls", kind: .toolUse), message("i3", .assistant, "索引を作りました"),
            message("i4", .user, "続けて"), message("i5", .assistant, "はい"),
        ]
        sources.setCodex("th-1", thread)
        let index = ConversationSearchIndex(store: store, sources: sources.sources)
        await index.update()
        #expect(try await index.search("索引", limit: 20).hits.first?.matches == 2)
        #expect(sources.pages == 3)

        thread += [message("i6", .user, "索引に検索を足す"), message("i7", .assistant, "足しました")]
        sources.setCodex("th-1", thread)
        // stats が替わらないうちは読まない
        await index.update()
        #expect(sources.pages == 3)
        _ = try store.updateConversationStats(id: record.id, ConversationStats(agentSessionID: "th-1", costUSD: 0.1, at: t0))
        await index.update()
        #expect(sources.pages == 5, "載せた i5 に当たったページで止まる")
        #expect(try await index.search("索引", limit: 20).hits.first?.messageID == "i6")
        #expect(try await index.search("索引", limit: 20).hits.first?.matches == 3)

        // daemon を起こし直しても（最初の見回り）、記録が替わっていなければ読まない
        let restarted = ConversationSearchIndex(store: store, sources: sources.sources)
        await restarted.update()
        #expect(sources.pages == 5)
        #expect(try await restarted.search("索引", limit: 20).hits.first?.matches == 3)
    }
}
