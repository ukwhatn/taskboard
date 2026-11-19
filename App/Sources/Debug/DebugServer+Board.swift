#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// ボード・タスク・起票と起動・作業項目・カーソル
    func respondBoard(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("POST", "/task/move"):
            // カードのコンテキストメニュー「列を移す」と同じ経路
            guard let body = request.jsonBody, let number = body["number"] as? Int, let column = body["column"] as? String else {
                return .json(400, ["error": "number と column が要る"])
            }
            let machine = (body["machine"] as? String).map(MachineID.init(rawValue:)) ?? model.selectedTask?.machine ?? model.fleet.allBoards.first?.machine
            guard let machine, let task = model.fleet.task(for: TaskKey(machine: machine, number: number)) else {
                return .json(404, ["error": "タスクが無い"])
            }
            model.move(task: task, to: column)
            return .json(200, ["ok": true])
        case ("POST", "/new-task"):
            // ⌘N と同じ。ボードは選択中のものか、最初のボード。{"close": true} で閉じる
            if request.jsonBody?["close"] as? Bool == true {
                model.newTaskSheet = nil
                return .json(200, ["ok": true])
            }
            guard let board = currentBoard(model) else { return .json(404, ["error": "ボードが無い"]) }
            var draft = NewTaskDraft(board: board)
            let body = request.jsonBody ?? [:]
            if let v = body["title"] as? String { draft.title = v }
            if let v = body["note"] as? String { draft.note = v }
            if let v = body["links"] as? String { draft.links = NewTaskDraft.normalizedLinks([v]) }
            if let v = body["column"] as? String { draft.columnID = v }
            if let v = body["due"] as? String { draft.due = BoardTask.dateFormatter.date(from: v) }
            applyLaunchFields(body, to: &draft.launch)
            if body["submit"] as? Bool == true || body["launch"] as? Bool == true {
                // シートの「作成」「作成して起動」と同じ要求を同じ経路で送る
                do {
                    let task = try await model.create(task: draft.request, on: board.machine)
                    var result: [String: Any] = ["ok": true, "number": task.number]
                    if body["launch"] as? Bool == true {
                        result.merge(debugJSON(try await model.launchSession(task: task, draft.launch))) { $1 }
                    }
                    model.navigate(to: .task(task.id), from: .debug)
                    return .json(200, result)
                } catch {
                    return .json(502, ["error": "\(error)"])
                }
            }
            if model.newTaskSheet != nil {
                // 開いているシートの @State は新しい下書きで作り直されないので、閉じてから出し直す
                model.newTaskSheet = nil
                try? await Task.sleep(for: .milliseconds(500))
            }
            model.newTaskSheet = draft
            return .json(200, ["ok": true, "board": board.id])
        case ("POST", "/launch"):
            // タスク画面の「起動」シートと同じ経路。{"number": 131, "cwd": "...", "kind": "claude", "preset": "claude-sonnet-high", "prompt": "..."}。
            // Codex は {"kind": "codex", "codexModel": "...", "codexEffort": "..."}
            let body = request.jsonBody ?? [:]
            // {"close": true} はシートを閉じるだけ（submit を省くと起動するので、閉じる口を分ける）
            if body["close"] as? Bool == true {
                model.launchSheet = nil
                return .json(200, ["ok": true])
            }
            guard let task = taskFor(body, model) else { return .json(404, ["error": "タスクが無い（number か選択中のタスク）"]) }
            var draft = model.launchDraft(for: task)
            applyLaunchFields(body, to: &draft)
            if body["submit"] as? Bool == false {
                // シートはタスクのパネルに付いているので、キーの起動（launchForTarget）と同じく先にタスクを開く
                model.navigate(to: .task(task.id, revealBoard: false), from: .debug)
                model.launchSheet = draft
                return .json(200, ["ok": true, "sheet": true])
            }
            do {
                let launched = try await model.launchSession(task: task, draft)
                // シートの［起動］と同じく、会話はタスクのパネルで開く
                model.navigate(to: .task(task.id, revealBoard: false), from: .debug)
                return .json(200, ["ok": true].merging(debugJSON(launched)) { $1 })
            } catch {
                return .json(502, ["error": "\(error)"])
            }
        case ("POST", "/worktrees/sheet"):
            // マシンの行の［使っていないworktreeを削除…］と同じ。{"close": true} で閉じる。一覧はそのマシンの daemon から読む（fixtures は書き込めないので読めない）
            let body = request.jsonBody ?? [:]
            if body["close"] as? Bool == true {
                model.worktreeCleanup = nil
                return .json(200, ["ok": true])
            }
            guard let machine = model.orchestratorMachine else { return .json(404, ["error": "マシンが無い"]) }
            model.worktreeCleanup = WorktreeCleanupTarget(machine: machine)
            return .json(200, ["ok": true, "machine": machine.rawValue])
        case ("POST", "/steer"):
            // 指示のシート（Mac）の「送信」と同じ経路
            guard let text = request.jsonBody?["text"] as? String, !text.isEmpty else { return .json(400, ["error": "text が要る"]) }
            guard let machine = model.orchestratorMachine else { return .json(404, ["error": "送り先のマシンが無い"]) }
            guard model.orchestratorConversation(on: machine) != nil else { return .json(409, ["error": "オーケストレーターが居ない（/orchestrator/start）"]) }
            Task { try? await model.sendToOrchestrator(text, on: machine) }
            return .json(200, ["ok": true, "machine": machine.rawValue])
        case ("POST", "/orchestrator/start"):
            guard let machine = model.orchestratorMachine else { return .json(404, ["error": "マシンが無い"]) }
            model.startOrchestrator(on: machine)
            return .json(200, ["ok": true, "machine": machine.rawValue])
        case ("POST", "/task/close"):
            model.closeTask()
            return .json(200, ["ok": true])
        case ("POST", "/work/add"):
            // インスペクタ「作業」の追加欄と同じ経路
            guard let body = request.jsonBody, let title = body["title"] as? String else { return .json(400, ["error": "title が要る"]) }
            guard let task = taskFor(body, model) else { return .json(404, ["error": "タスクが無い（number か選択中のタスク）"]) }
            model.addWorkItem(to: task, title: title)
            return .json(200, ["ok": true])
        case ("POST", "/work/update"):
            // 行の状態の印・コンテキストメニューと同じ経路。{"id": 3, "state": "doing"}
            guard let body = request.jsonBody, let id = body["id"] as? Int else { return .json(400, ["error": "id が要る"]) }
            guard let task = taskFor(body, model), let item = model.fleet.workItems(for: task.id).first(where: { $0.itemID == Int64(id) }) else {
                return .json(404, ["error": "作業項目が無い"])
            }
            var update = WorkItemUpdateRequest()
            if let v = body["state"] as? String {
                guard let state = WorkItem.State(rawValue: v) else { return .json(400, ["error": "state は todo / doing / wait / done / drop"]) }
                update.state = state
            }
            if let v = body["title"] as? String { update.title = v }
            if let v = body["blockerKind"] as? String { update.blockerKind = WorkItem.BlockerKind(rawValue: v) }
            if let v = body["blockerText"] as? String { update.blockerText = v }
            if body["delete"] as? Bool == true {
                model.deleteWorkItem(item)
            } else {
                model.updateWorkItem(item, update)
            }
            return .json(200, ["ok": true])
        case ("GET", "/work"):
            guard let task = taskFor(request.jsonBody ?? [:], model) else { return .json(404, ["error": "タスクが無い"]) }
            let items = model.fleet.workItems(for: task.id)
            let states = WorkItem.effectiveStates(of: items)
            return .json(200, [
                "task": task.number,
                "items": items.map { ["id": $0.itemID, "title": $0.title, "state": $0.state.rawValue, "effective": (states[$0.itemID] ?? .todo).rawValue, "position": $0.position, "wait": $0.waitLine?.text as Any] },
            ])
        case ("GET", "/board/cards"):
            // 全体のボードに並ぶカード（畳んでいないマシンと列。「さらにN件」の中を含む）を、列ごとに並びの順で。
            // 実画面の確認（scripts/ui/check-board.sh）は、列ごとに 1 枚目・見えている最後・「さらにN件」の中の 1 枚目を押す
            var columns: [[String: Any]] = []
            for section in model.overviewSections where !section.collapsed {
                for board in section.boards {
                    let tasks = section.state.tasks.values.filter { $0.boardID == board.id }.sorted { $0.number < $1.number }
                    for column in board.unfoldedColumns {
                        let keys = tasks.filter { $0.columnID == column.id }.map { "\($0.machine.rawValue)/\($0.number)" }
                        if !keys.isEmpty { columns.append(["board": board.name, "column": column.label, "cards": keys]) }
                    }
                }
            }
            let sizes = model.debugBoardScrollSizes.map { sizes in
                ["containerWidth": sizes.container.width, "containerHeight": sizes.container.height, "contentWidth": sizes.content.width, "contentHeight": sizes.content.height, "offsetX": sizes.offset.x, "offsetY": sizes.offset.y]
            }
            return .json(200, ["limit": BoardMetrics.cardLimit, "columns": columns, "scroll": sizes ?? [:]])
        case ("POST", "/cursor/move"):
            // {"direction": "down"}。↑↓←→ と同じくキーのカーソルを動かす（キーを送らないので、アプリを前面に出さずに済む。計測の scripts/ui/perf.sh）
            let direction: BoardCursorGrid.Direction? = switch request.jsonBody?["direction"] as? String {
            case "up": .up
            case "down": .down
            case "left": .left
            case "right": .right
            default: nil
            }
            guard let direction else { return .json(400, ["error": "direction は up / down / left / right"]) }
            model.moveCursor(direction)
            try? await Task.sleep(for: .milliseconds(300))
            return .json(200, ["ok": true])
        case ("POST", "/cursor"):
            // {"key": "<machine>/<number>"}。キーのカーソルを置く。ボードがそのカードまで送り、「さらにN件」の中なら列を開く。タスクは開かない
            guard let key = request.jsonBody?["key"] as? String, let slash = key.lastIndex(of: "/"), let number = Int(key[key.index(after: slash)...]) else {
                return .json(400, ["error": "key は <machine>/<number>"])
            }
            model.cursorTask = TaskKey(machine: MachineID(rawValue: String(key[..<slash])), number: number)
            return .json(200, ["ok": true])
        case ("POST", "/board/scroll"):
            // {"dy": 30, "steps": 120, "interval": 16}。全体のボードを 1 フレームずつ下へ送り、同じだけ戻す（合成したホイールは ScrollView に届かなかったので、位置を直接動かす）
            let body = request.jsonBody ?? [:]
            let dy = body["dy"] as? Double ?? 30
            let steps = body["steps"] as? Int ?? 120
            let interval = body["interval"] as? Int ?? 16
            for index in 0..<(steps * 2) {
                let offset = index < steps ? Double(index + 1) : Double(steps * 2 - index - 1)
                model.debugBoardScrollY = offset * dy
                try? await Task.sleep(for: .milliseconds(interval))
            }
            model.debugBoardScrollY = nil
            return .json(200, ["ok": true])
        default:
            return nil
        }
    }
}
#endif
