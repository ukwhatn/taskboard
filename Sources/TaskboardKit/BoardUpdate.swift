import Foundation

/// `PATCH /v1/boards/{id}`。nil は変えない。
public struct BoardUpdateRequest: Codable, Hashable, Sendable {
    public var name: String?
    public var promptTemplate: String?
    /// 列 id → テンプレート。空文字で消す
    public var columnTemplates: [String: String]?
    public var archived: Bool?
    public var launchDefaults: LaunchDefaults?
    /// true で `launchDefaults` を消す
    public var clearLaunchDefaults: Bool?
    /// 列の全体を置き換える（並びはこの順）。「完了」は消せない。既定の列の完了扱いは変えられない
    public var columns: [BoardColumnEdit]?
    /// 消える列 id → タスクを移す先の列 id。タスクが残る列を消すときに要る
    public var reassign: [String: String]?
    /// PR がマージされたタスクを進める先
    public var mergeTarget: MergeTarget?
    /// 委任範囲の案件の初期値を丸ごと置き換える（空で全部を組み込みの初期値に戻す）
    public var delegation: DelegationScope?

    public init(
        name: String? = nil, promptTemplate: String? = nil, columnTemplates: [String: String]? = nil, archived: Bool? = nil,
        launchDefaults: LaunchDefaults? = nil, clearLaunchDefaults: Bool? = nil, columns: [BoardColumnEdit]? = nil, reassign: [String: String]? = nil,
        mergeTarget: MergeTarget? = nil, delegation: DelegationScope? = nil
    ) {
        self.name = name
        self.promptTemplate = promptTemplate
        self.columnTemplates = columnTemplates
        self.archived = archived
        self.launchDefaults = launchDefaults
        self.clearLaunchDefaults = clearLaunchDefaults
        self.columns = columns
        self.reassign = reassign
        self.mergeTarget = mergeTarget
        self.delegation = delegation
    }
}

/// 列の置き換えの 1 列。`id` が nil なら新しい列で、daemon が id を振る。案件に無い既定の列の id なら、その列を戻す
public struct BoardColumnEdit: Codable, Hashable, Sendable {
    public var id: String?
    public var label: String
    public var kind: BoardColumn.Kind
    public var collapsed: Bool
    /// nil は「変えない」、空文字は「消す」
    public var promptTemplate: String?
    /// nil は「変えない」（戻した既定の列は既定の説明）
    public var description: String?

    public init(id: String?, label: String, kind: BoardColumn.Kind, collapsed: Bool, promptTemplate: String? = nil, description: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.collapsed = collapsed
        self.promptTemplate = promptTemplate
        self.description = description
    }
}

/// 案件ごとの起動の既定。daemon に置く（そのマシンのセッションが使うため）
public struct LaunchDefaults: Codable, Hashable, Sendable {
    public var kind: AgentKind
    public var agentArgs: [String]
    /// true なら起動のシートで worktree を切る
    public var worktree: Bool
    /// 空なら、最後に使った作業ディレクトリ（アプリ側）
    public var cwd: String

    public init(kind: AgentKind = .claude, agentArgs: [String] = [], worktree: Bool = false, cwd: String = "") {
        self.kind = kind
        self.agentArgs = agentArgs
        self.worktree = worktree
        self.cwd = cwd
    }
}
