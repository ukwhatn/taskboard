import Foundation

/// 委任範囲の項目。会話がどこまで自分で決めてよいかを、項目ごとに段階（`DelegationLevel`）で決める。並びは画面と案内の並び
public enum DelegationArea: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case implementation
    case tracker
    case followups
    case reviewMerge = "review_merge"
    case outbound
    case cost
    case destructive

    public var id: String { rawValue }

    /// 案件にもタスクにも指定が無いときの段階
    public var builtinLevel: DelegationLevel {
        switch self {
        case .implementation, .tracker: .delegate
        case .followups: .report
        case .reviewMerge, .outbound, .cost, .destructive: .ask
        }
    }

    /// 画面の名前
    public var label: String {
        switch self {
        case .implementation: String(localized: "実装の進め方（PRの分け方・順序・設計の細部）")
        case .tracker: String(localized: "issue・チケットの更新")
        case .followups: String(localized: "範囲外で見つけた不具合の起票")
        case .reviewMerge: String(localized: "レビューの依頼・マージ")
        case .outbound: String(localized: "社外・他チームへの文面の投稿")
        case .cost: String(localized: "費用の発生")
        case .destructive: String(localized: "削除・戻せない操作")
        }
    }

    /// 会話へ送る文の名前（`label` と同じ語。会話へ送る文は Agent の catalog に置く）
    public var agentLabel: String {
        switch self {
        case .implementation: Copy.text("agent.delegation.area.implementation")
        case .tracker: Copy.text("agent.delegation.area.tracker")
        case .followups: Copy.text("agent.delegation.area.followups")
        case .reviewMerge: Copy.text("agent.delegation.area.review_merge")
        case .outbound: Copy.text("agent.delegation.area.outbound")
        case .cost: Copy.text("agent.delegation.area.cost")
        case .destructive: Copy.text("agent.delegation.area.destructive")
        }
    }
}

/// 委任範囲の段階
public enum DelegationLevel: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// 決めて実行する
    case delegate
    /// 決めて実行し、決めたことを応答で報告する
    case report
    /// 今のとおり人に問う
    case ask

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .delegate: String(localized: "委任")
        case .report: String(localized: "報告のみ")
        case .ask: String(localized: "確認")
        }
    }

    public var agentLabel: String {
        switch self {
        case .delegate: Copy.text("agent.delegation.level.delegate")
        case .report: Copy.text("agent.delegation.level.report")
        case .ask: Copy.text("agent.delegation.level.ask")
        }
    }
}

/// 項目ごとの段階の指定（指定したものだけ）。案件の初期値とタスクの上書きの両方に使う。JSON は `{"tracker": "delegate"}`。
/// 知らない項目と段階（後の版が足したもの）は読み捨てる
public struct DelegationScope: Hashable, Sendable, Codable {
    public var levels: [DelegationArea: DelegationLevel]

    public init(_ levels: [DelegationArea: DelegationLevel] = [:]) {
        self.levels = levels
    }

    public subscript(area: DelegationArea) -> DelegationLevel? {
        get { levels[area] }
        set { levels[area] = newValue }
    }

    public var isEmpty: Bool { levels.isEmpty }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        var levels: [DelegationArea: DelegationLevel] = [:]
        for (key, value) in raw {
            guard let area = DelegationArea(rawValue: key), let level = DelegationLevel(rawValue: value) else { continue }
            levels[area] = level
        }
        self.levels = levels
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: levels.map { ($0.key.rawValue, $0.value.rawValue) }))
    }
}

/// 1 項目の、今効いている段階とその出所
public struct DelegationEntry: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        /// 案件にもタスクにも指定が無い
        case builtin
        /// 案件の初期値
        case board
        /// タスクの上書き
        case task
    }

    public var area: DelegationArea
    public var level: DelegationLevel
    public var source: Source

    public init(area: DelegationArea, level: DelegationLevel, source: Source) {
        self.area = area
        self.level = level
        self.source = source
    }

    /// 案件の設定に従っている（タスクで上書きしていない）か
    public var followsBoard: Bool { source != .task }
}

extension BoardTask {
    /// 7 項目の今効いている段階。タスクの上書き → 案件の初期値 → 組み込みの初期値の順に決める
    public func delegation(board: Board?) -> [DelegationEntry] {
        DelegationArea.allCases.map { area in
            if let level = delegation[area] { return DelegationEntry(area: area, level: level, source: .task) }
            if let level = board?.delegation[area] { return DelegationEntry(area: area, level: level, source: .board) }
            return DelegationEntry(area: area, level: area.builtinLevel, source: .builtin)
        }
    }

    public func delegationLevel(_ area: DelegationArea, board: Board?) -> DelegationLevel {
        delegation[area] ?? board?.delegation[area] ?? area.builtinLevel
    }
}

extension Board {
    /// 案件の初期値（指定が無い項目は組み込みの初期値）
    public func delegationLevel(_ area: DelegationArea) -> DelegationLevel {
        delegation[area] ?? area.builtinLevel
    }
}
