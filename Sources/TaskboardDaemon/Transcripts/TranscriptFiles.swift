import Foundation
import TaskboardKit

/// transcript の行の上位の `toolUseResult`（ツールごとに形が違う）から、読んだ・書いたファイルを取り出す。
/// チャットの行には要約（パス・diff・行の数）だけを載せ、全文と画像は中身の口（`content`）が行を読み直して返す
enum TranscriptFiles {
    // MARK: 行の要約

    /// 読めない形・ファイルに触れないツール（拒否の文字列、Bash の出力だけ、Agent など）は nil
    static func files(_ result: Any?, offset: UInt64) -> [ChatFile]? {
        guard let result = result as? [String: Any] else { return nil }
        if let diff = result["bashEditDiff"] as? [String: Any], let list = diff["files"] as? [[String: Any]] {
            let files = list.compactMap { entry -> ChatFile? in
                guard let path = entry["filePath"] as? String else { return nil }
                return edited(path, hunks(entry["hunks"]), offset: offset)
            }
            return files.isEmpty ? nil : files
        }
        let type = result["type"] as? String
        if type == "image", let file = result["file"] as? [String: Any] {
            let dimensions = file["dimensions"] as? [String: Any]
            let bytes = (file["originalSize"] as? Int) ?? (file["base64"] as? String).map { $0.utf8.count / 4 * 3 }
            return [
                ChatFile(
                    path: file["filePath"] as? String, action: .image, mediaType: file["type"] as? String, bytes: bytes,
                    width: dimensions?["originalWidth"] as? Int, height: dimensions?["originalHeight"] as? Int, offset: offset)
            ]
        }
        if type == "text", let file = result["file"] as? [String: Any], let path = file["filePath"] as? String {
            return [
                ChatFile(
                    path: path, action: .read, firstLine: file["startLine"] as? Int, lineCount: file["numLines"] as? Int,
                    totalLines: file["totalLines"] as? Int, offset: offset)
            ]
        }
        guard let path = result["filePath"] as? String else { return nil }
        if type == "create" {
            return [ChatFile(path: path, action: .created, added: ChatFile.lineCount(of: result["content"] as? String ?? ""), offset: offset)]
        }
        // Edit（type が無い）と Write の上書き（update）
        guard result["structuredPatch"] is [Any] else { return nil }
        return [edited(path, hunks(result["structuredPatch"]), offset: offset)]
    }

    private static func edited(_ path: String, _ hunks: [ChatDiffHunk], offset: UInt64) -> ChatFile {
        let bytes = hunks.reduce(0) { sum, hunk in sum + hunk.lines.reduce(0) { $0 + $1.utf8.count + 1 } }
        let omitted = bytes > ChatFile.hunkByteLimit
        return ChatFile(
            path: path, action: .edited, hunks: omitted ? [] : hunks, hunksOmitted: omitted, added: hunks.reduce(0) { $0 + $1.added },
            removed: hunks.reduce(0) { $0 + $1.removed }, offset: offset)
    }

    private static func hunks(_ raw: Any?) -> [ChatDiffHunk] {
        (raw as? [[String: Any]] ?? []).compactMap { hunk in
            guard let oldStart = hunk["oldStart"] as? Int, let newStart = hunk["newStart"] as? Int, let lines = hunk["lines"] as? [String] else {
                return nil
            }
            return ChatDiffHunk(
                oldStart: oldStart, oldLines: hunk["oldLines"] as? Int ?? 0, newStart: newStart, newLines: hunk["newLines"] as? Int ?? 0, lines: lines)
        }
    }

    // MARK: 読み飛ばした大きい行

    /// 読み飛ばす行の、先頭と末尾に持っておく大きさ
    static let headBytes = 16 * 1024
    static let tailBytes = 4 * 1024

    /// 読み飛ばした行の先頭と末尾から取れたもの。全体は JSON として解かない（画像の Read の行は 1MB を超える）
    struct LargeLine: Equatable {
        /// `message.content` の先頭の `tool_result` の id（行の先頭にある）
        var toolID: String?
        /// 結果が画像（`"content":[{"type":"image"`）なら、末尾の `toolUseResult.file` の種類・元の大きさ・幅と高さ
        var image: ChatFile?
        /// 画像を添えた人の発言の行。本文は先頭の text の block、uuid と時刻と画像の数（`imagePasteIds`）は末尾から取る
        var prompt: LargePrompt?
    }

    struct LargePrompt: Equatable {
        var uuid: String
        var text: String
        var at: String?
        var images: [ChatImage]
    }

    static func large(head: Data, tail: Data, offset: UInt64) -> LargeLine {
        let headBytes = head
        let head = String(decoding: head, as: UTF8.self)
        guard head.contains("\"type\":\"user\"") else { return LargeLine() }
        let toolID = first(#""tool_use_id":"([A-Za-z0-9_-]{1,128})""#, in: head)?.first
        if toolID == nil { return LargeLine(prompt: largePrompt(head: headBytes, tail: String(decoding: tail, as: UTF8.self), offset: offset)) }
        guard head.range(of: #""content":\[\{"type":"image""#, options: .regularExpression) != nil else { return LargeLine(toolID: toolID) }
        let tail = String(decoding: tail, as: UTF8.self)
        // 末尾の file の鍵。`"media_type"` は `"type"` の前が `_` なので当たらない
        func number(_ key: String) -> Int? { first(#""\#(key)":([0-9]+)"#, in: tail)?.first.flatMap { Int($0) } }
        return LargeLine(
            toolID: toolID,
            image: ChatFile(
                path: nil, action: .image, mediaType: first(#""type":"(image/[a-z0-9.+-]+)""#, in: tail)?.first, bytes: number("originalSize"),
                width: number("originalWidth"), height: number("originalHeight"), offset: offset))
    }

    /// 画像を添えた人の発言の本文（`"content":[{"type":"text","text":"…"`）。本文が先頭に収まらない・Claude Code が差し込んだ行・uuid が無ければ nil
    private static func largePrompt(head: Data, tail: String, offset: UInt64) -> LargePrompt? {
        let opening = Data(#""content":[{"type":"text","text":""#.utf8)
        guard head.range(of: Data(#""type":"image""#.utf8)) != nil, let start = head.range(of: opening), !tail.contains(#""isMeta":true"#),
            let uuid = first(#","uuid":"([0-9A-Za-z-]{8,80})""#, in: tail)?.first
        else { return nil }
        // 開きの引用符から、エスケープされていない閉じの引用符まで
        let quote = start.upperBound - 1
        var index = start.upperBound
        while index < head.endIndex, head[index] != UInt8(ascii: "\"") { index = head.index(index, offsetBy: head[index] == UInt8(ascii: "\\") ? 2 : 1) }
        guard index < head.endIndex, let text = try? JSONSerialization.jsonObject(with: head[quote...index], options: .fragmentsAllowed) as? String else { return nil }
        let pasted = first(#""imagePasteIds":\[([0-9,]*)\]"#, in: tail)?.first.map { $0.split(separator: ",").count } ?? 0
        let count = max(pasted, 1)
        return LargePrompt(
            uuid: uuid, text: text, at: first(#""timestamp":"([^"]+)""#, in: tail)?.first,
            images: (0..<count).map { ChatImage(index: $0, offset: offset) })
    }

    /// 人の発言の行（`uuid` の user の行か、ターンの途中に取り込まれた発言の attachment）の `index` 番目の画像
    static func userImage(line: Data, uuid: String, index: Int) -> Body? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let blocks: [[String: Any]]?
        if object["type"] as? String == "user", object["uuid"] as? String == uuid {
            blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
        } else if let attachment = object["attachment"] as? [String: Any], attachment["source_uuid"] as? String == uuid {
            blocks = attachment["prompt"] as? [[String: Any]]
        } else {
            return nil
        }
        let images = (blocks ?? []).filter { $0["type"] as? String == "image" }
        guard images.indices.contains(index), let source = images[index]["source"] as? [String: Any],
            let data = (source["data"] as? String).flatMap({ Data(base64Encoded: $0) }), !data.isEmpty
        else { return nil }
        let declared = (source["media_type"] as? String).flatMap { $0.hasPrefix("image/") ? $0 : nil }
        return .image(data, contentType: ChatAttachment.ImageType(sniffing: data)?.mimeType ?? declared ?? "application/octet-stream")
    }

    /// `offset`（履歴の行の位置）が合えばそこを読み、合わなければ（生きている発言）末尾から uuid の字で探す
    static func userImage(in url: URL, uuid: String, index: Int, at offset: UInt64?) -> Body? {
        if let offset, let line = line(in: url, at: offset), let body = userImage(line: line, uuid: uuid, index: index) { return body }
        var found: Body?
        for needle in [#""uuid":"\#(uuid)""#, #""source_uuid":"\#(uuid)""#] {
            lineStarts(containing: Data(needle.utf8), in: url) { start in
                found = line(in: url, at: start).flatMap { userImage(line: $0, uuid: uuid, index: index) }
                return found != nil
            }
            if found != nil { break }
        }
        return found
    }

    /// 最初の一致の、括弧の中身
    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    // MARK: 中身の口

    enum Body: Equatable {
        /// 読んだ文・書いた文・変える前の全文
        case text(String)
        /// unified diff（`ChatDiffHunk.unified`）
        case diff(String)
        case image(Data, contentType: String)
    }

    /// 1 行の上限（画像の Read で実測 1.3MB。base64 が 2 つ入る）
    static let readLimit = 64 << 20

    /// `offset` から始まる行。行の頭でない位置・上限を超える行・ファイルの外は nil
    static func line(in url: URL, at offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if offset > 0 {
            guard (try? handle.seek(toOffset: offset - 1)) != nil, let before = try? handle.read(upToCount: 1), before == Data([0x0A]) else { return nil }
        }
        var line = Data()
        while line.count < readLimit {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex..<newline])
                return line
            }
            line.append(chunk)
        }
        return line.count < readLimit && !line.isEmpty ? line : nil
    }

    /// 結果の行（`toolID` の `tool_result` を持つ user の行）から、頼まれた部分を返す。行が違う・その部分が無ければ nil。
    /// Bash で複数のファイルを変えたときは `path` で選ぶ（無ければ最初のファイル）
    static func content(line: Data, toolID: String, path: String?, part: ChatFile.Part) -> Body? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["type"] as? String == "user",
            let message = object["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]],
            let block = blocks.first(where: { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == toolID }),
            let result = object["toolUseResult"] as? [String: Any]
        else { return nil }
        if part == .original {
            return (result["originalFile"] as? String).map(Body.text)
        }
        if let diff = result["bashEditDiff"] as? [String: Any], let list = diff["files"] as? [[String: Any]] {
            guard let entry = list.first(where: { path == nil || $0["filePath"] as? String == path }) else { return nil }
            return .diff(ChatDiffHunk.unified(hunks(entry["hunks"])))
        }
        switch result["type"] as? String {
        case "image":
            let file = result["file"] as? [String: Any]
            let encoded = (file?["base64"] as? String) ?? imageSource(block)
            guard let data = encoded.flatMap({ Data(base64Encoded: $0) }), !data.isEmpty else { return nil }
            let declared = (file?["type"] as? String).flatMap { $0.hasPrefix("image/") ? $0 : nil }
            return .image(data, contentType: ChatAttachment.ImageType(sniffing: data)?.mimeType ?? declared ?? "application/octet-stream")
        case "text":
            return ((result["file"] as? [String: Any])?["content"] as? String).map(Body.text)
        case "create":
            return (result["content"] as? String).map(Body.text)
        default:
            guard result["structuredPatch"] is [Any] else { return nil }
            return .diff(ChatDiffHunk.unified(hunks(result["structuredPatch"])))
        }
    }

    /// `toolID` の結果の行から頼まれた部分を返す。`offset`（履歴の行の位置）が合えばそこを読み、
    /// 合わなければ（host の会話の生きている発言は位置を持たない）末尾から `tool_use_id` の字を探す
    static func content(in url: URL, toolID: String, at offset: UInt64?, path: String?, part: ChatFile.Part) -> Body? {
        if let offset, let line = line(in: url, at: offset), let body = content(line: line, toolID: toolID, path: path, part: part) { return body }
        var found: Body?
        lineStarts(containing: Data(#""tool_use_id":"\#(toolID)""#.utf8), in: url) { start in
            found = line(in: url, at: start).flatMap { content(line: $0, toolID: toolID, path: path, part: part) }
            return found != nil
        }
        return found
    }

    /// `needle` を含む行の頭の位置を、末尾の行から順に `visit` に渡す。`visit` が true を返したらやめる。
    /// 読むのは一致した行の頭までで、全体は持たない（200MB を超える transcript がある）。`readLimit` を超える行は飛ばす
    static func lineStarts(containing needle: Data, in url: URL, chunk: Int = 1 << 20, visit: (UInt64) -> Bool) {
        guard !needle.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard var position = try? handle.seekToEnd() else { return }
        // transcript の [position, position + window.count)。window の後ろは見終えている
        var window = Data()
        // 一致した位置（window の中）。行の頭を探している間だけ持つ
        var match: Int?
        while true {
            if match == nil {
                if let found = window.range(of: needle, options: .backwards) {
                    match = found.lowerBound
                } else {
                    // 前のチャンクとまたいで一致する分だけ残す
                    window = Data(window.prefix(needle.count - 1))
                }
            }
            if let at = match {
                if let newline = window[..<at].lastIndex(of: 0x0A) {
                    if visit(position + UInt64(newline + 1)) { return }
                    window = Data(window[..<newline])
                    match = nil
                    continue
                }
                if position == 0 {
                    _ = visit(0)
                    return
                }
                if window.count > readLimit {
                    window = Data(window.prefix(at))
                    match = nil
                    continue
                }
            }
            guard position > 0 else { return }
            let size = Int(min(UInt64(chunk), position))
            position -= UInt64(size)
            guard (try? handle.seek(toOffset: position)) != nil, let piece = try? handle.read(upToCount: size), piece.count == size else { return }
            window = piece + window
            if let at = match { match = at + size }
        }
    }

    /// `toolUseResult` に base64 が無いときは、モデルに渡した画像（`tool_result` の中の image）を使う
    private static func imageSource(_ block: [String: Any]) -> String? {
        (block["content"] as? [[String: Any]])?.lazy.compactMap { ($0["source"] as? [String: Any])?["data"] as? String }.first
    }
}
