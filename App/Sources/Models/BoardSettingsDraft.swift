import SwiftUI
import TaskboardKit

/// 編集中の列。`id` が nil は足した列（保存すると daemon が id を振る）
struct ColumnDraft: Identifiable, Hashable {
    let key = UUID()
    var id: String?
    var label: String
    var kind: BoardColumn.Kind
    var collapsed: Bool
    var standard: Bool
    /// 列ごとの起動プロンプト。空なら案件の起動プロンプトを使う
    var template: String
    var description = ""

    var removable: Bool { BoardColumn.isRemovable(id: id) }
}

/// 案件の設定の下書き。保存の帯の 1 回の［保存］で全部を送る
struct BoardSettingsDraft: Hashable {
    var name: String
    var mergeTarget: MergeTarget
    var columns: [ColumnDraft]
    /// 削除する列 id → タスクの移動先の列 id
    var reassign: [String: String] = [:]
    var hasLaunchDefaults: Bool
    var launch: LaunchDraft
    var promptTemplate: String
    /// 委任範囲の案件の初期値。組み込みの初期値と同じ項目は持たない（`DelegationArea.builtinLevel` が変わったら追従させる）
    var delegation: DelegationScope
    /// Slack の設定。daemon から読み終えるまで nil（案件とは別の API で読み書きする）
    var slack: BoardSlackDraft?

    init(_ board: Board) {
        name = board.name
        mergeTarget = board.mergeTarget
        columns = board.orderedColumns.map {
            ColumnDraft(
                id: $0.id, label: $0.label, kind: $0.kind, collapsed: $0.collapsed, standard: $0.isStandard, template: $0.promptTemplate ?? "",
                description: $0.description)
        }
        var launch = LaunchDraft(machine: board.machine)
        if let defaults = board.launchDefaults {
            launch.select(kind: defaults.kind, args: defaults.agentArgs)
            launch.cwd = defaults.cwd
        }
        self.launch = launch
        hasLaunchDefaults = board.launchDefaults != nil
        promptTemplate = board.promptTemplate
        delegation = board.delegation
    }

    /// 項目の段階を選ぶ。組み込みの初期値と同じなら指定を外す
    mutating func setDelegation(_ level: DelegationLevel, for area: DelegationArea) {
        delegation[area] = level == area.builtinLevel ? nil : level
    }

    /// 起動の初期値はオフの間の中身を比べない（オフにして戻すだけなら変更なし）
    func differs(from other: BoardSettingsDraft) -> Bool {
        boardDiffers(from: other) || slackRequest(from: other) != nil
    }

    /// Slack を除いた案件の設定の変更
    func boardDiffers(from other: BoardSettingsDraft) -> Bool {
        var a = self, b = other
        if !a.hasLaunchDefaults { a.launch = b.launch }
        a.launch.id = b.launch.id
        a.slack = nil
        b.slack = nil
        return a != b
    }

    /// Slack の設定で送る中身。読み終えていないか、変更が無ければ nil
    func slackRequest(from baseline: BoardSettingsDraft) -> BoardSlackUpdate? {
        guard let slack, let base = baseline.slack else { return nil }
        return slack.request(from: base)
    }

    /// 消える列のうち、タスクが残っているもの
    func removedColumns(of board: Board) -> [BoardColumn] {
        board.columns.filter { column in !columns.contains { $0.id == column.id } }
    }

    /// 下書きに無い既定の列（［列を追加］から戻せる）
    var missingStandardColumns: [BoardColumn] {
        BoardColumn.standard.filter { standard in !columns.contains { $0.id == standard.id } }
    }

    /// 既定の列を、既定の並びで次に来る列の前に戻す。名前・説明・起動プロンプトは既定の値
    mutating func restore(_ column: BoardColumn) {
        let order = BoardColumn.standard.map(\.id)
        guard let rank = order.firstIndex(of: column.id) else { return }
        let index = columns.firstIndex { draft in (draft.id.flatMap { order.firstIndex(of: $0) } ?? -1) > rank } ?? columns.endIndex
        columns.insert(
            ColumnDraft(
                id: column.id, label: column.label, kind: column.kind, collapsed: column.collapsed, standard: true,
                template: PromptTemplate.defaultColumnTemplates[column.id] ?? "", description: column.description),
            at: index)
    }

    func request(from baseline: BoardSettingsDraft, board: Board, needsTarget: [BoardColumn]) -> BoardUpdateRequest {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let columnsChanged = columns != baseline.columns
        let edits = columns.map {
            BoardColumnEdit(
                id: $0.id, label: $0.label.trimmingCharacters(in: .whitespaces), kind: $0.kind, collapsed: $0.collapsed, promptTemplate: $0.template,
                description: $0.description)
        }
        let targets = reassign.filter { entry in needsTarget.contains { $0.id == entry.key } && !entry.value.isEmpty }
        return BoardUpdateRequest(
            name: trimmed == board.name ? nil : trimmed,
            promptTemplate: promptTemplate == baseline.promptTemplate ? nil : promptTemplate,
            launchDefaults: hasLaunchDefaults
                ? LaunchDefaults(kind: launch.kind, agentArgs: launch.agentArgs, worktree: false, cwd: launch.cwd.trimmingCharacters(in: .whitespaces)) : nil,
            clearLaunchDefaults: !hasLaunchDefaults && board.launchDefaults != nil ? true : nil,
            columns: columnsChanged ? edits : nil,
            reassign: columnsChanged && !targets.isEmpty ? targets : nil,
            mergeTarget: mergeTarget == board.mergeTarget ? nil : mergeTarget,
            delegation: delegation == baseline.delegation ? nil : delegation)
    }
}
