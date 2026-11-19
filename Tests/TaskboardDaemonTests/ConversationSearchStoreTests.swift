import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("会話の全文検索の索引")
struct ConversationSearchStoreTests {
    private let machine = MachineID(rawValue: "m-test")
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func conversation(_ store: Store, session: String) throws -> ConversationRecord {
        try store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: session, cwd: "/w", runner: .none, createdAt: t0))
    }

    private func entry(_ id: String, _ text: String, at offset: TimeInterval, role: ChatMessage.Role = .assistant, position: UInt64 = 0) -> Store.ConversationSearchEntry {
        Store.ConversationSearchEntry(messageID: id, role: role, at: t0.addingTimeInterval(offset), text: text, position: position)
    }

    private func add(_ store: Store, _ record: ConversationRecord, source: String, position: UInt64 = 0, _ entries: [Store.ConversationSearchEntry]) throws {
        try store.addConversationSearch(
            conversation: record.id, source: Store.ConversationSearchSource(source: source, position: position, end: nil, mark: nil), entries: entries)
    }

    @Test("3 字以上の語は部分一致、2 字の語も引ける。大文字と小文字を区別せず、空白で区切った語はすべてを含む発言だけ")
    func matching() throws {
        let store = try Store(inMemory: machine)
        let a = try conversation(store, session: "s1")
        try add(
            store, a, source: "s1",
            [
                entry("m1", "会話をまたいだ全文検索を作る", at: 1), entry("m2", "Swift の Store を足す", at: 2),
                entry("m3", "検索の欄を直す", at: 3), entry("m4", "ボードの列を並べ替える", at: 4),
            ])
        func ids(_ query: String) throws -> [String] {
            try store.searchConversations(terms: ConversationSearchQuery.terms(query), limit: 20).map(\.messageID)
        }
        #expect(try ids("全文検索") == ["m1"])
        #expect(try ids("検索") == ["m3"], "会話ごとに最新の 1 つ")
        #expect(try ids("store") == ["m2"])
        #expect(try ids("STORE swift") == ["m2"])
        #expect(try ids("検索　欄") == ["m3"], "全角の空白でも区切る")
        #expect(try ids("検索 ボード").isEmpty)
        #expect(try ids("").isEmpty)
        #expect(try store.searchConversations(terms: ["検索"], limit: 20).first?.matches == 2)
    }

    @Test("会話ごとにまとめて、一致の新しい会話から並べ、limit 件で切る。抜粋は一致の前後")
    func grouping() throws {
        let store = try Store(inMemory: machine)
        let older = try conversation(store, session: "s1")
        let newer = try conversation(store, session: "s2")
        try add(store, older, source: "s1", [entry("o1", "taskboard の索引を作る", at: 10)])
        try add(store, newer, source: "s2", [entry("n1", "索引を作り直す", at: 20), entry("n2", "関係ない発言", at: 30)])
        let hits = try store.searchConversations(terms: ["索引"], limit: 20)
        #expect(hits.map(\.conversationID) == [newer.id, older.id])
        #expect(hits[0].snippet == "索引を作り直す" && hits[0].role == .assistant && hits[0].at == t0.addingTimeInterval(20))
        #expect(try store.searchConversations(terms: ["索引"], limit: 1).map(\.conversationID) == [newer.id])
    }

    @Test("記録の元に合わせる：無くなった元の発言と、範囲の終わりより後ろの発言を消し、読んだ所を終わりまで戻す")
    func trim() throws {
        let store = try Store(inMemory: machine)
        let record = try conversation(store, session: "s2")
        try add(store, record, source: "s1", position: 300, [entry("a", "前の会話の索引", at: 1, position: 0), entry("b", "後ろの索引", at: 2, position: 200)])
        try add(store, record, source: "gone", position: 50, [entry("c", "消えた元の索引", at: 3)])
        try store.trimConversationSearch(conversation: record.id, keeping: ["s1": 100, "s2": nil])
        #expect(try store.searchConversations(terms: ["索引"], limit: 20).map(\.messageID) == ["a"])
        let sources = try store.conversationSearchSources(conversation: record.id)
        #expect(sources.keys.sorted() == ["s1"])
        #expect(sources["s1"]?.position == 100 && sources["s1"]?.end == 100)
    }

    @Test("会話を消すと索引の発言も消え、検索に出ない")
    func deletion() throws {
        let store = try Store(inMemory: machine)
        let record = try conversation(store, session: "s1")
        try add(store, record, source: "s1", [entry("a", "消える会話の索引", at: 1)])
        try store.deleteConversation(id: record.id)
        #expect(try store.searchConversations(terms: ["索引"], limit: 20).isEmpty)
        #expect(try store.conversationSearchSources(conversation: record.id).isEmpty)
        // FTS5 の索引の側も、本文の表と食い違っていない（会話の削除の cascade でも trigger が走る）
        try store.database.write { db in
            try db.execute(sql: "INSERT INTO conversationSearchText(conversationSearchText, rank) VALUES ('integrity-check', 1)")
        }
        // 消えた会話には足さない（読んでいる間に消された）
        try add(store, record, source: "s1", [entry("b", "後から来た索引", at: 2)])
        #expect(try store.searchConversations(terms: ["索引"], limit: 20).isEmpty)
    }

    /// 壊し方は 2 つ：本文に無い行を索引にだけ足す、本文にある行を索引から抜く（どちらも trigger を通らない書き方）
    @Test("FTS5 の索引が本文と食い違ったら integrity-check で分かり、空にすると食い違いが消えて足し直せる", arguments: ["ghost", "missing"])
    func corruption(_ kind: String) throws {
        let store = try Store(inMemory: machine)
        let record = try conversation(store, session: "s1")
        try add(store, record, source: "s1", position: 10, [entry("a", "壊れる前の索引", at: 1), entry("b", "もう 1 つの索引", at: 2)])
        #expect(try store.conversationSearchIntact())
        try store.database.write { db in
            if kind == "ghost" {
                try db.execute(sql: "INSERT INTO conversationSearchText(rowid, text) VALUES (999, '本文に無い索引')")
            } else {
                let id = try Int64.fetchOne(db, sql: "SELECT id FROM conversationSearchEntry WHERE messageId = 'a'")
                try db.execute(sql: "INSERT INTO conversationSearchText(conversationSearchText, rowid, text) VALUES ('delete', ?, '壊れる前の索引')", arguments: [id])
            }
        }
        #expect(try !store.conversationSearchIntact())

        try store.clearConversationSearch()
        #expect(try store.conversationSearchIntact())
        #expect(try store.searchConversations(terms: ["索引"], limit: 20).isEmpty)
        #expect(try store.conversationSearchSources(conversation: record.id).isEmpty, "読んだ所も消え、初めから読み直す")
        try add(store, record, source: "s1", position: 10, [entry("a", "壊れる前の索引", at: 1)])
        #expect(try store.searchConversations(terms: ["壊れる前"], limit: 20).map(\.messageID) == ["a"])
        #expect(try store.conversationSearchIntact())
        // 戻した trigger が効いている（会話を消すと索引からも消える）
        try store.deleteConversation(id: record.id)
        #expect(try store.searchConversations(terms: ["壊れる前"], limit: 20).isEmpty)
        #expect(try store.conversationSearchIntact())
    }

    @Test("v32 の DB に v33 を当てると、前の会話は残ったまま索引の表が空で足され、前に backup を取る")
    func migrationV33() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-v33-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "taskboard.db")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Store.migrator().migrate(queue, upTo: "v32 conversation rewind redo and fork points")
            try queue.write { db in
                try db.execute(sql: "INSERT INTO board (id, name, position, createdAt) VALUES ('b1', 'default', 0, ?)", arguments: [t0])
                try db.execute(
                    sql: "INSERT INTO conversation (id, engine, agentSessionId, cwd, runner, title, createdAt, updatedAt) VALUES ('c1', 'claude', 's1', '/w', 'none', '前の会話', ?, ?)",
                    arguments: [t0, t0])
            }
            try queue.close()
        }
        let store = try Store(databaseURL: url, backupDirectory: dir.appending(path: "backups"), machineID: machine)
        defer { try? store.close() }
        #expect(try Store.listBackups(in: dir.appending(path: "backups")).count == 1)
        #expect(try store.conversation(id: "c1")?.title == "前の会話")
        #expect(try store.boards().map(\.id) == ["b1"])
        #expect(try store.searchConversations(terms: ["会話"], limit: 20).isEmpty)
        let record = try #require(try store.conversation(id: "c1"))
        try add(store, record, source: "s1", [entry("m1", "上げた後に足した会話", at: 1)])
        #expect(try store.searchConversations(terms: ["足した会話"], limit: 20).map(\.messageID) == ["m1"])
        #expect(try Store.verify(backupAt: try #require(try Store.listBackups(in: dir.appending(path: "backups")).first)).boards == 1)
    }
}
