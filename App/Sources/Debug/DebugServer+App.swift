#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// 画面の今・遷移・見た目・設定・fixtures・撮影
    func respondApp(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/state"):
            return .json(200, model.debugDescription)
        case ("POST", "/navigate"):
            guard let url = (request.jsonBody?["url"] as? String).flatMap(URL.init(string:)) else {
                return .json(400, ["error": "url が要る"])
            }
            model.open(url, from: .debug)
            return .json(200, ["ok": true])
        case ("POST", "/appearance"):
            switch request.jsonBody?["scheme"] as? String {
            case "light": model.appearanceOverride = .light
            case "dark": model.appearanceOverride = .dark
            case "system": model.appearanceOverride = nil
            default: return .json(400, ["error": "scheme は light / dark / system"])
            }
            return .json(200, ["ok": true])
        case ("POST", "/only-machine"):
            // {"enabled": true, "id": "local"}。⌃⌘1 と同じ（キーを送れない iPad の確認用）
            if let id = request.jsonBody?["id"] as? String { model.onlyMachineID = id }
            if let enabled = request.jsonBody?["enabled"] as? Bool { model.onlyMachineEnabled = enabled }
            return .json(200, ["ok": true, "label": model.onlyMachineLabel as Any])
        case ("POST", "/settings"):
            // {"section": "boards", "board": "<board-id>"}。設定を開く。board を渡すとその案件の中身まで開く
            let body = request.jsonBody ?? [:]
            guard let section = SettingsSection(rawValue: body["section"] as? String ?? "connections") else {
                return .json(400, ["error": "section は " + SettingsSection.allCases.map(\.rawValue).joined(separator: " / ")])
            }
            model.navigate(to: .settings(section), from: .debug)
            if let board = body["board"] as? String, let fleetID = model.fleet.allMachines.first(where: { $0.value.boards[board] != nil })?.key {
                model.openBoardSettings(SettingsBoardKey(fleetID: fleetID, boardID: board))
            }
            return .json(200, ["ok": true, "board": model.settingsBoardPath.first.flatMap(model.settingsBoard)?.name as Any])
        case ("POST", "/overlay"):
            // {"name": "palette" | "shortcuts" | "newBoard" | "orchestrator" | "none"}。キーを送れない iPad の撮影用（orchestrator の指示のシートは Mac だけ）
            switch request.jsonBody?["name"] as? String {
            case "palette": model.paletteOpen = true
            case "shortcuts": model.shortcutsOpen = true
            case "newBoard": model.startNewBoard()
            case "orchestrator": model.presentOrchestratorPrompt()
            case "none":
                model.orchestratorSheet = nil
                model.paletteOpen = false
                model.shortcutsOpen = false
                model.newBoardSheet = nil
            default: return .json(400, ["error": "name は palette / shortcuts / newBoard / orchestrator / none"])
            }
            return .json(200, ["ok": true])
        case ("POST", "/presentation"):
            // タスクパネルの「開き方」と同じ
            guard let mode = (request.jsonBody?["mode"] as? String).flatMap(TaskPresentation.init(rawValue:)) else {
                return .json(400, ["error": "mode は side / full / modal"])
            }
            model.taskPresentation = mode
            return .json(200, ["ok": true])
        case ("POST", "/scenario"):
            guard let name = request.jsonBody?["name"] as? String else { return .json(400, ["error": "name が要る"]) }
            model.load(scenario: name)
            return .json(200, ["ok": true, "note": model.connectionNote as Any])
        case ("POST", "/side-panels/drag"):
            // {"handle": "status|docs", "by": 120, "steps": 60, "gapMs": 8}。右側の欄の境目の取っ手を、ドラッグと同じく動かし始めからの移動量で steps 回動かして離す
            // （取っ手の DragGesture は、裏にある窓に作ったマウスのイベントでは動かない）
            let body = request.jsonBody ?? [:]
            guard let handle = body["handle"] as? String else { return .json(400, ["error": "handle（上の欄|下の欄）が要る"]) }
            let by = body["by"] as? Double ?? 120, steps = max(body["steps"] as? Int ?? 60, 1)
            let gap = Duration.milliseconds(body["gapMs"] as? Int ?? 8)
            for step in 1...steps {
                NotificationCenter.default.post(name: .debugSplitDrag, object: nil, userInfo: ["handle": handle, "delta": CGFloat(by * Double(step) / Double(steps))])
                try? await Task.sleep(for: gap)
            }
            NotificationCenter.default.post(name: .debugSplitDrag, object: nil, userInfo: ["handle": handle])
            return .json(200, ["ok": true])
        case ("POST", "/side-pane"):
            // {"tab": "status|docs|work|changes|terminal", "close"?: true}。タスク画面の右側の欄を開く（会話の画面の［状態］［差分］もこれを通る）。
            // terminal は開いている会話の端末の欄（会話と右の欄の下）を、会話の上の帯の［ターミナル］と同じく開く（close で閉じてシェルを止める）
            let name = request.jsonBody?["tab"] as? String
            if let tab = name.flatMap(SidePanel.init(rawValue:)) {
                model.showSidePane(tab)
                return .json(200, ["ok": true])
            }
            guard name == "terminal" else { return .json(400, ["error": "tab は status / docs / work / changes / terminal"]) }
            guard let conversation = model.activeConversation?.key else { return .json(404, ["error": "会話が開いていない"]) }
            if request.jsonBody?["close"] as? Bool == true {
                model.closeTerminal(of: conversation)
            } else {
                model.openTerminal(for: conversation)
            }
            return .json(200, ["ok": true, "conversation": conversation.id])
        case ("POST", "/sidebar/node"):
            // {"id": "board/<machine>/<board>" か "column/<machine>/<board>/<column>", "expanded": true, "collapsedByDefault"?: false}。サイドバーの節の開け閉め
            guard let id = request.jsonBody?["id"] as? String, let expanded = request.jsonBody?["expanded"] as? Bool else {
                return .json(400, ["error": "id と expanded が要る"])
            }
            model.setSidebarNode(id, expanded: expanded, collapsedByDefault: request.jsonBody?["collapsedByDefault"] as? Bool ?? false)
            return .json(200, ["ok": true])
        case ("POST", "/sidebar/arrangement"):
            // {"grouping"?: "boards"|"state"|"none", "order"?: "number"|"recent"|"created"|"title"}。サイドバーの「並べ方」のメニューと同じ
            var arrangement = model.sidebarArrangement
            if let raw = request.jsonBody?["grouping"] as? String {
                guard let grouping = SidebarArrangement.Grouping(rawValue: raw) else { return .json(400, ["error": "grouping が違う"]) }
                arrangement.grouping = grouping
            }
            if let raw = request.jsonBody?["order"] as? String {
                guard let order = SidebarArrangement.Order(rawValue: raw) else { return .json(400, ["error": "order が違う"]) }
                arrangement.order = order
            }
            model.sidebarArrangement = arrangement
            return .json(200, ["ok": true])
        case ("POST", "/home/layout"):
            // {"layout": "conversations"|"columns"}。⌘B（［会話と列を切り替える］）と同じ所に書く
            guard let raw = request.jsonBody?["layout"] as? String, let layout = HomeLayout(rawValue: raw) else { return .json(400, ["error": "layout が違う"]) }
            model.homeLayout = layout
            return .json(200, ["layout": layout.rawValue])
        case ("POST", "/sidebar/pin"):
            // {"number": 131, "machine"?, "pinned": true}。タスクの行の右クリックの［ピン留め］［ピン留めを外す］と同じ
            guard let task = taskFor(request.jsonBody ?? [:], model), let pinned = request.jsonBody?["pinned"] as? Bool else {
                return .json(400, ["error": "number と pinned が要る"])
            }
            model.setPinned(task, pinned)
            return .json(200, ["ok": true])
        case ("POST", "/task/end-all"):
            // {"number": 128, "machine"?}。タスクの行の右クリックの［すべて終了］と同じ。終えるものの数と、確認を出したならその本文を返す
            guard let task = taskFor(request.jsonBody ?? [:], model) else { return .json(400, ["error": "タスクが無い"]) }
            let targets = model.endTargets(of: task)
            model.requestEndAll(task)
            let asked = model.confirmation(in: model.activeWindow) == .endTaskSessions(task.id)
            return .json(200, [
                "conversations": targets.conversations.map(\.id), "busy": targets.busy,
                "confirmation": asked ? targets.message(task: task) : NSNull(),
            ])
        case ("POST", "/task/split"):
            // {"conversation": "c-term"}、"number"?・"machine"?（無ければ開いているタスク）。札を ⌘ を押しながら押したのと同じく右に並べる。
            // 窓の会話とチャットの一覧（`ChatListView`）の数が変わるまで（3 秒まで）待ち、その数を返す
            guard let task = taskFor(request.jsonBody ?? [:], model) else { return .json(400, ["error": "タスクが無い"]) }
            guard let id = request.jsonBody?["conversation"] as? String else { return .json(400, ["error": "conversation が要る"]) }
            let item = ConversationKey(machine: task.machine, id: id)
            #if os(macOS)
            func lists() -> Int { NSApp.windows.filter(\.isVisible).compactMap(\.contentView).reduce(0) { $0 + Self.all(ChatListView.self, in: $1).count } }
            let before = lists()
            model.sessionFocus = SessionFocus(scope: .task(task.id), item: item, beside: true)
            let deadline = ContinuousClock.now + .seconds(3)
            while lists() == before, ContinuousClock.now < deadline { _ = await FrameMonitor.shared.frames(1) }
            return .json(200, ["lists": lists(), "listsBefore": before])
            #else
            model.sessionFocus = SessionFocus(scope: .task(task.id), item: item, beside: true)
            return .json(200, ["ok": true])
            #endif
        case ("POST", "/attention/next"):
            // メニューの［次の入力待ちへ移動］（⌥⌘A）と同じ。開いた項目と、無かったときの知らせを返す
            model.openNextAttention()
            return .json(200, ["item": model.lastAttentionItem as Any, "notice": model.notice(in: model.activeWindow)?.text as Any])
        case ("POST", "/defaults"):
            // {"key": "terminal.fontSize", "value": 16}。@AppStorage の値を書く（⌘+ / ⌘- と同じ所に効く）
            guard let key = request.jsonBody?["key"] as? String, let value = request.jsonBody?["value"] else { return .json(400, ["error": "key と value が要る"]) }
            AppDefaults.store.set(value, forKey: key)
            return .json(200, ["ok": true])
        case ("POST", "/screenshot"):
            // 描画が落ち着くまで 1 フレーム待つ
            try? await Task.sleep(for: .milliseconds(150))
            guard let png = WindowScreenshot.capture(scheme: model.appearanceOverride, index: request.jsonBody?["window"] as? Int, popover: request.jsonBody?["popover"] as? Bool ?? false) else { return .json(500, ["error": "ウィンドウを撮れない"]) }
            return HTTPResponse(status: 200, contentType: "image/png", body: png)
        default:
            return nil
        }
    }
}
#endif
