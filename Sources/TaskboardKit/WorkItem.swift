import Foundation

/// 作業項目の識別。タスクと同じく、マシンをまたいで一意にするために machine を持つ。
public struct WorkItemKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let machine: MachineID
    public let id: Int64

    public init(machine: MachineID, id: Int64) {
        self.machine = machine
        self.id = id
    }

    public var description: String { "\(machine.rawValue)/work/\(id)" }
}

/// タスク内の進捗台帳の 1 行。セッション（lead）が MCP で登録し、アプリが見せる。
public struct WorkItem: Codable, Hashable, Identifiable, Sendable {
    /// 登録側が書く状態。「着手できる」は `effectiveStates(of:)` が依存から導く。
    public enum State: String, Codable, Hashable, Sendable, CaseIterable {
        case todo, doing, wait, done, drop
    }

    /// 画面に出す状態。`ready` は todo のうち依存が全部 done のもの。
    public enum EffectiveState: String, Hashable, Sendable, CaseIterable {
        case todo, ready, doing, wait, done, drop
    }

    public enum BlockerKind: String, Codable, Hashable, Sendable, CaseIterable {
        /// 自分（ユーザー）の承認・回答
        case approval
        /// 利用者の手作業（実機での確認・ケーブルの接続など）。受信箱の依頼になり、利用者が［対応済みにする］を押すと作業中に戻る
        case manual
        /// 他者のレビュー
        case review
        case ci
        case deploy
        /// 別の作業項目
        case item
        case external
    }

    /// 色の規則: attention = 自分の番（黄）、ok = 進められる（緑）、dim = 待つだけ（灰）
    public enum BlockerTone: String, Codable, Hashable, Sendable, CaseIterable {
        case attention, ok, dim
    }

    public enum DeliverableKind: String, Codable, Hashable, Sendable, CaseIterable {
        case pr, commit, file, doc
    }

    public var id: WorkItemKey { WorkItemKey(machine: machine, id: itemID) }

    public var machine: MachineID
    public var itemID: Int64
    public var taskNumber: Int
    public var title: String
    public var state: State
    public var blockerKind: BlockerKind?
    public var blockerText: String
    public var blockerTone: BlockerTone?
    public var dependsOn: [Int64]
    public var deliverableKind: DeliverableKind?
    public var deliverableRef: String
    public var owner: String
    /// まとまりの名前（「M3」のような段階）。空ならまとまりに入れない
    public var group: String
    /// 会話が付ける短い番号（「M3.6」「D3」）。概況・会話の画面・タスクの詳細で同じ表記で出す
    public var code: String
    public var position: Int
    /// 登録元: `session`（MCP）/ `manual`（アプリ）
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        machine: MachineID, itemID: Int64, taskNumber: Int, title: String, state: State, blockerKind: BlockerKind? = nil,
        blockerText: String = "", blockerTone: BlockerTone? = nil, dependsOn: [Int64] = [], deliverableKind: DeliverableKind? = nil,
        deliverableRef: String = "", owner: String = "", group: String = "", code: String = "", position: Int, source: String, createdAt: Date,
        updatedAt: Date
    ) {
        self.machine = machine
        self.itemID = itemID
        self.taskNumber = taskNumber
        self.title = title
        self.state = state
        self.blockerKind = blockerKind
        self.blockerText = blockerText
        self.blockerTone = blockerTone
        self.dependsOn = dependsOn
        self.deliverableKind = deliverableKind
        self.deliverableRef = deliverableRef
        self.owner = owner
        self.group = group
        self.code = code
        self.position = position
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case machine, itemID, taskNumber, title, state, blockerKind, blockerText, blockerTone, dependsOn, deliverableKind, deliverableRef, owner
        case group, code, position, source, createdAt, updatedAt
    }

    /// まとまりと番号を持つ前の版の JSON は空で読む
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(MachineID.self, forKey: .machine)
        itemID = try c.decode(Int64.self, forKey: .itemID)
        taskNumber = try c.decode(Int.self, forKey: .taskNumber)
        title = try c.decode(String.self, forKey: .title)
        state = try c.decode(State.self, forKey: .state)
        blockerKind = try c.decodeIfPresent(BlockerKind.self, forKey: .blockerKind)
        blockerText = try c.decode(String.self, forKey: .blockerText)
        blockerTone = try c.decodeIfPresent(BlockerTone.self, forKey: .blockerTone)
        dependsOn = try c.decode([Int64].self, forKey: .dependsOn)
        deliverableKind = try c.decodeIfPresent(DeliverableKind.self, forKey: .deliverableKind)
        deliverableRef = try c.decode(String.self, forKey: .deliverableRef)
        owner = try c.decode(String.self, forKey: .owner)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        position = try c.decode(Int.self, forKey: .position)
        source = try c.decode(String.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// 画面に出す題。番号があれば頭に付ける（「M3.6 移行の手順」）
    public var codedTitle: String { code.isEmpty ? title : "\(code) \(title)" }

    /// 同じタスクの項目一覧から、項目ごと（`itemID`）の画面用の状態を導く。依存は直接の依存だけを見る（循環があっても止まらない）。
    /// 一覧に無い id への依存は満たされたものとして扱う（消された項目で永久に塞がないため）
    public static func effectiveStates(of items: [WorkItem]) -> [Int64: EffectiveState] {
        let byID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        return byID.mapValues { item in
            switch item.state {
            case .doing: return .doing
            case .wait: return .wait
            case .done: return .done
            case .drop: return .drop
            case .todo:
                let blocked = item.dependsOn.contains { dep in
                    guard let other = byID[dep] else { return false }
                    return other.state != .done && other.state != .drop
                }
                return blocked ? .todo : .ready
            }
        }
    }

    /// 待ちの 1 行。blocker の色をカードの待ち理由の色に写す。
    public var waitLine: WaitLine? {
        guard state == .wait else { return nil }
        let text = blockerText.isEmpty ? (blockerKind?.label ?? String(localized: "待ち")) : blockerText
        let tone: WaitLine.Tone =
            switch blockerTone ?? blockerKind?.defaultTone ?? .dim {
            case .attention: .mine
            case .ok: .theirs
            case .dim: .quiet
            }
        return WaitLine(text: text, tone: tone)
    }

    /// 利用者に頼んだ手作業の待ち（受信箱の依頼になる）
    public var isManualWait: Bool { state == .wait && blockerKind == .manual }
}

extension WorkItem.BlockerKind {
    public var label: String {
        switch self {
        case .approval: String(localized: "承認・回答待ち")
        case .manual: String(localized: "手作業待ち")
        case .review: String(localized: "レビュー待ち")
        case .ci: String(localized: "CI待ち")
        case .deploy: String(localized: "デプロイ待ち")
        case .item: String(localized: "別の項目待ち")
        case .external: String(localized: "外部待ち")
        }
    }

    /// 種別だけ分かるときの色。自分の承認と手作業は自分の番、他は待つだけ。
    public var defaultTone: WorkItem.BlockerTone {
        switch self {
        case .approval, .manual: .attention
        case .review, .ci, .deploy, .item, .external: .dim
        }
    }
}

extension WorkItem.EffectiveState {
    public var label: String {
        switch self {
        case .todo: String(localized: "未着手")
        case .ready: String(localized: "着手できる")
        case .doing: String(localized: "作業中")
        case .wait: String(localized: "待ち")
        case .done: String(localized: "完了")
        case .drop: String(localized: "見送り")
        }
    }
}

/// タスクの進捗（カードの 2 行目と進捗帯）。作業項目から導く。
public struct TaskProgress: Hashable, Sendable {
    /// 見送りを除いた数
    public var total: Int
    public var done: Int
    /// 作業中の項目（計画順）
    public var current: [WorkItem]
    /// 待ちの項目（計画順）
    public var waiting: [WorkItem]
    public var ready: Int

    public static func derive(_ items: [WorkItem]) -> TaskProgress? {
        guard !items.isEmpty else { return nil }
        let ordered = items.sorted { ($0.position, $0.itemID) < ($1.position, $1.itemID) }
        let effective = WorkItem.effectiveStates(of: ordered)
        let states = ordered.map { ($0, effective[$0.itemID] ?? .todo) }
        return TaskProgress(
            total: states.filter { $0.1 != .drop }.count,
            done: states.filter { $0.1 == .done }.count,
            current: states.filter { $0.1 == .doing }.map(\.0),
            waiting: states.filter { $0.1 == .wait }.map(\.0),
            ready: states.filter { $0.1 == .ready }.count)
    }

    /// カードと帯に出す待ち理由。自分の番（attention）を他の待ちより優先し、同じ色なら計画順。
    public var primaryWait: WaitLine? {
        let rank: (WaitLine.Tone) -> Int = { tone in
            switch tone {
            case .mine: 0
            case .theirs: 1
            case .quiet: 2
            }
        }
        return waiting.compactMap(\.waitLine).min { rank($0.tone) < rank($1.tone) }
    }

    /// カードの 2 行目: 今の項目名（複数なら数）。
    public var currentLabel: String? {
        switch current.count {
        case 0: nil
        case 1: current[0].title
        default: "\(current.count)件を作業中"
        }
    }

    public var fractionLabel: String { "\(done) / \(total)" }
}

// MARK: - 要求

/// `POST /v1/tasks/{number}/work`。
public struct WorkItemCreateRequest: Codable, Hashable, Sendable {
    public var title: String
    public var state: WorkItem.State
    public var blockerKind: WorkItem.BlockerKind?
    public var blockerText: String
    public var blockerTone: WorkItem.BlockerTone?
    public var dependsOn: [Int64]
    public var deliverableKind: WorkItem.DeliverableKind?
    public var deliverableRef: String
    public var owner: String
    public var group: String
    public var code: String
    /// nil なら末尾
    public var position: Int?
    public var source: String

    public init(
        title: String, state: WorkItem.State = .todo, blockerKind: WorkItem.BlockerKind? = nil, blockerText: String = "",
        blockerTone: WorkItem.BlockerTone? = nil, dependsOn: [Int64] = [], deliverableKind: WorkItem.DeliverableKind? = nil,
        deliverableRef: String = "", owner: String = "", group: String = "", code: String = "", position: Int? = nil, source: String = "manual"
    ) {
        self.title = title
        self.state = state
        self.blockerKind = blockerKind
        self.blockerText = blockerText
        self.blockerTone = blockerTone
        self.dependsOn = dependsOn
        self.deliverableKind = deliverableKind
        self.deliverableRef = deliverableRef
        self.owner = owner
        self.group = group
        self.code = code
        self.position = position
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case title, state, blockerKind, blockerText, blockerTone, dependsOn, deliverableKind, deliverableRef, owner, group, code, position, source
    }

    /// まとまりと番号を持たない前の版のアプリの要求も読む
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        state = try c.decode(WorkItem.State.self, forKey: .state)
        blockerKind = try c.decodeIfPresent(WorkItem.BlockerKind.self, forKey: .blockerKind)
        blockerText = try c.decode(String.self, forKey: .blockerText)
        blockerTone = try c.decodeIfPresent(WorkItem.BlockerTone.self, forKey: .blockerTone)
        dependsOn = try c.decode([Int64].self, forKey: .dependsOn)
        deliverableKind = try c.decodeIfPresent(WorkItem.DeliverableKind.self, forKey: .deliverableKind)
        deliverableRef = try c.decode(String.self, forKey: .deliverableRef)
        owner = try c.decode(String.self, forKey: .owner)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        position = try c.decodeIfPresent(Int.self, forKey: .position)
        source = try c.decode(String.self, forKey: .source)
    }
}

/// `PATCH /v1/work/{id}`。nil は変えない。blocker / deliverable を消すのは `clearBlocker` / `clearDeliverable`。
public struct WorkItemUpdateRequest: Codable, Hashable, Sendable {
    public var title: String?
    public var state: WorkItem.State?
    public var blockerKind: WorkItem.BlockerKind?
    public var blockerText: String?
    public var blockerTone: WorkItem.BlockerTone?
    public var clearBlocker: Bool
    public var dependsOn: [Int64]?
    public var deliverableKind: WorkItem.DeliverableKind?
    public var deliverableRef: String?
    public var clearDeliverable: Bool
    public var owner: String?
    /// 空の文字列でまとまり・番号を外す
    public var group: String?
    public var code: String?
    public var position: Int?

    public init(
        title: String? = nil, state: WorkItem.State? = nil, blockerKind: WorkItem.BlockerKind? = nil, blockerText: String? = nil,
        blockerTone: WorkItem.BlockerTone? = nil, clearBlocker: Bool = false, dependsOn: [Int64]? = nil,
        deliverableKind: WorkItem.DeliverableKind? = nil, deliverableRef: String? = nil, clearDeliverable: Bool = false,
        owner: String? = nil, group: String? = nil, code: String? = nil, position: Int? = nil
    ) {
        self.title = title
        self.state = state
        self.blockerKind = blockerKind
        self.blockerText = blockerText
        self.blockerTone = blockerTone
        self.clearBlocker = clearBlocker
        self.dependsOn = dependsOn
        self.deliverableKind = deliverableKind
        self.deliverableRef = deliverableRef
        self.clearDeliverable = clearDeliverable
        self.owner = owner
        self.group = group
        self.code = code
        self.position = position
    }
}

/// `POST /v1/sessions/link`: SessionStart hook がセッションをタスクに結ぶ。
/// `taskNumber` を省くと daemon が決める（同じ session_id の紐づけ → 同じ cwd のタスク）。
public struct SessionLinkRequest: Codable, Hashable, Sendable {
    public var paneID: PaneID?
    public var agent: String
    public var agentSessionID: String
    public var cwd: String
    public var taskNumber: Int?
    public var label: String

    public init(paneID: PaneID? = nil, agent: String, agentSessionID: String, cwd: String, taskNumber: Int? = nil, label: String = "") {
        self.paneID = paneID
        self.agent = agent
        self.agentSessionID = agentSessionID
        self.cwd = cwd
        self.taskNumber = taskNumber
        self.label = label
    }

    /// API を直接叩く側が `label` / `paneID` / `taskNumber` を省けるように
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try c.decodeIfPresent(PaneID.self, forKey: .paneID)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
        agentSessionID = try c.decode(String.self, forKey: .agentSessionID)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        taskNumber = try c.decodeIfPresent(Int.self, forKey: .taskNumber)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

/// `POST /v1/sessions/link` と `GET /v1/resolve` の応答。`task` が nil なら結べなかった。
public struct TaskResolution: Codable, Hashable, Sendable {
    public var task: BoardTask?
    /// どう決めたか: `existing`（同じ session_id）/ `cwd`（同じ cwd）/ `explicit` / `launch` / `none`
    public var method: String
    /// タスクの案件（列の id と名前を hook の案内に載せる）。結べなかったとき、古い daemon では nil
    public var board: Board?

    public init(task: BoardTask?, method: String, board: Board? = nil) {
        self.task = task
        self.method = method
        self.board = board
    }

    private enum CodingKeys: String, CodingKey { case task, method, board }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decodeIfPresent(BoardTask.self, forKey: .task)
        method = try c.decode(String.self, forKey: .method)
        board = try c.decodeIfPresent(Board.self, forKey: .board)
    }
}

/// `POST /v1/hooks/stop`: Stop hook。紐づくタスクの列を PR の実状態へ進め、無ければ PR から起票する。
public struct HookStopRequest: Codable, Hashable, Sendable {
    public var paneID: PaneID?
    public var agent: String
    public var agentSessionID: String
    public var cwd: String
    /// 終わったターンの始まり（最後の人の発話）と、その後に taskboard 以外のツールを呼んだか。hook が transcript から読む。
    /// 読めなければ nil で、待ちの見直し（`HookStopResponse.reminder`）をしない
    public var turnStartedAt: Date?
    public var turnUsedTools: Bool?
    /// 終わったターンの最後の応答の文（hook の入力の `last_assistant_message`）と、そのターンで文書・質問を出したか（transcript）。
    /// どちらかが無ければ、問いの差し戻しをしない
    public var turnLastReply: String?
    public var turnPresented: Bool?

    public init(
        paneID: PaneID? = nil, agent: String, agentSessionID: String, cwd: String, turnStartedAt: Date? = nil, turnUsedTools: Bool? = nil,
        turnLastReply: String? = nil, turnPresented: Bool? = nil
    ) {
        self.paneID = paneID
        self.agent = agent
        self.agentSessionID = agentSessionID
        self.cwd = cwd
        self.turnStartedAt = turnStartedAt
        self.turnUsedTools = turnUsedTools
        self.turnLastReply = turnLastReply
        self.turnPresented = turnPresented
    }
}

public struct HookStopResponse: Codable, Hashable, Sendable {
    public var task: BoardTask?
    /// hook が stdout に出してよい 1 行（起票した・列を進めた）。無ければ黙る
    public var messages: [String]
    /// 待ちにした後のターンで作業したのに、待ちのままの作業項目の見直しの依頼。hook は stderr に載せて exit 2 でモデルを起こす。
    /// 同じ待ちについては 1 回だけ返る
    public var reminder: String?
    /// 回答・レビューは daemon がこのセッションの pane に人の発話として入れる。hook は `feedback/claim` で待たずに終わる。
    /// false（pane の無いセッション・古い daemon）なら今までどおり待つ
    public var feedbackViaPane: Bool

    public init(task: BoardTask?, messages: [String], reminder: String? = nil, feedbackViaPane: Bool = false) {
        self.task = task
        self.messages = messages
        self.reminder = reminder
        self.feedbackViaPane = feedbackViaPane
    }

    private enum CodingKeys: String, CodingKey { case task, messages, reminder, feedbackViaPane }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decodeIfPresent(BoardTask.self, forKey: .task)
        messages = try c.decode([String].self, forKey: .messages)
        reminder = try c.decodeIfPresent(String.self, forKey: .reminder)
        feedbackViaPane = try c.decodeIfPresent(Bool.self, forKey: .feedbackViaPane) ?? false
    }
}

/// `POST /v1/hooks/prompt`: UserPromptSubmit hook。結ばれたタスクの題に合わせた会話の題を返す
public struct HookPromptRequest: Codable, Hashable, Sendable {
    public var agentSessionID: String
    /// hook の入力の `session_title`（付いている会話の題）
    public var sessionTitle: String?

    public init(agentSessionID: String, sessionTitle: String?) {
        self.agentSessionID = agentSessionID
        self.sessionTitle = sessionTitle
    }
}

public struct HookPromptResponse: Codable, Hashable, Sendable {
    /// 付け直す会話の題。そのままでよければ nil
    public var sessionTitle: String?

    public init(sessionTitle: String?) {
        self.sessionTitle = sessionTitle
    }
}
