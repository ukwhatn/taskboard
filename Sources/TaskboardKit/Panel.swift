import Foundation

// MARK: - 会話が登録する概況の部品

/// 部品の状態の種類。会話は意味だけを渡し、色はアプリが当てる。強い色は attention と failed（基準の外の値）だけ
public enum PanelTone: String, Codable, Hashable, Sendable, CaseIterable {
    case ok, attention, waiting, done, failed, neutral
}

/// 部品に添える記号。会話は一覧の名前から選び、図柄はアプリが決める
public enum PanelSymbol: String, Codable, Hashable, Sendable, CaseIterable {
    case check, clock, person, people, document, chart, flag, warning, calendar, link
    case pullRequest = "pull_request"
    case bug, gear, mail, chat, lock, money, server, test, deploy
}

/// 表の行・図の項目を押したときに開く対象。どれか 1 つ
public struct PanelTarget: Codable, Hashable, Sendable {
    public var task: Int?
    public var doc: Int64?
    /// PR・issue・ほかの URL
    public var url: String?

    public init(task: Int? = nil, doc: Int64? = nil, url: String? = nil) {
        self.task = task
        self.doc = doc
        self.url = url
    }
}

/// 計器の値の基準
public struct PanelBasis: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// 分母（4 / 6）
        case denominator
        /// 上限（38h / 60h）
        case limit
        /// 期限（本番開始まで 18 日、期限 12/15）
        case deadline
        /// 前回（前回 12）
        case previous
    }

    public var kind: Kind
    /// 画面に出す基準の値（「6」「60h」「12/15」）
    public var value: String
    /// 値と比べる数。分母と上限で、計器の amount と両方あればバーを描く
    public var amount: Double?

    public init(kind: Kind, value: String, amount: Double? = nil) {
        self.kind = kind
        self.value = value
        self.amount = amount
    }
}

/// 計器。名前・値・基準・状態・補足 1 行
public struct PanelGauge: Codable, Hashable, Sendable {
    public var label: String
    /// 画面に出す値（「4」「18 日」「38h」）。紐づけた計器は空でよい（解決した値を出す）
    public var value: String
    /// 値の数（バーと基準との比較に使う）
    public var amount: Double?
    public var basis: PanelBasis?
    public var tone: PanelTone
    public var symbol: PanelSymbol?
    public var note: String

    public init(
        label: String, value: String = "", amount: Double? = nil, basis: PanelBasis? = nil, tone: PanelTone = .neutral, symbol: PanelSymbol? = nil,
        note: String = ""
    ) {
        self.label = label
        self.value = value
        self.amount = amount
        self.basis = basis
        self.tone = tone
        self.symbol = symbol
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case label, value, amount, basis, tone, symbol, note }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        basis = try c.decodeIfPresent(PanelBasis.self, forKey: .basis)
        tone = try c.decodeIfPresent(PanelTone.self, forKey: .tone) ?? .neutral
        symbol = try c.decodeIfPresent(PanelSymbol.self, forKey: .symbol)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// 表の 1 行
public struct PanelRow: Codable, Hashable, Sendable {
    public var cells: [String]
    public var tone: PanelTone?
    public var symbol: PanelSymbol?
    public var open: PanelTarget?

    public init(cells: [String], tone: PanelTone? = nil, symbol: PanelSymbol? = nil, open: PanelTarget? = nil) {
        self.cells = cells
        self.tone = tone
        self.symbol = symbol
        self.open = open
    }
}

/// 一覧と表。`primary` は主表（その仕事の中心の一覧）
public struct PanelTable: Codable, Hashable, Sendable {
    public var title: String
    public var columns: [String]
    public var rows: [PanelRow]
    public var primary: Bool

    public init(title: String, columns: [String] = [], rows: [PanelRow] = [], primary: Bool = false) {
        self.title = title
        self.columns = columns
        self.rows = rows
        self.primary = primary
    }

    private enum CodingKeys: String, CodingKey { case title, columns, rows, primary }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        rows = try c.decodeIfPresent([PanelRow].self, forKey: .rows) ?? []
        primary = try c.decodeIfPresent(Bool.self, forKey: .primary) ?? false
    }
}

/// 計画。作業項目に紐づき、まとまりごとに描く。`groups` を渡せばそのまとまりだけ
public struct PanelPlan: Codable, Hashable, Sendable {
    public var title: String
    public var groups: [String]

    public init(title: String = "", groups: [String] = []) {
        self.title = title
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case title, groups }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
    }
}

/// 図の項目（流れの段・時系列の出来事・比較の選択肢・関係の点）
public struct PanelNode: Codable, Hashable, Sendable {
    /// 関係の図で辺が指す名前（ほかの型では省いてよい）
    public var id: String
    public var label: String
    public var note: String
    public var tone: PanelTone?
    /// 時系列の時点（「12/1」「11:40」）
    public var at: String
    /// 比較の各列の値（`PanelDiagram.columns` と同じ数）
    public var values: [String]
    /// 比較で推奨する選択肢
    public var recommended: Bool
    public var open: PanelTarget?

    public init(
        id: String = "", label: String, note: String = "", tone: PanelTone? = nil, at: String = "", values: [String] = [], recommended: Bool = false,
        open: PanelTarget? = nil
    ) {
        self.id = id
        self.label = label
        self.note = note
        self.tone = tone
        self.at = at
        self.values = values
        self.recommended = recommended
        self.open = open
    }

    private enum CodingKeys: String, CodingKey { case id, label, note, tone, at, values, recommended, open }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decode(String.self, forKey: .label)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        tone = try c.decodeIfPresent(PanelTone.self, forKey: .tone)
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        values = try c.decodeIfPresent([String].self, forKey: .values) ?? []
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        open = try c.decodeIfPresent(PanelTarget.self, forKey: .open)
    }
}

/// 関係の図の辺
public struct PanelEdge: Codable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var label: String

    public init(from: String, to: String, label: String = "") {
        self.from = from
        self.to = to
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case from, to, label }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

/// 図。会話は値だけを渡し、型ごとの描き方はアプリが決める
public struct PanelDiagram: Codable, Hashable, Sendable {
    public enum Style: String, Codable, Hashable, Sendable, CaseIterable {
        case flow, timeline, compare, relation
    }

    public var style: Style
    public var title: String
    public var nodes: [PanelNode]
    /// 関係の図の辺
    public var edges: [PanelEdge]
    /// 比較の列の見出し
    public var columns: [String]

    public init(style: Style, title: String = "", nodes: [PanelNode], edges: [PanelEdge] = [], columns: [String] = []) {
        self.style = style
        self.title = title
        self.nodes = nodes
        self.edges = edges
        self.columns = columns
    }

    private enum CodingKeys: String, CodingKey { case style, title, nodes, edges, columns }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(Style.self, forKey: .style)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        nodes = try c.decodeIfPresent([PanelNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([PanelEdge].self, forKey: .edges) ?? []
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
    }
}

/// グラフの点
public struct PanelPoint: Codable, Hashable, Sendable {
    public var x: String
    public var y: Double

    public init(x: String, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PanelSeries: Codable, Hashable, Sendable {
    public var name: String
    public var points: [PanelPoint]

    public init(name: String = "", points: [PanelPoint]) {
        self.name = name
        self.points = points
    }

    private enum CodingKeys: String, CodingKey { case name, points }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        points = try c.decodeIfPresent([PanelPoint].self, forKey: .points) ?? []
    }
}

/// グラフ（棒・折れ線）。`target` は基準の線（目標・上限）
public struct PanelChart: Codable, Hashable, Sendable {
    public enum Style: String, Codable, Hashable, Sendable, CaseIterable {
        case bar, line
    }

    public var style: Style
    public var title: String
    public var unit: String
    public var series: [PanelSeries]
    public var target: Double?
    public var targetLabel: String

    public init(style: Style, title: String = "", unit: String = "", series: [PanelSeries], target: Double? = nil, targetLabel: String = "") {
        self.style = style
        self.title = title
        self.unit = unit
        self.series = series
        self.target = target
        self.targetLabel = targetLabel
    }

    private enum CodingKeys: String, CodingKey { case style, title, unit, series, target, targetLabel = "target_label" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(Style.self, forKey: .style)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        series = try c.decodeIfPresent([PanelSeries].self, forKey: .series) ?? []
        target = try c.decodeIfPresent(Double.self, forKey: .target)
        targetLabel = try c.decodeIfPresent(String.self, forKey: .targetLabel) ?? ""
    }
}

/// 送る文面の検査の 1 項目（「敬体」「表」）
public struct PanelCheck: Codable, Hashable, Sendable {
    public var label: String
    public var ok: Bool
    public var note: String

    public init(label: String, ok: Bool, note: String = "") {
        self.label = label
        self.ok = ok
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case label, ok, note }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        ok = try c.decode(Bool.self, forKey: .ok)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// 送る文面。人は本文を編集してから［承認］し、承認と本文が会話に届く。送るのは会話で、taskboard は送らない
public struct PanelDraft: Codable, Hashable, Sendable {
    public var title: String
    /// 宛先（「フォーラムのスレッド（ukwhatn 名義）」）
    public var to: String
    public var body: String
    public var checks: [PanelCheck]

    public init(title: String = "", to: String, body: String, checks: [PanelCheck] = []) {
        self.title = title
        self.to = to
        self.body = body
        self.checks = checks
    }

    private enum CodingKeys: String, CodingKey { case title, to, body, checks }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        to = try c.decode(String.self, forKey: .to)
        body = try c.decode(String.self, forKey: .body)
        checks = try c.decodeIfPresent([PanelCheck].self, forKey: .checks) ?? []
    }
}

/// 自由の部品（HTML）。アプリの CSS 変数と基本のクラスで組む。script と外部の読み込みは使えない
public struct PanelHTML: Codable, Hashable, Sendable {
    public var title: String
    public var html: String

    public init(title: String = "", html: String) {
        self.title = title
        self.html = html
    }

    private enum CodingKeys: String, CodingKey { case title, html }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        html = try c.decode(String.self, forKey: .html)
    }
}

/// 部品の中身。JSON は `kind` と各型の欄を同じ階層に並べる
public enum PanelContent: Hashable, Sendable {
    case gauge(PanelGauge)
    case table(PanelTable)
    case plan(PanelPlan)
    case diagram(PanelDiagram)
    case chart(PanelChart)
    case draft(PanelDraft)
    case html(PanelHTML)

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case gauge, table, plan, diagram, chart, draft, html
    }

    public var kind: Kind {
        switch self {
        case .gauge: .gauge
        case .table: .table
        case .plan: .plan
        case .diagram: .diagram
        case .chart: .chart
        case .draft: .draft
        case .html: .html
        }
    }
}

/// 紐づけ先。値の代わりに指定すると、部品は state の今の値で描かれ、会話が書き直さなくても古くならない
public struct PanelBinding: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable, CaseIterable {
        /// 作業項目（計画の部品、計器の「6 / 12」）
        case work
        /// リンクした PR と issue の状態・CI・レビュー
        case links
        /// 子のタスク（このタスクの会話が起動した会話の、別のタスク）の帯の 1 文と状態
        case children
        /// 監視の状態と最後の動き
        case watches
        /// このタスクの未回答の問い
        case questions
    }

    public var source: Source
    /// 作業項目のまとまり（`work` だけ）。空なら全部
    public var group: String

    public init(source: Source, group: String = "") {
        self.source = source
        self.group = group
    }

    private enum CodingKeys: String, CodingKey { case source, group }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(Source.self, forKey: .source)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
    }
}

/// 部品を置く場所。場所ごとに受ける種類と数が決まっている（`PanelValidation`）
public enum PanelPlace: String, Codable, Hashable, Sendable, CaseIterable {
    /// タスクの見出しの下の 1 行。計器だけを 4 個まで
    case band
    /// 会話の一覧の上。表・計画・図・グラフ・HTML のどれか 1 つ
    case head
    /// 入力欄の上。送る文面を 2 件まで
    case composer
    /// 右の欄。会話の頭と同じ種類を 1 つ
    case side

    /// この場所に置ける部品の数
    public var limit: Int {
        switch self {
        case .band: 4
        case .head, .side: 1
        case .composer: 2
        }
    }

    /// この場所が受ける種類
    public var kinds: [PanelContent.Kind] {
        switch self {
        case .band: [.gauge]
        case .composer: [.draft]
        case .head, .side: [.table, .plan, .diagram, .chart, .html]
        }
    }
}

/// 会話が渡す部品 1 つ（id は会話が付ける）
public struct PanelPartSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var content: PanelContent
    public var bind: PanelBinding?
    public var place: PanelPlace

    public init(id: String, content: PanelContent, bind: PanelBinding? = nil, place: PanelPlace = .head) {
        self.id = id
        self.content = content
        self.bind = bind
        self.place = place
    }

    private enum CodingKeys: String, CodingKey { case id, kind, bind, place }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        bind = try c.decodeIfPresent(PanelBinding.self, forKey: .bind)
        // place の無い登録（場所を持つ前の版の会話）は会話の頭に置く
        place = try c.decodeIfPresent(PanelPlace.self, forKey: .place) ?? .head
        content =
            switch try c.decode(PanelContent.Kind.self, forKey: .kind) {
            case .gauge: .gauge(try PanelGauge(from: decoder))
            case .table: .table(try PanelTable(from: decoder))
            case .plan: .plan(try PanelPlan(from: decoder))
            case .diagram: .diagram(try PanelDiagram(from: decoder))
            case .chart: .chart(try PanelChart(from: decoder))
            case .draft: .draft(try PanelDraft(from: decoder))
            case .html: .html(try PanelHTML(from: decoder))
            }
        // 計画は作業項目に紐づく部品（会話が bind を省いても作業項目を引く）
        if case .plan = content, bind == nil { bind = PanelBinding(source: .work) }
    }

    public func encode(to encoder: any Encoder) throws {
        switch content {
        case .gauge(let v): try v.encode(to: encoder)
        case .table(let v): try v.encode(to: encoder)
        case .plan(let v): try v.encode(to: encoder)
        case .diagram(let v): try v.encode(to: encoder)
        case .chart(let v): try v.encode(to: encoder)
        case .draft(let v): try v.encode(to: encoder)
        case .html(let v): try v.encode(to: encoder)
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(content.kind, forKey: .kind)
        try c.encodeIfPresent(bind, forKey: .bind)
        try c.encode(place, forKey: .place)
    }
}

/// 送る文面への人の承認。本文は人が編集した後のもの
public struct PanelDraftAnswer: Codable, Hashable, Sendable {
    public var answerID: Int64
    public var body: String
    /// 人が本文を変えたか
    public var edited: Bool
    public var answeredAt: Date

    public init(answerID: Int64, body: String, edited: Bool, answeredAt: Date) {
        self.answerID = answerID
        self.body = body
        self.edited = edited
        self.answeredAt = answeredAt
    }
}

/// daemon が持つ部品。会話が渡した中身と、更新の時刻・そのときのターン数、送る文面の承認
public struct PanelPart: Codable, Hashable, Sendable, Identifiable {
    public var spec: PanelPartSpec
    public var updatedAt: Date
    /// 更新したときのタスクのターン数（`OverviewPanel.turn`）
    public var updatedTurn: Int
    public var answer: PanelDraftAnswer?

    public var id: String { spec.id }

    public init(spec: PanelPartSpec, updatedAt: Date, updatedTurn: Int, answer: PanelDraftAnswer? = nil) {
        self.spec = spec
        self.updatedAt = updatedAt
        self.updatedTurn = updatedTurn
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey { case spec, updatedAt, updatedTurn, answer }
}

/// タスクの概況（会話が登録した部品の並び）
public struct OverviewPanel: Codable, Hashable, Sendable, Identifiable {
    public var machine: MachineID
    public var taskNumber: Int
    public var parts: [PanelPart]
    /// タスクに紐づいたセッションのターンを終えた数（Stop hook のたびに増える）
    public var turn: Int
    public var updatedAt: Date

    public var id: TaskKey { TaskKey(machine: machine, number: taskNumber) }

    public init(machine: MachineID, taskNumber: Int, parts: [PanelPart], turn: Int, updatedAt: Date) {
        self.machine = machine
        self.taskNumber = taskNumber
        self.parts = parts
        self.turn = turn
        self.updatedAt = updatedAt
    }

    /// 会話が 2 ターン以上更新していない部品（紐づけた部品は state の今の値を描くので古くならない）
    public func isStale(_ part: PanelPart) -> Bool {
        part.spec.bind == nil && turn - part.updatedTurn >= PanelBudget.staleTurns
    }

    /// その場所に置いた部品。場所の数と種類に収まる分だけを、登録の並びで返す（daemon は外れた登録を断るので、外れるのは手で作ったデータだけ）
    public func parts(in place: PanelPlace) -> [PanelPart] {
        Array(parts.filter { $0.spec.place == place && place.kinds.contains($0.spec.content.kind) }.prefix(place.limit))
    }

    /// 承認を待つ送る文面
    public var openDrafts: [PanelPart] {
        parts.filter { part in
            if case .draft = part.spec.content { return part.answer == nil }
            return false
        }
    }
}

// MARK: - 要求と応答

/// `PUT /v1/tasks/{number}/panel`: 概況を部品の配列で置き換える（空の配列で概況を外す）
public struct PanelSetRequest: Codable, Hashable, Sendable {
    public var parts: [PanelPartSpec]
    /// 登録した会話（送る文面の承認をこの会話に届ける）
    public var requester: FeedbackRequester?

    public init(parts: [PanelPartSpec], requester: FeedbackRequester? = nil) {
        self.parts = parts
        self.requester = requester
    }
}

/// `POST /v1/tasks/{number}/panel/parts`: 部品 1 つを id で置き換えるか加える。`remove` で外す
public struct PanelUpdateRequest: Codable, Hashable, Sendable {
    public var part: PanelPartSpec?
    public var remove: String?
    /// 加えるときの位置（0 始まり）。nil なら末尾。置き換えるときは今の位置のまま
    public var position: Int?
    public var requester: FeedbackRequester?

    public init(part: PanelPartSpec? = nil, remove: String? = nil, position: Int? = nil, requester: FeedbackRequester? = nil) {
        self.part = part
        self.remove = remove
        self.position = position
        self.requester = requester
    }
}

/// 書き込みの応答。`warnings` は受け付けたうえで会話に返す注意（自由の部品で色・余白を直接書いた箇所など）
public struct PanelWriteResult: Codable, Hashable, Sendable {
    public var panel: OverviewPanel
    public var warnings: [String]

    public init(panel: OverviewPanel, warnings: [String]) {
        self.panel = panel
        self.warnings = warnings
    }
}

/// `GET /v1/tasks/{number}/panel`: 概況と、紐づけた部品の今の値（部品の id ごと）
public struct PanelReadResult: Codable, Hashable, Sendable {
    public var panel: OverviewPanel?
    public var resolved: [String: PanelResolved]

    public init(panel: OverviewPanel?, resolved: [String: PanelResolved]) {
        self.panel = panel
        self.resolved = resolved
    }
}

/// `POST /v1/tasks/{number}/panel/parts/{id}/approve`: 送る文面の［承認］。本文は人が編集した後のもの
public struct PanelDraftApproveRequest: Codable, Hashable, Sendable {
    public var body: String

    public init(body: String) {
        self.body = body
    }
}

/// 未受領の束に載せる送る文面の承認
public struct PanelDraftFeedback: Codable, Hashable, Sendable {
    public var answerID: Int64
    public var taskNumber: Int
    public var partID: String
    public var title: String
    public var to: String
    /// 会話が出した本文
    public var original: String
    /// 人が承認した本文
    public var body: String
    public var answeredAt: Date

    public var edited: Bool { original != body }

    public init(answerID: Int64, taskNumber: Int, partID: String, title: String, to: String, original: String, body: String, answeredAt: Date) {
        self.answerID = answerID
        self.taskNumber = taskNumber
        self.partID = partID
        self.title = title
        self.to = to
        self.original = original
        self.body = body
        self.answeredAt = answeredAt
    }
}
