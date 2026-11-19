import Foundation

/// 案件の Slack アプリの設定（`GET /v1/boards/{id}/slack`）。token は返さず、入っているかと `auth.test` で取れた名前だけを返す
public struct BoardSlack: Codable, Hashable, Sendable {
    /// bot token と app-level token の両方が入っている
    public var configured: Bool
    /// `auth.test` のワークスペースの名前と bot の名前（取れなかったら nil）
    public var workspace: String?
    public var botName: String?
    /// 受け付ける Slack の人。ほかの人の発言には何もしない
    public var allowedUsers: [SlackMember]
    /// チャンネル → タスク。表に無いチャンネルの依頼はオーケストレーターへ届ける
    public var routes: [SlackRoute]
    public var connection: SlackConnection

    public init(
        configured: Bool = false, workspace: String? = nil, botName: String? = nil, allowedUsers: [SlackMember] = [], routes: [SlackRoute] = [],
        connection: SlackConnection = .off
    ) {
        self.configured = configured
        self.workspace = workspace
        self.botName = botName
        self.allowedUsers = allowedUsers
        self.routes = routes
        self.connection = connection
    }
}

public struct SlackMember: Codable, Hashable, Identifiable, Sendable {
    /// Slack のメンバー ID（`U…`・`W…`）
    public var id: String
    /// 表示名（取れなかったら nil）
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

public struct SlackRoute: Codable, Hashable, Identifiable, Sendable {
    /// チャンネル ID（`C…`・`G…`）
    public var channelID: String
    /// `#` を除いたチャンネルの名前（取れなかったら nil）
    public var channelName: String?
    public var taskNumber: Int

    public var id: String { channelID }

    public init(channelID: String, channelName: String? = nil, taskNumber: Int) {
        self.channelID = channelID
        self.channelName = channelName
        self.taskNumber = taskNumber
    }
}

/// Socket Mode の接続の様子
public enum SlackConnection: Codable, Hashable, Sendable {
    /// 設定が無い
    case off
    case connecting
    case connected
    /// つなげなかった。`message` は利用者に見せる理由（token は含まない）
    case failed(message: String)
}

/// `PUT /v1/boards/{id}/slack`。token は入れ替えるときだけ渡す（nil は今のまま）。人と対応表は渡した値で置き換える
public struct BoardSlackUpdate: Codable, Hashable, Sendable {
    public var botToken: String?
    public var appToken: String?
    public var allowedUsers: [String]
    public var routes: [SlackRouteUpdate]

    public init(botToken: String? = nil, appToken: String? = nil, allowedUsers: [String], routes: [SlackRouteUpdate]) {
        self.botToken = botToken
        self.appToken = appToken
        self.allowedUsers = allowedUsers
        self.routes = routes
    }
}

public struct SlackRouteUpdate: Codable, Hashable, Sendable {
    public var channelID: String
    public var taskNumber: Int

    public init(channelID: String, taskNumber: Int) {
        self.channelID = channelID
        self.taskNumber = taskNumber
    }
}

/// bot が入っているチャンネル（`GET /v1/boards/{id}/slack/channels`）。対応表のチャンネルを選ぶ
public struct SlackChannel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Slack の bot token と app-level token の形。中身は確かめない（`auth.test` が確かめる）
public enum SlackToken {
    public static func isBotToken(_ token: String) -> Bool { token.hasPrefix("xoxb-") }
    public static func isAppToken(_ token: String) -> Bool { token.hasPrefix("xapp-") }
}

/// 受けた依頼（`GET /v1/slack/requests/{id}`）。`text` は依頼した人の発言、`shared` と `thread` は外から来た文
public struct SlackRequestDetail: Codable, Hashable, Sendable {
    public var id: Int64
    public var boardID: String
    public var channelID: String
    public var channelName: String?
    public var user: SlackMember
    public var text: String
    public var permalink: String?
    public var receivedAt: Date
    /// 転送されたメッセージと、本文の中のメッセージのリンクの中身
    public var shared: [SlackMessage]
    /// 依頼のスレッドの、依頼より前の発言（スレッドの中で頼まれたとき）
    public var thread: [SlackMessage]
    /// アプリとの DM で頼まれたとき、依頼した人が横で開いていたチャンネル（Slack の Agents の機能）
    public var viewing: SlackViewing?

    public init(
        id: Int64, boardID: String, channelID: String, channelName: String?, user: SlackMember, text: String, permalink: String?, receivedAt: Date,
        shared: [SlackMessage] = [], thread: [SlackMessage] = [], viewing: SlackViewing? = nil
    ) {
        self.id = id
        self.boardID = boardID
        self.channelID = channelID
        self.channelName = channelName
        self.user = user
        self.text = text
        self.permalink = permalink
        self.receivedAt = receivedAt
        self.shared = shared
        self.thread = thread
        self.viewing = viewing
    }
}

/// 依頼した人が開いていたチャンネルと、その新しい発言（古い順）。bot が入っていないチャンネルは `recent` が空で `readable` が false
public struct SlackViewing: Codable, Hashable, Sendable {
    public var channelID: String
    public var channelName: String?
    public var readable: Bool
    public var recent: [SlackMessage]

    public init(channelID: String, channelName: String?, readable: Bool, recent: [SlackMessage]) {
        self.channelID = channelID
        self.channelName = channelName
        self.readable = readable
        self.recent = recent
    }
}

public struct SlackMessage: Codable, Hashable, Sendable {
    public var author: String?
    public var text: String
    public var permalink: String?
    public var ts: String?

    public init(author: String?, text: String, permalink: String?, ts: String?) {
        self.author = author
        self.text = text
        self.permalink = permalink
        self.ts = ts
    }
}

/// `POST /v1/slack/requests/{id}/reply`
public struct SlackReplyRequest: Codable, Hashable, Sendable {
    public var text: String
    /// 返した後の依頼の様子。省くと `done`
    public var status: SlackRequestStatus?

    public init(text: String, status: SlackRequestStatus? = nil) {
        self.text = text
        self.status = status
    }

    /// Slack が本文を切り捨てる長さ
    public static let maxCharacters = 40_000
}

/// 返信の後の、Slack の会話（agent session）の様子
public enum SlackRequestStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// 終わった（次の依頼を待つ）
    case done
    /// まだ作業している（途中の報告）
    case working
    /// 依頼した人の答えを待つ
    case waiting
}

public struct SlackReplyResult: Codable, Hashable, Sendable {
    public var permalink: String?

    public init(permalink: String?) { self.permalink = permalink }
}
