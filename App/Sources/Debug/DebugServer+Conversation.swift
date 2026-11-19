#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// host の会話
    func respondConversation(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/conversation"):
            // 開いている会話の今（発言の末尾・生成中・先に出した発言・問い）
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            return .json(200, feed.debugDescription.merging(["requests": model.fleet.conversation(for: feed.key)?.requests.map { ["id": $0.id, "kind": $0.kind.rawValue] } ?? []]) { a, _ in a })
        case ("POST", "/conversation/shell-sheet"):
            // iPhone の上の帯の［ターミナル］と同じく、作業フォルダのシェルを起こしてシートで出す
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            do {
                let pane = try await feed.shell()
                feed.sheet = .terminal(pane)
                return .json(200, ["ok": true, "pane": pane.rawValue])
            } catch {
                return .json(500, ["error": "\(error)"])
            }
        case ("POST", "/conversation/send"):
            // 入力欄の送信と同じ（先に出してから送る）。{"text": "..."}
            guard let feed = model.activeConversation, let text = request.jsonBody?["text"] as? String else { return .json(400, ["error": "会話を開いて text を送る"]) }
            feed.send(text, images: [])
            return .json(200, ["ok": true, "outgoing": feed.outgoing.map(\.clientMessageID)])
        case ("POST", "/conversation/retry"):
            guard let feed = model.activeConversation, let id = request.jsonBody?["clientMessageID"] as? String else { return .json(400, ["error": "会話を開いて clientMessageID を送る"]) }
            feed.retry(id)
            return .json(200, ["ok": true])
        case ("POST", "/conversation/answer"):
            // 今の問いに答える。質問は {"answers": [{"questionID": "...", "selected": ["..."]}]}、権限と計画は {"allow": true}
            guard let feed = model.activeConversation, let current = model.fleet.conversation(for: feed.key)?.requests.first else {
                return .json(400, ["error": "問いが出ていない"])
            }
            let body = request.jsonBody ?? [:]
            let answers = (body["answers"] as? [[String: Any]])?.map { item in
                AskAnswer(questionID: item["questionID"] as? String ?? "", selected: item["selected"] as? [String] ?? [], freeText: item["freeText"] as? String)
            }
            do {
                try await feed.answer(ConversationAnswerRequest(requestID: current.id, answers: answers, allow: body["allow"] as? Bool, message: body["message"] as? String))
                return .json(200, ["ok": true, "request": current.id])
            } catch {
                return .json(502, ["error": "\(error)"])
            }
        case ("POST", "/conversation/interrupt"):
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            do {
                try await feed.interrupt()
                return .json(200, ["ok": true])
            } catch {
                return .json(502, ["error": "\(error)"])
            }
        case ("POST", "/conversation/close"):
            // メニューの「終了」（確認は出さない）
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            model.close(conversation: feed.key)
            return .json(200, ["ok": true])
        case ("POST", "/conversation/field"):
            // 入力欄の下の欄を開く（model / effort / permission）。{"close": true} で閉じる
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            if request.jsonBody?["close"] as? Bool == true {
                feed.openField = nil
                return .json(200, ["ok": true])
            }
            guard let field = (request.jsonBody?["open"] as? String).flatMap(ConversationField.init(rawValue:)) else {
                return .json(400, ["error": "open は \(ConversationField.allCases.map(\.rawValue).joined(separator: "・"))"])
            }
            feed.openField = field
            return .json(200, ["ok": true, "field": field.rawValue])
        case ("POST", "/conversation/sheet"):
            // 差分の画面（{"open": "diff"}）・巻き戻しの確認（{"open": "rewind", "message": "<id>"}。省くと最後の指示）・コネクタ（{"open": "connectors"}）・
            // コンテキストの内訳（{"open": "context"}）・上の帯の［状態］（{"open": "info"}）を出す。{"close": true} で閉じる
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            let body = request.jsonBody ?? [:]
            if body["close"] as? Bool == true {
                feed.sheet = nil
                feed.showsInfo = false
                return .json(200, ["ok": true])
            }
            switch body["open"] as? String {
            case "diff":
                feed.loadDiff()
                feed.sheet = .diff
            case "rewind":
                let id = body["message"] as? String
                let range = ChatRewindRange(feed.messages)
                guard let message = id.map({ id in feed.messages.last { $0.id == id && range.allows($0) } }) ?? ChatRewindRange.last(in: feed.messages) else {
                    return .json(404, ["error": "巻き戻せる指示が無い"])
                }
                feed.sheet = .rewind(message)
            case "connectors":
                feed.sheet = .connectors
            case "context":
                feed.sheet = .context
            case "info":
                feed.showsInfo = true
            default:
                return .json(400, ["error": "open は diff・rewind・connectors・context・info"])
            }
            return .json(200, ["ok": true, "sheet": feed.sheet?.debugName as Any])
        case ("POST", "/conversation/slash"):
            // 入力欄に {"text": "/mo"} と打ったときの候補（名前・操作・合った別名）。文の途中の / も同じ（{"text": "この文を /yo"}）
            guard let feed = model.activeConversation, let text = request.jsonBody?["text"] as? String else { return .json(400, ["error": "会話を開いて text を送る"]) }
            let conversation = model.fleet.conversation(for: feed.key)
            let items =
                SlashTyping.find(in: text).map {
                    ConversationSlashItem.matching(
                        $0.name, commands: feed.commands, engine: conversation?.engine ?? .claude,
                        unavailableFields: conversation.map(model.unavailableFields(for:)) ?? [], leading: $0.leading)
                } ?? []
            return .json(200, ["items": items.map { ["name": $0.name, "action": "\($0.action)", "alias": $0.matchedAlias as Any] }])
        case ("POST", "/conversation/keep-subscriptions"):
            // 画面を離れても unsubscribe を送らない切り替え（裏に入れたときに購読の数がいつ減るかを測る）。{"enabled": true}
            model.fleet.keepsSubscriptions = request.jsonBody?["enabled"] as? Bool ?? true
            return .json(200, ["keepsSubscriptions": model.fleet.keepsSubscriptions, "subscribed": model.fleet.subscribedConversations.map { ["key": $0.key.description, "count": $0.value] }])
        default:
            return nil
        }
    }
}
#endif
