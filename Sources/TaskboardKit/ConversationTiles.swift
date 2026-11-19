import Foundation

/// 見張り盤の札 1 枚（会話 1 本）。iPhone の一覧の先頭の「対応待ち」の節も、対応待ちの組の札を読む
public struct ConversationTile: Hashable, Sendable, Identifiable {
    public enum State: Hashable, Sendable {
        /// 答えを待っている問い（先頭の 1 つ。defer で終えた問いを含む）
        case request(ConversationRequest)
        /// 止まりの異常
        case problem(ConversationProblem)
        case starting
        case running
        /// この端末で見ていないターンの終わり（`UnreadMarks`）
        case unread
        /// 入力待ち（プロセスが動いている）
        case idle
    }

    public var conversation: Conversation
    public var state: State
    /// 会話のタスクと、その案件。タスクに結ばれていない会話（オーケストレーター・タスクなし）は nil
    public var task: BoardTask?
    public var board: Board?

    public var id: ConversationKey { conversation.key }

    public var group: ConversationTileGroup {
        switch state {
        case .request, .problem: .waiting
        case .starting, .running: .running
        case .unread: .unread
        case .idle: .idle
        }
    }

    /// 状態の時刻。問いは待ち始め、止まりは止まった時刻、実行中はターンの始まり、未読と待機は最後の応答。分からなければ nil
    public var since: Date? {
        switch state {
        case .request(let request): request.waiting.since
        case .problem(let problem): problem.since
        case .starting, .running: conversation.turnStartedAt
        case .unread, .idle: conversation.lastReply?.at
        }
    }

    /// 会話を札にする。札にしない会話は nil（`State.of`）
    public init?(_ conversation: Conversation, task: BoardTask?, board: Board?, unread: Bool, dismissed: Set<String> = [], now: Date) {
        guard let state = State.of(conversation, unread: unread, dismissed: dismissed, now: now) else { return nil }
        self.conversation = conversation
        self.state = state
        self.task = task
        self.board = board
    }
}

extension ConversationTile.State {
    /// 会話の状態の判定。見張り盤の札・サイドバーの札（`SidebarStatus.of`）・バッジ（`ConversationTiles.waitingCount`）がこれを読む。
    /// nil は見張り盤に出さない会話（終了した会話と、止まっていて異常も問いも未読も無い会話）。
    /// 問いは止まりの異常より先（札の上で答えられる）。`dismissed` は受信箱で非表示にした問いの id で、対応待ちに数えない。
    /// 未読は止まった会話にも付く（サイドバーの行の札と同じ）
    public static func of(_ conversation: Conversation, unread: Bool, dismissed: Set<String> = [], now: Date) -> Self? {
        guard !conversation.isClosed else { return nil }
        if let request = conversation.requests.first(where: { !dismissed.contains($0.id) }) { return .request(request) }
        if let problem = ConversationProblem(conversation, now: now) { return .problem(problem) }
        switch conversation.phase {
        case .starting: return .starting
        case .running: return .running
        case .waiting:
            // 問いが届く前の一瞬だけ、問いの無い waiting がある。答えるものが無いので実行中に入れる。
            // 問いを全部非表示にした会話は、入力を待っているので待機
            if conversation.requests.isEmpty { return .running }
            return unread ? .unread : .idle
        case .idle: return unread ? .unread : .idle
        case .stopped: return unread ? .unread : nil
        }
    }
}

/// 札の組（並びは case の順）。サイドバーの［並べ方］の「状態」と同じ 4 つ
public enum ConversationTileGroup: CaseIterable, Hashable, Sendable {
    case waiting, running, unread, idle
}

/// 止まりの異常（見張り盤では対応待ちの組に出す）。並びは会話の画面の行（`ConversationActivity`）と同じく、止まりが送り直しより先
public enum ConversationProblem: Hashable, Sendable {
    /// 生成中なのに engine から何も届かない。値は最後に届いた時刻
    case stalled(since: Date)
    /// API に届かず engine が送り直している
    case apiRetry(ConversationAPIRetry)
    /// 利用枠の上限で止まり、`resumeAt` に続きを送る。`paused` は上限の前に taskboard が区切った待ち
    case usageLimit(resumeAt: Date, paused: Bool)
    /// ネットワークに繋がらずに止まり、接続が戻ったら続きを送る
    case network
    /// プロセスが予期せず終わった（`ConversationStopCause.unexpected`）。値は終わり方の文
    case exited(String)

    /// 予期しない終了を出す期間（終了から）。止まった会話は送るまでそのまま残るので、切らないと古いものが対応待ちに溜まる
    public static let exitedWindow: TimeInterval = 24 * 3600

    public init?(_ conversation: Conversation, now: Date) {
        if let since = conversation.stalledSince {
            self = .stalled(since: since)
        } else if let retry = conversation.apiRetry {
            self = .apiRetry(retry)
        } else if let resumeAt = conversation.limitResumeAt {
            self = .usageLimit(resumeAt: resumeAt, paused: conversation.limitPaused)
        } else if conversation.networkResume == true {
            self = .network
        } else if conversation.phase == .stopped, conversation.stoppedInTurn, let lastExit = conversation.lastExit,
            case .unexpected(let text) = ConversationStopCause(lastExit: lastExit), now < Self.exitedUntil(conversation)
        {
            self = .exited(text)
        } else {
            return nil
        }
    }

    /// 予期しない終了の札を外す時刻
    static func exitedUntil(_ conversation: Conversation) -> Date { conversation.updatedAt.addingTimeInterval(exitedWindow) }

    /// 止まりの時刻（分かるものだけ）
    var since: Date? {
        if case .stalled(let since) = self { return since }
        return nil
    }
}

/// 全マシンの札を組に分けたもの（`Fleet.conversationTiles`）
public struct ConversationTiles: Hashable, Sendable {
    /// 対応待ち。待ち始めの古い順（⌥⌘A の「次の入力待ち」と同じ向き）。時刻の分からない止まりは後ろ
    public var waiting: [ConversationTile] = []
    /// 実行中。ターンの始まりの新しい順
    public var running: [ConversationTile] = []
    /// 未読。最後の応答の新しい順
    public var unread: [ConversationTile] = []
    /// 待機。最後の応答の新しい順
    public var idle: [ConversationTile] = []
    /// 中身が時刻で変わる最初の時刻（予期しない終了の札が外れる）。無ければ nil
    public var validUntil: Date?

    public init() {}

    /// マシンの会話を札にして組に分ける。`unread` はこの端末で見ていないターンの終わりの会話、
    /// `dismissed` は受信箱で非表示にした会話の問い（会話 → 問いの id）
    public init(_ states: some Sequence<MachineState>, unread: Set<ConversationKey>, dismissed: [ConversationKey: Set<String>] = [:], now: Date = Date()) {
        var tiles: [ConversationTile] = []
        for state in states {
            guard let machine = state.machine?.id else { continue }
            for conversation in state.conversations.values {
                let task = conversation.taskNumber.flatMap { state.tasks[TaskKey(machine: machine, number: $0)] }
                let board = task.flatMap { state.boards[$0.boardID] }
                guard
                    let tile = ConversationTile(
                        conversation, task: task, board: board, unread: unread.contains(conversation.key), dismissed: dismissed[conversation.key] ?? [], now: now)
                else { continue }
                tiles.append(tile)
            }
        }
        self.init(sorting: tiles)
        validUntil = tiles.compactMap { tile in
            if case .problem(.exited) = tile.state { return ConversationProblem.exitedUntil(tile.conversation) }
            return nil
        }.min()
    }

    /// 受信箱で非表示にした会話の問い（`Fleet` が受信箱を分けた結果から作る）
    public static func dismissedRequests(_ items: [InboxItem]) -> [ConversationKey: Set<String>] {
        items.reduce(into: [:]) { result, item in
            switch item.kind {
            case .conversationRequest(let conversation, let request): result[conversation.key, default: []].insert(request.id)
            default: break
            }
        }
    }

    /// 対応待ちの数（Dock とアプリのバッジ、「すべての案件」の数）。会話の分は対応待ちの札（会話 1 本で 1 つ。止まりの異常を含む）で数え、
    /// 受信箱のほかの対応待ち（文書の質問・レビュー依頼・承認・PR）を足す。`items` は非表示にしたものを除いた受信箱
    public func waitingCount(with items: [InboxItem]) -> Int {
        items.filter { item in
            guard item.group == .waiting else { return false }
            switch item.kind {
            case .conversationRequest: return false
            default: return true
            }
        }.count + waiting.count
    }

    private init(sorting tiles: [ConversationTile]) {
        let grouped = Dictionary(grouping: tiles, by: \.group)
        // 同じ時刻は会話の作った順、さらに key で決める（決めておかないと、更新のたびに札が入れ替わる）
        func order(_ newest: Bool, _ time: @escaping (ConversationTile) -> Date?) -> (ConversationTile, ConversationTile) -> Bool {
            { a, b in
                switch (time(a), time(b)) {
                case let (x?, y?) where x != y: return newest ? x > y : x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return Conversation.listOrder(a.conversation, b.conversation)
                }
            }
        }
        waiting = (grouped[.waiting] ?? []).sorted(by: order(false, \.since))
        running = (grouped[.running] ?? []).sorted(by: order(true) { $0.since ?? $0.conversation.createdAt })
        unread = (grouped[.unread] ?? []).sorted(by: order(true) { $0.since ?? $0.conversation.updatedAt })
        idle = (grouped[.idle] ?? []).sorted(by: order(true) { $0.since ?? $0.conversation.updatedAt })
    }

    public subscript(group: ConversationTileGroup) -> [ConversationTile] {
        switch group {
        case .waiting: waiting
        case .running: running
        case .unread: unread
        case .idle: idle
        }
    }

    /// その案件の札だけ（サイドバーで案件を選んだとき）。タスクに結ばれていない会話は、どの案件にも入れない
    public func filtered(board id: String, machine: MachineID) -> ConversationTiles {
        ConversationTiles(sorting: (waiting + running + unread + idle).filter { $0.board?.id == id && $0.conversation.machine == machine })
    }
}

/// 見張り盤の並べ方（札にするものと 1 行に送るもの）
public struct ConversationBoardLayout: Hashable, Sendable {
    /// 実行中の組の出し方
    public enum Running: Hashable, Sendable {
        case tiles([ConversationTile])
        /// 札が入りきらないので 1 行ずつ
        case lines([ConversationTile])
        /// 1 行でも入りきらないので、案件ごとの見出しで分ける
        case boards([BoardLines])
    }

    /// 案件 1 つの実行中の 1 行。`lines` は新しい `perBoard` 件、残りは `hidden` 件として折りたたむ
    public struct BoardLines: Hashable, Sendable {
        /// 見出しの案件。タスクに結ばれていない会話の組は nil
        public var board: Board?
        public var machine: MachineID
        public var lines: [ConversationTile]
        public var hidden: Int
    }

    /// 対応待ちは常に札（答えるボタンを札に残す）
    public var waiting: [ConversationTile]
    public var running: Running
    /// 未読は 1 行ずつ（題と最後の応答の頭）
    public var unread: [ConversationTile]
    /// 待機は件数の 1 行に折りたたむ（押すと 1 行の一覧で開く）
    public var idle: [ConversationTile]

    /// 札を窓の高さの 3 分の 2 までに収める。対応待ちと実行中の札が収まらなければ実行中を 1 行に送り、1 行でも収まらなければ案件の見出しで分けて
    /// 各案件の新しい `perBoard` 件だけを出す。札は `columns` 枚ずつ横に並べ、段の高さはその段のいちばん高い札（`tileHeight` は札と段の間を含めた高さ）
    public init(
        _ tiles: ConversationTiles, windowHeight: Double, columns: Int, lineHeight: Double, perBoard: Int = 2,
        tileHeight: (ConversationTile) -> Double
    ) {
        let budget = windowHeight * 2 / 3
        func gridHeight(_ tiles: [ConversationTile]) -> Double {
            stride(from: 0, to: tiles.count, by: max(1, columns)).reduce(0) { sum, start in
                sum + (tiles[start..<min(tiles.count, start + max(1, columns))].map(tileHeight).max() ?? 0)
            }
        }
        let waitingHeight = gridHeight(tiles.waiting)
        waiting = tiles.waiting
        unread = tiles.unread
        idle = tiles.idle
        if waitingHeight + gridHeight(tiles.running) <= budget {
            running = .tiles(tiles.running)
        } else if waitingHeight + Double(tiles.running.count) * lineHeight <= budget {
            running = .lines(tiles.running)
        } else {
            running = .boards(Self.byBoard(tiles.running, perBoard: perBoard))
        }
    }

    /// マシン・案件の並び（`Fleet.allBoards` と同じ）で、タスクの無い会話の組はそのマシンの後ろ。中は新しい順のまま
    private static func byBoard(_ running: [ConversationTile], perBoard: Int) -> [BoardLines] {
        struct Key: Hashable {
            var machine: MachineID
            var board: String?
        }
        var order: [Key] = []
        var grouped: [Key: [ConversationTile]] = [:]
        for tile in running {
            let key = Key(machine: tile.conversation.machine, board: tile.board?.id)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(tile)
        }
        return order.sorted { a, b in
            if a.machine != b.machine { return a.machine.rawValue < b.machine.rawValue }
            let x = grouped[a]?.first?.board?.position ?? .max
            let y = grouped[b]?.first?.board?.position ?? .max
            return x != y ? x < y : (a.board ?? "") < (b.board ?? "")
        }.map { key in
            let tiles = grouped[key] ?? []
            return BoardLines(board: tiles.first?.board, machine: key.machine, lines: Array(tiles.prefix(perBoard)), hidden: max(0, tiles.count - perBoard))
        }
    }
}
