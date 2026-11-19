import Foundation

/// transcript の行を uuid で引く（フォークと巻き戻しの地点）。末尾から `ConversationHistory.readLimit` までだけを読み、それより前は見ない
/// （200MB を超える transcript がある）
enum TranscriptLines {
    /// 会話の本筋（サブエージェントの行を除く）の 1 行
    struct Line: Equatable {
        var uuid: String
        var parentUUID: String?
        var type: String
        /// 行の頭の、transcript の中の位置
        var start: UInt64
        /// 行の終わり（改行の後ろ）の、transcript の中の位置
        var end: UInt64
        /// 人が送った発言の本文（ツールの結果・meta・コマンドの付記は nil）
        var prompt: String?
    }

    /// `uuid` の user か assistant の行。読む範囲（`upper` を渡せばその位置より前）に無ければ nil
    static func find(_ uuid: String, in url: URL, before upper: UInt64? = nil) -> Line? {
        let needle = Data(uuid.utf8)
        return scan(url, before: upper) { data in data.range(of: needle) != nil } where: { $0.uuid == uuid && isMessage($0) }
    }

    /// 写す地点（`--resume-session-at` に渡した行）。種別を問わない（巻き戻しの地点は戻す発言の親で、たいてい system か attachment の行）
    static func point(_ uuid: String, in url: URL) -> Line? {
        let needle = Data(uuid.utf8)
        return scan(url) { data in data.range(of: needle) != nil } where: { $0.uuid == uuid }
    }

    /// 末尾の user か assistant の行
    static func last(in url: URL) -> Line? {
        scan(url) { _ in true } where: { isMessage($0) }
    }

    /// `uuid` の行を transcript の全体から探す（末尾の 4MB に限らない。写し元の要約の区切りを引くときだけ使う）
    static func line(_ uuid: String, in url: URL) -> Line? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let needle = Data(uuid.utf8)
        var found: Line?
        reverseLines(handle, from: 0, to: size) { body, start, end in
            guard body.range(of: needle) != nil, let line = parse(body, start: start, end: end), line.uuid == uuid else { return false }
            found = line
            return true
        }
        return found
    }

    /// transcript の本筋の最初の行が要約の区切りなら、その uuid（フォーク・巻き戻しで CLI が要約の後だけを写した transcript）。
    /// 頭の 4MB に本筋の行が無ければ nil
    static func headBoundary(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        /// 本筋の行なら、区切りの uuid か nil を包んで返す。本筋の行でなければ nil
        func judge(_ body: Data) -> String?? {
            guard body.range(of: Data(#""uuid""#.utf8)) != nil, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                object["isSidechain"] as? Bool != true, let uuid = object["uuid"] as? String
            else { return nil }
            return .some(isBoundary(object) ? uuid : nil)
        }
        // 履歴を読むたびに呼ぶので、頭の行の分だけ読む（64KB から倍にして、読む上限まで）
        var data = Data()
        var start = 0
        var chunk = 64 * 1024
        while true {
            while let newline = data[start...].firstIndex(of: 0x0A) {
                defer { start = newline + 1 }
                if let found = judge(data[start..<newline]) { return found }
            }
            guard data.count < ConversationHistory.readLimit,
                let more = try? handle.read(upToCount: min(chunk, ConversationHistory.readLimit - data.count)), !more.isEmpty
            else { return start < data.endIndex ? judge(data[start...]) ?? nil : nil }
            data += more
            chunk *= 2
        }
    }

    /// `offset` より後に要約の区切りの行があるか（要約より前へは巻き戻さない）
    static func hasBoundary(in url: URL, after offset: UInt64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return false }
        let needle = Data("compact_boundary".utf8)
        var found = false
        reverseLines(handle, from: offset, to: size) { body, _, _ in
            guard body.range(of: needle) != nil, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                object["isSidechain"] as? Bool != true, isBoundary(object)
            else { return false }
            found = true
            return true
        }
        return found
    }

    private static func isBoundary(_ object: [String: Any]) -> Bool {
        object["type"] as? String == "system" && object["subtype"] as? String == "compact_boundary"
    }

    private static func isMessage(_ line: Line) -> Bool { line.type == "user" || line.type == "assistant" }

    /// 末尾から 1 行ずつ、`prefilter` が通った行だけを読んで、`match` に合った最初の行を返す。`upper` を渡すとその位置より前の 4MB を読む
    private static func scan(_ url: URL, before upper: UInt64? = nil, prefilter: (Data) -> Bool, where match: (Line) -> Bool) -> Line? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let size = min(upper ?? fileSize, fileSize)
        guard size > 0 else { return nil }
        let start = size > UInt64(ConversationHistory.readLimit) ? size - UInt64(ConversationHistory.readLimit) : 0
        var found: Line?
        // 読んだ範囲の頭の行は、前の部分が欠けているかもしれない
        reverseLines(handle, from: start, to: size, headIsLineStart: start == 0) { body, lineStart, lineEnd in
            guard prefilter(body), let line = parse(body, start: lineStart, end: lineEnd), match(line) else { return false }
            found = line
            return true
        }
        return found
    }

    /// `lower`〜`upper` の中の行を後ろから 1 行ずつ渡す（改行は含めない。`body` が true を返したら止める）。`upper` は行の頭か末尾。
    /// 1MB ずつ読み、`TranscriptParser.lineLimit` を超える行は渡さない（要約の区切りや地点の行は小さい）。
    /// `headIsLineStart` が false なら、`lower` から始まる最初の行は前が欠けているとみなして渡さない
    static func reverseLines(
        _ handle: FileHandle, from lower: UInt64, to upper: UInt64, headIsLineStart: Bool = true, _ body: (Data, _ start: UInt64, _ end: UInt64) -> Bool
    ) {
        var position = upper
        // 頭をまだ見ていない行の後ろの部分と、その行の終わり
        var tail = Data()
        var tailEnd = upper
        var oversized = false
        func prepend(_ piece: Data.SubSequence) {
            guard !oversized, !piece.isEmpty else { return }
            if tail.count + piece.count > TranscriptParser.lineLimit {
                oversized = true
                tail = Data()
            } else {
                tail.insert(contentsOf: piece, at: 0)
            }
        }
        while position > lower {
            let size = Int(min(UInt64(ConversationHistory.chunkBytes), position - lower))
            position -= UInt64(size)
            guard (try? handle.seek(toOffset: position)) != nil, let chunk = try? handle.read(upToCount: size), chunk.count == size else { return }
            var cut = chunk.endIndex
            while let newline = chunk[chunk.startIndex..<cut].lastIndex(of: 0x0A) {
                prepend(chunk[chunk.index(after: newline)..<cut])
                let lineStart = position + UInt64(newline - chunk.startIndex) + 1
                if !oversized, !tail.isEmpty, body(tail, lineStart, tailEnd) { return }
                tail = Data()
                oversized = false
                tailEnd = lineStart
                cut = newline
            }
            prepend(chunk[chunk.startIndex..<cut])
        }
        if headIsLineStart, !oversized, !tail.isEmpty { _ = body(tail, lower, tailEnd) }
    }

    static func parse(_ body: Data, start: UInt64, end: UInt64) -> Line? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let type = object["type"] as? String,
            object["isSidechain"] as? Bool != true, let uuid = object["uuid"] as? String
        else { return nil }
        return Line(
            uuid: uuid, parentUUID: object["parentUuid"] as? String, type: type, start: start, end: end, prompt: TranscriptParser.humanPrompt(object))
    }
}
