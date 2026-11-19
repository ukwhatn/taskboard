import Foundation

/// ボード = context（案件・PJ）ごとのタスクの集まり。1 マシンが複数持つ。
public struct Board: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var machine: MachineID
    public var name: String
    public var position: Int
    public var columns: [BoardColumn]
    public var createdAt: Date
    /// 起動プロンプトの既定（`PromptTemplate`）。列ごとの上書きは `BoardColumn.promptTemplate`
    public var promptTemplate: String
    /// アーカイブした案件は、ボード・サイドバー・⌘K・hook と MCP の既定の起票先から外す
    public var archived: Bool
    /// 起動のシートの初期値。nil なら今までどおり（最初のプリセット・最後に使った作業ディレクトリ）
    public var launchDefaults: LaunchDefaults?
    /// PR がマージされたタスクを進める先（99_history Q3）
    public var mergeTarget: MergeTarget
    /// 委任範囲の案件の初期値（指定した項目だけ）
    public var delegation: DelegationScope

    public init(
        id: String, machine: MachineID, name: String, position: Int, columns: [BoardColumn], createdAt: Date, promptTemplate: String = "",
        archived: Bool = false, launchDefaults: LaunchDefaults? = nil, mergeTarget: MergeTarget = .deploying, delegation: DelegationScope = DelegationScope()
    ) {
        self.id = id
        self.machine = machine
        self.name = name
        self.position = position
        self.columns = columns
        self.createdAt = createdAt
        self.promptTemplate = promptTemplate
        self.archived = archived
        self.launchDefaults = launchDefaults
        self.mergeTarget = mergeTarget
        self.delegation = delegation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        machine = try c.decode(MachineID.self, forKey: .machine)
        name = try c.decode(String.self, forKey: .name)
        position = try c.decode(Int.self, forKey: .position)
        columns = try c.decode([BoardColumn].self, forKey: .columns)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        promptTemplate = try c.decodeIfPresent(String.self, forKey: .promptTemplate) ?? ""
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        launchDefaults = try c.decodeIfPresent(LaunchDefaults.self, forKey: .launchDefaults)
        mergeTarget = try c.decodeIfPresent(MergeTarget.self, forKey: .mergeTarget) ?? .deploying
        delegation = try c.decodeIfPresent(DelegationScope.self, forKey: .delegation) ?? DelegationScope()
    }

    /// 列の並び（`position` の順）。画面に列を並べるときと、隣の列を引くときはこれを使う
    public var orderedColumns: [BoardColumn] { columns.sorted { $0.position < $1.position } }
    public var openColumns: [BoardColumn] { orderedColumns.filter { $0.kind == .open } }
    public var terminalColumns: [BoardColumn] { orderedColumns.filter { $0.kind == .terminal } }
    /// 畳まずに出す列（並びの順）。キーのカーソルが動く範囲
    public var unfoldedColumns: [BoardColumn] { orderedColumns.filter { !$0.collapsed } }

    /// 並びで `offset` 個先の列（⌥⌘← / ⌥⌘→）。列が見つからないか端を越えるなら nil
    public func column(nextTo columnID: String, by offset: Int) -> BoardColumn? {
        let ordered = orderedColumns
        guard let index = ordered.firstIndex(where: { $0.id == columnID }), ordered.indices.contains(index + offset) else { return nil }
        return ordered[index + offset]
    }

    /// この案件の進行中のタスクの数（進行中の列にあるもの）。サイドバーと概観の案件の数
    public func openTaskCount(_ tasks: some Sequence<BoardTask>) -> Int {
        let open = Set(openColumns.map(\.id))
        return tasks.filter { $0.boardID == id && open.contains($0.columnID) }.count
    }

    /// 起票の既定の列。未着手、無ければ `firstWorkColumn`
    public var defaultColumn: BoardColumn? { columns.first { $0.id == BoardColumn.todoID } ?? firstWorkColumn }

    /// 列の指定が無い起票と案件の移動の受け皿。常設とレビュー依頼を除く最初の進行中の列（常設は期限の無い仕事の列、
    /// レビュー依頼は他人の PR の受け口で、どちらにもほかの仕事を入れない）。それしか無ければレビュー依頼、常設の順
    public var firstWorkColumn: BoardColumn? {
        let open = openColumns
        guard let id = BoardColumn.firstWorkColumnID(openIDs: open.map(\.id)) else { return nil }
        return open.first { $0.id == id }
    }

    /// PR がマージされたタスクを進める列の id。「マージしたら」の列を消していれば完了
    public var mergeTargetColumnID: String {
        columns.contains { $0.id == mergeTarget.columnID } ? mergeTarget.columnID : MergeTarget.done.columnID
    }
}

/// PR がマージされたタスクを進める先の列。既定は今までどおり「デプロイ中」
public enum MergeTarget: String, Codable, Hashable, Sendable, CaseIterable {
    case deploying
    case done

    public var columnID: String { rawValue }
}

/// ボードの列。`open` は進行中、`terminal` は折り畳んで見せる終端（完了 / 見送り）。
public struct BoardColumn: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case open
        case terminal
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var position: Int
    /// この列から起動するときのプロンプト（nil ならボードの既定）
    public var promptTemplate: String?
    /// ボードで初めから畳んで出す
    public var collapsed: Bool
    /// 列の役割の説明。人と、紐づいたセッション（SessionStart の案内と MCP の応答）が読む。daemon の動きは id で決め、説明は読まない
    public var description: String

    public init(
        id: String, label: String, kind: Kind, position: Int, promptTemplate: String? = nil, collapsed: Bool? = nil, description: String = ""
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.position = position
        self.promptTemplate = promptTemplate
        self.collapsed = collapsed ?? (kind == .terminal)
        self.description = description
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(Kind.self, forKey: .kind)
        position = try c.decode(Int.self, forKey: .position)
        promptTemplate = try c.decodeIfPresent(String.self, forKey: .promptTemplate)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? (kind == .terminal)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    /// 既定の列。GitHub 同期・hook・MCP が id で見ているので、完了扱いは変えられない（名前・順序・畳む・説明は変えられる）。
    /// 消せるのは「完了」以外。消しても id ごと戻せる（`standard` から同じ id で足す）
    public var isStandard: Bool { Self.standardIDs.contains(id) }
    public var isRemovable: Bool { Self.isRemovable(id: id) }
    /// 「完了」だけは消せない（daemon がマージとレビュー依頼の終わりで進める先）。まだ id の無い新しい列は消せる
    public static func isRemovable(id: String?) -> Bool { id != doneID }
    public static let standardIDs = Set(standard.map(\.id))

    public static let standingID = "standing"
    public static let reviewRequestID = "review_req"

    /// `Board.firstWorkColumn` の規則。進行中の列の id を並びの順で受ける（daemon は DB の行から同じ規則で選ぶ）
    public static func firstWorkColumnID(openIDs: [String]) -> String? {
        let reserved: Set = [standingID, reviewRequestID]
        return openIDs.first { !reserved.contains($0) } ?? openIDs.first { $0 == reviewRequestID } ?? openIDs.first
    }
    public static let todoID = "todo"
    /// マージとレビュー依頼の終わりで daemon が進める先なので、消せない
    public static let doneID = "done"

    /// PR の状態で進める向きの順。表示の順序を並べ替えても、この順で決める。常設は PR の状態で動かさないので入れない
    public static let progressOrder = standard.map(\.id).filter { $0 != standingID }
    public static func progressIndex(of id: String) -> Int? { progressOrder.firstIndex(of: id) }

    /// taskherd の 8 列（99_history 2026-10-02 の裁定で日本語化）の先頭に、期限の無い仕事の「常設」を足した 9 列。
    public static let standard: [BoardColumn] = [
        BoardColumn(id: standingID, label: String(localized: "常設"), kind: .open, position: 0),
        BoardColumn(id: reviewRequestID, label: String(localized: "レビュー依頼"), kind: .open, position: 1),
        BoardColumn(id: todoID, label: String(localized: "未着手"), kind: .open, position: 2),
        BoardColumn(id: "planning", label: String(localized: "計画"), kind: .open, position: 3),
        BoardColumn(id: "working", label: String(localized: "作業中"), kind: .open, position: 4),
        BoardColumn(id: "review", label: String(localized: "レビュー中"), kind: .open, position: 5),
        BoardColumn(id: "deploying", label: String(localized: "デプロイ中"), kind: .open, position: 6),
        BoardColumn(id: doneID, label: String(localized: "完了"), kind: .terminal, position: 7),
        BoardColumn(id: "wontfix", label: String(localized: "見送り"), kind: .terminal, position: 8),
    ].map { column in
        var column = column
        column.description = ColumnGuide.defaultDescriptions[column.id] ?? ""
        return column
    }
}

/// タスクをマシンを跨いで一意に指すキー。番号はマシン（daemon）ごとに振る。
public struct TaskKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let machine: MachineID
    public let number: Int
    public init(machine: MachineID, number: Int) {
        self.machine = machine
        self.number = number
    }
    public var description: String { "\(machine.rawValue)/#\(number)" }
}

public struct TaskLink: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case githubPR = "github_pr"
        case githubIssue = "github_issue"
        case jira
        case other
    }

    public var id: Int64
    public var url: String
    public var kind: Kind
    public var note: String
    public var addedAt: Date

    public init(id: Int64, url: String, kind: Kind, note: String = "", addedAt: Date) {
        self.id = id
        self.url = url
        self.kind = kind
        self.note = note
        self.addedAt = addedAt
    }

    /// URL から種別を決める（taskherd と同じ規則。GHES は `ghesHosts`）。
    public static func kind(of url: String, ghesHosts: [String] = []) -> Kind {
        guard let parsed = URL(string: url), let host = parsed.host() else { return .other }
        let isGitHub = host == "github.com" || ghesHosts.contains(host)
        if isGitHub {
            if parsed.path.contains("/pull/") { return .githubPR }
            if parsed.path.contains("/issues/") { return .githubIssue }
        }
        if host.hasSuffix(".atlassian.net") && parsed.path.contains("/browse/") { return .jira }
        return .other
    }

    /// `owner/repo#123` の短い表記。Devin のセッションは「Devin」。ほかは host。
    public var shortLabel: String {
        guard let parsed = URL(string: url), let host = parsed.host() else { return url }
        if DevinSession.id(fromURL: url) != nil { return "Devin" }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        switch kind {
        case .githubPR, .githubIssue:
            if parts.count >= 4 { return "\(parts[1])#\(parts[3])" }
        case .jira:
            if let last = parts.last { return last }
        case .other:
            break
        }
        return host
    }
}

/// どのタスクにもリンクしていない URL を、決めたタスクに足した結果（`watch_create`・Stop hook が PR を足す）
public enum AutoLinkResult: Codable, Hashable, Sendable {
    case linked(task: Int)
    case alreadyLinked(task: Int)
    /// ほかのタスクにあるので足さなかった
    case linkedElsewhere(task: Int)
}

/// タスクに紐づく agent セッション。`sessionID`（Claude Code・codex の会話 ID）で会話と hook のセッションを見分ける。
public struct TaskSessionRef: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64
    public var agent: String
    public var sessionID: String
    public var cwd: String
    public var label: String
    public var linkedAt: Date
    /// 起動したときの agent の引数（モデル・effort など）。再開のときに同じ引数で起こす。手で紐づけたものは空
    public var launchArgs: [String]

    public init(id: Int64, agent: String, sessionID: String, cwd: String, label: String = "", linkedAt: Date, launchArgs: [String] = []) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.label = label
        self.linkedAt = linkedAt
        self.launchArgs = launchArgs
    }

    private enum CodingKeys: String, CodingKey { case id, agent, sessionID, cwd, label, linkedAt, launchArgs }

    /// P6 までの daemon は launchArgs を返さない
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        agent = try c.decode(String.self, forKey: .agent)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        cwd = try c.decode(String.self, forKey: .cwd)
        label = try c.decode(String.self, forKey: .label)
        linkedAt = try c.decode(Date.self, forKey: .linkedAt)
        launchArgs = try c.decodeIfPresent([String].self, forKey: .launchArgs) ?? []
    }
}

/// ボードのカード 1 枚。
public struct BoardTask: Codable, Hashable, Identifiable, Sendable {
    public var id: TaskKey { TaskKey(machine: machine, number: number) }

    public var machine: MachineID
    public var number: Int
    public var boardID: String
    public var columnID: String
    public var title: String
    public var note: String
    /// 期限・リリース日（`YYYY-MM-DD`）。期日の唯一の出所（99_history Q6）。
    public var due: String?
    public var links: [TaskLink]
    public var sessions: [TaskSessionRef]
    /// taskherd から取り込んだときの元 id。再取り込みの重複防止に使う。
    public var importedID: Int?
    /// 委任範囲のタスクの上書き（指定した項目だけ）。今効いている段階は `delegation(board:)`
    public var delegation: DelegationScope
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        machine: MachineID, number: Int, boardID: String, columnID: String, title: String, note: String = "", due: String? = nil,
        links: [TaskLink] = [], sessions: [TaskSessionRef] = [], importedID: Int? = nil, delegation: DelegationScope = DelegationScope(),
        createdAt: Date, updatedAt: Date
    ) {
        self.machine = machine
        self.number = number
        self.boardID = boardID
        self.columnID = columnID
        self.title = title
        self.note = note
        self.due = due
        self.links = links
        self.sessions = sessions
        self.importedID = importedID
        self.delegation = delegation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case machine, number, boardID, columnID, title, note, due, links, sessions, importedID, delegation, createdAt, updatedAt }

    /// 委任範囲より前の daemon と fixtures は `delegation` を持たない
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(MachineID.self, forKey: .machine)
        number = try c.decode(Int.self, forKey: .number)
        boardID = try c.decode(String.self, forKey: .boardID)
        columnID = try c.decode(String.self, forKey: .columnID)
        title = try c.decode(String.self, forKey: .title)
        note = try c.decode(String.self, forKey: .note)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        links = try c.decode([TaskLink].self, forKey: .links)
        sessions = try c.decode([TaskSessionRef].self, forKey: .sessions)
        importedID = try c.decodeIfPresent(Int.self, forKey: .importedID)
        delegation = try c.decodeIfPresent(DelegationScope.self, forKey: .delegation) ?? DelegationScope()
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public var pullRequestLinks: [TaskLink] { links.filter { $0.kind == .githubPR } }
}

// MARK: - 待ち理由

/// カードの 1 行「何を待っているか」。優先順は 作業項目の待ち（フェーズ 4）→ PR の状態（フェーズ 7）→ 期日。
public struct WaitLine: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        /// 自分の番（承認・質問・期限切れ）。
        case mine
        /// 相手や外部を待っている。
        case theirs
        /// 情報だけ。
        case quiet
    }

    public var text: String
    public var tone: Tone

    public init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

extension BoardTask {
    public static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension Sequence<Board> {
    /// 既定の起票先（hook・`POST /v1/tasks`・MCP）。アーカイブしていない案件のうち position が先頭のもの。同じ position なら並びの先
    public var defaultBoard: Board? {
        filter { !$0.archived }.min { $0.position < $1.position }
    }
}

extension Sequence<BoardTask> {
    /// その Claude の会話 ID を最後に結んだタスク（daemon の `Store.task(linkedToSession:)` と同じく、紐づけの記録の id の大きい方）
    public func task(linkedToSession sessionID: String) -> BoardTask? {
        var latest: (task: BoardTask, ref: Int64)?
        for task in self {
            guard let ref = task.sessions.filter({ $0.sessionID == sessionID }).map(\.id).max(), ref > latest?.ref ?? .min else { continue }
            latest = (task, ref)
        }
        return latest?.task
    }
}
