import Foundation

/// daemon が動いているマシン
public struct MachineInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: MachineID
    /// 表示名。既定はホスト名。
    public var name: String
    public var daemonVersion: String
    /// host の会話を動かす agent host の様子（host の会話を持たない daemon と、古い daemon は nil）
    public var agentHost: AgentHostInfo?
    /// host の会話が使う Claude Code の版と、新しい版を確かめた結果（古い daemon は nil）
    public var claudeCLI: CLIVersionStatus?
    /// host の会話が使う codex の版と、新しい版を確かめた結果（codex が入っていないマシンと、古い daemon は nil）
    public var codexCLI: CLIVersionStatus?

    public init(
        id: MachineID,
        name: String,
        daemonVersion: String,
        agentHost: AgentHostInfo? = nil,
        claudeCLI: CLIVersionStatus? = nil,
        codexCLI: CLIVersionStatus? = nil
    ) {
        self.id = id
        self.name = name
        self.daemonVersion = daemonVersion
        self.agentHost = agentHost
        self.claudeCLI = claudeCLI
        self.codexCLI = codexCLI
    }

    private enum CodingKeys: String, CodingKey { case id, name, daemonVersion, agentHost, claudeCLI, codexCLI, herdrConnected }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(MachineID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        daemonVersion = try c.decode(String.self, forKey: .daemonVersion)
        agentHost = try c.decodeIfPresent(AgentHostInfo.self, forKey: .agentHost)
        claudeCLI = try c.decodeIfPresent(CLIVersionStatus.self, forKey: .claudeCLI)
        codexCLI = try c.decodeIfPresent(CLIVersionStatus.self, forKey: .codexCLI)
    }

    // shortcut: H2 までのアプリは herdrConnected が無いと state 全体を読めない。全部の端末のアプリを入れ替えたら外す
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(daemonVersion, forKey: .daemonVersion)
        try c.encodeIfPresent(agentHost, forKey: .agentHost)
        try c.encodeIfPresent(claudeCLI, forKey: .claudeCLI)
        try c.encodeIfPresent(codexCLI, forKey: .codexCLI)
        try c.encode(false, forKey: .herdrConnected)
    }
}

/// host の会話の CLI の版（`CLIVersionWatcher`）
public struct CLIVersionStatus: Codable, Hashable, Sendable {
    /// 会話が使う版（確かめた版のうち最も新しいもの）。無ければ会話を起こせない
    public var using: String?
    /// 入っている最も新しい版
    public var newest: String?
    /// 確かめで通らなかった最も新しい版と、その最初の段
    public var failedVersion: String?
    public var failedStep: String?

    public init(using: String?, newest: String?, failedVersion: String? = nil, failedStep: String? = nil) {
        self.using = using
        self.newest = newest
        self.failedVersion = failedVersion
        self.failedStep = failedStep
    }
}

public struct AgentHostInfo: Codable, Hashable, Sendable {
    public var connected: Bool
    /// 版の違う host に入れ替えを頼み、その host の子が全部終わるのを待っている（その間は会話を起こせない）
    public var draining: Bool
    /// 入れ替えを待つ間も動いている会話の id。止めるか終われば入れ替わる
    public var remaining: [String]

    public init(connected: Bool, draining: Bool = false, remaining: [String] = []) {
        self.connected = connected
        self.draining = draining
        self.remaining = remaining
    }
}

/// `GET /v1/state` の全体。WebSocket の最初のフレームも同じ。
public struct StateSnapshot: Codable, Hashable, Sendable {
    public var machine: MachineInfo
    public var boards: [Board]
    public var tasks: [BoardTask]
    public var workItems: [WorkItem]
    /// タスクに属する文書（本文は別に取る）
    public var documents: [Document]
    /// 質問（open と、回答済みで未受領のもの。受領済みは落とす）
    public var asks: [Ask]
    public var reviewRequests: [ReviewRequest]
    /// PR の一覧（gh が無い・まだ取っていないマシンは nil）
    public var prs: PRSnapshot?
    /// 利用枠と context（statusline がまだ届いていないマシンは nil）
    public var usage: UsageSnapshot?
    public var schedules: [Schedule]
    /// タスクのリンク（PR・Jira）の状態。取れたものだけ
    public var links: [LinkStatus]
    /// マシンの設定（P6 までの daemon は返さない）
    public var settings: MachineSettings?
    /// オーケストレーターの状態（P6 までの daemon は返さない）
    public var orchestrator: OrchestratorInfo?
    /// 受信箱で消した項目の記録（古い daemon は返さない）
    public var inboxDismissals: [InboxDismissal] = []
    /// host の会話（E1 までの daemon は返さない）
    public var conversations: [Conversation] = []
    /// ツールを使っている会話の、使っているツール（前の版の daemon は返さない）
    public var conversationActivities: [ConversationToolActivity] = []
    /// 起こす予定（届けた・取り消した・失敗したものは 7 日残す。前の版の daemon は返さない）
    public var wakes: [Wake] = []
    /// GitHub の issue・PR の見張り（終えた・取り消したものは 7 日残す。前の版の daemon は返さない）
    public var watches: [Watch] = []
    /// 会話が登録した概況（部品のあるタスクだけ。前の版の daemon は返さない）
    public var panels: [OverviewPanel] = []
    public var generatedAt: Date

    public init(
        machine: MachineInfo, boards: [Board] = [], tasks: [BoardTask] = [], workItems: [WorkItem] = [],
        documents: [Document] = [], asks: [Ask] = [], reviewRequests: [ReviewRequest] = [], prs: PRSnapshot? = nil, usage: UsageSnapshot? = nil,
        schedules: [Schedule] = [], links: [LinkStatus] = [], settings: MachineSettings? = nil, orchestrator: OrchestratorInfo? = nil,
        generatedAt: Date
    ) {
        self.machine = machine
        self.boards = boards
        self.tasks = tasks
        self.workItems = workItems
        self.documents = documents
        self.asks = asks
        self.reviewRequests = reviewRequests
        self.prs = prs
        self.usage = usage
        self.schedules = schedules
        self.links = links
        self.settings = settings
        self.orchestrator = orchestrator
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case machine, sessions, boards, tasks, workItems, documents, asks, reviewRequests, prs, usage, schedules, links, settings, orchestrator, inboxDismissals
        case conversations, conversationActivities, wakes, watches, panels, generatedAt
    }

    /// 古い fixtures（boards / tasks 無し）も読めるように、無ければ空にする。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(MachineInfo.self, forKey: .machine)
        boards = try c.decodeIfPresent([Board].self, forKey: .boards) ?? []
        tasks = try c.decodeIfPresent([BoardTask].self, forKey: .tasks) ?? []
        workItems = try c.decodeIfPresent([WorkItem].self, forKey: .workItems) ?? []
        documents = try c.decodeIfPresent([Document].self, forKey: .documents) ?? []
        asks = try c.decodeIfPresent([Ask].self, forKey: .asks) ?? []
        reviewRequests = try c.decodeIfPresent([ReviewRequest].self, forKey: .reviewRequests) ?? []
        prs = try c.decodeIfPresent(PRSnapshot.self, forKey: .prs)
        usage = try c.decodeIfPresent(UsageSnapshot.self, forKey: .usage)
        schedules = try c.decodeIfPresent([Schedule].self, forKey: .schedules) ?? []
        links = try c.decodeIfPresent([LinkStatus].self, forKey: .links) ?? []
        settings = try c.decodeIfPresent(MachineSettings.self, forKey: .settings)
        orchestrator = try c.decodeIfPresent(OrchestratorInfo.self, forKey: .orchestrator)
        inboxDismissals = try c.decodeIfPresent([InboxDismissal].self, forKey: .inboxDismissals) ?? []
        conversations = try c.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        conversationActivities = (try? c.decodeIfPresent([ConversationToolActivity].self, forKey: .conversationActivities)) ?? []
        wakes = try c.decodeIfPresent([Wake].self, forKey: .wakes) ?? []
        // 1 件ずつ読み、読めない見張り（後の版の種類）は捨てる。1 件のために state 全体を読めなくしない
        watches = try c.decodeIfPresent([Lossy<Watch>].self, forKey: .watches)?.compactMap(\.value) ?? []
        // 後の版の種類の部品を持つ概況は読み捨てる
        panels = try c.decodeIfPresent([Lossy<OverviewPanel>].self, forKey: .panels)?.compactMap(\.value) ?? []
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
    }

    // shortcut: H2 までのアプリは sessions が無いと state 全体を読めないので、空で書く。全部の端末のアプリを入れ替えたら外す
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machine, forKey: .machine)
        try c.encode([String](), forKey: .sessions)
        try c.encode(boards, forKey: .boards)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(workItems, forKey: .workItems)
        try c.encode(documents, forKey: .documents)
        try c.encode(asks, forKey: .asks)
        try c.encode(reviewRequests, forKey: .reviewRequests)
        try c.encodeIfPresent(prs, forKey: .prs)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encode(schedules, forKey: .schedules)
        try c.encode(links, forKey: .links)
        try c.encodeIfPresent(settings, forKey: .settings)
        try c.encodeIfPresent(orchestrator, forKey: .orchestrator)
        try c.encode(inboxDismissals, forKey: .inboxDismissals)
        try c.encode(conversations, forKey: .conversations)
        try c.encode(conversationActivities, forKey: .conversationActivities)
        try c.encode(wakes, forKey: .wakes)
        try c.encode(watches, forKey: .watches)
        try c.encode(panels, forKey: .panels)
        try c.encode(generatedAt, forKey: .generatedAt)
    }
}

/// `GET /v1/health`。認証なしで返す最小情報。
public struct HealthInfo: Codable, Hashable, Sendable {
    public var ok: Bool
    public var daemonVersion: String
    public var machineID: MachineID

    public init(ok: Bool, daemonVersion: String, machineID: MachineID) {
        self.ok = ok
        self.daemonVersion = daemonVersion
        self.machineID = machineID
    }
}

/// 配列の 1 要素。読めなければ nil にする
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}
