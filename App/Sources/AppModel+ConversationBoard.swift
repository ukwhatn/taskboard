import Foundation
import TaskboardKit

/// ホームの形。会話は会話を状態の組（対応待ち・実行中・未読・待機）で並べ、列は案件の列（`OverviewBoard`）。⌘B で切り替える
enum HomeLayout: String, CaseIterable {
    case conversations
    case columns

    var label: String {
        switch self {
        case .conversations: String(localized: "会話")
        case .columns: String(localized: "列")
        }
    }
}

/// Space で広げた会話。`messages` は取得するまで nil
struct TileExpansion: Equatable {
    var key: ConversationKey
    var messages: [ChatMessage]?
    var failure: UserFacingError?
}

extension ConversationBoardLayout.BoardLines {
    /// 「ほか n 件」を開いた印のキー
    var groupID: String { "\(machine.rawValue)/\(board?.id ?? "")" }
}

/// ホームの会話の形の操作。キー・メニュー・ボタンが同じ関数を通る。答えは会話の画面（`ConversationFeed.answer`）と同じく
/// マシンの `ConversationSource.answerConversation` に送る
extension AppModel {
    private typealias Metrics = ConversationBoardMetrics

    /// ホームを会話の形で出しているか（Mac の「すべての案件」か案件を選んでいるとき）。iPad は列の形のまま
    var homeShowsTiles: Bool {
        #if os(macOS)
        guard homeLayout == .conversations else { return false }
        switch sidebar {
        case .overview, .board: return true
        default: return false
        }
        #else
        return false
        #endif
    }

    /// 出す会話。サイドバーで案件を選んでいればその案件だけ
    var homeTiles: ConversationTiles {
        guard let board = focusedBoard else { return fleet.conversationTiles }
        return fleet.conversationTiles.filtered(board: board.id, machine: board.machine)
    }

    /// 面の幅に入る横の枚数
    static func tileColumns(width: CGFloat) -> Int {
        max(1, Int((width + Space.block) / (Metrics.tileMinWidth + Space.block)))
    }

    /// 面の大きさでの並べ方（実行中を札にするか 1 行にするか）
    static func conversationBoardLayout(_ tiles: ConversationTiles, viewport: CGSize) -> ConversationBoardLayout {
        ConversationBoardLayout(
            tiles, windowHeight: viewport.height, columns: tileColumns(width: viewport.width), lineHeight: Metrics.lineHeight, perBoard: Metrics.perBoard
        ) { tile in
            tile.group == .waiting ? Metrics.waitingTileHeight : Metrics.runningTileHeight
        }
    }

    /// 案件の見出しで分けた実行中の 1 行。「ほか n 件」を開いていれば、その案件の実行中を全部（並びは `tiles.running` のまま）
    func runningLines(_ group: ConversationBoardLayout.BoardLines, in tiles: ConversationTiles) -> [ConversationTile] {
        guard group.hidden > 0, expandedRunningGroups.contains(group.groupID) else { return group.lines }
        return tiles.running.filter { $0.conversation.machine == group.machine && $0.board?.id == group.board?.id }
    }

    /// キーで送る順の段。画面と同じ並びで、札は横に `columns` 枚ずつ、1 行は 1 段ずつ。閉じている待機は入れない
    func tileRows(_ layout: ConversationBoardLayout, tiles: ConversationTiles, columns: Int) -> [[ConversationKey]] {
        var rows: [[ConversationKey]] = []
        func grid(_ list: [ConversationTile]) {
            for start in stride(from: 0, to: list.count, by: max(1, columns)) {
                rows.append(list[start..<min(list.count, start + max(1, columns))].map(\.id))
            }
        }
        grid(layout.waiting)
        switch layout.running {
        case .tiles(let list): grid(list)
        case .lines(let list): rows += list.map { [$0.id] }
        case .boards(let groups):
            for group in groups { rows += runningLines(group, in: tiles).map { [$0.id] } }
        }
        rows += layout.unread.map { [$0.id] }
        if idleTilesExpanded { rows += layout.idle.map { [$0.id] } }
        return rows
    }

    /// ↑↓ は段を移り（横の位置は段の幅に収める）、←→ は並びの前後へ。選んでいなければ先頭
    static func moveTile(in rows: [[ConversationKey]], from current: ConversationKey?, _ direction: BoardCursorGrid.Direction) -> ConversationKey? {
        guard let first = rows.first?.first else { return nil }
        guard let current, let row = rows.firstIndex(where: { $0.contains(current) }), let column = rows[row].firstIndex(of: current) else { return first }
        switch direction {
        case .up:
            guard row > 0 else { return current }
            return rows[row - 1][min(column, rows[row - 1].count - 1)]
        case .down:
            guard row < rows.count - 1 else { return current }
            return rows[row + 1][min(column, rows[row + 1].count - 1)]
        case .left, .right:
            let flat = rows.flatMap { $0 }
            guard let index = flat.firstIndex(of: current) else { return first }
            return flat[min(max(0, index + (direction == .left ? -1 : 1)), flat.count - 1)]
        }
    }

    func moveTileCursor(_ direction: BoardCursorGrid.Direction) {
        let tiles = homeTiles
        let layout = Self.conversationBoardLayout(tiles, viewport: tileViewport)
        cursorTile = Self.moveTile(in: tileRows(layout, tiles: tiles, columns: Self.tileColumns(width: tileViewport.width)), from: cursorTile, direction)
    }

    /// 選んでいる会話のタスク（キーで操作する相手。⌘↩・⌥⌘← →）
    var cursorTileTask: TaskKey? {
        guard let key = cursorTile, let number = fleet.conversation(for: key)?.taskNumber else { return nil }
        return TaskKey(machine: key.machine, number: number)
    }

    /// 会話を開く（タスクの会話はそのタスクの画面で選ぶ）。選んだ会話はホームに戻っても選んだまま
    func openTile(_ key: ConversationKey) {
        cursorTile = key
        markTileRead(key)
        navigate(to: .conversation(key), from: .board)
    }

    func openCursorTile() {
        let tiles = homeTiles
        guard let key = cursorTile ?? (tiles.waiting + tiles.running + tiles.unread).first?.id else { return }
        openTile(key)
    }

    private func markTileRead(_ key: ConversationKey) {
        guard let conversation = fleet.conversation(for: key), unreadMarks.isUnread(conversation) else { return }
        unreadMarks.markRead([conversation])
    }

    /// Space: 選んでいる会話を広げ、最後の発言を取得する。もう一度押すか別の会話を広げると閉じ、閉じた会話を既読にする
    /// （広げたときに既読にすると、未読の組から待機へ移って、広げた中身ごと隠れる）
    func toggleTileExpansion(_ key: ConversationKey? = nil) {
        guard let key = key ?? cursorTile else { return }
        cursorTile = key
        let previous = expandedTile?.key
        if let previous { markTileRead(previous) }
        guard previous != key else {
            expandedTile = nil
            return
        }
        expandedTile = TileExpansion(key: key)
        Task { await loadTileMessages(key) }
    }

    /// 最後の数発言（文の発言だけ）。fixtures は手元の発言
    private func loadTileMessages(_ key: ConversationKey) async {
        let messages: [ChatMessage]
        if let source = fleet.conversationSource(for: key.machine) {
            do {
                messages = try await source.conversationHistory(key.id, before: nil, limit: Metrics.expandedFetch, subagents: false).messages
            } catch {
                guard expandedTile?.key == key else { return }
                expandedTile?.failure = UserFacingError("会話を読み込めませんでした", error: error)
                return
            }
        } else {
            messages = fixtureExtras.conversations[key.id]?.messages ?? []
        }
        guard expandedTile?.key == key else { return }
        expandedTile?.messages = Array(messages.filter { $0.kind == .text && !$0.text.isEmpty }.suffix(Metrics.expandedMessages))
    }

    // MARK: 答え

    /// 権限の確認の ⌘Y と［許可］が送る答え。codex の選択肢があれば主な答え
    static func allowAnswer(_ request: ConversationRequest) -> ConversationAnswerRequest {
        if let decisions = ConversationDecisionPanel.shown(request.decisions), let primary = ConversationDecisionPanel.primary(decisions) {
            return ConversationAnswerRequest(requestID: request.id, allow: primary.allows, decision: primary)
        }
        return ConversationAnswerRequest(requestID: request.id, allow: true)
    }

    /// 会話の問いに答える。送っている間は同じ会話のボタンを止め、失敗はその会話の中に出す
    func answerTile(_ key: ConversationKey, _ answer: ConversationAnswerRequest, failure event: LocalizedStringResource) {
        guard !tileSending.contains(key) else { return }
        tileFailures[key] = nil
        guard let source = fleet.conversationSource(for: key.machine) else {
            tileFailures[key] = UserFacingError(event, error: ActionError.notWritable(fleet.writeAccess(key.machine)))
            return
        }
        tileSending.insert(key)
        Task {
            do {
                try await source.answerConversation(key.id, answer)
            } catch {
                tileFailures[key] = UserFacingError(event, error: error)
            }
            tileSending.remove(key)
        }
    }

    /// ⌘Y: 選んでいる会話の権限の確認を許可する。ほかの問いは会話を開いて答える
    func confirmCursorTile() {
        guard let key = cursorTile, let tile = homeTiles.waiting.first(where: { $0.id == key }), case .request(let request) = tile.state,
            request.kind == .permission
        else { return }
        answerTile(key, Self.allowAnswer(request), failure: "許可できませんでした")
    }

    /// 止まった会話の［生成を停止］（会話の画面の Esc と同じ）
    func interruptTile(_ key: ConversationKey) {
        guard !tileSending.contains(key) else { return }
        tileFailures[key] = nil
        guard let source = fleet.conversationSource(for: key.machine) else {
            tileFailures[key] = UserFacingError("生成を停止できませんでした", error: ActionError.notWritable(fleet.writeAccess(key.machine)))
            return
        }
        tileSending.insert(key)
        Task {
            do {
                _ = try await source.controlConversation(key.id, ConversationControlRequest(kind: .interrupt))
            } catch {
                tileFailures[key] = UserFacingError("生成を停止できませんでした", error: error)
            }
            tileSending.remove(key)
        }
    }

    // MARK: 移動

    /// ⌥⌘A をホームの会話の形で押した: 開かずに、次の対応待ちの会話を選ぶ（古い順に 1 つずつ、最後なら先頭）
    func selectNextWaitingTile() {
        let waiting = homeTiles.waiting.map(\.id)
        guard !waiting.isEmpty else {
            inform(String(localized: "対応待ちの会話はありません"))
            return
        }
        cursorTile = cursorTile.flatMap { waiting.firstIndex(of: $0) }.map { waiting[($0 + 1) % waiting.count] } ?? waiting[0]
    }

    /// ⌘B
    func toggleHomeLayout() {
        homeLayout = homeLayout == .conversations ? .columns : .conversations
    }

    /// ⌘1〜9 で案件を選んだ後に選ぶ会話（その案件の先頭）
    func selectFirstTile() {
        let tiles = homeTiles
        cursorTile = (tiles.waiting + tiles.running + tiles.unread).first?.id
    }

    /// DebugServer の `/state` の `home`
    var homeDebugDescription: [String: Any] {
        let tiles = homeTiles
        let layout = Self.conversationBoardLayout(tiles, viewport: tileViewport)
        let running: String = switch layout.running {
        case .tiles: "tiles"
        case .lines: "lines"
        case .boards: "boards"
        }
        return [
            "layout": homeLayout.rawValue, "showsTiles": homeShowsTiles, "cursor": cursorTile?.description as Any,
            "expanded": expandedTile.map { ["key": $0.key.description, "messages": $0.messages?.count as Any, "failure": $0.failure?.text as Any] } as Any,
            "failures": tileFailures.map { ["key": $0.key.description, "text": $0.value.text] },
            "idleExpanded": idleTilesExpanded,
            "viewport": [tileViewport.width, tileViewport.height], "columns": Self.tileColumns(width: tileViewport.width), "running": running,
            "counts": ["waiting": tiles.waiting.count, "running": tiles.running.count, "unread": tiles.unread.count, "idle": tiles.idle.count],
            "waiting": tiles.waiting.map(\.id.description),
        ]
    }
}
