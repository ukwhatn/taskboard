import Foundation
import TaskboardKit

/// 設定画面の区分（47 §5 の順）。列と起動は案件の中（`BoardDetailSettings`）で設定するので区分には無い
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case connections, boards, sessions, terminal, chat, notifications, display, usage, shortcuts

    var id: String { rawValue }

    /// この端末で出す区分。iPhone にはショートカット（載せているキーはサイドバーとパネルの操作で、iPhone の画面に無い）と
    /// ターミナル（iPhone は端末をシートで見るだけで、フォント・テーマ・⌥ の扱いは初期値で足りる）を出さない
    @MainActor static var shown: [SettingsSection] {
        AppModel.isPhone ? allCases.filter { $0 != .shortcuts && $0 != .terminal } : allCases
    }

    var title: String {
        switch self {
        case .connections: String(localized: "接続先")
        case .boards: String(localized: "案件")
        case .sessions: String(localized: "セッション")
        case .terminal: String(localized: "ターミナル")
        case .chat: String(localized: "チャット")
        case .notifications: String(localized: "通知")
        case .display: String(localized: "表示")
        case .usage: String(localized: "利用状況")
        case .shortcuts: String(localized: "ショートカット")
        }
    }

    var symbol: String {
        switch self {
        case .connections: "network"
        case .boards: "rectangle.grid.2x2"
        case .sessions: "pause.circle"
        case .terminal: "terminal"
        case .chat: "bubble.left.and.text.bubble.right"
        case .notifications: "bell.badge"
        case .display: "eye"
        case .usage: "chart.xyaxis.line"
        case .shortcuts: "keyboard"
        }
    }
}

/// 設定の案件の区分で開いている案件（接続設定の id と案件の id）
struct SettingsBoardKey: Hashable {
    let fleetID: String
    let boardID: String
}

/// 案件の設定の編集中の値。`baseline` は読み込んだときの値で、`draft` との差が保存していない変更
struct BoardSettingsEdit: Hashable {
    var draft: BoardSettingsDraft
    var baseline: BoardSettingsDraft

    var dirty: Bool { draft.differs(from: baseline) }
}

/// 設定で未保存の変更があるまま移ろうとした先。確かめてから移る
enum SettingsLeave: Hashable {
    case section(SettingsSection)
    /// 案件の一覧へ戻る
    case boardList
}

/// 設定の案件の区分で編集できるマシン（接続設定の id と、そのマシンの状態）
struct SettingsBoardScope {
    let fleetID: String
    let state: MachineState
    let machine: MachineID
}

extension AppModel {
    /// 設定画面の中から別の区分へ移る（［案件の設定を開く］など）。狭い幅（iPhone と狭い iPad）は押して開いた区分を差し替える
    func showSettings(_ section: SettingsSection) {
        settingsSection = section
        #if os(iOS)
        compactSettingsSection = section
        #endif
    }

    /// 設定で案件を 1 件開く
    func openBoardSettings(_ key: SettingsBoardKey) {
        settingsBoardPath = [key]
    }

    /// 区分を移る・案件の一覧へ戻る。未保存の変更があれば確かめる（`SettingsView` が `settingsLeaveRequest` を出す）
    func leaveSettings(_ destination: SettingsLeave) {
        if settingsDirty {
            settingsLeaveRequest = destination
        } else {
            performSettingsLeave(destination)
        }
    }

    /// 確かめた後に移る。開いている案件の下書きは捨てる
    func performSettingsLeave(_ destination: SettingsLeave) {
        if let key = settingsBoardPath.first { settingsBoardDrafts[key] = nil }
        settingsDirty = false
        settingsLeaveRequest = nil
        switch destination {
        case .section(let section):
            settingsBoardPath = []
            showSettings(section)
        case .boardList: settingsBoardPath = []
        }
    }

    /// 非表示を含む全マシンを、サイドバーの順で（設定の接続先の一覧）
    var orderedAllMachines: [(id: String, state: MachineState)] {
        let ids = SidebarOrder.arrange(fleet.allMachines.keys.sorted(), by: machineOrder)
        return ids.compactMap { id in fleet.allMachines[id].map { (id, $0) } }
    }

    /// マシンの情報が届いている接続先を、非表示のマシンも含めてサイドバーの順で。設定の案件とセッションの対象。
    /// 書き込めない接続先（fixtures）も出し、保存したときに「表示用のデータです」と知らせる（本物の接続先はどれも書き込める）
    var settingsMachines: [SettingsBoardScope] {
        orderedAllMachines.compactMap { entry in
            guard let machine = entry.state.machine?.id else { return nil }
            return SettingsBoardScope(fleetID: entry.id, state: entry.state, machine: machine)
        }
    }

    /// 案件の設定の編集中の値を残す。変更が無ければ消す（保存した・元に戻した・daemon から読み直した）
    func keepBoardDraft(_ edit: BoardSettingsEdit, for key: SettingsBoardKey) {
        settingsBoardDrafts[key] = edit.dirty ? edit : nil
    }

    /// 設定で開いている案件。消えていれば nil
    func settingsBoard(_ key: SettingsBoardKey) -> Board? {
        fleet.allMachines[key.fleetID]?.boards[key.boardID]
    }

    /// マシンの設定（オーケストレーターの常駐、操作のないセッションの停止）を送る。画面は押した値を先に出し、失敗したら戻して帯で知らせる
    func saveSettings(on machine: MachineID, _ body: MachineSettingsUpdate) async -> Bool {
        let window = activeWindow
        do {
            _ = try await requireSource(machine).updateSettings(body)
            return true
        } catch {
            fail("設定を保存できませんでした", error, in: window)
            return false
        }
    }

    /// 設定の接続先の一覧で、1 つ上か下へ動かす（非表示のマシンも数える）
    func moveMachine(_ fleetID: String, by offset: Int) {
        var ids = orderedAllMachines.map(\.id)
        guard let index = ids.firstIndex(of: fleetID), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        machineOrder = ids
    }

    /// 設定の接続先の一覧のドラッグ（非表示のマシンも数える）
    func moveAllMachines(from source: IndexSet, to destination: Int) {
        machineOrder = SidebarOrder.move(orderedAllMachines.map(\.id), from: source, to: destination)
    }

    /// 設定の案件の一覧で、1 つ上か下へ動かす（アーカイブした案件も数える）
    func moveBoard(_ board: Board, fleetID: String, by offset: Int) {
        guard let state = fleet.allMachines[fleetID] else { return }
        let ids = orderedBoards(state, fleetID: fleetID, includeArchived: true).map(\.id)
        guard let index = ids.firstIndex(of: board.id), ids.indices.contains(index + offset) else { return }
        moveBoards(state, fleetID: fleetID, includeArchived: true, from: [index], to: offset > 0 ? index + offset + 1 : index + offset)
    }

    /// 案件の Slack の設定。表示用のデータの接続先は未設定として見せ、保存したときに「表示用のデータです」と知らせる
    func boardSlack(_ board: Board) async throws -> BoardSlack {
        if fleet.writeAccess(board.machine) == .readOnly { return BoardSlack() }
        return try await requireSource(board.machine).boardSlack(id: board.id)
    }

    func updateBoardSlack(_ board: Board, _ request: BoardSlackUpdate) async throws -> BoardSlack {
        try await requireSource(board.machine).updateBoardSlack(id: board.id, request)
    }

    func deleteBoardSlack(_ board: Board) async throws {
        try await requireSource(board.machine).deleteBoardSlack(id: board.id)
    }

    /// 届け先に選べるチャンネル（ボットが参加しているもの）
    func slackChannels(_ board: Board) async throws -> [SlackChannel] {
        if fleet.writeAccess(board.machine) == .readOnly { return [] }
        return try await requireSource(board.machine).slackChannels(board: board.id)
    }

    /// 案件の名前・アーカイブ・列・起動の既定を daemon で変える。届いた案件は `board.updated` で画面に入る
    @discardableResult
    func updateBoard(_ board: Board, _ request: BoardUpdateRequest) async throws -> Board {
        try await requireSource(board.machine).updateBoard(id: board.id, request)
    }

    /// タスクが 0 件の案件だけ消せる（daemon が確かめる）
    func deleteBoard(_ board: Board) async throws {
        try await requireSource(board.machine).deleteBoard(id: board.id)
    }

    /// default に混ざったタスクを別の案件へ振り分ける。列は daemon が決める（同じ id の列、無ければ先頭の進行中の列）
    func moveTasks(_ tasks: [BoardTask], to board: Board) async throws {
        let source = try requireSource(board.machine)
        for task in tasks where task.boardID != board.id {
            _ = try await source.updateTask(number: task.number, TaskUpdateRequest(boardID: board.id))
        }
    }
}
