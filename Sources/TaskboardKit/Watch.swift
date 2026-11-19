import Foundation

public struct WatchKey: Hashable, Codable, Sendable {
    public let machine: MachineID
    public let id: Int64

    public init(machine: MachineID, id: Int64) {
        self.machine = machine
        self.id = id
    }
}

/// GitHub の issue・PR を見張り、動きがあったら会話を起こして知らせる（MCP の `watch_create`）。届け先は会話か、タスク（その時点の lead）。
/// `item` は決めた issue・PR の動き（リンクの知らせと同じ種類）、`repo` は repo に新しく出た issue・PR、`command` はシェルのコマンドの結果
public struct Watch: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case item
        case repo
        case command
    }

    public enum State: String, Codable, Hashable, Sendable {
        case active
        case ended
        case cancelled
    }

    /// 見張りを終えた理由
    public enum Ending: String, Codable, Hashable, Sendable {
        /// issue・PR がマージかクローズされた（その知らせを届けてから終える）
        case finished
        /// 1 回だけ届ける見張りを届けた
        case delivered
        /// 期限を過ぎた
        case expired
        /// 届け先の会話の記録が無くなった
        case targetMissing = "target_missing"
    }

    public var watchID: Int64
    public var machine: MachineID
    public var kind: Kind
    /// `item` の issue・PR の URL
    public var url: String?
    /// `repo` の `owner/name`（github.com 以外は `host/owner/name`）と検索語
    public var repo: String?
    public var query: String?
    /// `command` のコマンドと条件
    public var command: CommandWatchSpec?
    /// `item` で届ける種類。空なら全部（`tagged` は選んだときか `tagPattern` を決めたときだけ）
    public var events: [LinkNotice.Kind]
    /// `tagged` で見るタグの名前の型（glob。`*-prod` など）。nil なら全部のタグ
    public var tagPattern: String?
    /// PR が入ったタグ（`tagged` を届けたか、見張りを作る前から入っていた）
    public var tag: String?
    public var conversationID: String?
    public var taskNumber: Int?
    /// 届ける文の頭に添える文
    public var prompt: String?
    public var once: Bool
    public var expiresAt: Date?
    public var state: State
    public var ending: Ending?
    /// 最後に取れなかった理由（取れたら消える）。agent とログに向けた文で、画面は有無だけを見る
    public var error: String?
    /// 最後に取れた時刻。取るたびには配らないので、state で配った値は配った時点のもの（新しい値は `GET /v1/watches`）
    public var fetchedAt: Date?
    /// 仕掛けた会話の id か pane
    public var createdBy: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: WatchKey { WatchKey(machine: machine, id: watchID) }

    public init(
        watchID: Int64, machine: MachineID, kind: Kind = .item, url: String? = nil, repo: String? = nil, query: String? = nil, command: CommandWatchSpec? = nil,
        events: [LinkNotice.Kind] = [],
        tagPattern: String? = nil, tag: String? = nil,
        conversationID: String? = nil, taskNumber: Int? = nil, prompt: String? = nil, once: Bool = false, expiresAt: Date? = nil, state: State = .active,
        ending: Ending? = nil, error: String? = nil, fetchedAt: Date? = nil, createdBy: String? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.watchID = watchID
        self.machine = machine
        self.kind = kind
        self.url = url
        self.repo = repo
        self.query = query
        self.command = command
        self.events = events
        self.tagPattern = tagPattern
        self.tag = tag
        self.conversationID = conversationID
        self.taskNumber = taskNumber
        self.prompt = prompt
        self.once = once
        self.expiresAt = expiresAt
        self.state = state
        self.ending = ending
        self.error = error
        self.fetchedAt = fetchedAt
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `POST /v1/watches`。見張るのは `url`（決めた issue・PR）・`repo`（新しく出た issue・PR。`query` で絞る）・`command`（daemon の token だけ）のどれか 1 つ、
/// 届け先は `conversationID` か `taskNumber` のどちらか 1 つ
public struct WatchCreateRequest: Codable, Hashable, Sendable {
    public var url: String?
    /// `owner/name`・`host/owner/name`・repo の URL
    public var repo: String?
    /// gh の検索語（`is:issue label:bug` など）。`repo:`・`created:`・`sort:` は daemon が付ける
    public var query: String?
    public var command: CommandWatchSpec?
    public var events: [LinkNotice.Kind]
    /// PR の見張りで、`tagged` で見るタグの名前の型（glob）。決めると `events` を省いても `tagged` を届ける
    public var tagPattern: String?
    public var conversationID: String?
    public var taskNumber: Int?
    public var prompt: String?
    public var once: Bool
    public var expiresAt: Date?
    public var createdBy: String?
    /// false なら PR を届け先のタスクにリンクしない（上流の PR を待つときなど）。nil と true はリンクする（`WatchCreated.link`）
    public var link: Bool?

    public init(
        url: String? = nil, repo: String? = nil, query: String? = nil, command: CommandWatchSpec? = nil, events: [LinkNotice.Kind] = [], tagPattern: String? = nil,
        conversationID: String? = nil,
        taskNumber: Int? = nil, prompt: String? = nil, once: Bool = false, expiresAt: Date? = nil, createdBy: String? = nil, link: Bool? = nil
    ) {
        self.url = url
        self.repo = repo
        self.query = query
        self.command = command
        self.events = events
        self.tagPattern = tagPattern
        self.conversationID = conversationID
        self.taskNumber = taskNumber
        self.prompt = prompt
        self.once = once
        self.expiresAt = expiresAt
        self.createdBy = createdBy
        self.link = link
    }

    /// issue で起きる種類（PR だけの種類を issue の見張りに渡したら断る）
    public static let issueEvents: Set<LinkNotice.Kind> = [.closed, .reopened, .comment]
}

/// `POST /v1/watches` の応答。`snapshot` は作ったときに取った元の様子（取れなければ nil。次の巡回で取る）
extension WatchCreateRequest {
    /// リンクの知らせ（マージ・CI・レビュー・コメント・conflict を lead に届ける）と同じものを待つ PR の監視。
    /// 種類の絞り込み・タグ・1 回だけ・期限・リンクしない、のどれかがあれば、知らせでは代わりにならない
    public var coveredByLinkNotices: Bool {
        guard let url, TaskLink.kind(of: url) == .githubPR else { return false }
        return events.isEmpty && tagPattern == nil && !once && expiresAt == nil && link != false
    }
}

public struct WatchCreated: Codable, Hashable, Sendable {
    /// nil なら作らなかった（`WatchCreateRequest.coveredByLinkNotices` の PR が届け先のタスクにリンクされ、lead にリンクの知らせが届く。指示はリンクのメモ）
    public var watch: Watch?
    public var snapshot: LinkSnapshot?
    /// 同じ見張りが既にあったので、それを返した
    public var existing: Bool
    /// PR を届け先のタスク（会話宛てなら、その会話のタスク）にリンクした結果。PR でない・届け先にタスクが無い・`link` が false なら nil
    public var link: AutoLinkResult?

    public init(watch: Watch?, snapshot: LinkSnapshot?, existing: Bool = false, link: AutoLinkResult? = nil) {
        self.watch = watch
        self.snapshot = snapshot
        self.existing = existing
        self.link = link
    }
}

/// コマンドの見張り（`Watch.Kind.command`）。daemon が `cwd` で `/bin/bash -c` に渡して動かし、結果が条件に合ったら届ける
public struct CommandWatchSpec: Codable, Hashable, Sendable {
    public enum Condition: String, Codable, Hashable, Sendable, CaseIterable {
        /// 終了コードが 0
        case succeeds
        /// 終了コードが 0 でない（打ち切りも）
        case fails
        /// 出力（標準出力と標準エラー）が `pattern` の正規表現に合う
        case matches
        /// 出力か終了コードが前の回と違う（1 回目は元にするだけ）
        case changes
        /// 1 回だけ動かし、終わったら届けて終える
        case finishes
    }

    public var command: String
    /// 絶対パス。省くとホーム
    public var cwd: String?
    public var condition: Condition
    public var pattern: String?
    /// 繰り返す間（`finishes` では使わない）
    public var intervalSeconds: Int?
    /// 1 回の打ち切り
    public var timeoutSeconds: Int?

    public init(command: String, cwd: String? = nil, condition: Condition, pattern: String? = nil, intervalSeconds: Int? = nil, timeoutSeconds: Int? = nil) {
        self.command = command
        self.cwd = cwd
        self.condition = condition
        self.pattern = pattern
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
    }

    public static let commandLimit = 4_096
    public static let patternLimit = 256
    public static let intervals = 30...86_400
    public static let defaultInterval = 60
    /// 繰り返す見張りの打ち切り（既定・上限）と、`finishes` の打ち切り（既定・上限）
    public static let checkTimeouts = (standard: 60, limit: 600)
    public static let finishTimeouts = (standard: 3_600, limit: 86_400)

    public var interval: Int { intervalSeconds ?? Self.defaultInterval }
    public var timeout: Int { timeoutSeconds ?? (condition == .finishes ? Self.finishTimeouts.standard : Self.checkTimeouts.standard) }
}
