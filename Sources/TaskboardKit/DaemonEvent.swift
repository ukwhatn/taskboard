import Foundation

/// 状態の出来事（`/v1/stream` の `event` の frame の `data`）。JSON は `{"event": "...", "data": {...}}`。
public enum DaemonEvent: Hashable, Sendable {
    case stateSnapshot(StateSnapshot)
    case machineUpdated(MachineInfo)
    case boardUpdated(Board)
    case boardRemoved(String)
    case taskUpdated(BoardTask)
    case taskRemoved(TaskKey)
    case workUpdated(WorkItem)
    case workRemoved(WorkItemKey)
    case docUpdated(Document)
    case docRemoved(DocKey)
    case askUpdated(Ask)
    case reviewRequestUpdated(ReviewRequest)
    case reviewRequestRemoved(TaskKey)
    /// マシンの PR 一覧・取得状態・変化を丸ごと置き換える
    case prsUpdated(PRSnapshot)
    /// マシンの利用枠とセッションの context を丸ごと置き換える
    case usageUpdated(UsageSnapshot)
    /// マシンのタスクのリンク（PR・Jira）の状態を丸ごと置き換える
    case linksUpdated([LinkStatus])
    case scheduleUpdated(Schedule)
    case scheduleRemoved(ScheduleKey)
    /// マシンの設定（常駐・自動停止）
    case settingsUpdated(MachineSettings)
    /// オーケストレーターの状態（居るか・起動の進み・最後の失敗・最後の返事）
    case orchestratorUpdated(OrchestratorInfo)
    /// ペアリングした端末の一覧を丸ごと置き換える（`current` は常に false）
    case devicesUpdated([DeviceInfo])
    /// 1 台の端末（アプリ）の設定の写し（`ClientPrefs`）
    case clientPrefsUpdated(ClientPrefs)
    /// 受信箱で消した項目の記録を丸ごと置き換える
    case inboxDismissalsUpdated([InboxDismissal])
    /// host の会話の様子（状態・問い・題・裏のタスクの数）。発言と差分は `/v1/stream` で購読した会話にだけ流れる
    case conversationUpdated(Conversation)
    case conversationRemoved(ConversationKey)
    /// host の会話が使っているツールが変わった（ツールの始まりと終わりのたび）
    case conversationActivity(ConversationToolActivity)
    case wakeUpdated(Wake)
    case wakeRemoved(WakeKey)
    case watchUpdated(Watch)
    case watchRemoved(WatchKey)
    /// 会話が登録した概況（部品が無くなったら `panelRemoved`）
    case panelUpdated(OverviewPanel)
    case panelRemoved(TaskKey)

    public var name: String {
        switch self {
        case .stateSnapshot: "state.snapshot"
        case .machineUpdated: "machine.updated"
        case .boardUpdated: "board.updated"
        case .boardRemoved: "board.removed"
        case .taskUpdated: "task.updated"
        case .taskRemoved: "task.removed"
        case .workUpdated: "work.updated"
        case .workRemoved: "work.removed"
        case .docUpdated: "doc.updated"
        case .docRemoved: "doc.removed"
        case .askUpdated: "ask.updated"
        case .reviewRequestUpdated: "review_request.updated"
        case .reviewRequestRemoved: "review_request.removed"
        case .prsUpdated: "prs.updated"
        case .usageUpdated: "usage.updated"
        case .linksUpdated: "links.updated"
        case .scheduleUpdated: "schedule.updated"
        case .scheduleRemoved: "schedule.removed"
        case .settingsUpdated: "settings.updated"
        case .orchestratorUpdated: "orchestrator.updated"
        case .devicesUpdated: "devices.updated"
        case .clientPrefsUpdated: "client_prefs.updated"
        case .inboxDismissalsUpdated: "inbox.dismissals_updated"
        case .conversationUpdated: "conversation.updated"
        case .conversationRemoved: "conversation.removed"
        case .conversationActivity: "conversation.activity"
        case .wakeUpdated: "wake.updated"
        case .wakeRemoved: "wake.removed"
        case .watchUpdated: "watch.updated"
        case .watchRemoved: "watch.removed"
        case .panelUpdated: "panel.updated"
        case .panelRemoved: "panel.removed"
        }
    }
}

extension DaemonEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case event
        case data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .event)
        switch name {
        case "state.snapshot": self = .stateSnapshot(try c.decode(StateSnapshot.self, forKey: .data))
        case "machine.updated": self = .machineUpdated(try c.decode(MachineInfo.self, forKey: .data))
        case "board.updated": self = .boardUpdated(try c.decode(Board.self, forKey: .data))
        case "board.removed": self = .boardRemoved(try c.decode(String.self, forKey: .data))
        case "task.updated": self = .taskUpdated(try c.decode(BoardTask.self, forKey: .data))
        case "task.removed": self = .taskRemoved(try c.decode(TaskKey.self, forKey: .data))
        case "work.updated": self = .workUpdated(try c.decode(WorkItem.self, forKey: .data))
        case "work.removed": self = .workRemoved(try c.decode(WorkItemKey.self, forKey: .data))
        case "doc.updated": self = .docUpdated(try c.decode(Document.self, forKey: .data))
        case "doc.removed": self = .docRemoved(try c.decode(DocKey.self, forKey: .data))
        case "ask.updated": self = .askUpdated(try c.decode(Ask.self, forKey: .data))
        case "review_request.updated": self = .reviewRequestUpdated(try c.decode(ReviewRequest.self, forKey: .data))
        case "review_request.removed": self = .reviewRequestRemoved(try c.decode(TaskKey.self, forKey: .data))
        case "prs.updated": self = .prsUpdated(try c.decode(PRSnapshot.self, forKey: .data))
        case "usage.updated": self = .usageUpdated(try c.decode(UsageSnapshot.self, forKey: .data))
        case "links.updated": self = .linksUpdated(try c.decode([LinkStatus].self, forKey: .data))
        case "schedule.updated": self = .scheduleUpdated(try c.decode(Schedule.self, forKey: .data))
        case "schedule.removed": self = .scheduleRemoved(try c.decode(ScheduleKey.self, forKey: .data))
        case "settings.updated": self = .settingsUpdated(try c.decode(MachineSettings.self, forKey: .data))
        case "orchestrator.updated": self = .orchestratorUpdated(try c.decode(OrchestratorInfo.self, forKey: .data))
        case "devices.updated": self = .devicesUpdated(try c.decode([DeviceInfo].self, forKey: .data))
        case "client_prefs.updated": self = .clientPrefsUpdated(try c.decode(ClientPrefs.self, forKey: .data))
        case "inbox.dismissals_updated": self = .inboxDismissalsUpdated(try c.decode([InboxDismissal].self, forKey: .data))
        case "conversation.updated": self = .conversationUpdated(try c.decode(Conversation.self, forKey: .data))
        case "conversation.removed": self = .conversationRemoved(try c.decode(ConversationKey.self, forKey: .data))
        case "conversation.activity": self = .conversationActivity(try c.decode(ConversationToolActivity.self, forKey: .data))
        case "wake.updated": self = .wakeUpdated(try c.decode(Wake.self, forKey: .data))
        case "wake.removed": self = .wakeRemoved(try c.decode(WakeKey.self, forKey: .data))
        case "watch.updated": self = .watchUpdated(try c.decode(Watch.self, forKey: .data))
        case "watch.removed": self = .watchRemoved(try c.decode(WatchKey.self, forKey: .data))
        case "panel.updated": self = .panelUpdated(try c.decode(OverviewPanel.self, forKey: .data))
        case "panel.removed": self = .panelRemoved(try c.decode(TaskKey.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: c, debugDescription: "unknown event \(name)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .event)
        switch self {
        case .stateSnapshot(let v): try c.encode(v, forKey: .data)
        case .machineUpdated(let v): try c.encode(v, forKey: .data)
        case .boardUpdated(let v): try c.encode(v, forKey: .data)
        case .boardRemoved(let v): try c.encode(v, forKey: .data)
        case .taskUpdated(let v): try c.encode(v, forKey: .data)
        case .taskRemoved(let v): try c.encode(v, forKey: .data)
        case .workUpdated(let v): try c.encode(v, forKey: .data)
        case .workRemoved(let v): try c.encode(v, forKey: .data)
        case .docUpdated(let v): try c.encode(v, forKey: .data)
        case .docRemoved(let v): try c.encode(v, forKey: .data)
        case .askUpdated(let v): try c.encode(v, forKey: .data)
        case .reviewRequestUpdated(let v): try c.encode(v, forKey: .data)
        case .reviewRequestRemoved(let v): try c.encode(v, forKey: .data)
        case .prsUpdated(let v): try c.encode(v, forKey: .data)
        case .usageUpdated(let v): try c.encode(v, forKey: .data)
        case .linksUpdated(let v): try c.encode(v, forKey: .data)
        case .scheduleUpdated(let v): try c.encode(v, forKey: .data)
        case .scheduleRemoved(let v): try c.encode(v, forKey: .data)
        case .settingsUpdated(let v): try c.encode(v, forKey: .data)
        case .orchestratorUpdated(let v): try c.encode(v, forKey: .data)
        case .devicesUpdated(let v): try c.encode(v, forKey: .data)
        case .clientPrefsUpdated(let v): try c.encode(v, forKey: .data)
        case .inboxDismissalsUpdated(let v): try c.encode(v, forKey: .data)
        case .conversationUpdated(let v): try c.encode(v, forKey: .data)
        case .conversationRemoved(let v): try c.encode(v, forKey: .data)
        case .conversationActivity(let v): try c.encode(v, forKey: .data)
        case .wakeUpdated(let v): try c.encode(v, forKey: .data)
        case .wakeRemoved(let v): try c.encode(v, forKey: .data)
        case .watchUpdated(let v): try c.encode(v, forKey: .data)
        case .watchRemoved(let v): try c.encode(v, forKey: .data)
        case .panelUpdated(let v): try c.encode(v, forKey: .data)
        case .panelRemoved(let v): try c.encode(v, forKey: .data)
        }
    }
}

/// アプリと daemon が同じ設定で JSON を読み書きするための coder。
public enum WireJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - タスク操作の要求（`/v1/tasks`）

/// `POST /v1/tasks`。
public struct TaskCreateRequest: Codable, Hashable, Sendable {
    public var boardID: String
    public var columnID: String
    public var title: String
    public var note: String
    public var due: String?
    public var links: [String]

    public init(boardID: String, columnID: String, title: String, note: String = "", due: String? = nil, links: [String] = []) {
        self.boardID = boardID
        self.columnID = columnID
        self.title = title
        self.note = note
        self.due = due
        self.links = links
    }
}

/// `PATCH /v1/tasks/{number}`。nil のフィールドは変えない。`due` を消すには `clearDue: true`。
public struct TaskUpdateRequest: Codable, Hashable, Sendable {
    public var title: String?
    public var note: String?
    public var columnID: String?
    public var boardID: String?
    public var due: String?
    public var clearDue: Bool
    public var addLinks: [String]
    public var removeLinkIDs: [Int64]
    /// 状態の文を書く（空の文で外す）
    public var status: TaskStatusUpdate?

    public init(
        title: String? = nil, note: String? = nil, columnID: String? = nil, boardID: String? = nil, due: String? = nil, clearDue: Bool = false,
        addLinks: [String] = [], removeLinkIDs: [Int64] = [], status: TaskStatusUpdate? = nil
    ) {
        self.title = title
        self.note = note
        self.columnID = columnID
        self.boardID = boardID
        self.due = due
        self.clearDue = clearDue
        self.addLinks = addLinks
        self.removeLinkIDs = removeLinkIDs
        self.status = status
    }
}

/// `POST /v1/boards`。列を省くと既定の 9 列（`BoardColumn.standard`）。
public struct BoardCreateRequest: Codable, Hashable, Sendable {
    public var name: String
    public var columns: [BoardColumn]?

    public init(name: String, columns: [BoardColumn]? = nil) {
        self.name = name
        self.columns = columns
    }
}

/// `POST /v1/import/taskherd`。CLI が taskherd の lock を取って読んだ中身をそのまま送る。
public struct TaskherdImportRequest: Codable, Hashable, Sendable {
    public struct TaskherdTask: Codable, Hashable, Sendable {
        public struct SessionRef: Codable, Hashable, Sendable {
            public var agent: String
            public var sessionID: String
            public var cwd: String
            public var label: String
            public var linkedAt: Date

            enum CodingKeys: String, CodingKey {
                case agent, cwd, label
                case sessionID = "session_id"
                case linkedAt = "linked_at"
            }

            public init(agent: String, sessionID: String, cwd: String, label: String, linkedAt: Date) {
                self.agent = agent
                self.sessionID = sessionID
                self.cwd = cwd
                self.label = label
                self.linkedAt = linkedAt
            }
        }

        public struct Link: Codable, Hashable, Sendable {
            public var url: String
            public var kind: String
            public var note: String
            public var addedAt: Date

            enum CodingKeys: String, CodingKey {
                case url, kind, note
                case addedAt = "added_at"
            }

            public init(url: String, kind: String, note: String, addedAt: Date) {
                self.url = url
                self.kind = kind
                self.note = note
                self.addedAt = addedAt
            }
        }

        public var id: Int
        public var title: String
        public var status: String
        public var due: String?
        public var note: String
        public var sessions: [SessionRef]
        public var links: [Link]
        public var createdAt: Date
        public var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, title, status, due, note, sessions, links
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }

        public init(
            id: Int, title: String, status: String, due: String?, note: String, sessions: [SessionRef], links: [Link], createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.due = due
            self.note = note
            self.sessions = sessions
            self.links = links
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    /// 取り込み先のボード名。無ければ作る。
    public var boardName: String
    /// taskherd の `config.toml` の列（id の順）。空なら既定の 9 列（`BoardColumn.standard`）。
    public var columns: [BoardColumn]
    public var tasks: [TaskherdTask]
    /// taskherd の `[session_start] prompt_template`。nil なら既存の値を変えない
    public var promptTemplate: String?
    /// `[session_start.templates]`（列 id → テンプレート）。nil なら変えない
    public var columnTemplates: [String: String]?

    public init(boardName: String, columns: [BoardColumn], tasks: [TaskherdTask], promptTemplate: String? = nil, columnTemplates: [String: String]? = nil) {
        self.boardName = boardName
        self.columns = columns
        self.tasks = tasks
        self.promptTemplate = promptTemplate
        self.columnTemplates = columnTemplates
    }
}

public struct TaskherdImportResult: Codable, Hashable, Sendable {
    public var boardID: String
    public var inserted: Int
    public var updated: Int
    public var unchanged: Int
    /// 取り込み元より daemon 側が新しく、取り込み元の値を採らなかった件数
    public var keptLocal: Int

    public init(boardID: String, inserted: Int, updated: Int, unchanged: Int, keptLocal: Int = 0) {
        self.boardID = boardID
        self.inserted = inserted
        self.updated = updated
        self.unchanged = unchanged
        self.keptLocal = keptLocal
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boardID = try c.decode(String.self, forKey: .boardID)
        inserted = try c.decode(Int.self, forKey: .inserted)
        updated = try c.decode(Int.self, forKey: .updated)
        unchanged = try c.decode(Int.self, forKey: .unchanged)
        keptLocal = try c.decodeIfPresent(Int.self, forKey: .keptLocal) ?? 0
    }
}
