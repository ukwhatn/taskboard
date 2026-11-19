import Foundation
import Logging
import TaskboardKit

/// 登録のある端末に APNs で送る。端末のトークンがもう使えなければ（410・`BadDeviceToken`・`DeviceTokenNotForTopic`）登録を消す。
/// ログには端末の id・トークンの先頭 8 字・status・reason だけを出す（JWT・鍵・トークンの全体は出さない）
public actor PushService {
    let store: Store
    let sender: APNsSender
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.whatn.taskboardd.push")

    public init(store: Store, sender: APNsSender, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.sender = sender
        self.now = now
    }

    public func hasCredentials() async -> Bool { await sender.credentials() != nil }

    public func delivers(to environment: PushEnvironment) async -> Bool { await sender.delivers(to: environment) }

    func targets() -> [Store.PushTarget] {
        do {
            return try store.pushTargets()
        } catch {
            logger.error("push targets unreadable", metadata: ["error": .string("\(error)")])
            return []
        }
    }

    /// 1 台に送る。結果は `POST /v1/push/test` の形で返す
    @discardableResult
    func deliver(_ push: APNsPush, to target: Store.PushTarget) async -> PushTestResult {
        let token = target.registration.token
        let result = await sender.send(push, deviceToken: token, environment: target.registration.environment)
        let metadata: Logger.Metadata = [
            "device": .string(target.deviceID), "token": .string(String(token.prefix(8))), "status": .string(result.status.map(String.init) ?? "-"),
            "reason": .string(result.reason ?? ""),
        ]
        if result.delivered {
            logger.info("push sent", metadata: metadata)
        } else {
            logger.warning("push not sent", metadata: metadata)
        }
        if result.tokenIsDead {
            do {
                if try store.clearPushRegistration(deviceID: target.deviceID, token: token) {
                    logger.notice("push registration removed", metadata: metadata)
                }
            } catch {
                logger.error("push registration not removed", metadata: ["device": .string(target.deviceID), "error": .string("\(error)")])
            }
        }
        return PushTestResult(deviceID: target.deviceID, deviceName: target.deviceName, status: result.status, reason: result.reason)
    }

    /// 登録のある全端末にテストの通知を送る
    func sendTest(machine: MachineID) async -> [PushTestResult] {
        var results: [PushTestResult] = []
        for target in targets() {
            let push = APNsPush(
                alert: .init(title: "通知のテスト", subtitle: target.registration.machineName, body: "アプリを閉じていても、このデバイスに通知が届きます。"),
                sound: target.registration.sound, threadID: machine.rawValue, category: nil,
                custom: [PushPayload.connection: target.registration.connection, PushPayload.machine: machine.rawValue],
                topic: target.registration.topic, collapseID: nil, expiration: now().addingTimeInterval(APNsPush.lifetime))
            results.append(await deliver(push, to: target))
        }
        return results
    }
}
