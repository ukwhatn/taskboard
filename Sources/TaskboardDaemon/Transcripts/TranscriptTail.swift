import Foundation
import Logging
import TaskboardKit

/// 読んだバイト列を行に切ってメッセージにする。行の途中で切れた分は次に持ち越し、上限を超える行は溜めずに読み飛ばす。
/// 行の頭の位置（ファイルの中のバイト）を数え、ツールの結果のファイルの情報に載せる
struct TranscriptCursor {
    private struct Skipped {
        var bytes: Int
        var head: Data
        var tail: Data
    }

    private var pending = Data()
    /// 上限を超えた行を読み飛ばしている間の、その行のバイト数と先頭・末尾
    private var skipping: Skipped?
    private var lineIndex = 0
    private(set) var incompatible = 0
    /// 次に読むバイトの、ファイルの中の位置
    private(set) var position: UInt64
    /// 読みかけの行の頭の位置（ここまでの行は読み終えた）
    private(set) var lineStart: UInt64
    private var tools = ToolPaths()
    /// サブエージェントの transcript を読むときの、起こした Agent の呼び出しの id
    private let parentToolID: String?

    /// `offset` は最初に渡すバイトの、ファイルの中の位置（行の頭）
    init(offset: UInt64 = 0, parentToolID: String? = nil) {
        position = offset
        lineStart = offset
        self.parentToolID = parentToolID
    }

    mutating func feed(_ chunk: Data) -> [ChatMessage] {
        let messages = read(chunk)
        guard let parentToolID else { return messages }
        return messages.map { $0.inSubagent(parentToolID) }
    }

    private mutating func read(_ chunk: Data) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let base = position
        position += UInt64(chunk.count)
        var rest = chunk[...]
        while !rest.isEmpty {
            guard let newline = rest.firstIndex(of: 0x0A) else {
                if var skipped = skipping {
                    skipped.bytes += rest.count
                    skipped.tail = Self.tail(skipped.tail, rest)
                    skipping = skipped
                } else if pending.count + rest.count > TranscriptParser.lineLimit {
                    var line = pending
                    line.append(contentsOf: rest)
                    skipping = Skipped(bytes: line.count, head: line.prefix(TranscriptFiles.headBytes), tail: Self.tail(Data(), line))
                    pending = Data()
                } else {
                    pending.append(contentsOf: rest)
                }
                break
            }
            let piece = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            lineIndex += 1
            let start = lineStart
            lineStart = base + UInt64(newline - chunk.startIndex) + 1
            if var skipped = skipping {
                skipping = nil
                skipped.bytes += piece.count
                skipped.tail = Self.tail(skipped.tail, piece)
                messages += tools.resolve([large(skipped, offset: start)])
                continue
            }
            var line = pending
            line.append(contentsOf: piece)
            pending = Data()
            if line.isEmpty { continue }
            if line.count > TranscriptParser.lineLimit {
                let skipped = Skipped(bytes: line.count, head: line.prefix(TranscriptFiles.headBytes), tail: line.suffix(TranscriptFiles.tailBytes))
                messages += tools.resolve([large(skipped, offset: start)])
                continue
            }
            switch TranscriptParser.parse(line, index: lineIndex, offset: start, sidechain: parentToolID != nil) {
            case .messages(let m): messages += tools.resolve(m)
            case .ignored: break
            case .incompatible: incompatible += 1
            }
        }
        return messages
    }

    /// 読み飛ばした Read の文の結果には、読んだことだけを載せる（中身は口が行を全部読んで返す）
    private func large(_ skipped: Skipped, offset: UInt64) -> ChatMessage {
        var message = TranscriptParser.large(
            TranscriptFiles.large(head: skipped.head, tail: skipped.tail, offset: offset), bytes: skipped.bytes, index: lineIndex)
        if message.files == nil, let toolID = message.toolID, let call = tools.call(toolID), call.name == "Read" {
            message.files = [ChatFile(path: call.path, action: .read, offset: offset)]
        }
        return message
    }

    private static func tail(_ kept: Data, _ more: Data.SubSequence) -> Data {
        var tail = kept
        tail.append(contentsOf: more.suffix(TranscriptFiles.tailBytes))
        return tail.count > TranscriptFiles.tailBytes ? Data(tail.suffix(TranscriptFiles.tailBytes)) : tail
    }
}

/// ツールの呼び出しの入力のパス（tool_use の id ごと）。画像の Read の結果と読み飛ばした大きい行は、結果の側にパスが無い
struct ToolPaths {
    static let limit = 256
    private var paths: [String: (name: String, path: String)] = [:]
    private var order: [String] = []

    func call(_ toolID: String) -> (name: String, path: String)? { paths[toolID] }

    /// 呼び出しを覚え、結果のファイルの情報に無いパスを入れる
    mutating func resolve(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            var message = message
            guard let toolID = message.toolID else { return message }
            switch message.kind {
            case .toolUse:
                // toolSummary が file_path を要約に取るツールだけ
                if let name = message.toolName, ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name), message.text.hasPrefix("/") {
                    remember(toolID, name: name, path: message.text)
                }
            case .toolResult:
                guard let call = paths[toolID], var files = message.files else { break }
                for i in files.indices where files[i].path == nil { files[i].path = call.path }
                message.files = files
            default:
                break
            }
            return message
        }
    }

    private mutating func remember(_ toolID: String, name: String, path: String) {
        if paths.updateValue((name, path), forKey: toolID) == nil { order.append(toolID) }
        if order.count > Self.limit { paths[order.removeFirst()] = nil }
    }
}

/// 解いた transcript の末尾を、WebSocket の外で持つ（daemon に 1 つ）。チャットを開くたびに末尾 4MB を解き直すと、
/// 大きいセッションで最初の frame まで 1 秒を超えた。持っているファイルは増えた分だけを解く
actor TranscriptCache {
    struct Snapshot: Sendable {
        /// ここまで読んだ（`cursor` はこの位置の続きを読む）
        var offset: UInt64
        var cursor: TranscriptCursor
        /// 直近 `ChatFrame.backlogLimit` 件
        var messages: [ChatMessage]
    }

    static let entryLimit = 32
    private var entries: [String: (snapshot: Snapshot, usedAt: UInt64)] = [:]
    private var clock: UInt64 = 0

    /// ファイルの今の末尾まで読んだ状態。縮んだファイル（書き直し）は初めから読み直す。開けなければ nil
    func snapshot(of url: URL) -> Snapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var snapshot: Snapshot
        if let cached = entries[url.path]?.snapshot, cached.offset <= size {
            snapshot = cached
        } else {
            let start = size > UInt64(TranscriptTail.backlogBytes) ? size - UInt64(TranscriptTail.backlogBytes) : 0
            try? handle.seek(toOffset: start)
            var data = (try? handle.read(upToCount: Int(size - start))) ?? Data()
            var lineStart = start
            if start > 0, let newline = data.firstIndex(of: 0x0A) {
                lineStart = start + UInt64(newline - data.startIndex) + 1
                data = data[data.index(after: newline)...]
            }
            var cursor = TranscriptCursor(offset: lineStart)
            let messages = cursor.feed(data)
            let fresh = Snapshot(offset: size, cursor: cursor, messages: Array(messages.suffix(ChatFrame.backlogLimit)))
            remember(url, fresh)
            return fresh
        }
        var appended: [ChatMessage] = []
        while snapshot.offset < size {
            try? handle.seek(toOffset: snapshot.offset)
            guard let data = try? handle.read(upToCount: min(TranscriptTail.chunkBytes, Int(size - snapshot.offset))), !data.isEmpty else { break }
            snapshot.offset += UInt64(data.count)
            appended += snapshot.cursor.feed(data)
        }
        if !appended.isEmpty { snapshot.messages = Array((snapshot.messages + appended).suffix(ChatFrame.backlogLimit)) }
        remember(url, snapshot)
        return snapshot
    }

    private func remember(_ url: URL, _ snapshot: Snapshot) {
        clock += 1
        entries[url.path] = (snapshot, clock)
        if entries.count > Self.entryLimit, let oldest = entries.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
            entries[oldest] = nil
        }
    }
}

/// pane の Claude Code セッションの transcript を追いかけ、チャットの frame にする（WebSocket 1 本に 1 つ）。
///
/// - path は session id から `<projects>/*/<id>.jsonl` を引く。projects の外は開かない
/// - 接続直後は直近 `ChatFrame.backlogLimit` 件を `backlog` で送り（`TranscriptCache`。初めて読むファイルは末尾 `backlogBytes` から）、以後は増えた分を `append` で送る
/// - session id が変わる（`/clear`・resume）かファイルが縮んだら開き直して `backlog` を送り直す
/// - user / assistant なのに読めない行が `incompatibleLimit` を超えたら `unavailable` を送って止まる（アプリは端末表示に戻す）
/// - `includesSubagents` なら、送った Agent の呼び出しのサブエージェントの発言も送る（`SubagentTranscripts`。backlog の件数の上限に数えない）
actor TranscriptTail {
    static let backlogBytes = 4 << 20
    /// 1 回の読み取りの上限（追いつくまで繰り返す）
    static let chunkBytes = 2 << 20
    static let incompatibleLimit = 20

    private let projects: URL
    private let sessionID: @Sendable () async -> String?
    private let interval: Duration
    private let cache: TranscriptCache
    private let includesSubagents: Bool
    private let logger = Logger(label: "uk.whatn.taskboardd.transcript")

    init(
        projects: URL, interval: Duration = .milliseconds(500), cache: TranscriptCache = TranscriptCache(), includesSubagents: Bool = false,
        sessionID: @escaping @Sendable () async -> String?
    ) {
        self.projects = projects.standardizedFileURL.resolvingSymlinksInPath()
        self.interval = interval
        self.cache = cache
        self.includesSubagents = includesSubagents
        self.sessionID = sessionID
    }

    /// session id から transcript を探す。id は UUID の形だけ受ける（path に混ぜるため）
    nonisolated func locate(_ id: String) -> URL? {
        Self.locate(id, in: projects)
    }

    /// `projects` は standardize と symlink の解決を済ませたもの
    static func locate(_ id: String, in projects: URL) -> URL? {
        guard id.range(of: "^[0-9A-Za-z-]{8,80}$", options: .regularExpression) != nil else { return nil }
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(id).jsonl").resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(projects.path + "/"), FileManager.default.fileExists(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }

    func run(_ send: @Sendable (ChatFrame) async throws -> Void) async throws {
        var current: (id: String, url: URL, handle: FileHandle, offset: UInt64, cursor: TranscriptCursor, subagents: SubagentTranscripts?)?
        var reported: String?
        defer { try? current?.handle.close() }
        while !Task.isCancelled {
            let id = await sessionID()
            if current?.id != id {
                try? current?.handle.close()
                current = nil
            }
            if current == nil, let id {
                if let url = locate(id), let handle = try? FileHandle(forReadingFrom: url), let snapshot = await cache.snapshot(of: url) {
                    var subagents = includesSubagents ? SubagentTranscripts(transcript: url) : nil
                    let children = subagents?.read(after: snapshot.messages) ?? []
                    current = (id, url, handle, snapshot.offset, snapshot.cursor, subagents)
                    reported = nil
                    try await send(.backlog(sessionID: id, messages: snapshot.messages + children))
                } else if reported != id {
                    reported = id
                    try await send(.unavailable(ChatFrame.UnavailableReason.transcriptNotFound.rawValue))
                }
            } else if id == nil, reported != "" {
                reported = ""
                try await send(.unavailable(ChatFrame.UnavailableReason.notClaude.rawValue))
            }
            if var open = current, open.cursor.incompatible <= Self.incompatibleLimit {
                let size = (try? FileManager.default.attributesOfItem(atPath: open.url.path)[.size] as? UInt64) ?? open.offset
                if size < open.offset {
                    // 書き直された。次の周回で開き直す
                    try? open.handle.close()
                    current = nil
                    continue
                }
                var appended: [ChatMessage] = []
                while open.offset < size {
                    try? open.handle.seek(toOffset: open.offset)
                    guard let data = try? open.handle.read(upToCount: min(Self.chunkBytes, Int(size - open.offset))), !data.isEmpty else { break }
                    open.offset += UInt64(data.count)
                    appended += open.cursor.feed(data)
                }
                if var subagents = open.subagents {
                    appended += subagents.read(after: appended)
                    open.subagents = subagents
                }
                current = open
                if !appended.isEmpty { try await send(.append(appended)) }
                if open.cursor.incompatible > Self.incompatibleLimit {
                    logger.warning("transcript format changed", metadata: ["session": .string(open.id)])
                    try await send(.unavailable(ChatFrame.UnavailableReason.incompatible.rawValue))
                }
            }
            try await Task.sleep(for: interval)
        }
    }
}
