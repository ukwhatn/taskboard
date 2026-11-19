import Foundation
import Observation
import TaskboardKit
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// iPhone・iPad の APNs。端末のトークンと通知の設定を接続先ごとに daemon へ預け、通知の「許可」「拒否」に答える。
/// 送るかどうかは毎回の中身と前に送った中身を比べて決める（`sync`）。通知の設定・接続先・1 台だけ表示の変化を個別に拾わず、
/// 受信箱の通知と同じ 2 秒ごとの見回りで比べる
@MainActor
@Observable
final class PushCenter {
    static let shared = PushCenter(environment: .current, topic: Bundle.main.bundleIdentifier ?? "")

    enum Authorization: String {
        case unknown, allowed, denied
    }

    /// 接続先ごとの登録の状態
    struct Entry {
        /// daemon が受け付けた中身。nil なら登録が無い（未送信・失敗・解除済み）
        var registered: PushRegistration?
        var delivering = false
        /// daemon がターンの完了も APNs で送る
        var deliversTurns = false
        var sentAt: Date?
        var failure: UserFacingError?
        /// 最後に送ろうとした中身と端末の行。同じなら、前面に戻るまで送り直さない（失敗も同じ）
        fileprivate var attempt: Attempt?
        fileprivate var inFlight = false
        /// 通知が許可されていない間に、登録の解除を送り終えた
        fileprivate var cleared = false
    }

    fileprivate struct Attempt: Equatable {
        var registration: PushRegistration
        /// QR で追加し直すと、中身が同じでも端末の行と token が替わる
        var deviceID: String?
    }

    let environment: PushEnvironment
    let topic: String
    private let session: URLSession
    private(set) var token: String?
    /// トークンを受け取れなかったときの失敗
    private(set) var tokenFailure: UserFacingError?
    /// 受け取れなかった理由の元の文（debug の `/push` だけが読む）
    private(set) var tokenErrorDescription: String?
    private(set) var authorization: Authorization = .unknown
    /// 接続先の id（`SavedConnection.fleetID`）ごと
    private(set) var entries: [String: Entry] = [:]

    init(environment: PushEnvironment, topic: String, session: URLSession = DaemonClient.cookieless) {
        self.environment = environment
        self.topic = topic
        self.session = session
    }

    func receive(token data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        tokenFailure = nil
        tokenErrorDescription = nil
    }

    func receive(tokenError: any Error) {
        tokenFailure = UserFacingError("登録できませんでした", error: tokenError)
        tokenErrorDescription = String(describing: tokenError)
    }

    func set(authorization: Authorization) {
        self.authorization = authorization
    }

    /// 通知の許可を確かめ直す（前面に戻ったとき。［設定］アプリで切り替えられる）
    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorization = .allowed
        case .denied: authorization = .denied
        case .notDetermined: authorization = .unknown
        @unknown default: authorization = .unknown
        }
    }

    /// 今の中身を接続先ごとに預ける。前に送ろうとした中身と同じなら送らない（`force` のときは送る）。
    /// 通知が許可されていなければ、登録した接続先から外す
    func sync(
        connections: [SavedConnection], kinds: Set<NotifyKind>, turns: TurnNotify = .never, sound: Bool, isHidden: (String) -> Bool, force: Bool = false
    ) {
        let live = Set(connections.map(\.fleetID))
        entries = entries.filter { live.contains($0.key) }
        if authorization == .denied {
            // 前の起動で登録した分はこの起動の記録に無いので、QR で追加した接続先には毎回の起動で 1 度ずつ解除を送る
            for connection in connections where connection.pairedDeviceID != nil {
                let entry = entries[connection.fleetID] ?? Entry()
                if !entry.cleared, !entry.inFlight { unregister(connection) }
            }
            return
        }
        guard authorization == .allowed, let token else { return }
        let desired = PushPlan.registrations(
            connections: connections, token: token, environment: environment, topic: topic, kinds: kinds, turns: turns, sound: sound, isHidden: isHidden)
        for connection in connections {
            guard let registration = desired[connection.fleetID] else { continue }
            let attempt = Attempt(registration: registration, deviceID: connection.pairedDeviceID)
            let entry = entries[connection.fleetID] ?? Entry()
            if entry.inFlight || (!force && entry.attempt == attempt) { continue }
            register(connection, attempt)
        }
    }

    private func register(_ connection: SavedConnection, _ attempt: Attempt) {
        let id = connection.fleetID
        entries[id, default: Entry()].attempt = attempt
        entries[id, default: Entry()].inFlight = true
        entries[id, default: Entry()].cleared = false
        let client = DaemonClient(endpoint: connection.endpoint, session: session)
        Task {
            do {
                let response = try await client.registerPush(attempt.registration)
                entries[id]?.registered = attempt.registration
                entries[id]?.delivering = response.delivering
                entries[id]?.deliversTurns = response.turns == true
                entries[id]?.failure = nil
                entries[id]?.sentAt = Date()
            } catch {
                // 古い daemon（口が無い 404）と繋がらないときも、送れていないものとして扱い、次に中身が変わるか前面に戻ったときに試す
                entries[id]?.registered = nil
                entries[id]?.delivering = false
                entries[id]?.deliversTurns = false
                entries[id]?.failure = UserFacingError("登録できませんでした", error: error)
                entries[id]?.sentAt = Date()
            }
            entries[id]?.inFlight = false
        }
    }

    private func unregister(_ connection: SavedConnection) {
        let id = connection.fleetID
        entries[id, default: Entry()].inFlight = true
        let client = DaemonClient(endpoint: connection.endpoint, session: session)
        Task {
            // 解除に失敗しても、次に許可されたときに上書きで送り直すので、ここでは覚えた登録を消すだけにする
            try? await client.unregisterPush()
            var entry = Entry()
            entry.cleared = true
            entries[id] = entry
        }
    }

    /// APNs の通知が届く接続先。この接続先のマシンの項目は、ローカル通知を出さない
    var deliveringConnections: Set<String> {
        guard authorization == .allowed else { return [] }
        return Set(entries.filter { $0.value.registered != nil && $0.value.delivering }.keys)
    }

    /// ターンの完了も APNs で届く接続先。この接続先のマシンのターンの完了は、ローカル通知を出さない
    var deliveringTurnConnections: Set<String> {
        deliveringConnections.filter { entries[$0]?.deliversTurns == true }
    }

    func status(for connection: SavedConnection, hidden: Bool) -> PushDeliveryStatus {
        if connection.pairedDeviceID == nil { return .manualConnection }
        if authorization == .denied { return .notAuthorized }
        if token == nil, let tokenFailure { return .failed(tokenFailure) }
        guard let entry = entries[connection.fleetID], !entry.inFlight || entry.registered != nil else { return .pending }
        if let failure = entry.failure { return .failed(failure) }
        guard entry.registered != nil else { return .pending }
        if !entry.delivering { return .notSending }
        return hidden ? .hidden : .delivering
    }

    // MARK: 「許可」「拒否」

    /// 通知の操作の id と中身から、どの接続先のどの会話の問いに何と答えるか。許可・拒否の操作でなければ nil
    struct Answer: Equatable, Sendable {
        /// 会話の問い。問いの id で答えるので、古い通知で別の問いに答えることはない
        struct Target: Equatable, Sendable {
            var conversation: String
            var request: String
            var allow: Bool
            var suggestion: String?
        }

        var connection: String
        var target: Target
        /// 失敗の知らせを押したときの行き先
        var itemID: String?
        var url: URL?

        init?(actionID: String, userInfo: [AnyHashable: Any]) {
            let allow: Bool
            var suggestion: String?
            switch actionID {
            case PushPayload.allowAction: allow = true
            case PushPayload.denyAction: allow = false
            case PushPayload.alwaysAllowAction:
                // 候補の無い通知には付かない操作。候補を指せなければ、ただの許可にはしない
                guard let id = userInfo[PushPayload.suggestion] as? String else { return nil }
                (allow, suggestion) = (true, id)
            default: return nil
            }
            guard let connection = userInfo[PushPayload.connection] as? String, let conversation = userInfo[PushPayload.conversation] as? String,
                let request = userInfo[PushPayload.request] as? String
            else { return nil }
            target = Target(conversation: conversation, request: request, allow: allow, suggestion: suggestion)
            self.connection = connection
            itemID = userInfo[PushPayload.item] as? String
            url = (userInfo[PushPayload.url] as? String).flatMap(URL.init(string:))
        }
    }

    enum AnswerOutcome: Equatable {
        case answered
        /// 会話の問いにもう答えてある（409）。会話を開いて今の問いを見せる
        case stale
        case failed(UserFacingError)

        var failure: UserFacingError? { if case .failed(let failure) = self { failure } else { nil } }
    }

    /// 答えを送る。接続の WebSocket は待たない（アプリが閉じていた状態から裏で起きたときも、Keychain の接続先だけで送れる）
    func answer(_ answer: Answer, connections: [SavedConnection]) async -> AnswerOutcome {
        let event: LocalizedStringResource = "応答できませんでした"
        guard let connection = connections.first(where: { $0.fleetID == answer.connection }) else {
            return .failed(UserFacingError(event, cause: String(localized: "通知の接続先が見つかりません")))
        }
        let client = DaemonClient(endpoint: connection.endpoint, session: session)
        do {
            let target = answer.target
            try await client.answerConversation(
                target.conversation, ConversationAnswerRequest(requestID: target.request, allow: target.allow, suggestionID: target.suggestion))
            return .answered
        } catch {
            if case .rejected(let rejection) = error as? SessionSourceError, rejection.status == 409 { return .stale }
            return UserFacingError(event, error: error).map(AnswerOutcome.failed) ?? .answered
        }
    }

    /// 答えられなかったことをローカル通知で知らせる。押すとそのセッションを開く（通知を押したときと同じ `item`・`url`）。
    /// 答えられたときは何も出さない（セッションの画面が進むので分かる）
    static func postAnswerFailure(_ failure: UserFacingError, for answer: Answer) {
        let content = UNMutableNotificationContent()
        content.title = failure.event
        content.body = failure.detail ?? UserFacingError.retry + "。"
        var info: [String: String] = [:]
        if let itemID = answer.itemID { info[PushPayload.item] = itemID }
        if let url = answer.url { info[PushPayload.url] = url.absoluteString }
        content.userInfo = info
        content.threadIdentifier = answer.connection
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "answer-failed/\(answer.connection)/\(answer.itemID ?? answer.target.request)", content: content, trigger: nil))
    }

    // MARK: 通知の種類

    /// 権限の確認の通知の「許可」「拒否」（候補のある通知は間に［常に許可］）。どれもロックの解除を求め、アプリを前に出さずに答える
    static func registerCategories() {
        let allow = UNNotificationAction(identifier: PushPayload.allowAction, title: String(localized: "許可"), options: [.authenticationRequired])
        let always = UNNotificationAction(identifier: PushPayload.alwaysAllowAction, title: String(localized: "常に許可"), options: [.authenticationRequired])
        let deny = UNNotificationAction(
            identifier: PushPayload.denyAction, title: String(localized: "拒否"), options: [.authenticationRequired, .destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: PushPayload.permissionCategory, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: PushPayload.permissionAlwaysCategory, actions: [allow, always, deny], intentIdentifiers: []),
        ])
    }

    /// 通知の許可が取れたら APNs にトークンを求める（届くのは app delegate の `didRegisterForRemoteNotificationsWithDeviceToken`）
    func requestToken() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
}

#if os(iOS)
/// APNs のトークンは UIApplicationDelegate にしか届かない
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushCenter.shared.receive(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        MainActor.assumeIsolated { PushCenter.shared.receive(tokenError: error) }
    }
}
#endif
