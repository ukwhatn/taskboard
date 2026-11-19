import Foundation
import TaskboardKit

/// 1 つの transcript を読み終えた位置と、続きの行を数えるのに要る値
struct UsageCursor: Hashable, Sendable {
    var inode: UInt64
    var offset: UInt64
    /// これより前の時刻の行は数えない。途中から見つけた transcript（フォーク・再開で前の行を写したもの）の写した分を数え直さないため
    var countFrom: Date?
    /// Codex の今の model（turn_context が運び、続く token_count は運ばない）
    var model: String?
    /// Claude Code は 1 つの応答を content の塊ごとの行に分けて同じ usage を書くので、最後に数えた message の id
    var lastMessageID: String?
    /// Codex の累計のトークン。同じ累計の token_count が続いたら数えない
    var lastTotal: Int?
    /// Codex の直前の応答の入力（圧縮の直前の大きさに使う）
    var lastContext: Int?

    init(
        inode: UInt64, offset: UInt64, countFrom: Date? = nil, model: String? = nil, lastMessageID: String? = nil, lastTotal: Int? = nil,
        lastContext: Int? = nil
    ) {
        self.inode = inode
        self.offset = offset
        self.countFrom = countFrom
        self.model = model
        self.lastMessageID = lastMessageID
        self.lastTotal = lastTotal
        self.lastContext = lastContext
    }
}

/// 行から読み取ったもの。`UsageRecorder` が時間の区切りに集めて `UsageBatch` にする
struct UsageObservations: Equatable {
    struct Response: Equatable {
        var at: Date
        var engine: AgentKind
        var session: String
        var model: String
        var tokens: TokenCounts
        /// 本筋の応答の入力（サブエージェントの応答は nil）
        var context: Int?
        var cwd: String?
    }

    struct Event: Equatable {
        enum Kind: String { case skill, compaction }
        var at: Date
        var engine: AgentKind
        var session: String
        var kind: Kind
        var name: String
        var source: String?
        var before: Int?
        var after: Int?
    }

    var responses: [Response] = []
    var events: [Event] = []
    /// セッションの名前（Claude Code の custom-title。時刻を持たない行）
    var titles: [String: String] = [:]
    /// セッションの作業フォルダ（Codex の turn_context。Claude Code は応答の行が持つ）
    var cwds: [String: String] = [:]
}

/// 1 回の見回りで DB に書く分
struct UsageBatch {
    struct Token {
        var hour: Int64
        var engine: AgentKind
        var session: String
        var model: String
        var requests: Int
        var tokens: TokenCounts
    }

    struct Event {
        var at: Int64
        var engine: AgentKind
        var session: String
        var kind: UsageObservations.Event.Kind
        var name: String
        var source: String?
        var before: Int?
        var after: Int?
    }

    struct Session {
        var engine: AgentKind
        var session: String
        var cwd: String? = nil
        var title: String? = nil
        var firstAt: Int64? = nil
        var lastAt: Int64? = nil
        var maxContext: Int? = nil
    }

    var tokens: [Token] = []
    var events: [Event] = []
    var sessions: [Session] = []
    var samples: [UsageHistory.Sample] = []
    var cursors: [String: UsageCursor] = [:]

    var isEmpty: Bool { tokens.isEmpty && events.isEmpty && sessions.isEmpty && samples.isEmpty && cursors.isEmpty }
}

/// transcript の 1 行の読み方。行を JSON に開く前にバイト列で絞る（大きな行は開かない。Claude Code の api-request-blob は 1 行が数 MB ある）
enum UsageLines {
    /// Claude Code の行で数えるもの: assistant の usage と Skill の tool_use、人が打った `/名前`、compact_boundary、custom-title
    static func readClaude(_ line: Data, session fallback: String, cursor: inout UsageCursor, into out: inout UsageObservations, excludedCommands: Set<String>) {
        guard !line.starts(with: apiRequestPrefix), claudeNeedles.contains(where: { line.range(of: $0) != nil }),
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = object["type"] as? String
        else { return }
        let session = object["sessionId"] as? String ?? fallback
        if type == "custom-title" {
            if let title = object["customTitle"] as? String, !title.isEmpty { out.titles[session] = title }
            return
        }
        guard let at = timestamp(object["timestamp"]) else { return }
        if let from = cursor.countFrom, at < from { return }
        switch type {
        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" && block["name"] as? String == "Skill" {
                if let name = (block["input"] as? [String: Any])?["skill"] as? String, !name.isEmpty {
                    out.events.append(.init(at: at, engine: .claude, session: session, kind: .skill, name: name, source: UsageHistory.SkillSource.model.rawValue))
                }
            }
            let id = message["id"] as? String
            guard let usage = message["usage"] as? [String: Any], let model = message["model"] as? String, model != "<synthetic>",
                id == nil || id != cursor.lastMessageID
            else { return }
            cursor.lastMessageID = id
            let tokens = TokenCounts(
                input: int(usage["input_tokens"]), cacheWrite: int(usage["cache_creation_input_tokens"]), cacheRead: int(usage["cache_read_input_tokens"]),
                output: int(usage["output_tokens"]))
            let sidechain = object["isSidechain"] as? Bool ?? false
            out.responses.append(
                .init(
                    at: at, engine: .claude, session: session, model: model, tokens: tokens,
                    context: sidechain ? nil : tokens.input + tokens.cacheWrite + tokens.cacheRead, cwd: object["cwd"] as? String))
        case "user":
            guard let text = (object["message"] as? [String: Any])?["content"] as? String, let name = commandName(text), !excludedCommands.contains(name) else { return }
            out.events.append(.init(at: at, engine: .claude, session: session, kind: .skill, name: name, source: UsageHistory.SkillSource.command.rawValue))
        case "system":
            guard object["subtype"] as? String == "compact_boundary" else { return }
            let metadata = object["compactMetadata"] as? [String: Any]
            out.events.append(
                .init(
                    at: at, engine: .claude, session: session, kind: .compaction, name: metadata?["trigger"] as? String ?? "", source: nil,
                    before: optionalInt(metadata?["preTokens"]), after: optionalInt(metadata?["postTokens"])))
        default:
            return
        }
    }

    /// Codex の rollout の行で数えるもの: turn_context の model、token_count の直前の応答、compacted、SKILL.md を読むツールの呼び出し。
    /// セッションはファイル名の末尾の id（session_meta は先頭にしか無く、途中から読む rollout には無い）
    static func readCodex(_ line: Data, session: String, cursor: inout UsageCursor, into out: inout UsageObservations) {
        guard codexNeedles.contains(where: { line.range(of: $0) != nil }),
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = object["type"] as? String,
            let at = timestamp(object["timestamp"])
        else { return }
        let payload = object["payload"] as? [String: Any] ?? [:]
        if type == "turn_context" {
            if let model = payload["model"] as? String, !model.isEmpty { cursor.model = model }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { out.cwds[session] = cwd }
            return
        }
        if let from = cursor.countFrom, at < from { return }
        switch (type, payload["type"] as? String) {
        case ("event_msg", "token_count"):
            guard let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] else { return }
            let total = optionalInt((info["total_token_usage"] as? [String: Any])?["total_tokens"])
            if let total, total == cursor.lastTotal { return }
            cursor.lastTotal = total
            let input = int(last["input_tokens"]), cached = int(last["cached_input_tokens"])
            cursor.lastContext = input
            out.responses.append(
                .init(
                    at: at, engine: .codex, session: session, model: cursor.model ?? "",
                    tokens: TokenCounts(
                        input: max(0, input - cached), cacheWrite: int(last["cache_write_input_tokens"]), cacheRead: cached, output: int(last["output_tokens"])),
                    context: input, cwd: nil))
        case ("compacted", _):
            out.events.append(.init(at: at, engine: .codex, session: session, kind: .compaction, name: "", source: nil, before: cursor.lastContext, after: nil))
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
            let text = (payload["arguments"] as? String ?? "") + (payload["input"] as? String ?? "")
            for name in skillNames(text) {
                out.events.append(.init(at: at, engine: .codex, session: session, kind: .skill, name: name, source: UsageHistory.SkillSource.model.rawValue))
            }
        default:
            return
        }
    }

    /// rollout のファイル名（`rollout-2026-10-25T12-47-01-<uuid>.jsonl`）の末尾の id
    static func codexSession(fileName: String) -> String {
        let stem = fileName.hasSuffix(".jsonl") ? String(fileName.dropLast(6)) : fileName
        return stem.count > 36 ? String(stem.suffix(36)) : stem
    }

    /// `<command-name>/名前</command-name>` の名前
    static func commandName(_ text: String) -> String? {
        guard let start = text.range(of: "<command-name>"), let end = text.range(of: "</command-name>", range: start.upperBound..<text.endIndex) else { return nil }
        var name = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("/") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    /// ツールの呼び出しの中の `skills/<名前>/SKILL.md`（`.system/` の下の同梱の skill も）。1 回の呼び出しの中の同じ名前は 1 つに
    static func skillNames(_ text: String) -> [String] {
        var names: [String] = []
        var rest = text[...]
        while let marker = rest.range(of: "/SKILL.md") {
            let before = rest[rest.startIndex..<marker.lowerBound]
            if let slash = before.lastIndex(of: "/") {
                let name = String(before[before.index(after: slash)...])
                let parent = before[before.startIndex..<slash]
                if parent.hasSuffix("skills") || parent.hasSuffix("skills/.system"), !name.isEmpty, name.allSatisfy(isNameCharacter), !names.contains(name) {
                    names.append(name)
                }
            }
            rest = rest[marker.upperBound...]
        }
        return names
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" || c == "."
    }

    private static let apiRequestPrefix = Data(#"{"type":"api-request"#.utf8)
    private static let claudeNeedles = [#""type":"assistant""#, "compact_boundary", "<command-name>", #""type":"custom-title""#].map { Data($0.utf8) }
    private static let codexNeedles = [#""type":"token_count""#, #""type":"compacted""#, #""type":"turn_context""#, "SKILL.md"].map { Data($0.utf8) }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? Date(text, strategy: fractional)) ?? (try? Date(text, strategy: .iso8601))
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func int(_ value: Any?) -> Int { optionalInt(value) ?? 0 }

    private static func optionalInt(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
}
