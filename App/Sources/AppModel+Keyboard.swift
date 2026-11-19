import Foundation
import SwiftUI
import TaskboardKit

/// ⌃Tab / ⌃⇧Tab の知らせ。`count` が変わるたびに、開いているタスクのパネルが `delta` だけセッションを送る
struct SessionCycleRequest: Equatable {
    var count = 0
    var delta = 0
}

/// キーボードとパレットから呼ぶ操作。メニュー・⌘K・ボードのキーが同じ関数を通る
extension AppModel {
    /// キーで操作する相手のタスク: 開いているタスク、無ければ選んでいるカード（ホームの会話の形では、選んでいる会話のタスク）
    var keyboardTarget: TaskKey? { selectedTask ?? (homeShowsTiles ? cursorTileTask : cursorTask) }

    /// 全体のボードの並び（出している案件だけ。畳んだマシンは除く。列は終端以外、カードは番号順で、画面と同じ）
    var boardCursorGrid: BoardCursorGrid {
        BoardCursorGrid(boards: overviewSections.filter { !$0.collapsed }.flatMap { section in
            section.boards.map { board in
                let tasks = section.state.tasks.values.filter { $0.boardID == board.id }.sorted { $0.number < $1.number }
                return board.unfoldedColumns.map { column in tasks.filter { $0.columnID == column.id }.map(\.id) }
            }
        })
    }

    func moveCursor(_ direction: BoardCursorGrid.Direction) {
        let next = boardCursorGrid.move(from: cursorTask ?? selectedTask, direction)
        cursorTask = next
        // パネルを開いたままなら、中身も選んだカードに合わせる
        if selectedTask != nil, let next { navigate(to: .task(next, revealBoard: false), from: .key) }
    }

    /// ↩: 選んでいるカードを開く
    func openCursor() {
        guard let key = cursorTask ?? boardCursorGrid.move(from: nil, .down) else { return }
        navigate(to: .task(key, revealBoard: false), from: .key)
    }

    /// ⌘1〜⌘9: サイドバーの n 番目の案件（マシンの順、その中の案件の順）へ移り、先頭のカードを選ぶ
    func selectSidebarBoard(_ slot: Int) {
        let boards = orderedMachines.flatMap { orderedBoards($0.state, fleetID: $0.id) }
        guard boards.indices.contains(slot - 1) else { return }
        let board = boards[slot - 1]
        collapsedMachines.remove(board.machine.rawValue)
        navigate(to: .board(machine: board.machine, id: board.id), from: .key)
        if homeShowsTiles {
            selectFirstTile()
            return
        }
        let grid = boardCursorGrid
        cursorTask = grid.boards.lazy.flatMap { $0 }.flatMap { $0 }.first { key in fleet.task(for: key)?.boardID == board.id && key.machine == board.machine }
    }

    /// ⌘N の行き先: サイドバーで選んだ案件 → キーで選んでいるタスクの案件 → 先頭の案件
    var newTaskBoard: Board? {
        if case .board(let machine, let id) = phoneTaskPath.last ?? sidebar, let board = fleet.board(id: id, on: machine) { return board }
        if let key = keyboardTarget, let task = fleet.task(for: key), let board = fleet.board(id: task.boardID, on: task.machine) { return board }
        for machine in orderedMachines {
            if let board = orderedBoards(machine.state, fleetID: machine.id).first { return board }
        }
        return nil
    }

    func startNewTask() {
        guard let board = newTaskBoard else { return }
        newTaskSheet = NewTaskDraft(board: board)
    }

    /// 「案件を作る」の行き先: キーで選んでいるタスクのマシン → サイドバーで選んだ案件のマシン → 書き込める最初のマシン
    var newBoardMachine: MachineID? {
        if let key = keyboardTarget { return key.machine }
        if case .board(let machine, _) = sidebar { return machine }
        return writableMachines.first
    }

    func startNewBoard(on machine: MachineID? = nil) {
        guard let machine = machine ?? newBoardMachine else { return }
        newBoardSheet = NewBoardDraft(machine: machine)
    }

    /// 案件を作り、全体のボードでそこを見せる。列は daemon の既定
    @discardableResult
    func createBoard(_ draft: NewBoardDraft, reveal: Bool = true) async throws -> Board {
        let board = try await requireSource(draft.machine).createBoard(BoardCreateRequest(name: draft.name.trimmingCharacters(in: .whitespaces)))
        if reveal { self.navigate(to: .board(machine: board.machine, id: board.id), from: .app) }
        return board
    }

    /// 起動シートの初期値: 紐づくセッションの cwd、無ければ案件の起動の既定、それも空ならこの案件で最後に使った cwd
    func launchDraft(for task: BoardTask) -> LaunchDraft {
        LaunchDraft.initial(
            machine: task.machine, board: fleet.board(id: task.boardID, on: task.machine), boardID: task.boardID, columnID: task.columnID,
            cwd: fleet.machineState(for: task.machine)?.conversations(of: task).first { !$0.isClosed }?.cwd ?? "")
    }

    /// キーで選んでいるタスクを開き、起動シートを出す
    func launchForTarget() {
        guard let key = keyboardTarget, let task = fleet.task(for: key) else { return }
        navigate(to: .task(key, revealBoard: false), from: .key)
        launchSheet = launchDraft(for: task)
    }

    func requestSessionFocus() {
        sessionFocusTarget = nil
        sessionFocusRequests += 1
        activeTerminal?.engine.requestFocus()
    }

    /// `item` の入力欄か端末にフォーカスを移す（並べた欄の間の移動）
    func requestSessionFocus(on item: ConversationKey) {
        sessionFocusTarget = item
        sessionFocusRequests += 1
    }

    func cycleSession(by delta: Int) {
        sessionCycleRequest = SessionCycleRequest(count: sessionCycleRequest.count + 1, delta: delta)
    }

    // MARK: パレット

    /// パレットのコマンド。今の状態で使えないもの（相手のタスクが無い等）は出さない。
    /// キーの表記は Apple の順（⌃⌥⇧⌘）。iPhone はキーの表記と、画面に無い操作（列の移動・開き方・ショートカットの一覧）を出さない
    var paletteCommands: [PaletteEntry] {
        var entries: [PaletteEntry] = []
        let phone = Self.isPhone
        func add(_ id: String, _ title: String, _ shortcut: String? = nil, keywords: [String] = []) {
            entries.append(PaletteEntry(id: "command:\(id)", kind: .command, title: title, keywords: keywords, shortcut: phone ? nil : shortcut))
        }
        if newTaskBoard != nil { add("newTask", String(localized: "タスクを追加"), "⌘N", keywords: ["new task", "起票"]) }
        add("nextAttention", String(localized: "次の入力待ちへ移動"), "⌥⌘A", keywords: ["attention", "next", "応答待ち", "回答待ち", "承認待ち"])
        if newBoardMachine != nil { add("newBoard", String(localized: "案件を追加"), keywords: ["new board", "board", "ボード"]) }
        if keyboardTarget != nil {
            add("launch", String(localized: "セッションを起動"), keywords: ["launch", "start", "claude", "codex"])
            if !phone {
                add("moveLeft", String(localized: "左の列へ移動"), "⌥⌘←", keywords: ["move"])
                add("moveRight", String(localized: "右の列へ移動"), "⌥⌘→", keywords: ["move"])
            }
        }
        if selectedTask != nil {
            add("focusSession", String(localized: "セッションの入力欄へ移動"), "⌘L", keywords: ["focus", "terminal", "ターミナル", "端末", "フォーカス"]) // ui-copy:ignore（検索キーワード。前の語でも探せるように残す）
            add("closeTask", String(localized: "タスクを閉じる"), "Esc", keywords: ["close"])
        }
        if orchestratorMachine != nil {
            if AppModel.showsOrchestratorSheet {
                add("orchestratorPrompt", String(localized: "オーケストレーターにメッセージを送信…"), keywords: ["orchestrator", "メッセージ", "指示", "送信"])
            }
            add("orchestratorOpen", String(localized: "オーケストレーターを開く"), keywords: ["orchestrator", "chat", "チャット"])
        }
        add("onlyMachine", onlyMachineEnabled ? String(localized: "1台だけ表示を解除") : String(localized: "1台だけ表示"), "⌃⌘1", keywords: ["focus", "only", "画面共有", "Mac", "マシン"]) // ui-copy:ignore（検索キーワード。前の語でも探せるように残す）
        add("overview", String(localized: "全体のボードを表示"), keywords: ["board", "overview", "ボード", "案件"])
        #if os(macOS)
        add(
            "homeLayout", homeLayout == .conversations ? String(localized: "ホームを列で表示") : String(localized: "ホームを会話で表示"), "⌘B",
            keywords: ["home", "layout", "会話", "列", "ボード", "切り替え"])
        #endif
        add("connections", String(localized: "接続先の設定を開く"), keywords: ["connection", "machine", "Mac", "マシン"]) // ui-copy:ignore（検索キーワード。前の語でも探せるように残す）
        add("settings", String(localized: "設定を開く"), "⌘,", keywords: ["settings", "preferences", "設定"])
        guard !phone else { return entries }
        for (index, presentation) in TaskPresentation.allCases.enumerated() {
            // 相手のタスクがあればそのタスクをその開き方で開く。無ければ次に開くときの開き方を変えるだけ
            let title = keyboardTarget != nil
                ? String(localized: "タスクを開く（\(presentation.label)）")
                : String(localized: "開き方を「\(presentation.label)」にする")
            add("present.\(presentation.rawValue)", title, "⌥⌘\(index + 1)", keywords: ["presentation", "開き方", "並べて表示", "大きく表示", "中央に表示", "サイドビュー", "全面", "中央モーダル"]) // ui-copy:ignore（検索キーワード。前の語でも探せるように残す）
        }
        add("shortcuts", String(localized: "ショートカットの一覧を表示"), "⌘/", keywords: ["shortcut", "keyboard", "キー"])
        return entries
    }

    var paletteEntries: [PaletteEntry] {
        var entries = paletteCommands
        for machine in orderedMachines {
            let name = machineName(fleetID: machine.id, state: machine.state)
            let boards = orderedBoards(machine.state, fleetID: machine.id)
            for board in boards {
                let tasks = machine.state.tasks.values.filter { $0.boardID == board.id }.sorted { $0.number < $1.number }
                for task in tasks {
                    let column = board.columns.first { $0.id == task.columnID }?.label ?? ""
                    entries.append(PaletteEntry(
                        id: "task:\(task.machine.rawValue)/\(task.number)", kind: .task, title: "#\(task.number) \(task.title)",
                        subtitle: [name, board.name, column].filter { !$0.isEmpty }.joined(separator: "・"),
                        keywords: task.links.map(\.shortLabel), urls: task.links.map(\.url), destination: .task(task.id)))
                }
                entries.append(PaletteEntry(id: "board:\(board.machine.rawValue)/\(board.id)", kind: .board, title: board.name, subtitle: name, keywords: ["案件"],
                    destination: .board(machine: board.machine, id: board.id)))
            }
        }
        for pr in fleet.pullRequestsByURL {
            entries.append(PaletteEntry(id: "pr:\(pr.url)", kind: .pullRequest, title: pr.title, subtitle: "\(pr.repository)#\(pr.number)",
                urls: [pr.url], destination: .pullRequest(url: pr.url)))
        }
        return entries
    }

    /// 接続しているマシンの会話を全文検索し、一致の新しい順に会話の行にする。引けないマシン（前の版の daemon の 404・切れた接続）は飛ばす。
    /// `indexing` はどれかのマシンが索引を作っている途中
    func paletteConversations(matching query: String) async -> (entries: [PaletteEntry], indexing: Bool) {
        let terms = ConversationSearchQuery.terms(query)
        guard !terms.isEmpty else { return ([], false) }
        let machines = Set(orderedMachines.compactMap { $0.state.machine?.id })
        let sources = machines.compactMap { machine in fleet.conversationSearchSource(for: machine).map { (machine, $0) } }
        let responses = await withTaskGroup(of: (MachineID, ConversationSearchResponse)?.self) { group in
            for (machine, source) in sources {
                group.addTask { (try? await source.searchConversations(query: query, limit: ConversationSearchResponse.defaultLimit)).map { (machine, $0) } }
            }
            var responses: [(MachineID, ConversationSearchResponse)] = []
            for await response in group { if let response { responses.append(response) } }
            return responses
        }
        let hits = responses.flatMap { machine, response in response.hits.map { hit in (machine, hit) } }
            .sorted { ($0.1.at ?? .distantPast) > ($1.1.at ?? .distantPast) }
        let entries = hits.compactMap { machine, hit -> PaletteEntry? in
            let key = ConversationKey(machine: machine, id: hit.conversationID)
            guard let conversation = fleet.conversation(for: key) else { return nil }
            return PaletteEntry(
                id: "conversation:\(machine.rawValue)/\(hit.conversationID)", kind: .conversation, title: conversation.displayTitle, subtitle: hit.snippet,
                destination: .conversation(key))
        }
        return (entries, responses.contains { $0.1.indexing })
    }

    /// パレットで選んだ行を実行する。別ウィンドウは view の `openWindow` が要るので呼び手が持つ。
    /// 会話の行は、開いた会話の中で `query` の最初の語を検索する
    func runPalette(_ entry: PaletteEntry, query: String = "") {
        paletteOpen = false
        if entry.kind == .command, entry.id.hasPrefix("command:") {
            runCommand(String(entry.id.dropFirst("command:".count)))
        } else if let destination = entry.destination {
            if entry.kind == .conversation, case .conversation(let key) = destination, let term = ConversationSearchQuery.terms(query).first {
                chatSearchRequest = ChatSearchRequest(key: key, query: term)
            }
            navigate(to: destination, from: .palette)
        }
    }

    private func runCommand(_ id: String) {
        switch id {
        case "newTask": startNewTask()
        case "newBoard": startNewBoard()
        case "nextAttention": openNextAttention()
        case "launch": launchForTarget()
        case "moveLeft": moveSelectedTask(by: -1)
        case "moveRight": moveSelectedTask(by: 1)
        case "focusSession": requestSessionFocus()
        case "closeTask": closeTask()
        case "orchestratorPrompt": presentOrchestratorPrompt()
        case "orchestratorOpen": navigate(to: .orchestrator(nil), from: .palette)
        case "onlyMachine": toggleOnlyMachine()
        case "overview":
            logNavigation(.overview, from: .palette)
            closeTask()
            sidebar = .overview
        case "homeLayout": toggleHomeLayout()
        case "connections": navigate(to: .settings(.connections), from: .palette)
        case "settings": navigate(to: .settings(.connections), from: .palette)
        case "shortcuts": shortcutsOpen = true
        default:
            if id.hasPrefix("present."), let presentation = TaskPresentation(rawValue: String(id.dropFirst("present.".count))) {
                present(presentation, from: .palette)
            }
        }
    }

    /// ⌥⌘1〜3・メニュー・パレットの「◯◯で開く」。開き方を変え、相手のタスク（開いているタスク、無ければ選んでいるカード）があればそれを開く。
    /// 名前が「開く」なので、設定を変えるだけで終わらない
    func present(_ presentation: TaskPresentation, from source: NavigationSource) {
        taskPresentation = presentation
        if let key = keyboardTarget { navigate(to: .task(key, revealBoard: false), from: source) }
    }
}

