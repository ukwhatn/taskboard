#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// キー・クリック・ウィンドウ・メニュー
    func respondWindow(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("POST", "/key"):
            // {"key": "k", "modifiers": ["command"], "activate": true}。アプリの中でキー入力を作り、NSApp.sendEvent で流す。activate を付けたときだけアプリを前面に出す（既定は出さない。ほかの作業のキー入力を奪うため）（メニューの key equivalent と、フォーカスのある view の onKeyPress が本物と同じ経路で受ける）
            #if os(macOS)
            guard let name = request.jsonBody?["key"] as? String, let key = DebugKey(name) else { return .json(400, ["error": "key が要る（a〜z・0〜9・/ + - . , 空白・return / escape / tab / delete / up / down / left / right）"]) }
            let modifiers = request.jsonBody?["modifiers"] as? [String] ?? []
            guard key.send(modifiers: modifiers, window: request.jsonBody?["window"] as? String, activate: request.jsonBody?["activate"] as? Bool ?? false) else { return .json(500, ["error": "キーを送るウィンドウが無い"]) }
            try? await Task.sleep(for: .milliseconds(300))
            return .json(200, ["ok": true, "firstResponder": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } as Any])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/window/open"):
            // {"task": 200} か {"doc": 1}（開いているマシン、無ければ最初のマシン）。⌘ を押しながらのクリックと［別ウィンドウで開く］と同じ窓を開く
            let body = request.jsonBody ?? [:]
            guard let machine = model.selectedTask?.machine ?? model.fleet.allBoards.first?.machine else { return .json(404, ["error": "マシンが無い"]) }
            if let number = body["task"] as? Int {
                model.taskWindowRequest = TaskKey(machine: machine, number: number)
            } else if let id = body["doc"] as? Int {
                model.docWindowRequest = DocKey(machine: machine, id: Int64(id))
            } else {
                return .json(400, ["error": "task か doc が要る"])
            }
            return .json(200, ["ok": true])
        case ("POST", "/window/close"):
            // {"title": "..."}。確認で開いたウィンドウを閉じる（前面に無いと ⌘W が効かないため）
            #if os(macOS)
            guard let title = request.jsonBody?["title"] as? String, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == title }) else { return .json(404, ["error": "その題のウィンドウが無い"]) }
            window.performClose(nil)
            return .json(200, ["ok": true])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/click"):
            // {"x": 100, "y": 200}。画面の座標（左上が原点。読み上げの木の位置と同じ）を、アプリの中で作ったクリックで窓に渡す。
            // マウスを動かさず、アプリを前面に出さないので、ほかの作業の裏で確かめられる。⌘ を押しながらは作れない（ボタンの処理が走るときに currentEvent が残っていない）
            #if os(macOS)
            guard let x = request.jsonBody?["x"] as? Double, let y = request.jsonBody?["y"] as? Double else { return .json(400, ["error": "x と y が要る"]) }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let point = NSPoint(x: x, y: top - y)
            guard let window = DebugServer.window(at: point) else { return .json(404, ["error": "その位置に窓が無い"]) }
            let location = window.convertPoint(fromScreen: point)
            let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            guard events.count == 2 else { return .json(500, ["error": "クリックを作れない"]) }
            // mouseUp は先に列へ入れる。開閉の三角のように mouseDown の中で離すまで待つ部品は、sendEvent が返る前に列から mouseUp を取る。
            // "queued": true は mouseDown も列に入れる（local monitor は列から取り出したイベントにしか走らない。シートの外のクリックの確かめ）
            if request.jsonBody?["queued"] as? Bool == true {
                NSApp.postEvent(events[0], atStart: false)
                NSApp.postEvent(events[1], atStart: false)
            } else {
                NSApp.postEvent(events[1], atStart: false)
                NSApp.sendEvent(events[0])
            }
            try? await Task.sleep(for: .milliseconds(100))
            return .json(200, ["ok": true, "window": window.title])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/drag"):
            // {"from": {"x": 100, "y": 200}, "to": {"x": 300, "y": 600}, "steps": 12, "clickCount": 1}。/click と同じ座標で、押して動かして離すまでを
            // アプリの中で作って渡す（離すまで待つ部品のため、動かすのと離すのを先に列へ入れる）。会話の一覧の選択の確かめに使う
            #if os(macOS)
            let body = request.jsonBody ?? [:]
            guard let from = body["from"] as? [String: Double], let to = body["to"] as? [String: Double],
                let fx = from["x"], let fy = from["y"], let tx = to["x"], let ty = to["y"]
            else { return .json(400, ["error": "from と to（x・y）が要る"]) }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let start = NSPoint(x: fx, y: top - fy)
            guard let window = DebugServer.window(at: start) else { return .json(404, ["error": "その位置に窓が無い"]) }
            let steps = max(body["steps"] as? Int ?? 12, 1)
            let clicks = body["clickCount"] as? Int ?? 1
            func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: window.convertPoint(fromScreen: NSPoint(x: x, y: top - y)), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
            }
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                if let moved = event(.leftMouseDragged, fx + (tx - fx) * t, fy + (ty - fy) * t) { NSApp.postEvent(moved, atStart: false) }
            }
            guard let down = event(.leftMouseDown, fx, fy), let up = event(.leftMouseUp, tx, ty) else { return .json(500, ["error": "イベントを作れない"]) }
            NSApp.postEvent(up, atStart: false)
            // キーでない窓は、acceptsFirstMouse の無い AppKit の部品（会話の一覧の文）に押下を渡さず、アプリが後ろにあると窓をキーにもできない。
            // そのときは押した位置の view に直に渡す（離すまでの動きは同じ列から取る）
            // hit は押下を渡した view の型
            var target = "window"
            if !window.isKeyWindow, let hit = window.contentView?.superview?.hitTest(down.locationInWindow) ?? window.contentView?.hitTest(down.locationInWindow) {
                target = String(describing: type(of: hit))
                hit.mouseDown(with: down)
            } else {
                NSApp.sendEvent(down)
            }
            try? await Task.sleep(for: .milliseconds(100))
            return .json(200, ["ok": true, "window": window.title, "hit": target])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/file/comment"):
            // 見えているファイルの文（会話の差分の画面）の、選んだ行の［コメント］を押したときと同じ操作をする。
            // 後ろにあるアプリのボタンは /click・/drag の押下を押したと見なさないため
            #if os(macOS)
            func files(_ view: NSView) -> [ChatFileNSTextView] { ((view as? ChatFileNSTextView).map { [$0] } ?? []) + view.subviews.flatMap(files) }
            guard let text = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(files).first(where: { $0.comment != nil }) else {
                return .json(404, ["error": "コメントを付けられるファイルの文が無い"])
            }
            text.startComment()
            return .json(200, ["ok": true, "selected": text.selectedRange().length])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("GET", "/chat/selection"):
            // 会話の一覧が選んでいる文（⌘C で写す文。クリップボードには書かない）
            #if os(macOS)
            func lists(_ view: NSView) -> [ChatListView] { ((view as? ChatListView).map { [$0] } ?? []) + view.subviews.flatMap(lists) }
            let found = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(lists)
            // frames は /click と同じ画面の座標（左上が原点）の一覧の枠
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let frames = found.compactMap { list -> [String: Double]? in
                guard let window = list.window else { return nil }
                let rect = window.convertToScreen(list.convert(list.bounds, to: nil))
                return ["x": rect.minX, "y": top - rect.maxY, "width": rect.width, "height": rect.height]
            }
            // texts は置いている文の頭の字と枠（同じ座標）
            func texts(_ view: NSView) -> [ChatTextView] { ((view as? ChatTextView).map { [$0] } ?? []) + view.subviews.flatMap(texts) }
            let placed = found.flatMap(texts).compactMap { text -> [String: Any]? in
                guard let window = text.window else { return nil }
                let rect = window.convertToScreen(text.convert(text.bounds, to: nil))
                return ["text": String(text.string.prefix(20)), "x": rect.minX, "y": top - rect.maxY, "width": rect.width, "height": rect.height]
            }
            return .json(200, ["lists": found.count, "selections": found.map { $0.selectedText() }, "frames": frames, "texts": placed])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/wheel"):
            // {"x": 100, "y": 200, "lines": 6, "count": 20, "intervalMs": 16}。画面の座標（/click と同じ）に、phase の無いホイール（マウスのホイール）を
            // アプリの中で作って渡す。lines が正なら上へ送る。CGEvent から作った NSEvent には窓が付かないので、窓の中の位置に合わせて window.sendEvent で渡し、
            // local monitor に見せるために同じものを出来事の列にも入れる（列に入れた方は窓が無く、どの view にも渡らない）
            #if os(macOS)
            let body = request.jsonBody ?? [:]
            guard let x = body["x"] as? Double, let y = body["y"] as? Double else { return .json(400, ["error": "x と y が要る"]) }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            guard let window = DebugServer.window(at: NSPoint(x: x, y: top - y))
            else { return .json(404, ["error": "その位置に窓が無い"]) }
            // 窓の無い NSEvent の locationInWindow は、CGEvent の位置を左下が原点の座標にしたもの
            let inWindow = window.convertPoint(fromScreen: NSPoint(x: x, y: top - y))
            let lines = Int32(body["lines"] as? Int ?? 6)
            for _ in 0..<(body["count"] as? Int ?? 20) {
                if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
                    cgEvent.location = CGPoint(x: inWindow.x, y: top - inWindow.y)
                    if let event = NSEvent(cgEvent: cgEvent) {
                        NSApp.postEvent(event, atStart: false)
                        window.sendEvent(event)
                    }
                }
                try? await Task.sleep(for: .milliseconds(body["intervalMs"] as? Int ?? 16))
            }
            return .json(200, ["ok": true, "window": window.title])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/sidebar/toggle"):
            // 主ウィンドウのサイドバーを開閉する（ツールバーの［サイドバー］と同じ toggleSidebar）。メニューの項目は窓が key でないと届かないので、分割の controller に直に送る。
            // 開閉した後のサイドバーが閉じているかを返す
            #if os(macOS)
            func splitViews(_ view: NSView) -> [NSSplitView] { ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews) }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let content = window.contentView,
                  let controller = splitViews(content).lazy.compactMap({ $0.delegate as? NSSplitViewController }).first,
                  let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar })
            else { return .json(404, ["error": "サイドバーのある窓が無い"]) }
            controller.toggleSidebar(nil)
            try? await Task.sleep(for: .milliseconds(400))
            return .json(200, ["collapsed": sidebar.isCollapsed])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/window/order"):
            // {"back": true}。窓をほかのアプリの窓の後ろへ回す（確かめている間、ほかの作業の窓を覆わない）。{"back": false} で前へ（アプリは前面に出さない）
            #if os(macOS)
            let back = request.jsonBody?["back"] as? Bool ?? true
            for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                if back { window.orderBack(nil) } else { window.orderFrontRegardless() }
            }
            return .json(200, ["ok": true])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/orientation"):
            // {"landscape": true}。iPad と iPhone の画面の向きを変える（シミュレータを回す道具が無いので、横向きの撮影に使う）
            #if os(iOS)
            let landscape = request.jsonBody?["landscape"] as? Bool ?? true
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                return .json(404, ["error": "scene が無い"])
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
            return .json(200, ["ok": true])
            #else
            return .json(404, ["error": "iOS だけ"])
            #endif
        case ("POST", "/window/frame"):
            // {"width": 1600, "height": 1000, "title": "案件"}。表示中のウィンドウの大きさを変える（幅ごとの崩れの確認用。title を省くと主ウィンドウ）
            #if os(macOS)
            let body = request.jsonBody ?? [:]
            let title = body["title"] as? String
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && (title == nil || $0.title == title) }),
                let width = body["width"] as? Double, let height = body["height"] as? Double
            else { return .json(404, ["error": "ウィンドウか width / height が無い"]) }
            let screen = window.screen?.visibleFrame ?? .zero
            // fixtures で動かしている間は、変えた大きさをユーザーのアプリの窓の大きさとして残さない（AppDefaults）
            if AppDefaults.isScratch {
                window.setFrameAutosaveName("")
                window.isRestorable = false
            }
            window.setFrame(NSRect(x: screen.minX, y: screen.maxY - height, width: width, height: height), display: true)
            return .json(200, ["ok": true, "frame": [window.frame.width, window.frame.height]])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("GET", "/menu"):
            // メニューバーの項目（題・キー・有効か）。ショートカットの割り当ての確認用
            #if os(macOS)
            // ?update=1 で、メニューを開いたときと同じ更新（NSMenu.update）をかけてから読む。チェック（state）はそのときに付く
            let update = request.query["update"] == "1"
            if update { MenuCheckmarks.apply(model) }
            let menus = (NSApp.mainMenu?.items ?? []).map { top in
                if update { top.submenu?.update() }
                return ["title": top.title, "items": (top.submenu?.items ?? []).filter { !$0.isSeparatorItem }.map { item in
                    ["title": item.title, "key": item.keyEquivalent, "modifiers": item.keyEquivalentModifierMask.rawValue, "enabled": item.isEnabled, "hidden": item.isHidden, "state": item.state.rawValue, "action": item.action.map(NSStringFromSelector) as Any] as [String: Any]
                }] as [String: Any]
            }
            return .json(200, ["menus": menus, "active": NSApp.isActive, "windows": NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map(\.title), "keyWindow": NSApp.keyWindow?.title as Any, "mainWindow": NSApp.mainWindow?.title as Any])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("GET", "/outline"):
            // 主ウィンドウのサイドバー（List が作る NSOutlineView）の行。段・開いているか・読み上げの名前と、行と開閉の三角の位置（画面の座標。/click と同じ）。
            // SwiftUI の開閉の状態（AppModel）でなく、画面の上で開いているかを見る。List は /screenshot に写らないので、開閉はこれで確かめる
            #if os(macOS)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let content = window.contentView,
                  let outline = Self.firstOutline(in: content)
            else { return .json(404, ["error": "サイドバーが無い"]) }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            func screen(_ rect: NSRect) -> [String: Int] {
                let r = window.convertToScreen(outline.convert(rect, to: nil))
                return ["x": Int(r.minX), "y": Int(top - r.maxY), "w": Int(r.width), "h": Int(r.height)]
            }
            let rows = (0..<outline.numberOfRows).map { row -> [String: Any] in
                let item = outline.item(atRow: row)
                let cell = outline.rowView(atRow: row, makeIfNecessary: false)
                return [
                    "row": row, "level": outline.level(forRow: row), "expandable": outline.isExpandable(item), "expanded": outline.isItemExpanded(item),
                    "label": cell.map(Self.accessibilityText) ?? "", "frame": screen(outline.rect(ofRow: row)),
                    "triangle": screen(outline.frameOfOutlineCell(atRow: row)),
                ]
            }
            return .json(200, ["rows": rows, "toggled": model.toggledSidebarNodes.sorted(), "collapsedMachines": model.collapsedMachines.sorted()])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/menu/perform"):
            // {"title": "Taskboardについて"}。メニューの項目を題で探して実行する（標準のパネルとダイアログの撮影用。アプリは前面に出さない）
            #if os(macOS)
            guard let title = request.jsonBody?["title"] as? String else { return .json(400, ["error": "title が要る"]) }
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.title == title { return item }
                    if let sub = item.submenu, let found = find(sub) { return found }
                }
                return nil
            }
            guard let item = NSApp.mainMenu.flatMap(find), let action = item.action else { return .json(404, ["error": "その題の項目が無い"]) }
            NSApp.sendAction(action, to: item.target, from: item)
            return .json(200, ["ok": true])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        default:
            return nil
        }
    }

    #if os(macOS)
    static func firstOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews { if let found = firstOutline(in: child) { return found } }
        return nil
    }

    /// 行の読み上げの名前を、子の要素まで順につないだもの
    static func accessibilityText(_ element: Any) -> String {
        guard let object = element as? NSAccessibilityProtocol else { return "" }
        let own = [object.accessibilityLabel(), object.accessibilityValue() as? String].compactMap { $0 }.filter { !$0.isEmpty }
        let views = (element as? NSView)?.subviews ?? []
        let children = ((object.accessibilityChildren() ?? []) + views).map(accessibilityText).filter { !$0.isEmpty }
        return (own + children).joined(separator: " ")
    }
    #endif
}

#if os(macOS)
extension DebugServer {
    /// 画面の点（左下が原点）にある一番手前の窓。シートと popover も入れる（どちらも主の窓になれない。popover は panel なので orderedWindows に無い）
    static func window(at point: NSPoint) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.contains(point) && $0.className.contains("Popover") }
            // 確認のダイアログ（シートか NSPanel）は親の窓より前にある。orderedWindows はシートを含まない
            ?? NSApp.windows.first { $0.isVisible && $0.frame.contains(point) && ($0.isSheet || $0 is NSPanel) }
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.frame.contains(point) && $0.canBecomeMain }
    }
}
#endif
#endif
