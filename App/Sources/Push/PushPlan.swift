import Foundation
import TaskboardKit

extension PushEnvironment {
    /// アプリの APNs の環境。シミュレータは sandbox。実機は入っているプロファイルの `aps-environment` で決まり、
    /// プロファイルが無い（App Store・TestFlight）なら production
    static func detect(profile: Data?, simulator: Bool) -> PushEnvironment {
        if simulator { return .sandbox }
        guard let profile else { return .production }
        return ProvisioningProfile.apsEnvironment(profile) == "development" ? .sandbox : .production
    }

    /// 動いているアプリの環境
    static var current: PushEnvironment {
        #if targetEnvironment(simulator)
        detect(profile: nil, simulator: true)
        #else
        detect(profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }, simulator: false)
        #endif
    }
}

/// `embedded.mobileprovision` の読み取り。中身は CMS で署名した plist なので、署名を確かめずに plist の部分だけを取り出す
/// （環境を決めるだけで、信頼の判断には使わない）
enum ProvisioningProfile {
    static func apsEnvironment(_ data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
            let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["aps-environment"] as? String
    }
}

/// 接続先ごとに daemon へ預ける登録の中身
enum PushPlan {
    /// QR・コードで追加した接続先（`pairedDeviceID` がある）だけ。daemon の token を手で入れた接続先は daemon に端末の行が無い。
    /// 画面で隠しているマシン（1 台だけ表示・非表示）は種類を空にする（ローカル通知も鳴らさないのと同じ）
    static func registrations(
        connections: [SavedConnection], token: String, environment: PushEnvironment, topic: String, kinds: Set<NotifyKind>, turns: TurnNotify = .never,
        sound: Bool, isHidden: (String) -> Bool
    ) -> [String: PushRegistration] {
        var result: [String: PushRegistration] = [:]
        for connection in connections where connection.pairedDeviceID != nil {
            result[connection.fleetID] = PushRegistration(
                token: token, environment: environment, topic: topic,
                kinds: isHidden(connection.fleetID) ? [] : NotifyKind.allCases.filter(kinds.contains), turns: isHidden(connection.fleetID) ? .never : turns,
                sound: sound,
                machineName: String(connection.name.prefix(PushRegistration.machineNameLimit)), connection: connection.fleetID)
        }
        return result
    }
}

/// 設定の［通知］に出す、アプリを閉じているときに通知が届くか
enum PushDeliveryStatus: Equatable {
    case delivering
    /// 登録はできたが、画面で隠しているので届かない
    case hidden
    /// 登録の結果を待っている（トークンが届く前、送っている途中）
    case pending
    /// daemon の token を手で入れた接続先
    case manualConnection
    case notAuthorized
    /// 接続先の Mac が APNs に送れない（鍵が無い）
    case notSending
    case failed(UserFacingError)

    var text: String {
        switch self {
        case .delivering: String(localized: "届きます。")
        case .hidden: String(localized: "1台だけ表示で隠している間は届きません。")
        case .pending: String(localized: "確認しています…")
        case .manualConnection: String(localized: "トークンを入力して追加した接続先には届きません。QRコードで追加し直すと届きます。")
        case .notAuthorized: String(localized: "通知が許可されていません。［設定］アプリの［通知］>［Taskboard］で許可してください。")
        case .notSending: String(localized: "接続先のMacで通知の送信が設定されていないため、届きません。")
        case .failed(let error): error.text
        }
    }
}
