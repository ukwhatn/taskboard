import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 設定の案件の中身: 1 回の［保存］で送る中身と、未保存の判定
@MainActor
@Suite struct BoardSettingsDraftTests {
    private static let machine = MachineID(rawValue: "m1")

    private static func board(defaults: LaunchDefaults? = nil, mergeTarget: MergeTarget = .deploying) -> Board {
        Board(
            id: "b1", machine: machine, name: "taskboard", position: 0,
            columns: [
                BoardColumn(id: "todo", label: "未着手", kind: .open, position: 0, collapsed: false),
                BoardColumn(id: "done", label: "完了", kind: .terminal, position: 1, promptTemplate: "振り返る", collapsed: true),
            ],
            createdAt: Date(timeIntervalSince1970: 0), promptTemplate: "#{{id}}", launchDefaults: defaults, mergeTarget: mergeTarget)
    }

    @Test("読み込んだままなら未保存の変更は無く、送る中身も空")
    func untouchedSendsNothing() {
        let board = Self.board()
        let draft = BoardSettingsDraft(board)
        #expect(!draft.differs(from: draft))
        let request = draft.request(from: draft, board: board, needsTarget: [])
        #expect(request == BoardUpdateRequest())
    }

    @Test("名前・マージしたら・起動プロンプトは変えたものだけ送る。名前は前後の空白を除く")
    func changedFieldsOnly() {
        let board = Self.board()
        let baseline = BoardSettingsDraft(board)
        var draft = baseline
        draft.name = "  taskboard 2 "
        draft.mergeTarget = .done
        #expect(draft.differs(from: baseline))
        let request = draft.request(from: baseline, board: board, needsTarget: [])
        #expect(request.name == "taskboard 2")
        #expect(request.mergeTarget == .done)
        #expect(request.promptTemplate == nil)
        #expect(request.columns == nil)
    }

    @Test("委任範囲は組み込みの初期値と違う段階だけを持ち、変えたときだけ丸ごと送る")
    func delegationDiffersFromBuiltin() {
        let board = Self.board()
        let baseline = BoardSettingsDraft(board)
        var draft = baseline
        draft.setDelegation(.ask, for: .implementation)
        draft.setDelegation(.delegate, for: .reviewMerge)
        draft.setDelegation(.ask, for: .destructive)
        #expect(draft.delegation == DelegationScope([.implementation: .ask, .reviewMerge: .delegate]))
        #expect(draft.request(from: baseline, board: board, needsTarget: []).delegation == draft.delegation)
        draft.setDelegation(.delegate, for: .implementation)
        draft.setDelegation(.ask, for: .reviewMerge)
        #expect(!draft.differs(from: baseline), "組み込みの初期値に戻すと変更なし")
        #expect(draft.request(from: baseline, board: board, needsTarget: []).delegation == nil)
    }

    @Test("列を変えたら、列ごとの起動プロンプトも含めて全体を送る。足した列の起動プロンプトも載る")
    func columnsCarryTemplates() {
        let board = Self.board()
        let baseline = BoardSettingsDraft(board)
        var draft = baseline
        draft.columns.append(ColumnDraft(id: nil, label: " 確認 ", kind: .open, collapsed: false, standard: false, template: "見る"))
        let columns = draft.request(from: baseline, board: board, needsTarget: []).columns
        #expect(columns?.map(\.label) == ["未着手", "完了", "確認"])
        #expect(columns?.map(\.promptTemplate) == ["", "振り返る", "見る"])
        #expect(columns?.last?.id == nil)
    }

    @Test("起動の初期値はオフの間の中身を比べず、オフにすると消す要求を送る")
    func launchDefaultsToggle() {
        let board = Self.board(defaults: LaunchDefaults(kind: .claude, agentArgs: LaunchChoice.standard.args, worktree: false, cwd: "~/dev"))
        let baseline = BoardSettingsDraft(board)
        #expect(baseline.hasLaunchDefaults)
        var draft = baseline
        draft.hasLaunchDefaults = false
        draft.launch.cwd = "~/other"
        let request = draft.request(from: baseline, board: board, needsTarget: [])
        #expect(request.clearLaunchDefaults == true)
        #expect(request.launchDefaults == nil)

        let empty = BoardSettingsDraft(Self.board())
        var off = empty
        off.launch.cwd = "~/x"
        #expect(!off.differs(from: empty), "オフのまま中身を変えても未保存にしない")
    }

    @Test("タスクが残る列を消すときだけ、選んだ移動先を送る")
    func reassignOnlyForRemovedColumnsWithTasks() {
        let board = Self.board()
        let baseline = BoardSettingsDraft(board)
        var draft = baseline
        draft.columns.removeAll { $0.id == "todo" }
        draft.reassign = ["todo": "done", "gone": "done"]
        let removed = draft.removedColumns(of: board)
        #expect(removed.map(\.id) == ["todo"])
        let request = draft.request(from: baseline, board: board, needsTarget: removed)
        #expect(request.reassign == ["todo": "done"])
    }

    @Test("未保存の変更があるまま区分を移ると確かめ、破棄すると移る")
    func leavingWithUnsavedChangesAsks() {
        AppDefaults.useScratch("board-settings-draft")
        let model = AppModel(options: LaunchOptions(scenario: "sessions-basic"))
        model.settingsSection = .boards
        model.settingsBoardPath = [SettingsBoardKey(fleetID: "f", boardID: "b1")]
        model.settingsDirty = true
        model.leaveSettings(.section(.display))
        #expect(model.settingsSection == .boards)
        #expect(model.settingsLeaveRequest == .section(.display))
        model.performSettingsLeave(.section(.display))
        #expect(model.settingsSection == .display)
        #expect(model.settingsBoardPath.isEmpty)
        #expect(!model.settingsDirty)

        model.settingsBoardPath = [SettingsBoardKey(fleetID: "f", boardID: "b1")]
        model.leaveSettings(.boardList)
        #expect(model.settingsBoardPath.isEmpty, "変更が無ければ確かめずに戻る")
    }

    @Test("保存していない下書きは案件ごとに model に残り、変更が無くなれば消える。開き直すと続きから始まる")
    func draftsSurviveClosingTheWindow() {
        AppDefaults.useScratch("board-settings-draft")
        let model = AppModel(options: LaunchOptions(scenario: "sessions-basic"))
        let board = Self.board()
        let key = SettingsBoardKey(fleetID: "f", boardID: board.id)
        let other = SettingsBoardKey(fleetID: "f", boardID: "b2")
        let baseline = BoardSettingsDraft(board)
        var draft = baseline
        draft.name = "taskboard 2"

        model.keepBoardDraft(BoardSettingsEdit(draft: draft, baseline: baseline), for: key)
        model.keepBoardDraft(BoardSettingsEdit(draft: draft, baseline: baseline), for: other)
        #expect(model.settingsBoardDrafts[key]?.draft.name == "taskboard 2")
        // 開き直したとき（設定の窓を閉じて開く）は、残った下書きと読み込んだときの値から始める
        let kept = model.settingsBoardDrafts[key]
        #expect(kept?.dirty == true)
        #expect(kept?.baseline == baseline)

        // 元に戻す・保存すると、変更が無いので消える
        model.keepBoardDraft(BoardSettingsEdit(draft: baseline, baseline: baseline), for: key)
        #expect(model.settingsBoardDrafts[key] == nil)

        // 「変更の破棄」で移ると、開いている案件の下書きだけ消える
        model.keepBoardDraft(BoardSettingsEdit(draft: draft, baseline: baseline), for: key)
        model.settingsBoardPath = [key]
        model.performSettingsLeave(.boardList)
        #expect(model.settingsBoardDrafts[key] == nil)
        #expect(model.settingsBoardDrafts[other] != nil, "ほかの案件の下書きは残す")
    }
}

/// 列の説明と、既定の列の削除と戻し
@MainActor
@Suite struct BoardSettingsColumnGuideTests {
    private static func board(_ ids: [String]) -> Board {
        let columns = ids.enumerated().map { index, id in
            BoardColumn.standard.first { $0.id == id }.map { var c = $0; c.position = index; return c }
                ?? BoardColumn(id: id, label: "保留", kind: .open, position: index, description: "返事待ち")
        }
        return Board(id: "b1", machine: MachineID(rawValue: "m1"), name: "a", position: 0, columns: columns, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("説明を直すと、列の全体と一緒に説明を送る")
    func descriptionIsSent() {
        let board = Self.board(BoardColumn.standard.map(\.id))
        let baseline = BoardSettingsDraft(board)
        var draft = baseline
        draft.columns[0].description = "定常の運用"
        let columns = draft.request(from: baseline, board: board, needsTarget: []).columns
        #expect(columns?.first?.description == "定常の運用")
        #expect(columns?[1].description == ColumnGuide.defaultDescriptions["review_req"])
    }

    @Test("消せないのは完了だけ。下書きに無い既定の列を、既定の並びの位置に既定の説明と起動プロンプトで戻す")
    func restoreStandard() {
        let board = Self.board(["c-hold", "todo", "working", "done"])
        var draft = BoardSettingsDraft(board)
        #expect(draft.columns.filter { !$0.removable }.map(\.id) == ["done"])
        #expect(draft.missingStandardColumns.map(\.id) == ["standing", "review_req", "planning", "review", "deploying", "wontfix"])

        draft.restore(BoardColumn.standard.first { $0.id == "review_req" }!)
        draft.restore(BoardColumn.standard.first { $0.id == "planning" }!)
        draft.restore(BoardColumn.standard.first { $0.id == "wontfix" }!)
        #expect(draft.columns.map(\.id) == ["c-hold", "review_req", "todo", "planning", "working", "done", "wontfix"])
        let restored = draft.columns[1]
        #expect(restored.standard && restored.label == "レビュー依頼" && restored.kind == .open)
        #expect(restored.template == PromptTemplate.defaultReviewRequestTemplate)
        #expect(restored.description == ColumnGuide.defaultDescriptions["review_req"])
        #expect(draft.columns.last?.collapsed == true)
    }
}
