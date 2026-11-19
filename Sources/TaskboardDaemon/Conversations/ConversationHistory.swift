import Foundation
import TaskboardKit

/// 会話の履歴（`GET /v1/conversations/{id}/history`）。会話の今の Claude の会話 ID の transcript を、後ろから 1MB ずつ読んで行に切り、
/// 新しい方から `limit` 件ずつ返す。1 回で読むのは 4MB まで（読み切れなければ、それまでの分と次の cursor を返す）。
/// cursor は daemon が作る「会話 ID.行の頭の byte の位置」で、message の id から位置を探さない（200MB を超える transcript がある）。
/// `/clear` の前の分は別の transcript なので読まない。フォーク・巻き戻しの後で transcript がまだ無い間は、写す元の transcript を写す地点の行から前へ読む
/// （cursor は写す元の会話 ID で作る）。transcript の頭まで読んだら、写し元（`TranscriptLineage`。CLI が写さなかった要約より前）へ続ける。
/// `subagents` なら、ページの中の Agent の呼び出しのサブエージェントの発言を後ろに足す（`SubagentTranscripts`。件数の `limit` に数えない）
enum ConversationHistory {
    static let chunkBytes = 1 << 20
    static let readLimit = 4 << 20

    struct InvalidCursor: Error {}

    static func read(lineage: TranscriptLineage, before cursor: String?, limit: Int, subagents: Bool = false) throws -> ConversationHistoryResponse {
        let sessionID = lineage.record.agentSessionId
        let limit = min(max(limit, 1), ConversationHistoryResponse.maxLimit)
        let empty = ConversationHistoryResponse(messages: [], nextCursor: nil, agentSessionID: sessionID)
        if let cursor, parse(cursor) == nil { throw InvalidCursor() }
        guard var segment = lineage.head else { return empty }
        // 別の会話 ID の cursor は、写し元のものならその transcript から、そうでなければ（`/clear` の後）末尾から読む。アプリは返った会話 ID で手元を捨てる
        if let cursor, let parsed = parse(cursor) {
            var found: TranscriptLineage.Segment? = segment
            var depth = 0
            while let current = found, current.session != parsed.session, depth < TranscriptLineage.depthLimit {
                found = lineage.next(after: current)
                depth += 1
            }
            if var found, found.session == parsed.session {
                found.end = min(found.end, parsed.offset)
                segment = found
            }
        }
        for _ in 0..<TranscriptLineage.depthLimit {
            guard let handle = try? FileHandle(forReadingFrom: segment.url) else { return empty }
            defer { try? handle.close() }
            let end = min(segment.end, (try? handle.seekToEnd()) ?? 0)
            let page = try readPage(handle, end: end, limit: limit)
            let next = page.start > 0 ? nil : lineage.next(after: segment)
            // 写し元の区切りより前に発言が無い（頭が同じ区切りの写し）なら、そのまま次の写し元を読む
            if page.messages.isEmpty, let next {
                segment = next
                continue
            }
            var children: [ChatMessage] = []
            if subagents {
                var transcripts = SubagentTranscripts(transcript: segment.url)
                children = transcripts.read(after: page.messages)
            }
            let cursor = page.start > 0 ? "\(segment.session).\(page.start)" : next.map { "\($0.session).\($0.end)" }
            return ConversationHistoryResponse(messages: page.messages + children, nextCursor: cursor, agentSessionID: sessionID)
        }
        return empty
    }

    static func parse(_ cursor: String) -> (session: String, offset: UInt64)? {
        guard let dot = cursor.lastIndex(of: "."), let offset = UInt64(cursor[cursor.index(after: dot)...]) else { return nil }
        return (String(cursor[..<dot]), offset)
    }

    /// `end` より前の行を後ろから読む。返す `start` は、返した中で最も古い行の頭（そこから前が次のページ）
    static func readPage(_ handle: FileHandle, end: UInt64, limit: Int) throws -> (messages: [ChatMessage], start: UInt64) {
        // 古い順に並べた行の発言
        var lines: [[ChatMessage]] = []
        var count = 0
        var position = end
        var read = 0
        var partial = Partial()
        var start = end
        func page() -> (messages: [ChatMessage], start: UInt64) {
            var tools = ToolPaths()
            return (lines.flatMap { tools.resolve($0) }, start)
        }
        while position > 0 {
            if read >= readLimit, partial.bytes == 0 { break }
            let size = Int(min(UInt64(chunkBytes), position))
            position -= UInt64(size)
            try handle.seek(toOffset: position)
            let chunk = try handle.read(upToCount: size) ?? Data()
            read += chunk.count
            var cut = chunk.endIndex
            // 後ろから改行を探し、改行の後ろを 1 行として閉じる
            while let newline = chunk[chunk.startIndex..<cut].lastIndex(of: 0x0A) {
                let offset = position + UInt64(newline - chunk.startIndex) + 1
                partial.prepend(chunk[chunk.index(after: newline)..<cut])
                cut = newline
                guard let messages = partial.close(offset: offset) else { continue }
                lines.insert(messages, at: 0)
                count += messages.count
                start = offset
                if count >= limit || read >= readLimit { return page() }
            }
            // 改行より前は、前のチャンクに続く行の一部
            partial.prepend(chunk[chunk.startIndex..<cut])
        }
        if position == 0, let messages = partial.close(offset: 0) {
            lines.insert(messages, at: 0)
            start = 0
        }
        return page()
    }

    /// 頭をまだ見ていない読みかけの 1 行（後ろから前へ足していく）。行の上限を超えたら、頭（足すたびに入れ替わる）と末尾だけを持つ
    struct Partial {
        private(set) var bytes = 0
        private var data = Data()
        private var tail = Data()

        mutating func prepend(_ piece: Data.SubSequence) {
            guard !piece.isEmpty else { return }
            let before = bytes
            bytes += piece.count
            if before <= TranscriptParser.lineLimit, bytes > TranscriptParser.lineLimit {
                // ここで上限を超えた：今までの分の末尾を残す
                var kept = Data(piece.suffix(max(0, TranscriptFiles.tailBytes - data.count)))
                kept.append(data.suffix(TranscriptFiles.tailBytes))
                tail = Data(kept.suffix(TranscriptFiles.tailBytes))
            }
            var joined = Data(piece)
            joined.append(data)
            data = bytes > TranscriptParser.lineLimit ? Data(joined.prefix(TranscriptFiles.headBytes)) : joined
        }

        /// 行の頭を見た。空行なら nil
        mutating func close(offset: UInt64) -> [ChatMessage]? {
            defer { self = Partial() }
            guard bytes > 0 else { return nil }
            if bytes > TranscriptParser.lineLimit {
                return [TranscriptParser.large(TranscriptFiles.large(head: data, tail: tail, offset: offset), bytes: bytes, index: Int(offset))]
            }
            if case .messages(let messages) = TranscriptParser.parse(data, index: Int(offset), offset: offset) { return messages }
            return []
        }
    }
}
