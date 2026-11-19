import Foundation
import Observation

/// 1 つの供給元（= 1 マシン）の現在の見え方。
/// マシンに書き込めるか（`Fleet.writeAccess`）
public enum WriteAccess: Hashable, Sendable {
    case writable
    /// 表示用のデータ（fixtures）。読むだけ
    case readOnly
    /// 1 台だけ表示か、設定の非表示で隠している
    case hidden
    /// そのマシンの状態がまだ届いていない（接続していない、接続先が消えた）
    case unknown
}

public struct MachineState: Hashable, Sendable {
    public var machine: MachineInfo? { didSet { derived = MachineDerived() } }
    public var boards: [String: Board] = [:] { didSet { derived = MachineDerived() } }
    public var tasks: [TaskKey: BoardTask] = [:] { didSet { derived = MachineDerived() } }
    public var workItems: [WorkItemKey: WorkItem] = [:] { didSet { derived = MachineDerived() } }
    public var documents: [DocKey: Document] = [:] { didSet { derived = MachineDerived() } }
    public var prs: PRSnapshot? { didSet { derived = MachineDerived() } }
    /// `/v1/state` から読んだ利用枠。`Fleet` はここに残さず `Fleet.usage` に移す
    public var usage: UsageSnapshot?
    /// タスクのリンクの状態。key は URL
    public var links: [String: LinkStatus] = [:] { didSet { derived = MachineDerived() } }
    public var schedules: [ScheduleKey: Schedule] = [:] { didSet { derived = MachineDerived() } }
    public var asks: [AskKey: Ask] = [:] { didSet { derived = MachineDerived() } }
    public var reviewRequests: [TaskKey: ReviewRequest] = [:] { didSet { derived = MachineDerived() } }
    /// マシンの設定。P6 までの daemon は nil
    public var settings: MachineSettings?
    /// オーケストレーターの状態。P6 までの daemon は nil
    public var orchestrator: OrchestratorInfo? { didSet { derived = MachineDerived() } }
    /// ペアリングした端末。`devices.updated` が来るか、設定画面が `GET /v1/devices` で取るまで nil
    public var devices: [DeviceInfo]?
    /// そのマシンの codex（アカウント・コネクタ）。設定画面が `GET /v1/codex` で取るまで nil
    public var codex: CodexMachineInfo?
    /// そのマシンの Claude Code のモデルの一覧。起動の欄と会話の欄が `GET /v1/claude` で取るまで nil（引くときは `ClaudeModels` の控えで引く）
    public var claude: ClaudeMachineInfo?
    /// 受信箱で消した項目の記録。key は `InboxDismissal.itemID`
    public var inboxDismissals: [String: InboxDismissal] = [:] { didSet { derived = MachineDerived() } }
    /// host の会話の様子。発言は会話を開いたときに購読する
    public var conversations: [ConversationKey: Conversation] = [:] { didSet { derived = MachineDerived() } }
    /// 起こす予定
    public var wakes: [WakeKey: Wake] = [:] { didSet { derived = MachineDerived() } }
    public var watches: [WatchKey: Watch] = [:] { didSet { derived = MachineDerived() } }
    /// 会話が登録した概況（部品のあるタスクだけ）
    public var panels: [TaskKey: OverviewPanel] = [:] { didSet { derived = MachineDerived() } }
    /// 供給元との接続
    public var connected: Bool
    /// 繋がった回数（切れてから繋ぎ直すたびに 1 増える）。接続ごとに 1 回だけ確かめる値（daemon が持つ口など）を、繋ぎ直したら取り直すのに使う
    public var connection = 0
    public var lastError: String?
    /// アーカイブしていない案件。ボード・サイドバー・⌘K・起票の候補はこちらを見る（設定の案件の一覧だけが `boards` の全部を見る）
    public var activeBoards: [String: Board] { boards.filter { !$0.value.archived } }
    /// 最後の失敗が認証（daemon の token / Cloudflare Access）によるものなら、その種類。資格情報の差し替えを促すのに使う
    public var authFailure: SessionSourceError?
    /// 上の欄から数えたものの控え
    var derived = MachineDerived()

    public init(machine: MachineInfo? = nil, connected: Bool = false, lastError: String? = nil) {
        self.machine = machine
        self.connected = connected
        self.lastError = lastError
    }

    mutating func connect() {
        if !connected { connection += 1 }
        connected = true
    }

    public mutating func apply(_ event: DaemonEvent) {
        switch event {
        case .stateSnapshot(let snap):
            machine = snap.machine
            boards = Dictionary(uniqueKeysWithValues: snap.boards.map { ($0.id, $0) })
            tasks = Dictionary(uniqueKeysWithValues: snap.tasks.map { ($0.id, $0) })
            workItems = Dictionary(uniqueKeysWithValues: snap.workItems.map { ($0.id, $0) })
            documents = Dictionary(uniqueKeysWithValues: snap.documents.map { ($0.id, $0) })
            asks = Dictionary(uniqueKeysWithValues: snap.asks.map { ($0.id, $0) })
            reviewRequests = Dictionary(uniqueKeysWithValues: snap.reviewRequests.map { ($0.id, $0) })
            prs = snap.prs
            usage = snap.usage
            links = Dictionary(snap.links.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            schedules = Dictionary(uniqueKeysWithValues: snap.schedules.map { ($0.id, $0) })
            settings = snap.settings
            orchestrator = snap.orchestrator
            inboxDismissals = Self.dismissalsByItem(snap.inboxDismissals)
            conversations = Dictionary(snap.conversations.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
            wakes = Dictionary(snap.wakes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            watches = Dictionary(snap.watches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            panels = Dictionary(snap.panels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        case .machineUpdated(let m):
            machine = m
        case .boardUpdated(let b):
            boards[b.id] = b
        case .boardRemoved(let id):
            boards.removeValue(forKey: id)
        case .taskUpdated(let t):
            tasks[t.id] = t
        case .taskRemoved(let key):
            tasks.removeValue(forKey: key)
            for item in workItems.values where item.taskNumber == key.number && item.machine == key.machine {
                workItems.removeValue(forKey: item.id)
            }
            for doc in documents.values where doc.taskNumber == key.number && doc.machine == key.machine {
                documents.removeValue(forKey: doc.id)
            }
            for ask in asks.values where ask.taskNumber == key.number && ask.machine == key.machine {
                asks.removeValue(forKey: ask.id)
            }
            for wake in wakes.values where wake.taskNumber == key.number && wake.machine == key.machine {
                wakes.removeValue(forKey: wake.id)
            }
            for watch in watches.values where watch.taskNumber == key.number && watch.machine == key.machine {
                watches.removeValue(forKey: watch.id)
            }
            reviewRequests.removeValue(forKey: key)
            panels.removeValue(forKey: key)
        case .workUpdated(let w):
            workItems[w.id] = w
        case .workRemoved(let key):
            workItems.removeValue(forKey: key)
        case .docUpdated(let doc):
            documents[doc.id] = doc
        case .docRemoved(let key):
            documents.removeValue(forKey: key)
            for ask in asks.values where ask.docID == key.id && ask.machine == key.machine {
                asks.removeValue(forKey: ask.id)
            }
        case .askUpdated(let ask):
            // 受領済み（delivered）と取り下げは一覧から落とす。文書画面は履歴を API で取る
            if ask.status == .cancelled || ask.deliveredAt != nil {
                asks.removeValue(forKey: ask.id)
            } else {
                asks[ask.id] = ask
            }
        case .reviewRequestUpdated(let request):
            reviewRequests[request.id] = request
        case .reviewRequestRemoved(let key):
            reviewRequests.removeValue(forKey: key)
        case .prsUpdated(let snapshot):
            prs = snapshot
        case .usageUpdated(let snapshot):
            usage = snapshot
        case .linksUpdated(let statuses):
            links = Dictionary(statuses.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        case .scheduleUpdated(let schedule):
            schedules[schedule.id] = schedule
        case .scheduleRemoved(let key):
            schedules.removeValue(forKey: key)
        case .settingsUpdated(let value):
            settings = value
        case .orchestratorUpdated(let value):
            orchestrator = value
        case .devicesUpdated(let value):
            devices = value
        case .inboxDismissalsUpdated(let value):
            inboxDismissals = Self.dismissalsByItem(value)
        case .conversationUpdated(let value):
            conversations[value.key] = value
        case .conversationRemoved(let key):
            conversations.removeValue(forKey: key)
        case .conversationActivity:
            // `Fleet.toolActivity` に置く（ツールのたびに届くので、マシンの状態を変えない）
            break
        case .wakeUpdated(let value):
            wakes[value.id] = value
        case .wakeRemoved(let key):
            wakes.removeValue(forKey: key)
        case .watchUpdated(let value):
            watches[value.id] = value
        case .watchRemoved(let key):
            watches.removeValue(forKey: key)
        case .panelUpdated(let panel):
            panels[panel.id] = panel
        case .panelRemoved(let key):
            panels.removeValue(forKey: key)
        }
    }

    static func dismissalsByItem(_ records: [InboxDismissal]) -> [String: InboxDismissal] {
        Dictionary(records.map { ($0.itemID, $0) }, uniquingKeysWith: { a, b in a.dismissedAt >= b.dismissedAt ? a : b })
    }

    /// タスクの文書（新しい順）。
    public func documents(forTask number: Int) -> [Document] {
        documents.values.filter { $0.taskNumber == number }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 文書の未回答の質問。
    public func openAsk(forDoc id: Int64) -> Ask? {
        asks.values.first { $0.docID == id && $0.status == .open }
    }

    /// タスクの作業項目を計画順で。
    public func workItems(forTask number: Int) -> [WorkItem] {
        let byTask = derived.value(.workByTask) {
            Dictionary(grouping: workItems.values, by: \.taskNumber).mapValues { $0.sorted { ($0.position, $0.itemID) < ($1.position, $1.itemID) } }
        }
        return byTask[number] ?? []
    }
}

/// 接続先のマシンの ID と名前（`Fleet.identities`）
public struct MachineIdentity: Hashable, Sendable {
    public var id: MachineID
    public var name: String
}

/// そのマシンの Claude Code と codex の値（`Fleet.engines(on:)`）
public struct MachineEngines: Hashable, Sendable {
    public var claude: ClaudeMachineInfo?
    public var codex: CodexMachineInfo?
}

/// `Fleet` の引き口 1 つぶんの見張りの箱。読む画面は、その値が変わったときだけ描き直される
@MainActor
@Observable
final class FleetCell<Value: Equatable> {
    private(set) var value: Value
    /// 捨てた印。読んでいた画面を描き直させ、次に読むときに新しい箱を作らせる
    private(set) var retired = false
    @ObservationIgnored private let compute: (Fleet) -> Value

    init(_ fleet: Fleet, compute: @escaping (Fleet) -> Value) {
        self.compute = compute
        value = compute(fleet)
    }

    func refresh(_ fleet: Fleet) {
        let next = compute(fleet)
        if next != value { value = next }
    }

    func retire() { retired = true }
}

@MainActor
private protocol RefreshableCell: AnyObject {
    func refresh(_ fleet: Fleet)
    func retire()
}

extension FleetCell: RefreshableCell {}

/// 箱の鍵。`machine` のマシンの知らせで入れ直す
private enum FleetCellKey: Hashable {
    case conversation(ConversationKey)
    case forks(ConversationKey)
    case delegates(ConversationKey)
    case engines(MachineID)
    case tool(ConversationKey)

    var machine: MachineID {
        switch self {
        case .conversation(let key), .forks(let key), .delegates(let key), .tool(let key): key.machine
        case .engines(let machine): machine
        }
    }
}

/// 複数の供給元を 1 つに合成し、アプリの画面が観測する状態。
@MainActor
@Observable
public final class Fleet {
    /// 接続しているすべてのマシン。画面は `machines` を見る
    public private(set) var allMachines: [String: MachineState] = [:]
    /// 1 台だけ表示で残すマシン（接続設定の id）。nil なら全部。接続は切らない
    public var onlyMachine: String? {
        didSet {
            refreshCells()
            rebuildOverview()
        }
    }
    /// 設定で非表示にしたマシン（接続設定の id）。接続は切らない
    public var hiddenMachines: Set<String> = [] {
        didSet {
            refreshCells()
            rebuildOverview()
        }
    }
    /// 接続先ごとのマシンの ID と名前。マシン ID から接続先を引く所（書き込めるか・マシン名）はこれを読む。
    /// `allMachines` を読むと、どのマシンのどの知らせでも描き直される
    public private(set) var identities: [String: MachineIdentity] = [:]
    /// 会話・フォーク・委譲先・セッション・モデルの一覧の引き口の箱（`cached`）。読む画面は、その値が変わったときだけ描き直される
    @ObservationIgnored private var cells: [FleetCellKey: any RefreshableCell] = [:]
    /// 箱を最後に引いた順番（多すぎたら古いものから捨てる）
    @ObservationIgnored private var cellUses: [FleetCellKey: Int] = [:]
    @ObservationIgnored private var cellClock = 0
    /// 箱の数の上限。知らせのたびに、届いたマシンの箱を全部計算し直すので、開いた会話の数だけ増やし続けない
    static let cellLimit = 128
    /// マシンごとの利用枠（接続設定の id）。statusline のたびに届くので `allMachines` と分ける。
    /// 同じプロパティに持つと、届くたびにマシンの状態を読む画面がすべて描き直される
    public private(set) var usage: [String: UsageSnapshot] = [:]
    /// 会話が使っているツールの名前（接続設定の id → 会話 → 名前）。ツールのたびに届くので `allMachines` と分け、札は `toolName(of:)` の箱で読む
    @ObservationIgnored private var toolActivity: [String: [ConversationKey: String]] = [:]

    /// 受信箱（出すマシンの分。無視・既読と、送っている途中の操作を効かせたもの）。`Fleet` の中身が変わったときに 1 回だけ組み、
    /// 中身が変わったときだけ書く。サイドバーの札・Dock とタブのバッジ・通知は、これを読むだけにする
    public private(set) var inbox = InboxContents()
    /// 隠したマシンの分と、消した項目も含めた受信箱（受信箱の並び）。通知が「もう見た」を覚えるのに使う（解除したとき・戻したときに、まとめて鳴らないように）
    public private(set) var inboxIncludingHidden: [InboxItem] = []
    /// 出すマシンの会話の札（見張り盤と iPhone の「対応待ち」の節）。受信箱と同じときに組む
    public private(set) var conversationTiles = ConversationTiles()
    /// 端末が送っている途中の受信箱の操作（key は `InboxItem.id`、値は消した revision。nil は戻した）。daemon の記録より先に効かせる
    public var inboxPending: [String: String?] = [:] {
        didSet { if inboxPending != oldValue { rebuildOverview() } }
    }
    /// この端末で見ていないターンの終わりの会話（アプリの `UnreadMarks`）。札の「未読」
    public var unreadConversations: Set<ConversationKey> = [] {
        didSet { if unreadConversations != oldValue { rebuildOverview() } }
    }
    @ObservationIgnored private let now: @MainActor () -> Date
    /// 受信箱の中身が時刻で変わる（お知らせが窓から出る・日付が替わる）ときに組み直す
    @ObservationIgnored private var overviewExpiry: Task<Void, Never>?
    /// 画面に出すマシン。1 台だけ表示の間は `onlyMachine` だけ（そのマシンが無ければ空。他のマシンを見せないため）。それ以外は非表示のマシンを除く
    public var machines: [String: MachineState] {
        if onlyMachine == nil, hiddenMachines.isEmpty { return allMachines }
        return allMachines.filter { isVisible(fleetID: $0.key) }
    }

    /// その接続先を画面に出すか（`machines` と、iPhone・iPad の通知の登録が同じ決まりを使う）
    public func isVisible(fleetID: String) -> Bool {
        if let onlyMachine { return fleetID == onlyMachine }
        return !hiddenMachines.contains(fleetID)
    }

    /// そのマシンに書き込めるか。画面の操作の可否と、できないときの理由の文はこれ 1 つで決める
    public func writeAccess(_ machine: MachineID) -> WriteAccess {
        let ids = identities.filter { $0.value.id == machine }.keys
        if let id = ids.first(where: isVisible(fleetID:)) {
            let source = sources[id]
            return source is any DaemonWriter || source is any ConversationSource ? .writable : .readOnly
        }
        return ids.isEmpty ? .unknown : .hidden
    }
    private var sources: [String: any SessionSource] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var streams: [String: any StreamConnection] = [:]
    @ObservationIgnored private var conversationListeners: [ConversationKey: ListenerEntry] = [:]
    /// 画面を離れても unsubscribe を送らない（debug の口。裏に入れたときに購読の数がいつ減るかを測る）
    @ObservationIgnored public var keepsSubscriptions = false

    private struct ListenerEntry {
        weak var listener: (any ConversationListener)?
        var count: Int
    }

    /// `now` は受信箱を組む時刻（テストが差し替える）
    public init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    /// 供給元を追加して購読を始める。`id` は接続設定ごとの識別子（マシン ID が分かる前から要るので文字列）。
    /// daemon は 1 本の接続（`/v1/stream`）で受け、切れたか断られたら `reconnectDelay` の後に開き直す
    public func add(id: String, source: any SessionSource, reconnectDelay: Duration = .seconds(3)) {
        tasks[id]?.cancel()
        allMachines[id] = MachineState()
        identities.removeValue(forKey: id)
        toolActivity.removeValue(forKey: id)
        refreshCells()
        rebuildOverview()
        sources[id] = source
        tasks[id] = Task { [weak self] in
            let cursor = StreamCursor()
            while !Task.isCancelled {
                do {
                    switch source {
                    case let stream as any StreamSource:
                        do {
                            try await self?.readStream(id, stream.openStateStream(), cursor: cursor)
                        } catch StreamRestart.revisionSkipped {
                            // 番号が飛んだ。全体を受け直す（待たない）
                            continue
                        }
                    case let snapshots as any SnapshotSource:
                        try await self?.readEvents(id, snapshots)
                    default:
                        return
                    }
                    self?.update(id) { $0.connected = false }
                } catch {
                    self?.update(id) { state in
                        state.connected = false
                        state.lastError = String(describing: error)
                        let failure = error as? SessionSourceError
                        state.authFailure = failure == .unauthorized || failure == .forbidden ? failure : nil
                    }
                }
                try? await Task.sleep(for: reconnectDelay)
            }
        }
    }

    /// fixtures とテスト。全体を取ってから出来事を読む
    private func readEvents(_ id: String, _ source: any SnapshotSource) async throws {
        let snap = try await source.snapshot()
        applySnapshot(id, snap)
        for try await event in source.events() {
            apply(id, event)
        }
    }

    /// 1 本の接続。前に受けた番号で `hello` を送り、全体か続きを受ける。番号が 1 つ飛んだら、番号を捨てて繋ぎ直す
    private func readStream(_ id: String, _ connection: any StreamConnection, cursor: StreamCursor) async throws {
        defer {
            connection.close()
            disconnectStream(id)
        }
        // upgrade を断られたら send が先に失敗する。断られた理由（404 など）は frames が投げる
        try? await connection.send(.hello(epoch: cursor.epoch, rev: cursor.rev))
        for try await frame in connection.frames {
            switch frame {
            case .state(let epoch, let rev, let snapshot):
                cursor.epoch = epoch
                cursor.rev = rev
                applySnapshot(id, snapshot)
                if streams[id] == nil {
                    // 接続の途中の全体（daemon の stateSnapshot）では購読し直さない（同じ接続に 2 つ購読ができる）
                    streams[id] = connection
                    await resubscribe(id, connection)
                }
            case .resume(let epoch, let rev):
                cursor.epoch = epoch
                cursor.rev = rev
                update(id) { state in
                    state.connect()
                    state.lastError = nil
                    state.authFailure = nil
                }
                if streams[id] == nil {
                    // 接続の途中の全体（daemon の stateSnapshot）では購読し直さない（同じ接続に 2 つ購読ができる）
                    streams[id] = connection
                    await resubscribe(id, connection)
                }
            case .event(let rev, let event):
                if let last = cursor.rev {
                    if rev <= last { continue }
                    guard rev == last + 1 else {
                        cursor.epoch = nil
                        cursor.rev = nil
                        throw StreamRestart.revisionSkipped
                    }
                }
                cursor.rev = rev
                if let event { apply(id, event) }
            case .subscribed(let conversation, let epoch, let through):
                listener(id, conversation)?.streamSubscribed(epoch: epoch, through: through)
            case .conversation(let event):
                listener(id, event.conversationID)?.streamEvent(event)
            case .unsubscribed(let conversation, let reason):
                guard let listener = listener(id, conversation) else { continue }
                if reason == StreamServerFrame.behind {
                    let point = listener.resumePoint
                    try? await connection.send(.subscribe(conversation: conversation, epoch: point.epoch, after: point.after, subagents: true))
                } else {
                    listener.streamUnsubscribed(reason: reason)
                }
            }
        }
    }

    private func applySnapshot(_ id: String, _ snap: StateSnapshot) {
        update(id) { state in
            state.apply(.stateSnapshot(snap))
            state.connect()
            state.lastError = nil
            state.authFailure = nil
        }
        setUsage(id, snap.usage)
        setToolActivity(id, snap)
    }

    private func apply(_ id: String, _ event: DaemonEvent) {
        switch event {
        case .usageUpdated(let snapshot):
            setUsage(id, snapshot)
        case .stateSnapshot(let snap):
            // 全体の中の利用枠も `Fleet.usage` に移す（`update` は `MachineState.usage` を捨てる）
            update(id) { $0.apply(event) }
            setUsage(id, snap.usage)
            setToolActivity(id, snap)
        case .conversationActivity(let activity):
            setToolActivity(id, activity)
        case .conversationRemoved(let key):
            update(id) { $0.apply(event) }
            setToolActivity(id, ConversationToolActivity(conversation: key, toolName: nil))
        default:
            update(id) { $0.apply(event) }
        }
    }

    // MARK: 会話の購読

    /// 会話の画面が出ている間だけ購読する。同じ会話を 2 か所で開いても、線の上の subscribe は 1 つ
    public func retainConversation(_ key: ConversationKey, listener: any ConversationListener) {
        if var entry = conversationListeners[key] {
            entry.count += 1
            entry.listener = listener
            conversationListeners[key] = entry
            return
        }
        conversationListeners[key] = ListenerEntry(listener: listener, count: 1)
        guard let id = fleetID(for: key.machine), let connection = streams[id] else { return }
        let point = listener.resumePoint
        Task { try? await connection.send(.subscribe(conversation: key.id, epoch: point.epoch, after: point.after, subagents: true)) }
    }

    /// 最後の 1 つが離れたら unsubscribe を送る。`keepsSubscriptions` の間は送らない（確かめ用）
    public func releaseConversation(_ key: ConversationKey) {
        guard var entry = conversationListeners[key] else { return }
        entry.count -= 1
        guard entry.count <= 0 else {
            conversationListeners[key] = entry
            return
        }
        conversationListeners.removeValue(forKey: key)
        guard !keepsSubscriptions, let id = fleetID(for: key.machine), let connection = streams[id] else { return }
        Task { try? await connection.send(.unsubscribe(conversation: key.id)) }
    }

    /// 購読している会話（確かめ用）
    public var subscribedConversations: [ConversationKey: Int] { conversationListeners.mapValues(\.count) }

    /// 1 本の接続で受けているマシンか（今の取り方の daemon と fixtures は false）
    public func isStreaming(_ machine: MachineID) -> Bool {
        fleetID(for: machine).map { streams[$0] != nil } ?? false
    }

    private func listener(_ id: String, _ conversation: String) -> (any ConversationListener)? {
        guard let machine = allMachines[id]?.machine?.id else { return nil }
        return conversationListeners[ConversationKey(machine: machine, id: conversation)]?.listener
    }

    private func resubscribe(_ id: String, _ connection: any StreamConnection) async {
        guard let machine = allMachines[id]?.machine?.id else { return }
        for (key, entry) in conversationListeners where key.machine == machine {
            guard let listener = entry.listener else { continue }
            let point = listener.resumePoint
            try? await connection.send(.subscribe(conversation: key.id, epoch: point.epoch, after: point.after, subagents: true))
        }
    }

    private func disconnectStream(_ id: String) {
        guard streams.removeValue(forKey: id) != nil, let machine = allMachines[id]?.machine?.id else { return }
        for (key, entry) in conversationListeners where key.machine == machine { entry.listener?.streamDisconnected() }
    }

    /// そのマシンの接続先（隠しているマシンも引く）
    public func fleetID(for machine: MachineID) -> String? {
        identities.first { $0.value.id == machine }?.key
    }

    /// そのマシンの、画面に出している接続先
    private func visibleFleetID(for machine: MachineID) -> String? {
        identities.first { $0.value.id == machine && isVisible(fleetID: $0.key) }?.key
    }

    public func remove(id: String) {
        tasks[id]?.cancel()
        streams.removeValue(forKey: id)?.close()
        tasks.removeValue(forKey: id)
        allMachines.removeValue(forKey: id)
        identities.removeValue(forKey: id)
        usage.removeValue(forKey: id)
        toolActivity.removeValue(forKey: id)
        sources.removeValue(forKey: id)
        refreshCells()
        rebuildOverview()
    }

    public func task(for key: TaskKey) -> BoardTask? {
        machines.values.lazy.compactMap { $0.tasks[key] }.first
    }

    public func workItems(for key: TaskKey) -> [WorkItem] {
        machineState(for: key.machine)?.workItems(forTask: key.number) ?? []
    }

    public func documents(for key: TaskKey) -> [Document] {
        machineState(for: key.machine)?.documents(forTask: key.number) ?? []
    }

    public func document(for key: DocKey) -> Document? {
        machineState(for: key.machine)?.documents[key]
    }

    /// 全マシンの受信箱（対応待ちが先、その中は新しい順）。
    /// 全マシンの PR をアカウントごとに。同じアカウントの同じ PR は 1 つ、違うアカウントの同じ PR は別々。新しい順
    public var allPullRequests: [PullRequestSummary] { Self.mergePullRequests(machines.values.map { $0 }) }

    public nonisolated static func mergePullRequests(_ states: [MachineState]) -> [PullRequestSummary] {
        newestFirst(mergedByAccount(states).values)
    }

    /// 全マシンの PR を URL ごとに 1 つ（どのアカウントの分でも、最後に更新されたもの）。新しい順。⌘K の候補のように PR を 1 回だけ並べる所に使う
    public var pullRequestsByURL: [PullRequestSummary] { Self.uniqueByURL(allPullRequests) }

    nonisolated static func uniqueByURL(_ merged: [PullRequestSummary]) -> [PullRequestSummary] {
        var seen: Set<String> = []
        return merged.filter { seen.insert($0.url).inserted }
    }

    /// その URL の PR（どのアカウントの分でも、最後に更新されたもの）
    public func pullRequest(url: String) -> PullRequestSummary? {
        allPullRequests.first { $0.url == url }
    }

    /// レビューを頼まれていて、まだ返していない PR の数。2 つのアカウントが頼まれていても 1 つと数える
    public var reviewRequestedCount: Int { Self.reviewRequestedCount(allPullRequests) }

    nonisolated static func reviewRequestedCount(_ merged: [PullRequestSummary]) -> Int {
        Set(merged.filter { $0.category == .reviewRequested }.map(\.url)).count
    }

    /// その PR を取ったマシン。中身を頼む順（接続しているマシン、その中は新しく取れた方）
    public func machinesFetching(url: String) -> [MachineID] {
        Self.machinesFetching(url: url, machines.values.map { $0 })
    }

    nonisolated static func machinesFetching(url: String, _ states: [MachineState]) -> [MachineID] {
        let fetched = states.compactMap { state -> (MachineID, Bool, Date)? in
            guard let id = state.machine?.id, let pr = state.prs?.pullRequests.filter({ $0.url == url }).max(by: { $0.updatedAt < $1.updatedAt })
            else { return nil }
            return (id, state.connected, pr.updatedAt)
        }
        return fetched.sorted { ($0.1 ? 0 : 1, $1.2, $0.0.rawValue) < ($1.1 ? 0 : 1, $0.2, $1.0.rawValue) }.map(\.0)
    }

    /// 送った操作の応答で、そのマシンの記録を置き換える（`inbox.dismissals_updated` が届く前に画面を合わせる）
    public func setInboxDismissals(_ records: [InboxDismissal], for machine: MachineID) {
        guard let id = allMachines.first(where: { $0.value.machine?.id == machine })?.key else { return }
        update(id) { $0.inboxDismissals = MachineState.dismissalsByItem(records) }
    }

    /// 受信箱と札を今の中身で組み直し、変わったものだけ書く。自分の番の PR の重なりを除いてから無視・既読で分ける
    /// （先に分けると、消した PR の代わりに別のマシンの同じ PR が出てくる）。各マシンの受信箱は `MachineDerived` の控えを使う
    func rebuildOverview() {
        let at = now()
        let visible = machines
        let states = Dictionary(visible.values.compactMap { state in state.machine.map { ($0.id, state) } }, uniquingKeysWith: { a, _ in a })
        let pending = inboxPending
        let contents = InboxContents.split(Self.dedupedPullRequestTurns(visible.values.flatMap { $0.inboxEntry(now: at).items })) { item in
            if let override = pending[item.id] { return override == item.revision }
            return states[item.machine]?.isDismissed(item) ?? false
        }
        if contents != inbox { inbox = contents }
        let entries = allMachines.values.map { $0.inboxEntry(now: at) }
        let all = Self.sortedInbox(entries.flatMap(\.items))
        if all != inboxIncludingHidden { inboxIncludingHidden = all }
        // 札も受信箱の非表示を効かせる（対応待ちの数をバッジと揃える）
        let tiles = ConversationTiles(visible.values, unread: unreadConversations, dismissed: ConversationTiles.dismissedRequests(contents.dismissed), now: at)
        if tiles != conversationTiles { conversationTiles = tiles }
        scheduleOverviewExpiry(min(entries.map(\.validUntil).min() ?? .distantFuture, tiles.validUntil ?? .distantFuture), from: at)
    }

    /// 中身が時刻で変わる時刻に組み直す。今の時刻を使った項目（取れていない PR の失敗の時刻）があれば 1 分後
    private func scheduleOverviewExpiry(_ until: Date, from at: Date) {
        overviewExpiry?.cancel()
        guard until != .distantFuture else { return }
        let wait = until > at ? until.timeIntervalSince(at) : 60
        overviewExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.rebuildOverview()
        }
    }

    private static func sortedInbox(_ items: [InboxItem]) -> [InboxItem] {
        dedupedPullRequestTurns(items).sorted(by: InboxItem.inboxOrder)
    }

    /// 同じアカウントの PR を複数のマシンが取っていると、自分の番の PR が重なる。URL ごとに 1 つ（タスクに紐づいているほう）にする
    nonisolated static func dedupedPullRequestTurns(_ items: [InboxItem]) -> [InboxItem] {
        var kept: [String: InboxItem] = [:]
        var others: [InboxItem] = []
        for item in items {
            guard case .pullRequestTurn(let pr, _) = item.kind else {
                others.append(item)
                continue
            }
            // 残す側は辞書の順に左右されないように決める（変わると id が変わり、通知が鳴り直す）
            func rank(_ item: InboxItem) -> (Int, String) { (item.taskNumber == nil ? 1 : 0, item.machine.rawValue) }
            if let current = kept[pr.url], rank(current) <= rank(item) { continue }
            kept[pr.url] = item
        }
        return others + kept.values
    }

    /// オーケストレーターの host の会話（daemon の `OrchestratorInfo.conversationID`）
    public func orchestratorConversation(on machine: MachineID) -> Conversation? {
        guard let state = machineState(for: machine), let id = state.orchestrator?.conversationID else { return nil }
        return state.conversations[ConversationKey(machine: machine, id: id)]
    }

    public func board(id: String, on machine: MachineID) -> Board? {
        machineState(for: machine)?.boards[id]
    }

    /// 全マシンのアーカイブしていないボードを、マシン → position の順で。
    public var allBoards: [Board] {
        machines.values.flatMap { $0.activeBoards.values }.sorted { a, b in
            if a.machine != b.machine { return a.machine.rawValue < b.machine.rawValue }
            return a.position < b.position
        }
    }

    public func tasks(onBoard boardID: String, machine: MachineID) -> [BoardTask] {
        (machineState(for: machine)?.tasks.values.filter { $0.boardID == boardID } ?? []).sorted { $0.number < $1.number }
    }

    public func machineState(for machine: MachineID) -> MachineState? {
        machines.values.first { $0.machine?.id == machine }
    }

    /// そのマシンの端末を開ける供給元。fixtures など開けない供給元なら nil。
    public func terminalSource(for machine: MachineID) -> (any DaemonWriter)? {
        guard let id = visibleFleetID(for: machine) else { return nil }
        return sources[id] as? any DaemonWriter
    }

    /// そのマシンの会話を操作できる供給元。fixtures など操作できない供給元なら nil
    public func conversationSource(for machine: MachineID) -> (any ConversationSource)? {
        guard let id = visibleFleetID(for: machine) else { return nil }
        return sources[id] as? any ConversationSource
    }

    /// そのマシンの会話を検索できる供給元。前の版の daemon も DaemonClient なので返す（引けなければ 404）
    public func conversationSearchSource(for machine: MachineID) -> (any ConversationSearchSource)? {
        guard let id = visibleFleetID(for: machine) else { return nil }
        return sources[id] as? any ConversationSearchSource
    }

    /// 接続の利用状況を引ける供給元。前の版の daemon も DaemonClient なので返す（引けなければ 404）
    public func usageHistorySource(fleetID: String) -> (any UsageHistorySource)? {
        sources[fleetID] as? any UsageHistorySource
    }

    public func conversation(for key: ConversationKey) -> Conversation? {
        cached(.conversation(key)) { $0.visibleStateUntracked(key.machine)?.conversations[key] }
    }

    /// その会話からフォークした会話（古い順）
    public func forks(of conversation: Conversation) -> [Conversation] {
        cached(.forks(conversation.key)) { $0.visibleStateUntracked(conversation.machine)?.forks(of: conversation) ?? [] }
    }

    /// その会話が起こした会話
    public func delegates(of conversation: Conversation) -> [Conversation] {
        cached(.delegates(conversation.key)) { $0.visibleStateUntracked(conversation.machine)?.delegates(of: conversation) ?? [] }
    }

    /// その会話が使っているツールの名前（ツールを使っていなければ nil）。読む画面は、その会話の値が変わったときだけ描き直される
    public func toolName(of key: ConversationKey) -> String? {
        cached(.tool(key)) { fleet in
            guard let id = fleet._identities.first(where: { $0.value.id == key.machine && fleet.visibleUntracked($0.key) })?.key else { return nil }
            return fleet.toolActivity[id]?[key]
        }
    }

    public func engines(on machine: MachineID) -> MachineEngines {
        cached(.engines(machine)) { fleet in
            let state = fleet.visibleStateUntracked(machine)
            return MachineEngines(claude: state?.claude, codex: state?.codex)
        }
    }

    /// 箱の値を返す。読む画面が見張るのは箱だけ（`compute` は見張りに入らない値から計算する）
    private func cached<Value: Equatable>(_ key: FleetCellKey, _ compute: @escaping (Fleet) -> Value) -> Value {
        cellClock += 1
        cellUses[key] = cellClock
        let cell: FleetCell<Value>
        if let existing = cells[key] as? FleetCell<Value> {
            cell = existing
        } else {
            cell = FleetCell(self, compute: compute)
            cells[key] = cell
            retireOldCells()
        }
        _ = cell.retired
        return cell.value
    }

    private func retireOldCells() {
        guard cells.count > Self.cellLimit, let oldest = cellUses.min(by: { $0.value < $1.value })?.key else { return }
        cells.removeValue(forKey: oldest)?.retire()
        cellUses.removeValue(forKey: oldest)
    }

    /// 画面に出すマシンの state。`_allMachines` を読むので見張りに入らない
    private func visibleStateUntracked(_ machine: MachineID) -> MachineState? {
        guard let id = _identities.first(where: { $0.value.id == machine && visibleUntracked($0.key) })?.key else { return nil }
        return _allMachines[id]
    }

    private func visibleUntracked(_ fleetID: String) -> Bool {
        if let only = _onlyMachine { return fleetID == only }
        return !_hiddenMachines.contains(fleetID)
    }

    /// 箱を今の値に入れ直す。値の変わった箱だけ書く（`machine` を渡せばそのマシンの箱だけ）
    private func refreshCells(machine: MachineID? = nil) {
        for (key, cell) in cells where machine == nil || key.machine == machine { cell.refresh(self) }
    }

    /// `GET /v1/devices` で取った端末の一覧を入れる（`devices.updated` が来るまでの間の値）
    public func setDevices(_ devices: [DeviceInfo], for machine: MachineID) {
        guard let id = machines.first(where: { $0.value.machine?.id == machine })?.key else { return }
        update(id) { $0.devices = devices }
    }

    /// `GET /v1/codex`・`POST /v1/codex/connectors/refresh` で取った codex の値を入れる
    public func setCodexMachine(_ info: CodexMachineInfo, for machine: MachineID) {
        guard let id = machines.first(where: { $0.value.machine?.id == machine })?.key else { return }
        update(id) { $0.codex = info }
    }

    /// `GET /v1/claude` で取った値を入れる
    public func setClaudeMachine(_ info: ClaudeMachineInfo, for machine: MachineID) {
        guard let id = machines.first(where: { $0.value.machine?.id == machine })?.key else { return }
        update(id) { $0.claude = info }
    }

    /// そのマシンの利用枠
    public func usage(for machine: MachineID) -> UsageSnapshot? {
        visibleFleetID(for: machine).flatMap { usage[$0] }
    }

    public func usage(fleetID: String) -> UsageSnapshot? {
        usage[fleetID]
    }

    /// 変わらない値は書かない（書くだけで、そのプロパティを読む画面がすべて描き直される）
    private func update(_ id: String, _ body: (inout MachineState) -> Void) {
        guard let current = allMachines[id] else { return }
        var state = current
        body(&state)
        state.usage = nil
        guard state != current else { return }
        allMachines[id] = state
        let identity = state.machine.map { MachineIdentity(id: $0.id, name: $0.name) }
        if identities[id] != identity { identities[id] = identity }
        // マシンの ID が替わったら、前の ID の会話の箱も入れ直す
        refreshCells(machine: current.machine?.id == state.machine?.id ? state.machine?.id : nil)
        rebuildOverview()
    }

    /// 全体を受けた：そのマシンの分を置き換える
    private func setToolActivity(_ id: String, _ snap: StateSnapshot) {
        let next = Dictionary(snap.conversationActivities.compactMap { a in a.toolName.map { (a.conversation, $0) } }, uniquingKeysWith: { _, b in b })
        guard allMachines[id] != nil, toolActivity[id, default: [:]] != next else { return }
        let changed = Set(next.keys).union(toolActivity[id, default: [:]].keys)
        toolActivity[id] = next
        for key in changed { cells[.tool(key)]?.refresh(self) }
    }

    private func setToolActivity(_ id: String, _ activity: ConversationToolActivity) {
        guard allMachines[id] != nil, toolActivity[id]?[activity.conversation] != activity.toolName else { return }
        toolActivity[id, default: [:]][activity.conversation] = activity.toolName
        cells[.tool(activity.conversation)]?.refresh(self)
    }

    private func setUsage(_ id: String, _ snapshot: UsageSnapshot?) {
        guard allMachines[id] != nil, usage[id] != snapshot else { return }
        usage[id] = snapshot
    }
}

/// 1 本の接続で前に受けた番号。繋ぎ直しても持ち越す
private final class StreamCursor: @unchecked Sendable {
    var epoch: String?
    var rev: Int?
}

private enum StreamRestart: Error {
    case revisionSkipped
}
