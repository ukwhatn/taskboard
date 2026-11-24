import Foundation
import TaskboardKit

/// Claude Code の transcript（JSONL）の 1 行をチャットのメッセージにする。
///
/// 読むのは `type` が user / assistant の行と、ターンの途中に取り込まれた発言（attachment の `queued_command`）だけで、それ以外（ほかの attachment・mode・file-history など）は黙って捨てる。
/// Claude Code は行の種別をよく足すので、未知の種別を数えても互換性の判定にならない。
/// 判定に使うのは「user / assistant なのに `message` を読めない行」（`incompatible`）
enum TranscriptParser {
    /// これを超える行は読まずに印だけ出す（実測で tool_result の 1 行が 1.28 MB あった。読むとそれだけで止まる）
    static let lineLimit = 1 << 20

    enum Line: Equatable {
        case messages([ChatMessage])
        case ignored
        case incompatible
    }

    /// `offset` は行の頭の、transcript の中の位置（ファイルの情報に載せ、中身の口が行を読み直す）。
    /// `sidechain` はサブエージェントの transcript を読むとき（行がみな `isSidechain`）
    static func parse(_ line: Data, index: Int, offset: UInt64 = 0, sidechain: Bool = false) -> Line {
        if line.count > lineLimit {
            let found = TranscriptFiles.large(head: line.prefix(TranscriptFiles.headBytes), tail: line.suffix(TranscriptFiles.tailBytes), offset: offset)
            return .messages([large(found, bytes: line.count, index: index)])
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return .ignored }
        if object["type"] as? String == "attachment" {
            if !sidechain, object["isSidechain"] as? Bool == true { return .ignored }
            return absorbed(object, offset: offset).map { .messages($0) } ?? .ignored
        }
        return parse(object: object, index: index, offset: offset, sidechain: sidechain)
    }

    /// ターンの途中に CLI が取り込んだ発言。transcript には user の行が無く、`attachment` の `queued_command` で残る。
    /// id は送った発言の uuid（`source_uuid`）にし、送った側の手元の発言と同じものと分かるようにする。
    /// stream-json の経路（`parse(object:)`）では読まない（同じ発言を user の行で受けたときに 2 つ出さない）
    private static func absorbed(_ object: [String: Any], offset: UInt64) -> [ChatMessage]? {
        guard let attachment = object["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
            attachment["commandMode"] as? String == "prompt", let source = attachment["source_uuid"] as? String
        else { return nil }
        let injected = !isHumanLine(attachment)
        let at = (object["timestamp"] as? String).flatMap(parseDate)
        if let text = attachment["prompt"] as? String {
            return userText(text, id: source, at: at).map { [marked($0, injected: injected)] } ?? []
        }
        guard let blocks = attachment["prompt"] as? [[String: Any]] else { return nil }
        let messages = blocks.enumerated().compactMap { i, block -> ChatMessage? in
            guard block["type"] as? String == "text" else { return nil }
            return (block["text"] as? String).flatMap { userText($0, id: "\(source)#\(i)", at: at) }.map { marked($0, injected: injected) }
        }
        return withImages(messages, blocks: blocks, lineID: source, at: at, offset: offset)
    }

    /// base64 を解いた大きさ（解かずに数える。末尾の = の分を引く）
    private static func decodedSize(_ base64: String) -> Int {
        base64.utf8.count / 4 * 3 - base64.utf8.suffix(2).filter { $0 == UInt8(ascii: "=") }.count
    }

    /// 人の発言の行の画像の block を、その行の最初の人の文に添える（文が無ければ、画像だけの発言にする）。base64 は載せない
    private static func withImages(_ messages: [ChatMessage], blocks: [[String: Any]], lineID: String, at: Date?, offset: UInt64) -> [ChatMessage] {
        let images = blocks.filter { $0["type"] as? String == "image" }.enumerated().map { index, block in
            let source = block["source"] as? [String: Any]
            return ChatImage(
                index: index, mediaType: source?["media_type"] as? String, bytes: (source?["data"] as? String).map(decodedSize), offset: offset)
        }
        guard !images.isEmpty else { return messages }
        var messages = messages
        if let first = messages.firstIndex(where: { $0.kind == .text }) {
            messages[first].images = images
        } else {
            let position = blocks.firstIndex { $0["type"] as? String == "image" } ?? 0
            messages.append(ChatMessage(id: "\(lineID)#\(position)", role: .user, kind: .text, text: "", at: at, images: images))
        }
        return messages
    }

    /// 読んだ後の 1 行。stream-json の出力の `user`・`assistant` も transcript と同じ形なので、`ClaudeStreamParser` もここを通す
    static func parse(object: [String: Any], index: Int, offset: UInt64 = 0, sidechain: Bool = false) -> Line {
        guard let type = object["type"] as? String else { return .ignored }
        guard type == "system" || type == "user" || type == "assistant" else { return .ignored }
        if !sidechain, object["isSidechain"] as? Bool == true { return .ignored }
        if type == "system" {
            if object["subtype"] as? String == "compact_boundary" { return .messages([compactBoundary(object, index: index)]) }
            return localCommand(object, index: index)
        }
        let injected = type == "user" && !isHumanLine(object)
        let uuid = object["uuid"] as? String ?? "line-\(index)"
        let at = (object["timestamp"] as? String).flatMap(parseDate)
        if type == "assistant", let output = object["local_command_source"] as? String {
            return .messages(localCommandOutput(output, outcome: object["local_command_outcome"] as? [String: Any], uuid: uuid, at: at))
        }
        guard let message = object["message"] as? [String: Any] else { return .incompatible }
        // 区切りは直前の要約の区切りの行（`compactBoundary`）が出す
        if object["isCompactSummary"] as? Bool == true { return .ignored }
        if type == "assistant" {
            guard let blocks = message["content"] as? [[String: Any]] else { return .incompatible }
            // 送り直しを諦めた API の誤りの文。transcript は `isApiErrorMessage`、stream-json は `is_api_error_message`
            let apiError = object["isApiErrorMessage"] as? Bool == true || object["is_api_error_message"] as? Bool == true
            return .messages(assistant(blocks, uuid: uuid, at: at, apiError: apiError))
        }
        if let text = message["content"] as? String {
            return .messages(userText(text, id: uuid, at: at).map { [marked($0, injected: injected)] } ?? [])
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return .incompatible }
        var result: [ChatMessage] = []
        // 行の toolUseResult は 1 つなので、最初の tool_result に結ぶ。stream-json では同じ形が `tool_use_result` で届く（2.1.304 で実測）
        let toolUseResult = object["toolUseResult"] ?? object["tool_use_result"]
        var files = TranscriptFiles.files(toolUseResult, offset: offset)
        var backgroundTaskID = backgroundTaskID(toolUseResult)
        for (i, block) in blocks.enumerated() {
            let id = "\(uuid)#\(i)"
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, let m = userText(text, id: id, at: at) { result.append(m) }
            case "tool_result":
                let (text, full) = clip(resultText(block["content"]))
                result.append(
                    ChatMessage(
                        id: id, role: .user, kind: .toolResult, text: text, toolID: block["tool_use_id"] as? String,
                        isError: block["is_error"] as? Bool ?? false, fullBytes: full, at: at, files: files, backgroundTaskID: backgroundTaskID))
                files = nil
                backgroundTaskID = nil
            default:
                continue
            }
        }
        return .messages(withImages(result.map { marked($0, injected: injected) }, blocks: blocks, lineID: uuid, at: at, offset: offset))
    }

    /// local コマンド（`/usage`・`/reload-plugins` など、モデルを呼ばず CLI が答えるもの）の出力。stream-json のライブでは `assistant` の行
    /// （`local_command_source`）、transcript では `system/local_command` の行（`content`）で、uuid は同じ。
    /// 打った文だけの行（`content` が印で包まれていない）は、人の発言の行が別にあるので読まない
    /// 要約の区切りの行（transcript の `compactMetadata`、stream-json の `compact_metadata`）を区切りの印にする。id は行の uuid で、
    /// 生きている会話（`ClaudeStream`）と transcript で同じ。数は前後が揃ったときだけ出す
    static func compactBoundary(_ object: [String: Any], index: Int) -> ChatMessage {
        let metadata = (object["compactMetadata"] ?? object["compact_metadata"]) as? [String: Any] ?? [:]
        let before = (metadata["preTokens"] ?? metadata["pre_tokens"]) as? Int
        let after = (metadata["postTokens"] ?? metadata["post_tokens"]) as? Int
        let text = ConversationScreenText.compacted(automatic: metadata["trigger"] as? String == "auto", tokens: before.flatMap { b in after.map { (b, $0) } })
        return ChatMessage(
            id: object["uuid"] as? String ?? "line-\(index)", role: .user, kind: .notice, text: text,
            at: (object["timestamp"] as? String).flatMap(parseDate), compactSummary: true)
    }

    private static func localCommand(_ object: [String: Any], index: Int) -> Line {
        guard object["subtype"] as? String == "local_command", let content = object["content"] as? String else { return .ignored }
        let uuid = object["uuid"] as? String ?? "line-\(index)"
        let at = (object["timestamp"] as? String).flatMap(parseDate)
        return .messages(localCommandOutput(content, outcome: object["commandOutcome"] as? [String: Any], uuid: uuid, at: at))
    }

    /// CLI の `local_command_outcome` の kind の型（2.1.304）。`unavailable_headless` 以外は出た文をそのまま出し、これに無い kind は読み飛ばす
    private static let outcomeKinds: Set<String> = ["unavailable_headless", "unknown", "failed", "restart_required"]

    /// 出力が空（`/clear`）なら発言にしない。id はライブの assistant の text block と同じ `<uuid>#0`
    private static func localCommandOutput(_ raw: String, outcome: [String: Any]?, uuid: String, at: Date?) -> [ChatMessage] {
        let kind = outcome?["kind"] as? String
        if let kind, !outcomeKinds.contains(kind) { return [] }
        guard let text = tagContent("local-command-stdout", in: withoutTerminalControls(raw)) else { return [] }
        let id = "\(uuid)#0"
        guard kind == "unavailable_headless" else { return [ChatMessage(id: id, role: .assistant, kind: .text, text: text, at: at)] }
        return [ChatMessage(id: id, role: .assistant, kind: .notice, text: unavailableNotice(text), at: at)]
    }

    /// TUI の transcript の出力には、色と太字の SGR（CSI）やリンクの OSC が入る。CSI・OSC（BEL か ESC \ で終わる）・単独の ESC を外す
    private static func withoutTerminalControls(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(
            of: "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{7}\u{1B}]*(?:\u{7}|\u{1B}\\\\)?|\u{1B}", with: "", options: .regularExpression)
    }

    /// CLI の文は「/theme isn't available in this environment.」。コマンド名だけ取り、英語の文は出さない
    private static func unavailableNotice(_ output: String) -> String {
        guard let name = output.split(separator: " ").first, name.hasPrefix("/"), name.count > 1 else { return ConversationScreenText.commandUnavailable }
        return "「\(name)」は\(ConversationScreenText.commandUnavailable)"
    }

    /// 結果が裏で続けている tool の裏のタスクの id。Bash は `backgroundTaskId`、Agent は `status` が `async_launched` の `agentId`（2.1.304 で実測）
    private static func backgroundTaskID(_ toolUseResult: Any?) -> String? {
        guard let result = toolUseResult as? [String: Any] else { return nil }
        if let id = result["backgroundTaskId"] as? String { return id }
        return result["status"] as? String == "async_launched" ? result["agentId"] as? String : nil
    }

    /// 差し込んだ行の文に印を付ける。印（中断・裏の作業の終わり）とツールの結果はそのまま
    private static func marked(_ message: ChatMessage, injected: Bool) -> ChatMessage {
        guard injected, message.kind == .text else { return message }
        var message = message
        message.injected = true
        return message
    }

    private static func assistant(_ blocks: [[String: Any]], uuid: String, at: Date?, apiError: Bool) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for (i, block) in blocks.enumerated() {
            let id = "\(uuid)#\(i)"
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(ChatMessage(id: id, role: .assistant, kind: .text, text: text, isError: apiError, at: at))
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                result.append(
                    ChatMessage(
                        id: id, role: .assistant, kind: .toolUse, text: toolSummary(name: name, input: block["input"] as? [String: Any] ?? [:]),
                        toolName: name, toolID: block["id"] as? String, at: at))
            case "thinking":
                // 署名だけで中身の空の thinking は捨てる
                guard let text = block["thinking"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(ChatMessage(id: id, role: .assistant, kind: .text, text: text, at: at, thinking: true))
            default:
                continue
            }
        }
        return result
    }

    /// 読み飛ばした行の印。tool_result の行なら呼び出しに結び（印の文は結果の欄に出る）、画像ならファイルの情報も載せる
    static func large(_ found: TranscriptFiles.LargeLine, bytes: Int, index: Int) -> ChatMessage {
        if let prompt = found.prompt {
            let at = prompt.at.flatMap(parseDate)
            var message = userText(prompt.text, id: "\(prompt.uuid)#0", at: at) ?? ChatMessage(id: "\(prompt.uuid)#0", role: .user, kind: .text, text: "", at: at)
            if message.kind == .text { message.images = prompt.images }
            return message
        }
        let text = String(format: "大きい出力（%.1fMB）を省きました", Double(bytes) / 1_048_576)
        guard let toolID = found.toolID else {
            return ChatMessage(id: "large-\(index)", role: .user, kind: .notice, text: text, fullBytes: bytes)
        }
        return ChatMessage(id: "large-\(index)", role: .user, kind: .toolResult, text: text, toolID: toolID, files: found.image.map { [$0] })
    }

    /// 人が送った発言の本文。人の行（`isHumanLine`）で、サブエージェントの行でなく、content が文字列か text・image の block だけのもので、
    /// 印でない文（`userText` が text にするもの）。Stop hook のターンの始まり・フォークと巻き戻しの地点・履歴の印は、みなこれで見分ける
    static func humanPrompt(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "user", object["isSidechain"] as? Bool != true, isHumanLine(object),
            let message = object["message"] as? [String: Any]
        else { return nil }
        let text: String
        if let content = message["content"] as? String {
            text = content
        } else if let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty {
            guard blocks.allSatisfy({ ($0["type"] as? String) == "text" || ($0["type"] as? String) == "image" }) else { return nil }
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return nil
        }
        guard let message = userText(text, id: "", at: nil), message.kind == .text else { return nil }
        return message.text
    }

    /// 行の印で見て、人が送った行か。Claude Code が差し込んだ行（transcript の isMeta、stream-json の isSynthetic、
    /// origin が人でないもの）と圧縮の要約は人の行でない。origin の human は端末で打った文、plugin は前の版の taskboard の mod が人の発言として入れた文
    static func isHumanLine(_ object: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true || object["isSynthetic"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return false }
        guard let origin = object["origin"] as? [String: Any] else { return true }
        return ["human", "plugin"].contains(origin["kind"] as? String)
    }

    /// 人が打った文。Claude Code が差し込む文（system-reminder・コマンドの付記・通知）は印にするか捨てる
    static func userText(_ raw: String, id: String, at: Date?) -> ChatMessage? {
        let text = stripTag("system-reminder", from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<local-command-caveat>") || text.hasPrefix("<local-command-stdout>") { return nil }
        if let name = tagContent("command-name", in: text) {
            let args = tagContent("command-args", in: text) ?? ""
            return ChatMessage(id: id, role: .user, kind: .text, text: args.isEmpty ? name : "\(name) \(args)", at: at)
        }
        if RunResultText.isResult(text) {
            return ChatMessage(id: id, role: .user, kind: .notice, text: ConversationScreenText.runResultSent, at: at)
        }
        if text.hasPrefix("<task-notification>") {
            return ChatMessage(id: id, role: .user, kind: .notice, text: tagContent("summary", in: text) ?? "バックグラウンドタスクが終わりました", at: at)
        }
        if text.hasPrefix("[Request interrupted") { return ChatMessage(id: id, role: .user, kind: .notice, text: "中断しました", at: at) }
        // 画像を添えた発言の直後に Claude Code が差し込む `[Image: source: <パス>]`。画像は発言の縮小版（`ChatMessage.images`）で出す
        if text.hasPrefix("[Image:") { return nil }
        return ChatMessage(id: id, role: .user, kind: .text, text: text, at: at)
    }

    /// ツール呼び出しの 1 行要約。よく使うツールは要の引数を、それ以外は入力の JSON の先頭を出す
    static func toolSummary(name: String, input: [String: Any]) -> String {
        let keys = ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt", "skill"]
        if let key = keys.first(where: { input[$0] is String }), let value = input[key] as? String {
            return String(value.prefix(300))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
        return String(String(decoding: data, as: UTF8.self).prefix(300))
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.map { block in
            if let text = block["text"] as? String { return text }
            return block["type"] as? String == "image" ? "[画像]" : ""
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// UTF-8 の文字の途中で切らない
    static func clip(_ text: String) -> (String, Int?) {
        let bytes = text.utf8.count
        guard bytes > ChatMessage.resultLimit else { return (text, nil) }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: ChatMessage.resultLimit)
        while end > text.utf8.startIndex, String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return (String(text[..<end]), bytes)
    }

    private static func stripTag(_ tag: String, from text: String) -> String {
        guard text.contains("<\(tag)>") else { return text }
        return text.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
    }

    private static func tagContent(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else { return nil }
        let value = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
