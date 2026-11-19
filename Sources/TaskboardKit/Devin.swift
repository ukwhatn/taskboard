import Foundation

/// Devin のセッション。タスクのリンクのうち `…/sessions/<id>` の形の URL（`app.devin.ai`・`*.devinenterprise.com`）を daemon が巡回する（`DevinSync`）。
/// リンクの種類（`TaskLink.Kind`）は `other` のまま、URL の形で見分ける（種類を足すと、古いアプリが state を読めなくなる）
public enum DevinSession {
    /// URL の `<id>`（`devin-` を除いた 16 進）。Devin のセッションの URL でなければ nil
    public static func id(fromURL url: String) -> String? {
        guard let parsed = URL(string: url), let host = parsed.host(), host == "app.devin.ai" || host.hasSuffix(".devinenterprise.com") else { return nil }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "sessions" else { return nil }
        return normalized(parts[1])
    }

    /// `devin-<id>`・`<id>`・URL のどれかから `<id>`。読めなければ nil
    public static func id(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return id(fromURL: trimmed) }
        return normalized(trimmed)
    }

    /// API の session_id（`devin-<id>`）
    public static func apiID(_ id: String) -> String { "devin-" + id }

    private static func normalized(_ raw: String) -> String? {
        let id = raw.hasPrefix("devin-") ? String(raw.dropFirst("devin-".count)) : raw
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return id.lowercased()
    }
}

/// Devin のセッションの今の様子（`GET /v1/sessions/{id}`）。カードのチップと知らせに使う
public struct DevinLinkState: Codable, Hashable, Sendable {
    /// Devin の `status_enum`。知らない値もそのまま持つ
    public var status: String
    public var title: String
    public var pullRequestURL: String?

    public init(status: String, title: String = "", pullRequestURL: String? = nil) {
        self.status = status
        self.title = title
        self.pullRequestURL = pullRequestURL
    }

    public enum Phase: Sendable {
        case working
        /// Devin が返答を待っている（作業を終えて報告した後も、この状態で待つ）
        case waiting
        case finished
        case expired
        /// 止める・戻すの途中など
        case other
    }

    public var phase: Phase {
        switch status {
        case "working", "resumed", "resume_requested", "resume_requested_frontend": .working
        case "blocked": .waiting
        case "finished": .finished
        case "expired": .expired
        default: .other
        }
    }
}

/// `POST /v1/devin/sessions`：Devin のセッションを作り、タスクにリンクする
public struct DevinStartRequest: Codable, Hashable, Sendable {
    public var prompt: String
    public var title: String?
    public var tags: [String]
    /// 使ってよい ACU の上限（必須。省くと org の上限まで使いうる）
    public var maxAcuLimit: Int
    public var taskNumber: Int?
    /// devin.json のアカウントの名前（org）。省くとタスクの案件に割り当てたアカウント
    public var account: String?

    public init(prompt: String, title: String? = nil, tags: [String] = [], maxAcuLimit: Int, taskNumber: Int? = nil, account: String? = nil) {
        self.prompt = prompt
        self.title = title
        self.tags = tags
        self.maxAcuLimit = maxAcuLimit
        self.taskNumber = taskNumber
        self.account = account
    }
}

public struct DevinStarted: Codable, Hashable, Sendable {
    /// `<id>`（`devin-` を除く）
    public var sessionID: String
    public var url: String
    /// 同じプロンプトのセッションが既にあり、それを返した（Devin の `idempotent`）
    public var existing: Bool
    public var link: AutoLinkResult?
    /// 作ったアカウントの名前
    public var account: String

    public init(sessionID: String, url: String, existing: Bool, link: AutoLinkResult?, account: String) {
        self.sessionID = sessionID
        self.url = url
        self.existing = existing
        self.link = link
        self.account = account
    }
}

/// `GET /v1/devin/sessions/{id}`：様子と、最後のほうの発言（古い順）
public struct DevinSessionDetail: Codable, Hashable, Sendable {
    public struct Message: Codable, Hashable, Sendable {
        /// `devin_message`・`user_message`・`initial_user_message` など
        public var type: String
        public var text: String
        public var at: String?
        /// 長すぎて切った
        public var clipped: Bool

        public init(type: String, text: String, at: String?, clipped: Bool) {
            self.type = type
            self.text = text
            self.at = at
            self.clipped = clipped
        }
    }

    public var sessionID: String
    public var url: String?
    public var state: DevinLinkState
    public var messages: [Message]
    /// 載せなかった古い発言の数
    public var omitted: Int
    /// 通ったアカウントの名前
    public var account: String?

    public init(sessionID: String, url: String?, state: DevinLinkState, messages: [Message], omitted: Int, account: String? = nil) {
        self.account = account
        self.sessionID = sessionID
        self.url = url
        self.state = state
        self.messages = messages
        self.omitted = omitted
    }
}

/// `POST /v1/devin/sessions/{id}/message`
public struct DevinMessageRequest: Codable, Hashable, Sendable {
    public var message: String

    public init(message: String) { self.message = message }
}

public struct DevinMessageSent: Codable, Hashable, Sendable {
    /// 届かなかった理由（止まっているセッションなど。Devin の `detail`）。届けば nil
    public var refused: String?

    public init(refused: String?) { self.refused = refused }
}
