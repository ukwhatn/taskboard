#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// 受信箱の項目（画面は持たず、通知・バッジ・サイドバーの札・タスク画面の［無視］が使う）と通知
    func respondInbox(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/inbox"):
            return .json(200, [
                "sidebar": model.sidebar.id, "waiting": model.inboxWaitingCount,
                "dismissed": model.inbox(now: Date()).dismissed.map(\.id), "pending": model.inboxPending.count,
                "items": model.inboxItems.map { item in
                    var row: [String: Any] = [
                        "id": item.id, "group": item.group == .waiting ? "waiting" : "notice", "kind": item.kind.label, "title": item.title,
                        "details": item.details, "at": ISO8601DateFormatter().string(from: item.at), "task": item.taskNumber as Any,
                    ]
                    if let notification = InboxNotification.make(item, machineName: model.machineName(item.machine)) {
                        row["notification"] = ["title": notification.title, "subtitle": notification.subtitle, "body": notification.body, "url": notification.url.absoluteString]
                    }
                    return row
                },
            ])
        case ("POST", "/inbox/notification"):
            guard let id = request.jsonBody?["id"] as? String, let item = model.inboxItems.first(where: { $0.id == id }),
                let notification = InboxNotification.make(item, machineName: model.machineName(item.machine))
            else { return .json(404, ["error": "通知する行が無い"]) }
            model.openNotification(itemID: notification.itemID, fallback: notification.url)
            return .json(200, model.debugDescription)
        case ("POST", "/inbox/open"):
            // 項目の行き先へ移る（通知を押したのと同じ。項目が残っているとき）
            guard let id = request.jsonBody?["id"] as? String else { return .json(400, ["error": "id が要る"]) }
            guard let item = model.inboxItems.first(where: { $0.id == id }) else { return .json(404, ["error": "受信箱にその行が無い"]) }
            model.open(inbox: item, from: .debug)
            return .json(200, ["ok": true])
        case ("POST", "/inbox/dismiss"):
            // タスク画面の待ち理由の帯の［無視］と同じ。{"task": 番号, "machine"?: id} でそのタスクの対応待ちを全部、{"id"} で 1 つ
            if let number = request.jsonBody?["task"] as? Int {
                let machine = (request.jsonBody?["machine"] as? String).map(MachineID.init(rawValue:)) ?? model.selectedTask?.machine
                guard let machine else { return .json(400, ["error": "machine が要る"]) }
                let items = model.waitingItems(for: TaskKey(machine: machine, number: number))
                model.dismiss(items)
                return .json(200, ["ok": true, "count": items.count])
            }
            guard let id = request.jsonBody?["id"] as? String else { return .json(400, ["error": "task か id が要る"]) }
            guard let item = model.inboxItems.first(where: { $0.id == id }) else { return .json(404, ["error": "受信箱にその行が無い"]) }
            model.dismiss([item])
            return .json(200, ["ok": true])
        case ("GET", "/push"):
            // トークンは先頭 8 字だけ。接続先の資格情報は返さない
            let push = PushCenter.shared
            let formatter = ISO8601DateFormatter()
            return .json(200, [
                "token": push.token.map { String($0.prefix(8)) } as Any, "tokenError": push.tokenErrorDescription as Any,
                "environment": push.environment.rawValue, "topic": push.topic, "authorization": push.authorization.rawValue,
                "delivering": push.deliveringConnections.sorted(),
                "connections": model.connections.map { connection in
                    let entry = push.entries[connection.fleetID]
                    return [
                        "id": connection.fleetID, "name": connection.name, "paired": connection.pairedDeviceID != nil,
                        "registered": entry?.registered != nil, "kinds": entry?.registered?.kinds.map(\.rawValue) as Any,
                        "delivering": entry?.delivering ?? false, "sentAt": entry?.sentAt.map(formatter.string(from:)) as Any,
                        "failure": entry?.failure?.text as Any,
                        "status": push.status(for: connection, hidden: !model.fleet.isVisible(fleetID: connection.fleetID)).text,
                    ] as [String: Any]
                },
            ])
        case ("GET", "/push/delivered"):
            // 通知センターに残っている通知（本物の APNs から届いたかの確かめと、/push/respond に渡す userInfo）
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let formatter = ISO8601DateFormatter()
            return .json(200, [
                "notifications": delivered.map { notification in
                    let content = notification.request.content
                    return [
                        "id": notification.request.identifier, "date": formatter.string(from: notification.date),
                        "title": content.title, "body": content.body, "category": content.categoryIdentifier,
                        "remote": notification.request.trigger is UNPushNotificationTrigger,
                        "userInfo": content.userInfo.reduce(into: [String: String]()) { result, pair in
                            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
                        },
                    ] as [String: Any]
                }
            ])
        case ("POST", "/push/respond"):
            let body = request.jsonBody ?? [:]
            let action =
                switch body["action"] as? String {
                case "deny": PushPayload.denyAction
                case "always": PushPayload.alwaysAllowAction
                default: PushPayload.allowAction
                }
            guard let info = body["userInfo"] as? [String: Any], let answer = PushCenter.Answer(actionID: action, userInfo: info) else {
                return .json(400, ["error": "userInfo に connection・conversation・request が要る"])
            }
            let failure = await model.answerPush(answer)
            return .json(200, ["ok": failure == nil, "failure": failure?.text as Any])
        default:
            return nil
        }
    }
}
#endif
