#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

/// DEBUG ビルドだけが開く loopback の制御口。私が画面を確認・操作するための経路で、本番ビルドには入らない。
///
/// - `GET  /state`                  画面の今（JSON）
/// - `POST /navigate {"url": ...}`  `taskboard://` の遷移
/// - `POST /screenshot`             自ウィンドウの PNG（{"popover": true} で一番手前の popover）
/// - `POST /appearance {"scheme": "light"|"dark"|"system"}`
/// - `POST /scenario {"name": ...}` fixtures の差し替え
/// - `GET  /terminal/text`           開いている端末に見えている文字（Metal の描画はスクリーンショットに写らないため）
/// - `POST /terminal/input {"text": ...}` 開いている端末へ入力
/// - `POST /terminal/takeover` / `POST /terminal/release`
/// - `POST /inspector {"tab": "work"|"pr"|"docs"|null}`
/// - `GET  /work` / `POST /work/add {"number"?, "title"}` / `POST /work/update {"id", "state"?, "title"?, "blockerKind"?, "blockerText"?, "delete"?}`
/// - `GET  /inbox`（項目と、鳴らす項目の通知の中身）/ `POST /inbox/open {"id"}`（項目の行き先へ）/ `POST /inbox/notification {"id"}`（通知を押すのと同じ）
///   / `POST /inbox/dismiss {"task", "machine"?}|{"id"}`（タスク画面の［無視］と同じ）
/// - `POST /side-pane {"tab", "close"?}`（タスク画面の右の欄の切り替え。terminal は開いている会話のシェルの欄を開け閉めする）/ `POST /sidebar/node {"id", "expanded"}`（サイドバーの案件と列の節）
/// - `POST /sidebar/arrangement {"grouping"?, "order"?}`（サイドバーの並べ方）/ `POST /attention/next`（［次の入力待ちへ移動］）
/// - `POST /home/layout {"layout": "conversations"|"columns"}`（ホームの形。⌘B と同じ）
/// - `POST /sidebar/pin {"number", "machine"?, "pinned"}`（［ピン留め］）/ `POST /task/end-all {"number", "machine"?}`（［すべて終了］。確認を出したら本文を返す）
/// - `POST /task/split {"conversation", "number"?, "machine"?}`（札を ⌘ を押しながら押して右に並べる。窓の会話の一覧の数を返す）
/// - `GET  /push`（APNs のトークンの有無と先頭 8 字・環境・許可・接続先ごとの登録）/ `GET /push/delivered`（通知センターの通知と userInfo）/ `POST /push/respond {"action": "allow"|"deny", "userInfo": {…}}`（通知の「許可」「拒否」を押すのと同じ）
/// - `POST /doc/open {"number", "id"}` / `POST /doc/close` / `POST /doc/select {"text"}`（本文の最初の一致を選ぶ）
/// - `GET  /doc/text`（開いている文書の本文・画像の読み込み有無）/ `POST /doc/screenshot`（WKWebView の PNG）
/// - `POST /ask/answer {"askID", "answers": [{"questionID", "selected": [...], "freeText"?}]}`
/// - `POST /comment {"docID", "body", "quote"?}`（quote は本文中の文字列。下書きに足す）
/// - `POST /review/submit {"number", "summary"?}`
/// - `GET  /schedules` / `GET /schedules/runs?id=` / `POST /schedules/create {"machine"?, "name", "cron"|"intervalMinutes", "cwd"?, "kind"?, "preset"?, "prompt"?, "task"?|"board"+"column"?, "overlap"?}`（フォームの保存と同じ）
///   / `POST /schedules/run {"id"}` / `POST /schedules/enable {"id", "enabled"}` / `POST /schedules/delete {"id"}`
/// - `GET  /chat/question`（AskUserQuestion の今の問）/ `POST /chat/answer {"choices": [番号], "other"?}`（質問の欄の［次へ］・［回答を送信］）
/// - `GET  /chat`（会話の末尾と貼った画像）/ `POST /chat/paste {"path"}`（画像のファイルを入力欄に貼る）/ `POST /chat/send {"text"}`（貼った画像も送る）
/// - `GET  /prs` / `POST /prs/open {"url"}`（結んだタスクの PR の欄か、タスクなしの画面で開く）/ `POST /prs/refresh` / `GET /prs/detail?url=`（daemon から中身を取る）
@MainActor
final class DebugServer {
    static let shared = DebugServer()
    private var listener: NWListener?
    private weak var model: AppModel?

    func start(port: Int, model: AppModel) {
        self.model = model
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handle(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            NSLog("[taskboard debug] listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("[taskboard debug] listener failed: \(error)")
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest.parse(buffer) {
                    let response = await self.respond(to: request)
                    connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receiveRequest(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard let model else { return .json(503, ["error": "no model"]) }
        if let response = await respondApp(to: request, model: model) { return response }
        if let response = await respondBoard(to: request, model: model) { return response }
        if let response = await respondInbox(to: request, model: model) { return response }
        if let response = await respondDocuments(to: request, model: model) { return response }
        if let response = await respondChat(to: request, model: model) { return response }
        if let response = await respondConversation(to: request, model: model) { return response }
        if let response = await respondSchedules(to: request, model: model) { return response }
        if let response = await respondConnections(to: request, model: model) { return response }
        if let response = await respondTerminal(to: request, model: model) { return response }
        if let response = await respondPerf(to: request, model: model) { return response }
        if let response = await respondChatPerf(to: request, model: model) { return response }
        if let response = await respondFields(to: request, model: model) { return response }
        if let response = await respondWindow(to: request, model: model) { return response }
        return .json(404, ["error": "unknown route"])
    }
}

/// `/new-task` と `/launch` が返す、起こしたもの
func debugJSON(_ conversation: Conversation) -> [String: Any] {
    ["conversation": conversation.id, "phase": conversation.phase.rawValue]
}

/// `/new-task` と `/launch` が受ける起動先の項目。
@MainActor
func applyLaunchFields(_ body: [String: Any], to draft: inout LaunchDraft) {
    if let v = body["cwd"] as? String { draft.cwd = v }
    if let v = (body["kind"] as? String).flatMap(AgentKind.init(rawValue:)) { draft.choice.select(kind: v) }
    if let v = body["model"] as? String { draft.choice.select(model: v) }
    if let v = (body["effort"] as? String).flatMap(Effort.init(rawValue:)) { draft.choice.select(effort: v) }
    // Codex の会話のモデルと effort は codex の名前のまま（{"kind": "codex", "codexModel": "gpt-5.5-codex", "codexEffort": "high"}）
    if let v = body["codexModel"] as? String { draft.choice.select(codexModel: v) }
    if let v = body["codexEffort"] as? String { draft.choice.select(codexEffort: v) }
    if let v = body["args"] as? [String] { draft.select(kind: draft.kind, args: v) }
    if let v = body["prompt"] as? String {
        draft.prompt = v
        draft.promptEdited = true
    }
}

/// `number`（と `machine`）か、選択中のタスク。
@MainActor
func taskFor(_ body: [String: Any], _ model: AppModel) -> BoardTask? {
    if let number = body["number"] as? Int {
        let machine = (body["machine"] as? String).map(MachineID.init(rawValue:)) ?? model.selectedTask?.machine ?? model.fleet.allBoards.first?.machine
        guard let machine else { return nil }
        return model.fleet.task(for: TaskKey(machine: machine, number: number))
    }
    return model.selectedTask.flatMap { model.fleet.task(for: $0) }
}

@MainActor
func currentBoard(_ model: AppModel) -> Board? {
    if case .board(let machine, let id) = model.sidebar { return model.fleet.board(id: id, on: machine) }
    return model.fleet.allBoards.first
}

struct HTTPRequest {
    var method: String
    var path: String
    var body: Data
    /// `?a=b` の値（パーセントを戻したもの）
    var query: [String: String] = [:]

    var jsonBody: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// ヘッダ終端まで届いていて、Content-Length 分の本文が揃っていれば返す。
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        let target = String(requestLine[1])
        let items = URLComponents(string: target)?.queryItems ?? []
        return HTTPRequest(
            method: String(requestLine[0]), path: String(target.split(separator: "?").first ?? ""), body: Data(body.prefix(contentLength)),
            query: Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a }))
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
#endif

#if DEBUG && os(macOS)
import AppKit

/// `/key` が作るキー入力。keyCode は US 配列
struct DebugKey {
    let characters: String
    let keyCode: UInt16

    init?(_ name: String) {
        let special: [String: (String, UInt16)] = [
            "return": ("\r", 36), "escape": ("\u{1b}", 53), "tab": ("\t", 48), "delete": ("\u{7f}", 51),
            "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126), "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
        ]
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "+": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "/": 44, " ": 49, ".": 47, ",": 43,
        ]
        if let (characters, code) = special[name] {
            self.characters = characters
            keyCode = code
        } else if name.count == 1, let code = codes[Character(name)] {
            characters = name
            keyCode = code
        } else {
            return nil
        }
    }

    @MainActor
    /// `title` を渡すと、その題のウィンドウを前に出してから送る
    /// `activate` が false なら、アプリを前面に出さない（ほかの作業のキー入力を奪わない）。前面に無いアプリでは、フォーカスが要る onKeyPress には届かないことがある
    func send(modifiers: [String], window title: String? = nil, activate: Bool = false) -> Bool {
        let titled = title.flatMap { title in NSApp.windows.first { $0.isVisible && $0.title == title } }
        guard let window = titled ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return false }
        if activate, !window.isKeyWindow || titled != nil {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        for event in events(modifiers: modifiers, windowNumber: window.windowNumber) { NSApp.sendEvent(event) }
        return true
    }

    /// 押して離す 2 つのキーの出来事
    func events(modifiers: [String], windowNumber: Int) -> [NSEvent] {
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.command)
            case "option": flags.insert(.option)
            case "control": flags.insert(.control)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        if keyCode >= 123 && keyCode <= 126 { flags.formUnion([.numericPad, .function]) }
        return [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
        }
    }
}
#endif

#if DEBUG
import QuartzCore

/// `/bench/conversation` が流す出来事。人の指示・返答の文・ツールの呼び出しと結果・画像を添えた発言・表・長い段落を、実際の会話に近い長さで順に作る
enum BenchConversation {
    /// 画像を添えた発言は、fixtures の `chatFiles` にある画像の行（`cu1`）の id にする（縮小版を fixtures から読む）
    static func messageIDs(count: Int) -> [String] { (0..<count).map { $0 % 8 == 4 ? "cu1#bench-\($0)" : "bench-\($0)" } }

    /// `thinking` なら、段落の発言の半分を畳んだ思考の行にする（思考の行が増えたときの重さを比べる）
    static func events(conversation: String, count: Int, thinking: Bool = false) -> [ConversationEvent] {
        let reply = "調べた結果を書きます。**変更した所**は `ConversationTimeline` の並べ方で、控えとページのどちらにもある発言を目印にします。\n\n- 1 つ目の確かめ\n- 2 つ目の確かめ\n\n```swift\nlet merged = ConversationTimeline.merged(local, page)\n```\n"
        let output = String(repeating: "Sources/TaskboardKit/ConversationTimeline.swift:120: let x = 1\n", count: 12)
        let table = "比べた結果です。\n\n| 手順 | 前 | 後 | 差 |\n|---|---|---|---|\n" + (1...8).map { "| 手順 \($0) | \($0 * 13) ms | \($0 * 4) ms | -\($0 * 9) ms |" }.joined(separator: "\n") + "\n"
        let paragraph = String(repeating: "一覧の行は見えている所だけを置き、外れた行は使い回します。行の高さは測って覚え、測っていない行は見積もりで数えます。詳しくは https://example.com/docs/chat-list を見てください。", count: 8)
        let images = [ChatImage(index: 0, mediaType: "image/png", bytes: 627, offset: 0), ChatImage(index: 1, mediaType: "image/png", bytes: 609, offset: 0)]
        return messageIDs(count: count).enumerated().map { index, id in
            let message: ChatMessage =
                switch index % 8 {
                case 0: ChatMessage(id: id, role: .user, kind: .text, text: "次の所を直してください。番号 \(index)")
                case 1: ChatMessage(id: id, role: .assistant, kind: .text, text: reply)
                case 2, 6: ChatMessage(id: id, role: .assistant, kind: .toolUse, text: "rg -n merged Sources", toolName: "Bash", toolID: "tool-\(index)")
                case 3, 7: ChatMessage(id: id, role: .user, kind: .toolResult, text: output, toolID: "tool-\(index - 1)")
                case 4: ChatMessage(id: id, role: .user, kind: .text, text: "画面を撮りました。番号 \(index)", images: images)
                default: ChatMessage(id: id, role: .assistant, kind: .text, text: index % 16 == 5 ? table : paragraph, thinking: thinking && index % 16 == 13)
                }
            return ConversationEvent(seq: index + 1, conversationID: conversation, at: Date(), kind: .messages([message], apiMessageID: nil))
        }
    }

    /// 開いている会話に、思考を書いている block を出して `holdMs` ミリ秒おき、終わった思考の発言（履歴の行）で置き換える。置き換わる前後の画面を撮って、行が動かないかを見る
    @MainActor
    static func thinking(into feed: ConversationFeed, holdMs: Int) async {
        let messageID = "bench-think-\(UUID().uuidString.prefix(8))"
        var seq = feed.resumePoint.after
        func send(_ kind: ConversationEvent.Kind) {
            seq += 1
            feed.streamEvent(ConversationEvent(seq: seq, conversationID: feed.key.id, at: Date(), kind: kind))
        }
        let text = "ログを読んで原因を探す。\n\n- トークンの期限\n- 更新の呼び出し"
        send(.blockStart(messageID: messageID, index: 0, block: .thinking, toolName: nil))
        send(.delta(messageID: messageID, index: 0, block: .thinking, text: text))
        try? await Task.sleep(for: .milliseconds(holdMs))
        send(.messages([ChatMessage(id: "\(messageID)#0", role: .assistant, kind: .text, text: text, thinking: true)], apiMessageID: messageID))
        send(.blockStop(messageID: messageID, index: 0))
    }

    /// 開いている会話に、生成中の返答の差分を `seconds` 秒流して終わった発言で置き換える。何回かに 1 回は段落を切り、リンクも混ぜる。流した字数を返す
    @MainActor
    static func stream(into feed: ConversationFeed, seconds: Double, gap: Duration) async -> Int {
        let messageID = "bench-stream-\(UUID().uuidString.prefix(8))"
        var seq = feed.resumePoint.after
        func send(_ kind: ConversationEvent.Kind) {
            seq += 1
            feed.streamEvent(ConversationEvent(seq: seq, conversationID: feed.key.id, at: Date(), kind: kind))
        }
        send(.blockStart(messageID: messageID, index: 0, block: .text, toolName: nil))
        var text = ""
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            let delta = (seq + 1) % 8 == 0 ? "詳しくは https://example.com/docs を見る。\n\n" : "生成中の文を少しずつ足していく。 "
            send(.delta(messageID: messageID, index: 0, block: .text, text: delta))
            text += delta
            try? await Task.sleep(for: gap)
        }
        send(.messages([ChatMessage(id: "\(messageID)#0", role: .assistant, kind: .text, text: text)], apiMessageID: messageID))
        send(.blockStop(messageID: messageID, index: 0))
        return text.count
    }
}

/// 画面の更新間隔を記録する（計測用）。1 フレームが 2 倍以上かかった回を「引っかかり」と数える
@MainActor
final class FrameMonitor {
    static let shared = FrameMonitor()
    private var intervals: [Double] = []
    private var last: CFTimeInterval?
    private var startedAt: CFTimeInterval = 0
    private var link: CADisplayLink?

    func start() {
        intervals = []
        last = nil
        startedAt = CACurrentMediaTime()
        link?.invalidate()
        #if os(macOS)
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first(where: \.isVisible)?.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        #else
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if let last { intervals.append((now - last) * 1000) }
        last = now
    }

    /// 画面の更新を `count` 回待ち、最後の更新の呼ばれた時刻を返す（描画で main が塞がると、そのぶん遅れて呼ばれる）
    func frames(_ count: Int) async -> CFTimeInterval {
        await withCheckedContinuation { continuation in
            waiters.append(FrameWaiter(remaining: count, continuation: continuation))
            ensureWaitLink()
        }
    }

    private struct FrameWaiter {
        var remaining: Int
        let continuation: CheckedContinuation<CFTimeInterval, Never>
    }

    private var waiters: [FrameWaiter] = []
    private var waitLink: CADisplayLink?

    private func ensureWaitLink() {
        guard waitLink == nil else { return }
        #if os(macOS)
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first(where: \.isVisible)?.contentView else {
            waiters.forEach { $0.continuation.resume(returning: CACurrentMediaTime()) }
            waiters = []
            return
        }
        let link = view.displayLink(target: self, selector: #selector(waitTick(_:)))
        #else
        let link = CADisplayLink(target: self, selector: #selector(waitTick(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        waitLink = link
    }

    @objc private func waitTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        for index in waiters.indices { waiters[index].remaining -= 1 }
        waiters.filter { $0.remaining <= 0 }.forEach { $0.continuation.resume(returning: now) }
        waiters.removeAll { $0.remaining <= 0 }
        if waiters.isEmpty {
            waitLink?.invalidate()
            waitLink = nil
        }
    }

    /// 測った時間（ms）の中央値・p95・最大と各回
    static func summary(_ samples: [Double]) -> [String: Any] {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return ["count": 0] }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        return [
            "count": sorted.count, "medianMs": rounded(sorted[sorted.count / 2]), "p95Ms": rounded(percentile(0.95)), "maxMs": rounded(sorted.last ?? 0),
            "samplesMs": samples.map(rounded),
        ]
    }

    func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        let sorted = intervals.sorted()
        guard !sorted.isEmpty else { return ["frames": 0] }
        let expected = sorted[sorted.count / 2]
        let hitches = intervals.filter { $0 > expected * 2 }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let duration = (CACurrentMediaTime() - startedAt) * 1000
        return [
            "frames": intervals.count, "durationMs": Int(duration), "frameMs": round(expected * 10) / 10,
            "p95Ms": round(percentile(0.95) * 10) / 10, "maxMs": round((sorted.last ?? 0) * 10) / 10,
            "hitches": hitches.count, "hitchMs": Int(hitches.reduce(0) { $0 + $1 - expected }),
            // Apple の hitch ratio と同じ考え方: 遅れた時間 / 全体の時間（ms/s）
            "hitchRatio": duration > 0 ? round(hitches.reduce(0) { $0 + $1 - expected } / duration * 1000 * 10) / 10 : 0,
        ]
    }
}
#endif
