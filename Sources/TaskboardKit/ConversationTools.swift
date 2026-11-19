import Foundation

/// 会話の作業フォルダの差分の要約（`Conversation.diff`）。git の外なら `isRepo` が false で、ほかは 0
public struct ConversationDiffSummary: Codable, Hashable, Sendable {
    public var isRepo: Bool
    public var branch: String?
    public var files: Int
    public var insertions: Int
    public var deletions: Int

    public init(isRepo: Bool, branch: String? = nil, files: Int = 0, insertions: Int = 0, deletions: Int = 0) {
        self.isRepo = isRepo
        self.branch = branch
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// `mcp_status` の 1 server。CLI の応答から daemon が決めた項目だけを写す（設定の env・headers と、server が返した失敗の文は入れない）
public struct ConversationMcpServer: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// connected・failed・needs-auth・pending・disabled（CLI の値のまま。知らない値もそのまま）
    public var status: String
    /// 設定の置き場（user・project・local・plugin など）
    public var scope: String?
    public var source: String?
    /// 繋がった server が名乗った名前と版
    public var serverName: String?
    public var serverVersion: String?
    public var toolCount: Int?
    /// 繋ぎ方（設定の `type`：stdio・http・sse・claudeai-proxy など。CLI の値のまま）
    public var transport: String?
    /// 設定で有効か（codex の `mcp_servers.<名前>.enabled`。書いていなければ有効）。Claude は `status` の disabled で表す
    public var enabled: Bool?

    public var id: String { name }

    public init(
        name: String, status: String, scope: String? = nil, source: String? = nil, serverName: String? = nil, serverVersion: String? = nil,
        toolCount: Int? = nil, transport: String? = nil, enabled: Bool? = nil
    ) {
        self.name = name
        self.status = status
        self.scope = scope
        self.source = source
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.toolCount = toolCount
        self.transport = transport
        self.enabled = enabled
    }
}

/// `control` の `mcp_status` の `payloadJSON`
public struct ConversationMcpStatus: Codable, Hashable, Sendable {
    public var mcpServers: [ConversationMcpServer]

    public init(mcpServers: [ConversationMcpServer]) {
        self.mcpServers = mcpServers
    }
}

/// `control` の `mcp_authenticate` の `payloadJSON`。認証の URL は要求した端末への応答にだけ載せる
public struct ConversationMcpAuthentication: Codable, Hashable, Sendable {
    /// 開く認証のページ。開かなくてよい server（認証が済んでいた）は nil
    public var authURL: String?
    public var requiresUserAction: Bool
    /// CLI が localhost の callback を待っている。別の端末では、認証の後に開いたページのアドレスを `mcp_oauth_callback` で渡す
    public var callbackExpected: Bool

    public init(authURL: String?, requiresUserAction: Bool, callbackExpected: Bool) {
        self.authURL = authURL
        self.requiresUserAction = requiresUserAction
        self.callbackExpected = callbackExpected
    }
}

/// コネクタの認証で扱う URL の確かめ。アプリが開く URL と、daemon が CLI に渡す callback の URL
public enum OAuthLinks {
    public static let callbackLimit = 4096
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost"]

    /// 開いてよい認証のページ：https か、127.0.0.1・localhost の http で、userinfo が無い
    public static func openable(_ string: String) -> URL? {
        guard let components = URLComponents(string: string), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
            !host.isEmpty, components.user == nil, components.password == nil
        else { return nil }
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)) else { return nil }
        return components.url
    }

    /// CLI に渡してよい callback：127.0.0.1・localhost の http、userinfo と fragment が無く、query に state と（code か error）があり、4KB まで。
    /// 貼った文の前後の空白と改行は落とす
    public static func callback(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= callbackLimit, let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "http",
            let host = components.host?.lowercased(), loopbackHosts.contains(host), components.user == nil, components.password == nil,
            components.fragment == nil
        else { return nil }
        let items = components.queryItems ?? []
        func has(_ name: String) -> Bool { items.contains { $0.name == name && !($0.value ?? "").isEmpty } }
        guard has("state"), has("code") || has("error") else { return nil }
        return components.url
    }

    /// 認証のページの `redirect_uri`（127.0.0.1・localhost の http で port のあるもの）と `state`。別の端末のアプリは、この port で戻りを受ける
    public static func redirect(of page: URL) -> OAuthRedirect? {
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let value = items.first(where: { $0.name == "redirect_uri" })?.value, let state = items.first(where: { $0.name == "state" })?.value,
            !state.isEmpty, let components = URLComponents(string: value), components.scheme?.lowercased() == "http",
            let host = components.host?.lowercased(), loopbackHosts.contains(host), components.port != nil, let address = components.url
        else { return nil }
        return OAuthRedirect(address: address, state: state)
    }

    /// 戻り先に届いた要求の target（`/callback?code=…&state=…`）を、戻り先のアドレスの callback に組み直す。
    /// path が戻り先と違うか、state が認証のページと違えば nil
    public static func callback(requestTarget: String, redirect: OAuthRedirect) -> URL? {
        guard requestTarget.hasPrefix("/"), var components = URLComponents(url: redirect.address, resolvingAgainstBaseURL: false),
            let target = URLComponents(string: requestTarget), target.path == components.path,
            target.queryItems?.first(where: { $0.name == "state" })?.value == redirect.state
        else { return nil }
        components.percentEncodedQuery = target.percentEncodedQuery
        return components.url.flatMap { callback($0.absoluteString) }
    }
}

/// 認証のページが戻りを待つアドレスと、その認証の state
public struct OAuthRedirect: Equatable, Sendable {
    public let address: URL
    public let state: String

    public init(address: URL, state: String) {
        self.address = address
        self.state = state
    }
}

/// 会話の `/` で使えるコマンド（CLI の `initialize` の `commands`）。名前と alias の解決は CLI がする
public struct ConversationCommand: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var argumentHint: String?
    /// Claude Code の組み込みと同梱の skill
    public var builtin: Bool?
    /// 同じコマンドの別名（`clear` の `reset`・`new` など）
    public var aliases: [String]?

    public var id: String { name }

    public init(name: String, description: String, argumentHint: String? = nil, builtin: Bool? = nil, aliases: [String]? = nil) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.builtin = builtin
        self.aliases = aliases
    }
}

/// `GET /v1/conversations/{id}/commands`
public struct ConversationCommandsResponse: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// 動いている（か前に動いた）プロセスが知らせた一覧
        case session
        /// プロセスから受けていないので、`.claude` の skill と command だけを読んだ一覧（組み込みは入らない）
        case catalog
    }

    public var commands: [ConversationCommand]
    public var source: Source

    public init(commands: [ConversationCommand], source: Source) {
        self.commands = commands
        self.source = source
    }
}

/// `POST /v1/conversations/{id}/fork`。同じ `requestID` は 2 回作らない（作った会話を返す）
public struct ConversationForkRequest: Codable, Hashable, Sendable {
    public var requestID: String
    /// この発言までを写す（`ChatMessage.id`。`#n` が付いていてもよい）。省くと末尾まで
    public var messageID: String?
    /// フォークした会話に最初に送る発言
    public var prompt: String?

    public init(requestID: String = UUID().uuidString.lowercased(), messageID: String? = nil, prompt: String? = nil) {
        self.requestID = requestID
        self.messageID = messageID
        self.prompt = prompt
    }
}

/// `POST /v1/conversations/{id}/rewind`。`messageID` の発言の前まで会話を戻す（`files` ならファイルも）。
/// `expectedAgentSessionID` が今の Claude の会話 ID と違えば 409（古い画面からの要求と、送り直しの 2 回目）
public struct ConversationRewindRequest: Codable, Hashable, Sendable {
    public var messageID: String
    public var expectedAgentSessionID: String
    public var files: Bool
    public var dryRun: Bool

    public init(messageID: String, expectedAgentSessionID: String, files: Bool, dryRun: Bool) {
        self.messageID = messageID
        self.expectedAgentSessionID = expectedAgentSessionID
        self.files = files
        self.dryRun = dryRun
    }
}

/// 巻き戻しの結果。dry run では `canRewind`・`filesChanged`・`insertions`・`deletions`（`files` のとき）を返し、会話は変えない。
/// 本番では `conversation`（巻き戻した後）と `draft`（戻した発言の本文。入力欄に戻す）と、戻せなかったリンクの数 `skippedLinks`
public struct ConversationRewindResponse: Codable, Hashable, Sendable {
    public var canRewind: Bool?
    /// ファイルを戻せない理由（CLI の文。E2 までに送った発言は「No file checkpoint found for this message.」）
    public var error: String?
    public var filesChanged: [String]?
    public var insertions: Int?
    public var deletions: Int?
    public var skippedLinks: Int?
    public var draft: String?
    public var conversation: Conversation?

    public init(
        canRewind: Bool? = nil, error: String? = nil, filesChanged: [String]? = nil, insertions: Int? = nil, deletions: Int? = nil,
        skippedLinks: Int? = nil, draft: String? = nil, conversation: Conversation? = nil
    ) {
        self.canRewind = canRewind
        self.error = error
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
        self.skippedLinks = skippedLinks
        self.draft = draft
        self.conversation = conversation
    }
}

/// `POST /v1/conversations/{id}/rewind/undo`・`POST /v1/conversations/{id}/rewind/redo`・`POST /v1/conversations/{id}/terminal`
public struct ConversationSessionGuard: Codable, Hashable, Sendable {
    public var expectedAgentSessionID: String

    public init(expectedAgentSessionID: String) {
        self.expectedAgentSessionID = expectedAgentSessionID
    }
}

/// `POST /v1/conversations/{id}/shell`。会話の作業フォルダのシェルの pane（生きていれば前と同じ）
public struct ConversationShellResponse: Codable, Hashable, Sendable {
    public var pane: PaneID

    public init(pane: PaneID) {
        self.pane = pane
    }
}

/// `POST /v1/conversations/prewarm`。起動の画面を開いた時点で、この条件の会話のプロセスを先に起こしておく
public struct ConversationPrewarmRequest: Codable, Hashable, Sendable {
    public var cwd: String
    public var model: String?
    public var effort: String?
    public var permissionMode: String?

    public init(cwd: String, model: String? = nil, effort: String? = nil, permissionMode: String? = nil) {
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
    }
}

/// `POST /v1/conversations/{id}/runs`。コードブロックを会話の作業フォルダで動かす（出力は Claude に渡さない）
public struct ConversationRunRequest: Codable, Hashable, Sendable {
    public var code: String
    /// コードブロックの言語（bash・sh・shell・console・zsh だけ受ける）
    public var language: String
    /// ブロックのある発言
    public var messageID: String?

    public static let languages: Set<String> = ["bash", "sh", "shell", "console", "zsh", "fish"]

    public init(code: String, language: String, messageID: String? = nil) {
        self.code = code
        self.language = language
        self.messageID = messageID
    }
}

/// コードブロックの Run（`GET /v1/conversations/{id}/runs/{run}` は全部の出力を返す）
public struct ConversationRun: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case running
        /// 終了コード 0
        case succeeded
        /// 0 以外で終わった
        case failed
        /// 取り消した
        case cancelled
        /// 時間の上限で打ち切った
        case timedOut
    }

    public var id: String
    public var conversationID: String
    public var messageID: String?
    public var language: String
    public var code: String
    public var status: Status
    public var exitCode: Int32?
    /// 標準出力と標準エラーを合わせたもの（先頭から上限まで）
    public var output: String
    /// 上限で切った
    public var truncated: Bool
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: String, conversationID: String, messageID: String?, language: String, code: String, status: Status, exitCode: Int32? = nil,
        output: String = "", truncated: Bool = false, startedAt: Date, endedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.language = language
        self.code = code
        self.status = status
        self.exitCode = exitCode
        self.output = output
        self.truncated = truncated
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// 購読に流す Run の変化。`chunk` は前に流した分の続きの出力
public struct ConversationRunUpdate: Codable, Hashable, Sendable {
    public var id: String
    public var messageID: String?
    public var status: ConversationRun.Status
    public var exitCode: Int32?
    public var chunk: String
    public var truncated: Bool

    public init(id: String, messageID: String?, status: ConversationRun.Status, exitCode: Int32? = nil, chunk: String, truncated: Bool) {
        self.id = id
        self.messageID = messageID
        self.status = status
        self.exitCode = exitCode
        self.chunk = chunk
        self.truncated = truncated
    }
}

/// 差分で比べる相手（`?scope=`）
public enum ConversationDiffScope: String, Codable, Sendable, CaseIterable {
    /// HEAD と作業フォルダ
    case all
    /// index と作業フォルダ（追跡していないファイルを含む）
    case unstaged
    /// HEAD と index
    case staged
    /// 既定のブランチから分かれた所と作業フォルダ
    case branch
}

/// `GET /v1/conversations/{id}/diff`。path は git の根からの相対
public struct ConversationDiffResponse: Codable, Hashable, Sendable {
    public var summary: ConversationDiffSummary
    public var files: [ConversationDiffFile]
    public var scope: ConversationDiffScope
    /// ブランチ全体で比べたブランチ。比べるブランチが無ければ nil
    public var base: String?

    public init(summary: ConversationDiffSummary, files: [ConversationDiffFile], scope: ConversationDiffScope = .all, base: String? = nil) {
        self.summary = summary
        self.files = files
        self.scope = scope
        self.base = base
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(ConversationDiffSummary.self, forKey: .summary)
        files = try container.decode([ConversationDiffFile].self, forKey: .files)
        // 範囲を知らない daemon はすべての変更を返す
        scope = (try? container.decode(ConversationDiffScope.self, forKey: .scope)) ?? .all
        base = try container.decodeIfPresent(String.self, forKey: .base)
    }
}

public struct ConversationDiffFile: Codable, Hashable, Sendable, Identifiable {
    public enum Change: String, Codable, Sendable {
        case modified, added, deleted, renamed, copied, untracked, typeChanged, unmerged
    }

    public var path: String
    /// rename・copy の元
    public var oldPath: String?
    public var change: Change
    /// バイナリのファイルは nil
    public var insertions: Int?
    public var deletions: Int?

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, change: Change, insertions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// `GET /v1/conversations/{id}/diff/file?path=`。1 ファイルの unified diff
public struct ConversationFileDiffResponse: Codable, Hashable, Sendable {
    public var path: String
    public var diff: String
    public var truncated: Bool

    public init(path: String, diff: String, truncated: Bool) {
        self.path = path
        self.diff = diff
        self.truncated = truncated
    }
}
