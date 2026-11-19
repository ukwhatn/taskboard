import Foundation

/// アプリのイベントの 1 行（JSON Lines）。種類（`type`）ごとに使う欄だけを埋め、使わない欄は書かない
struct AppEvent: Codable, Equatable, Sendable {
    var at: Date
    /// `session.switch` など
    var type: String
    /// 1 回の操作（切替 1 回）の行を束ねる
    var id: String
    var machine: String?
    var pane: String?
    /// `terminal` / `chat`
    var mode: String?
    var stage: String?
    /// 前の段階からの ms
    var ms: Int?
    /// 束ねた最初の行からの ms
    var totalMS: Int?
    /// 前に開いた端末・会話を持ち越した
    var reused: Bool?

    enum CodingKeys: String, CodingKey {
        case at, type, id, machine, pane, mode, stage, ms, reused
        case totalMS = "total_ms"
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init(
        at: Date, type: String, id: String, machine: String? = nil, pane: String? = nil, mode: String? = nil, stage: String? = nil, ms: Int? = nil,
        totalMS: Int? = nil, reused: Bool? = nil
    ) {
        self.at = at
        self.type = type
        self.id = id
        self.machine = machine
        self.pane = pane
        self.mode = mode
        self.stage = stage
        self.ms = ms
        self.totalMS = totalMS
        self.reused = reused
    }

    // JSONEncoder の `.iso8601` は秒までしか書かず、ms の差を後から引けない
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try Self.dateStyle.parse(container.decode(String.self, forKey: .at))
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        machine = try container.decodeIfPresent(String.self, forKey: .machine)
        pane = try container.decodeIfPresent(String.self, forKey: .pane)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        stage = try container.decodeIfPresent(String.self, forKey: .stage)
        ms = try container.decodeIfPresent(Int.self, forKey: .ms)
        totalMS = try container.decodeIfPresent(Int.self, forKey: .totalMS)
        reused = try container.decodeIfPresent(Bool.self, forKey: .reused)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at.formatted(Self.dateStyle), forKey: .at)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(machine, forKey: .machine)
        try container.encodeIfPresent(pane, forKey: .pane)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(stage, forKey: .stage)
        try container.encodeIfPresent(ms, forKey: .ms)
        try container.encodeIfPresent(totalMS, forKey: .totalMS)
        try container.encodeIfPresent(reused, forKey: .reused)
    }

    /// 改行で終わる 1 行
    func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

/// アプリのイベントを残す。直近の分はメモリに持って debug の `/state` に出し、ファイルにも 1 行ずつ書く
@MainActor
final class EventLog {
    static let recentLimit = 50
    private(set) var recent: [AppEvent] = []
    private let writer: EventLogWriter?

    /// `writer` が nil ならファイルに書かない
    init(writer: EventLogWriter?) {
        self.writer = writer
    }

    /// ユーザーのアプリは support ディレクトリの `taskboard/logs/app-events.jsonl` に書く。
    /// fixtures・test host・snapshot test（`AppDefaults.isScratch`）は書かない。確かめるたびに、ユーザーのアプリのログに確かめた分が混ざるため
    static func standard() -> EventLog {
        guard !AppDefaults.isScratch, let directory = standardDirectory() else { return EventLog(writer: nil) }
        return EventLog(writer: EventLogWriter(directory: directory))
    }

    /// macOS では daemon と同じ `logs/`（daemon のログは `taskboardd.*.log` で、名前は重ならない）。iOS はアプリの container の中
    static func standardDirectory() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return support.appending(path: "taskboard/logs", directoryHint: .isDirectory)
    }

    var fileURL: URL? { writer?.currentFile }

    func record(_ event: AppEvent) {
        recent.append(event)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        guard let writer, let line = try? event.line() else { return }
        writer.append(line)
    }

    /// DebugServer の `/state` 用。新しいものが後ろ
    var debugDescription: [Any] {
        recent.compactMap { event in (try? event.line()).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    }
}

/// JSON Lines のファイルに追記する。書き込みは専用の直列キューで行い、メインスレッドを待たせない。
/// `maxBytes` を超える行を書く前に回し、`generations` 世代（今のファイルを含む）まで残す
final class EventLogWriter: @unchecked Sendable {
    let directory: URL
    let name: String
    let maxBytes: Int
    let generations: Int
    private let queue = DispatchQueue(label: "uk.whatn.taskboard.event-log", qos: .utility)
    // 以下は queue の中だけで触る
    private var handle: FileHandle?
    private var size = 0

    init(directory: URL, name: String = "app-events", maxBytes: Int = 5 << 20, generations: Int = 3) {
        self.directory = directory
        self.name = name
        self.maxBytes = maxBytes
        self.generations = max(1, generations)
    }

    var currentFile: URL { file(generation: 0) }

    /// 0 が今のファイル。1 から古い順に `<name>.1.jsonl`・`<name>.2.jsonl`
    func file(generation: Int) -> URL {
        directory.appending(path: generation == 0 ? "\(name).jsonl" : "\(name).\(generation).jsonl")
    }

    func append(_ line: Data) {
        queue.async { self.write(line) }
    }

    /// 積んだ書き込みが終わるまで待つ（テスト用）
    func flush() {
        queue.sync {}
    }

    private func write(_ line: Data) {
        if handle == nil { open() }
        if size > 0, size + line.count > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: line)
            size += line.count
        } catch {
            // 次の行で開き直す（ディスクが一杯・ファイルを消された）
            try? handle.close()
            self.handle = nil
        }
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = currentFile
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: file(generation: generations - 1))
        for generation in stride(from: generations - 2, through: 0, by: -1) {
            try? manager.moveItem(at: file(generation: generation), to: file(generation: generation + 1))
        }
        open()
    }
}
