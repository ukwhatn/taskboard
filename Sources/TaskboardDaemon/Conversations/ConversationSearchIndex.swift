import Foundation
import Logging
import TaskboardKit

/// 会話をまたいだ全文検索の索引を作り、引く（`GET /v1/conversations/search`）。載せるのは履歴に出る発言のうち `ConversationSearchQuery.indexes` のもの。
///
/// - Claude の会話は、履歴と同じ transcript の並び（`TranscriptLineage`）を、前に読んだ所から前へ読み足す。並びが替わったら（フォーク・巻き戻し・`/clear`）、
///   無くなった transcript と写し元の地点より後ろの発言を消す
/// - codex の会話は、履歴（`thread/items/list`）を新しい方から、載せた発言に当たるまで読む
/// - 読むのは、会話が入力待ちになったとき（`conversationIdle`）、会話の記録が替わったとき、10 分ごとの全部の見回りのとき。
///   読み足すのは `run` の 1 本だけで、書き込みは 1MB ごとのトランザクションに分ける（DB は WAL なので、読みはこれを待たない）
/// - 索引は記録から作るので、いつ捨ててもよい。起動の後に FTS5 の索引を 1 度確かめ、本文と食い違っていれば空にして初めから読み直す。
///   `requestRebuild` も同じ。空にするのは `update` の頭だけ（読んでいる途中の会話の読んだ所を、空にした後に書き戻さないため）
actor ConversationSearchIndex {
    struct Sources: Sendable {
        /// Claude の会話の、履歴と同じ transcript の並び
        var segments: @Sendable (ConversationRecord) async -> [TranscriptLineage.Segment]
        /// codex の会話の履歴の 1 ページ（新しい方から。`before` は前のページの `nextCursor`）
        var codexHistory: @Sendable (ConversationRecord, _ before: String?) async throws -> ConversationHistoryResponse
    }

    static let chunkBytes = 1 << 20
    /// 1 つの発言から載せる字数
    static let entryCharacters = 50_000
    /// codex の会話を 1 回で読むページの上限
    static let codexPages = 50
    static let pollSeconds = 15
    static let sweepSeconds: TimeInterval = 600

    private let store: Store
    private let sources: Sources
    private let logger: Logger
    private let now: @Sendable () -> Date
    /// 会話の id → 最後に読んだときの記録の値（`signature`）
    private var seen: [String: String] = [:]
    /// 入力待ちになり、まだ読み足していない会話
    private var dirty: Set<String> = []
    private var lastSweep: Date?
    /// 次の `update` の頭で索引を空にする
    private var clearRequested = false

    init(store: Store, sources: Sources, logger: Logger = Logger(label: "uk.whatn.taskboardd.search"), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.sources = sources
        self.logger = logger
        self.now = now
    }

    /// 最初の見回り（空にした後も）を終えるまでは、まだ載っていない会話がある
    var building: Bool { lastSweep == nil || clearRequested }

    func conversationIdle(_ id: String) { dirty.insert(id) }

    /// 索引を捨てて初めから作り直す（`POST /v1/conversations/search/rebuild`、`taskboard conversation rebuild-search`）。空にするのは次の `update`
    func requestRebuild() { clearRequested = true }

    /// 起動の後に 1 度。FTS5 の索引が本文と食い違っていれば作り直す
    func checkIntegrity() {
        do {
            guard try !store.conversationSearchIntact() else { return }
            logger.warning("conversation search: index is inconsistent, rebuilding")
            clearRequested = true
        } catch {
            logger.warning("conversation search: integrity check failed", metadata: ["error": "\(error)"])
        }
    }

    func run() async {
        checkIntegrity()
        while !Task.isCancelled {
            await update()
            // 入力待ちになった会話か作り直しの要求があれば 1 秒で、無ければ `pollSeconds` で次を読む
            for _ in 0..<Self.pollSeconds where dirty.isEmpty && !clearRequested && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func search(_ query: String, limit: Int) throws -> ConversationSearchResponse {
        let hits = try store.searchConversations(terms: ConversationSearchQuery.terms(query), limit: limit)
        return ConversationSearchResponse(hits: hits, indexing: building)
    }

    /// 1 回の見回り。読むのは、入力待ちになった会話と、記録が前に読んだときから替わった会話（全部の見回りの回は全部）
    func update() async {
        if clearRequested {
            do {
                try store.clearConversationSearch()
            } catch {
                return logger.warning("conversation search: clear failed", metadata: ["error": "\(error)"])
            }
            clearRequested = false
            seen = [:]
            lastSweep = nil
        }
        let records: [ConversationRecord]
        do {
            // 廃止した説明役の会話は会話の一覧に出さないので、検索にも出さない
            records = try store.conversations().filter { $0.purposeValue != .briefing }
        } catch {
            return logger.warning("conversation search: list failed", metadata: ["error": "\(error)"])
        }
        let sweep = lastSweep.map { now().timeIntervalSince($0) >= Self.sweepSeconds } ?? true
        for record in records where !Task.isCancelled {
            let signature = Self.signature(record)
            guard sweep || dirty.contains(record.id) || seen[record.id] != signature else { continue }
            dirty.remove(record.id)
            do {
                if record.engineValue == .codex {
                    try await indexCodex(record, mark: signature)
                } else {
                    try await indexClaude(record)
                }
            } catch {
                logger.info("conversation search: index failed", metadata: ["conversation": .string(record.id), "error": "\(error)"])
            }
            // 失敗しても、記録が替わるか次の全部の見回りまでは読み直さない（codex app-server を起こし続けない）
            seen[record.id] = signature
        }
        let ids = Set(records.map(\.id))
        seen = seen.filter { ids.contains($0.key) }
        dirty.formIntersection(ids)
        if sweep, !Task.isCancelled { lastSweep = now() }
    }

    /// 読み直す目安。codex の `stats` はターンのたびに書く（`updatedAt` は進めない）
    private static func signature(_ record: ConversationRecord) -> String {
        [record.agentSessionId, record.pendingForkSessionId ?? "", record.pendingForkAt ?? "", "\(record.updatedAt.timeIntervalSince1970)", record.stats ?? ""]
            .joined(separator: "|")
    }

    private func indexClaude(_ record: ConversationRecord) async throws {
        let segments = await sources.segments(record)
        try store.trimConversationSearch(
            conversation: record.id, keeping: Dictionary(segments.map { ($0.session, $0.end == .max ? nil : $0.end) }, uniquingKeysWith: { first, _ in first }))
        let stored = try store.conversationSearchSources(conversation: record.id)
        for segment in segments where !Task.isCancelled {
            try await read(segment, of: record.id, from: stored[segment.session]?.position ?? 0)
        }
    }

    /// `position` から、transcript の末尾か `segment.end` まで読む。読みかけの行は次の回に読み直す
    private func read(_ segment: TranscriptLineage.Segment, of id: String, from stored: UInt64) async throws {
        guard let handle = try? FileHandle(forReadingFrom: segment.url) else { return }
        defer { try? handle.close() }
        let bound = min(segment.end, try handle.seekToEnd())
        var position = stored
        // 縮んだ transcript（書き直し）は初めから読み直す
        if bound < position, segment.end == .max {
            try store.trimConversationSearch(conversation: id, keeping: [segment.session: 0])
            position = 0
        }
        guard bound > position else { return }
        let end = segment.end == .max ? nil : segment.end
        var cursor = TranscriptCursor(offset: position)
        var offset = position
        try handle.seek(toOffset: position)
        while offset < bound, !Task.isCancelled {
            guard let chunk = try handle.read(upToCount: Int(min(UInt64(Self.chunkBytes), bound - offset))), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            var entries: [Store.ConversationSearchEntry] = []
            var rest = chunk[...]
            // 1 行ずつ渡し、発言をその行の頭の位置で載せる（写し元の地点より後ろを消すため）
            while !rest.isEmpty {
                let cut = rest.firstIndex(of: 0x0A).map { rest.index(after: $0) } ?? rest.endIndex
                let line = cursor.lineStart
                entries += cursor.feed(Data(rest[rest.startIndex..<cut])).filter(ConversationSearchQuery.indexes).map { Self.entry($0, position: line) }
                rest = rest[cut...]
            }
            try store.addConversationSearch(
                conversation: id, source: Store.ConversationSearchSource(source: segment.session, position: cursor.lineStart, end: end, mark: nil), entries: entries)
            await Task.yield()
        }
    }

    private func indexCodex(_ record: ConversationRecord, mark: String) async throws {
        // 送る前の会話には thread が無い（`agentSessionId` は会話の id のまま）
        guard record.agentSessionId != record.id else { return }
        let thread = record.agentSessionId
        try store.trimConversationSearch(conversation: record.id, keeping: [thread: nil])
        // 見回りと daemon の起動のたびに app-server を起こさない。記録が前に読んだときのままなら履歴も増えていない
        guard try store.conversationSearchSources(conversation: record.id)[thread]?.mark != mark else { return }
        var fresh: [ChatMessage] = []
        var before: String?
        pages: for _ in 0..<Self.codexPages {
            let page = try await sources.codexHistory(record, before)
            for message in page.messages.reversed() where ConversationSearchQuery.indexes(message) {
                if try store.hasConversationSearchEntry(conversation: record.id, source: thread, messageID: message.id) { break pages }
                fresh.append(message)
            }
            guard let next = page.nextCursor else { break }
            before = next
        }
        try store.addConversationSearch(
            conversation: record.id, source: Store.ConversationSearchSource(source: thread, position: 0, end: nil, mark: mark),
            entries: fresh.reversed().map { Self.entry($0, position: 0) })
    }

    private static func entry(_ message: ChatMessage, position: UInt64) -> Store.ConversationSearchEntry {
        Store.ConversationSearchEntry(
            messageID: message.id, role: message.role, at: message.at, text: String(message.text.prefix(entryCharacters)), position: position)
    }
}
