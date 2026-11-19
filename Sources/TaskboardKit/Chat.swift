import Foundation

/// Claude Code の transcript から作ったチャットの 1 件。
/// daemon が transcript の 1 行を 0 件以上に分ける（assistant の 1 行に text と tool_use が並ぶため）
public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable { case user, assistant }

    public enum Kind: String, Codable, Hashable, Sendable {
        case text
        /// ツール呼び出し。`toolName` と `text`（入力の要約）
        case toolUse
        /// ツールの結果。`toolID` で呼び出しに結ぶ。`text` は先頭 `ChatMessage.resultLimit` バイトまで
        case toolResult
        /// 画像・大きすぎて読まなかった行など、中身を出さない印
        case notice
    }

    /// transcript の行の uuid + 行内の位置
    public var id: String
    public var role: Role
    public var kind: Kind
    public var text: String
    public var toolName: String?
    public var toolID: String?
    public var isError: Bool
    /// 切り詰める前のバイト数（切り詰めたときだけ）
    public var fullBytes: Int?
    public var at: Date?
    /// ツールの結果が読んだ・書いたファイル（`toolResult` だけ。Bash は 1 回で複数のファイルを変える）
    public var files: [ChatFile]?
    /// Claude Code が差し込んだ人の側の文（Skill の本文・貼った画像の置き場所・別のセッションからのメッセージ）。`isInjected` で読む。
    /// true のときだけ書く（前の版のアプリは鍵を知らず、人の発言として出す）
    public var injected: Bool?
    /// サブエージェントの中の発言とツールなら、それを起こした Agent の呼び出しの `toolID`。
    /// daemon は求めた接続（`subagents=1`）にだけ送る（前の版のアプリは鍵を知らず、本筋の発言として出す）
    public var parentToolID: String?
    /// 人の発言に添えた画像（`text` の人の発言だけ）。中身は載せず、中身の口が行を読み直して返す。前の版の daemon は「画像」の印の行で送る
    public var images: [ChatImage]?
    /// ツールの結果が「裏で続けている」なら、その裏のタスクの id（`toolResult` だけ。`run_in_background`・［今すぐ送信］で裏に回した Bash と Agent）
    public var backgroundTaskID: String?
    /// 会話を要約した所の印（`notice` だけ。transcript の `isCompactSummary` の行）。`isCompactSummary` で読む。
    /// true のときだけ書く（前の版のアプリは鍵を知らず、ほかの印と同じ 1 行で出す）
    public var compactSummary: Bool?
    /// アシスタントの思考（`text` の assistant だけ。transcript の thinking の block）。`isThinking` で読む。
    /// true のときだけ書く（前の版のアプリは鍵を知らず、返答の文として出す。`kind` を足さないのは、知らない kind を読んだ前の版が frame ごと読めなくなるため）
    public var thinking: Bool?

    public static let resultLimit = 4096

    public var isInjected: Bool { injected == true }

    public var isCompactSummary: Bool { compactSummary == true }

    public var isThinking: Bool { thinking == true }

    /// 人が送った文。ツールの結果と、Claude Code が差し込む文（印の `notice` と `isInjected`）は除く。
    /// daemon が transcript の行を `TranscriptParser.humanPrompt` の規則で読み、人でない行に `injected` を付けている
    public var isHumanPrompt: Bool { role == .user && kind == .text && !isInjected }

    public var isSubagent: Bool { parentToolID != nil }

    /// transcript の行の uuid（`id` の「#位置」の前。画像の中身の口に渡す）
    public var lineID: String { id.split(separator: "#", maxSplits: 1).first.map(String.init) ?? id }

    public init(
        id: String, role: Role, kind: Kind, text: String, toolName: String? = nil, toolID: String? = nil, isError: Bool = false,
        fullBytes: Int? = nil, at: Date? = nil, files: [ChatFile]? = nil, injected: Bool = false, parentToolID: String? = nil, images: [ChatImage]? = nil,
        backgroundTaskID: String? = nil, compactSummary: Bool = false, thinking: Bool = false
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolID = toolID
        self.isError = isError
        self.fullBytes = fullBytes
        self.at = at
        self.files = files
        self.injected = injected ? true : nil
        self.parentToolID = parentToolID
        self.images = images
        self.backgroundTaskID = backgroundTaskID
        self.compactSummary = compactSummary ? true : nil
        self.thinking = thinking ? true : nil
    }
}

/// 人の発言に添えた 1 枚の画像（`ChatMessage.images`）。中身は `GET /v1/chat/{pane_id}/images/{line_id}/{index}` か
/// `GET /v1/conversations/{id}/images/{line_id}/{index}` で取る
public struct ChatImage: Codable, Hashable, Sendable {
    /// 行の中の画像の順番（0 から）
    public var index: Int
    /// `image/png` など。大きくて行を読まなかった画像は分からない
    public var mediaType: String?
    /// base64 を解いた大きさ（バイト）。分からなければ nil
    public var bytes: Int?
    /// transcript の中の、この発言の行の頭の位置（中身の口の `at`）。生きている発言は 0（daemon が uuid で探す）
    public var offset: UInt64

    public init(index: Int, mediaType: String? = nil, bytes: Int? = nil, offset: UInt64) {
        self.index = index
        self.mediaType = mediaType
        self.bytes = bytes
        self.offset = offset
    }
}

/// `GET /v1/chat/{pane_id}`（WebSocket）でサーバが送る frame
public enum ChatFrame: Codable, Hashable, Sendable {
    /// 接続直後と、セッションが切り替わったとき。直近の会話（`ChatFrame.backlogLimit` 件まで）
    case backlog(sessionID: String, messages: [ChatMessage])
    case append([ChatMessage])
    /// チャットでは見せられない（transcript が無い・形式が変わった）。理由は `UnavailableReason` の値で、画面の文はアプリが組む
    case unavailable(String)

    public static let backlogLimit = 300

    /// `unavailable` の理由
    public enum UnavailableReason: String, Sendable {
        /// 会話の記録が見つからない
        case transcriptNotFound = "transcript_not_found"
        /// Claude Code のセッションではない
        case notClaude = "not_claude"
        /// 記録の形式が読めない
        case incompatible
    }

    private enum CodingKeys: String, CodingKey { case type, sessionID, messages, reason }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "backlog": self = .backlog(sessionID: try c.decode(String.self, forKey: .sessionID), messages: try c.decode([ChatMessage].self, forKey: .messages))
        case "append": self = .append(try c.decode([ChatMessage].self, forKey: .messages))
        case "unavailable": self = .unavailable(try c.decode(String.self, forKey: .reason))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown chat frame \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .backlog(let sessionID, let messages):
            try c.encode("backlog", forKey: .type)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(messages, forKey: .messages)
        case .append(let messages):
            try c.encode("append", forKey: .type)
            try c.encode(messages, forKey: .messages)
        case .unavailable(let reason):
            try c.encode("unavailable", forKey: .type)
            try c.encode(reason, forKey: .reason)
        }
    }
}
