import Foundation
import TaskboardKit

/// Agent の呼び出しで起きたサブエージェントの transcript（`<transcript の名前>/subagents/agent-<id>.jsonl`）を、
/// 呼び出しの `toolID` に結んで読む。結びは同じ名前の `agent-<id>.meta.json` の `toolUseId`。
/// 親の transcript にはサブエージェントの行が入らない（Claude Code 2.1.303 で実測）。
/// サブエージェントの中の Agent の呼び出し（入れ子）も同じ置き場に並ぶので、読んだ発言の中の呼び出しも続けて結ぶ
struct SubagentTranscripts {
    /// 1 つのサブエージェントを初めて読むときの、末尾の大きさと件数
    static let tailBytes = 1 << 20
    static let messageLimit = 200
    static let agentToolNames: Set<String> = ["Agent", "Task"]
    /// 入れ子を続けて結ぶ深さ
    private static let depthLimit = 4

    private struct Followed {
        var url: URL
        var offset: UInt64
        var cursor: TranscriptCursor
    }

    private let directory: URL
    /// 覚えた Agent の呼び出しのうち、まだ transcript を読み始めていないもの
    private var waiting: Set<String> = []
    private var followed: [String: Followed] = [:]
    /// `toolUseId` → サブエージェントの transcript。読んだ meta のファイル名と、読んだときの置き場の更新日時
    private var index: [String: URL] = [:]
    private var scannedMeta: Set<String> = []
    private var scannedAt: Date?

    /// `transcript` は親の会話の transcript
    init(transcript: URL) {
        directory = transcript.deletingPathExtension().appendingPathComponent("subagents")
    }

    /// `messages`（親の transcript から読んだ発言）の中の Agent の呼び出しを覚え、覚えた呼び出しのサブエージェントの発言のうち、
    /// まだ返していないものを返す。新しく見つけたサブエージェントは末尾の `tailBytes`・`messageLimit` 件まで
    mutating func read(after messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var incoming = messages
        for _ in 0..<Self.depthLimit {
            remember(incoming)
            incoming = readOnce()
            result += incoming
            guard incoming.contains(where: Self.isAgentCall) else { break }
        }
        return result
    }

    private static func isAgentCall(_ message: ChatMessage) -> Bool {
        message.kind == .toolUse && message.toolID != nil && agentToolNames.contains(message.toolName ?? "")
    }

    private mutating func remember(_ messages: [ChatMessage]) {
        for message in messages where Self.isAgentCall(message) {
            guard let toolID = message.toolID, followed[toolID] == nil else { continue }
            waiting.insert(toolID)
        }
    }

    private mutating func readOnce() -> [ChatMessage] {
        var result: [ChatMessage] = []
        if !waiting.isEmpty {
            rescan()
            for toolID in waiting {
                guard let url = index[toolID], let started = Self.start(url, parentToolID: toolID) else { continue }
                waiting.remove(toolID)
                followed[toolID] = started.0
                result += started.1
            }
        }
        for (toolID, follow) in followed {
            var follow = follow
            let messages = Self.grow(&follow)
            if !messages.isEmpty {
                followed[toolID] = follow
                result += messages
            }
        }
        return result
    }

    /// 置き場が変わっていたら、まだ読んでいない meta を読む
    private mutating func rescan() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
        guard let modified, modified != scannedAt else { return }
        scannedAt = modified
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".meta.json") && !scannedMeta.contains(name) {
            let meta = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: meta),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let toolID = object["toolUseId"] as? String
            else { continue }
            scannedMeta.insert(name)
            index[toolID] = directory.appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
        }
    }

    private static func start(_ url: URL, parentToolID: String) -> (Followed, [ChatMessage])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.read(upToCount: Int(size - start))) ?? Data()
        var lineStart = start
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            lineStart = start + UInt64(newline - data.startIndex) + 1
            data = data[data.index(after: newline)...]
        }
        var follow = Followed(url: url, offset: size, cursor: TranscriptCursor(offset: lineStart, parentToolID: parentToolID))
        let messages = follow.cursor.feed(data)
        return (follow, Array(messages.suffix(messageLimit)))
    }

    private static func grow(_ follow: inout Followed) -> [ChatMessage] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: follow.url.path))?[.size] as? UInt64, size > follow.offset,
            let handle = try? FileHandle(forReadingFrom: follow.url)
        else { return [] }
        defer { try? handle.close() }
        var messages: [ChatMessage] = []
        while follow.offset < size {
            try? handle.seek(toOffset: follow.offset)
            guard let data = try? handle.read(upToCount: min(TranscriptTail.chunkBytes, Int(size - follow.offset))), !data.isEmpty else { break }
            follow.offset += UInt64(data.count)
            messages += follow.cursor.feed(data)
        }
        return messages
    }
}

extension ChatMessage {
    /// サブエージェントの中の発言にする。ファイルの情報は外す（中身の口は親の transcript の位置で読む）。
    /// 行の uuid を持たない id（読み飛ばした行の印）は、ほかの transcript の印と重ならないよう呼び出しの id を前に付ける
    func inSubagent(_ parentToolID: String) -> ChatMessage {
        var message = self
        message.parentToolID = parentToolID
        message.files = nil
        if id.hasPrefix("large-") || id.hasPrefix("line-") { message.id = "\(parentToolID)/\(id)" }
        return message
    }
}
