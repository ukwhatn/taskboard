import Foundation

/// 会話をまたいだ全文検索の 1 件（`GET /v1/conversations/search`）。会話ごとに、一致した最新の発言を 1 つ返す
public struct ConversationSearchHit: Codable, Hashable, Sendable {
    public var conversationID: String
    public var messageID: String
    public var role: ChatMessage.Role
    public var at: Date?
    /// 一致の前後を 1 行に縮めた抜粋（`ConversationSearchQuery.snippet`）
    public var snippet: String
    /// この会話で一致した発言の数
    public var matches: Int

    public init(conversationID: String, messageID: String, role: ChatMessage.Role, at: Date?, snippet: String, matches: Int) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.role = role
        self.at = at
        self.snippet = snippet
        self.matches = matches
    }
}

public struct ConversationSearchResponse: Codable, Hashable, Sendable {
    /// 一致の新しい順
    public var hits: [ConversationSearchHit]
    /// 索引を作っている途中で、まだ載っていない会話がある
    public var indexing: Bool

    public static let defaultLimit = 20
    public static let maxLimit = 100
    public static let maxQueryLength = 200

    public init(hits: [ConversationSearchHit], indexing: Bool) {
        self.hits = hits
        self.indexing = indexing
    }
}

/// 会話をまたいで検索できる供給元（daemon と fixtures）
public protocol ConversationSearchSource: Sendable {
    func searchConversations(query: String, limit: Int) async throws -> ConversationSearchResponse
}

/// 検索の語の切り方と抜粋。daemon の索引と fixtures の検索が同じ規則で一致を決める
public enum ConversationSearchQuery {
    /// 語の上限。これより後ろの語は捨てる
    public static let termLimit = 8

    /// 空白（全角を含む）で区切った語。すべてを含む発言が一致する
    public static func terms(_ query: String) -> [String] {
        Array(query.split(whereSeparator: \.isWhitespace).map(String.init).prefix(termLimit))
    }

    /// 発言がすべての語を含むか（大文字と小文字を区別しない）
    public static func matches(_ text: String, terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// 検索に載せる発言：人の発言とアシスタントの返答の文。ツール・印・思考・差し込まれた文・サブエージェントの中は載せない
    public static func indexes(_ message: ChatMessage) -> Bool {
        message.kind == .text && !message.isInjected && !message.isThinking && !message.isSubagent
            && !message.text.allSatisfy(\.isWhitespace)
    }

    /// 最初の語の最初の一致の前を `before` 字、後ろを合わせて `length` 字ほど残し、改行と続く空白を 1 つの空白にした 1 行。
    /// 切った側には「…」を付ける
    public static func snippet(_ text: String, terms: [String], before: Int = 24, length: Int = 120) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let first = terms.first, let match = flat.range(of: first, options: .caseInsensitive) else {
            return flat.count > length ? String(flat.prefix(length)) + "…" : flat
        }
        let start = flat.index(match.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}
