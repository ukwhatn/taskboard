// ui-copy:ignore-file
// このファイルの文（送れなかった理由）は daemon のログと CLI の出力に出て、画面には出ない
import CryptoKit
import Foundation
import Logging
import TaskboardKit

/// APNs の認証のトークン（JWT, ES256）。header `{"alg":"ES256","kid":<Key ID>}`、claims `{"iss":<Team ID>,"iat":<秒>}`
enum APNsJWT {
    static func make(credentials: APNsCredentials, issuedAt: Date) throws -> String {
        // Key ID と Team ID は英数 10 字（`APNsKeyStore.isValidID`）なので、そのまま埋めても JSON は壊れない
        let header = #"{"alg":"ES256","kid":"\#(credentials.config.keyID)"}"#
        let claims = #"{"iss":"\#(credentials.config.teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#
        let input = base64URL(Data(header.utf8)) + "." + base64URL(Data(claims.utf8))
        let signature = try credentials.key.signature(for: Data(input.utf8))
        return input + "." + base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// APNs への HTTP の口。本物は `URLSessionAPNsTransport`、テストは APNs に送らない代わりを渡す
public protocol APNsTransport: Sendable {
    func post(_ request: URLRequest) async throws -> APNsHTTPResponse
}

public struct APNsHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    /// 繋がった HTTP の版（`h2` など）。分からなければ nil
    public var protocolName: String?

    public init(status: Int, body: Data, protocolName: String? = nil) {
        self.status = status
        self.body = body
        self.protocolName = protocolName
    }
}

/// Foundation の `URLSession`。ALPN で h2 を選ぶ（APNs は HTTP/2 だけを受ける）
public struct URLSessionAPNsTransport: APNsTransport {
    private final class Metrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var name: String?

        var protocolName: String? { lock.withLock { name } }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.withLock { name = metrics.transactionMetrics.last?.networkProtocolName }
        }
    }

    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func post(_ request: URLRequest) async throws -> APNsHTTPResponse {
        let metrics = Metrics()
        let (data, response) = try await session.data(for: request, delegate: metrics)
        return APNsHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, protocolName: metrics.protocolName)
    }
}

/// APNs に送る 1 通（payload とヘッダの元）
public struct APNsPush: Sendable, Equatable {
    public struct Alert: Sendable, Equatable {
        public var title: String
        public var subtitle: String
        public var body: String
    }

    public var alert: Alert
    public var sound: Bool
    public var threadID: String?
    public var category: String?
    /// `aps` の外の値（`PushPayload` の名前）
    public var custom: [String: String]
    public var topic: String
    /// `apns-collapse-id`（64 字まで）
    public var collapseID: String?
    public var expiration: Date

    public static let payloadLimit = 4096
    static let lifetime: TimeInterval = 24 * 3600

    /// 受信箱の項目の通知。会話の問いなら会話と問いの id を、確認が読めたら hash と category を載せる
    /// （会話の問いは問いの id で答えるので、古い通知で別の問いに答えない）
    static func inbox(
        _ notification: InboxNotification, conversation: (id: String, request: String)? = nil, machine: MachineID,
        registration: PushRegistration, now: Date
    ) -> APNsPush {
        var custom = [
            PushPayload.item: notification.itemID, PushPayload.url: notification.url.absoluteString, PushPayload.connection: registration.connection,
            PushPayload.machine: machine.rawValue,
        ]
        if let conversation {
            custom[PushPayload.conversation] = conversation.id
            custom[PushPayload.request] = conversation.request
        }
        if let permission = notification.permission { custom[PushPayload.promptHash] = permission.hash }
        if let always = notification.alwaysAllow { custom[PushPayload.suggestion] = always.id }
        if notification.turn { custom[PushPayload.turn] = "1" }
        let category = notification.permission == nil ? nil : notification.alwaysAllow == nil ? PushPayload.permissionCategory : PushPayload.permissionAlwaysCategory
        return APNsPush(
            alert: Alert(title: notification.title, subtitle: notification.subtitle, body: notification.body), sound: registration.sound,
            threadID: notification.threadID, category: category, custom: custom,
            topic: registration.topic, collapseID: collapseID(notification.collapseKey), expiration: now.addingTimeInterval(lifetime))
    }

    /// 同じ鍵の通知を端末の上で 1 つにまとめる。鍵（PR の URL など）は 64 バイトを超えうるので SHA-256 の hex にする
    static func collapseID(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 4KB を超えるなら本文を切る
    public func payload() -> Data {
        let full = encode(body: alert.body)
        guard full.count > Self.payloadLimit else { return full }
        // 字ごとのバイト数（日本語は 3、escape される字は 2 以上）が揃わないので、収まる最長の字数を二分探索で探す
        let characters = Array(alert.body)
        var low = 0
        var high = characters.count - 1
        var best = encode(body: "")
        while low <= high {
            let middle = (low + high) / 2
            let data = encode(body: String(characters[..<middle]) + "…")
            if data.count <= Self.payloadLimit {
                best = data
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }

    private func encode(body: String) -> Data {
        var alertObject = ["title": alert.title, "body": body]
        if !alert.subtitle.isEmpty { alertObject["subtitle"] = alert.subtitle }
        var aps: [String: Any] = ["alert": alertObject]
        if sound { aps["sound"] = "default" }
        if let threadID { aps["thread-id"] = threadID }
        if let category { aps["category"] = category }
        var root: [String: Any] = custom
        root["aps"] = aps
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

/// APNs の答え。送る前に止まったら status は nil
public struct APNsResult: Sendable, Equatable {
    public var status: Int?
    public var reason: String?
    public var protocolName: String?

    public init(status: Int?, reason: String?, protocolName: String? = nil) {
        self.status = status
        self.reason = reason
        self.protocolName = protocolName
    }

    public var delivered: Bool { status == 200 }

    /// 端末のトークンがもう使えない（アプリを消した・別のアプリのトークン）。その端末の登録を消す
    public var tokenIsDead: Bool {
        status == 410 || (status == 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason ?? ""))
    }
}

/// 鍵で JWT を作って APNs に送る。鍵と設定はファイルが変わっていたら読み直す（`apns install` の後に daemon を起動し直さなくてよい）。
/// JWT は作ってから `tokenLifetime` 使う（Apple の決まりは 20〜60 分）。`ExpiredProviderToken` が返ったら作り直して 1 回だけ送り直す
public actor APNsSender {
    public static let tokenLifetime: TimeInterval = 40 * 60
    static let sandboxHost = URL(string: "https://api.sandbox.push.apple.com")!
    static let productionHost = URL(string: "https://api.push.apple.com")!

    let keys: APNsKeyStore
    let transport: any APNsTransport
    private let now: @Sendable () -> Date
    private let logger = Logger(label: "uk.whatn.taskboardd.push")

    private var loaded: (stamp: APNsKeyStore.Stamp, credentials: APNsCredentials?)?
    private var jwt: (token: String, issuedAt: Date)?

    public init(keys: APNsKeyStore, transport: any APNsTransport = URLSessionAPNsTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.keys = keys
        self.transport = transport
        self.now = now
    }

    /// 入っていなければ nil。読めない鍵もログに出して nil
    public func credentials() -> APNsCredentials? {
        let stamp = keys.stamp()
        if let loaded, loaded.stamp == stamp { return loaded.credentials }
        var credentials: APNsCredentials?
        do {
            credentials = try keys.load()
        } catch {
            logger.error("apns key unreadable", metadata: ["error": .string("\(error)")])
        }
        loaded = (stamp, credentials)
        jwt = nil
        return credentials
    }

    /// 鍵が入っていて、その環境の端末に送るか
    public func delivers(to environment: PushEnvironment) -> Bool {
        credentials()?.config.allows(environment) ?? false
    }

    public func send(_ push: APNsPush, deviceToken: String, environment: PushEnvironment) async -> APNsResult {
        guard let credentials = credentials() else { return APNsResult(status: nil, reason: "APNs の鍵が入っていない") }
        guard credentials.config.allows(environment) else {
            return APNsResult(status: nil, reason: "鍵の環境（\(credentials.config.environment?.rawValue ?? "")）と端末の環境（\(environment.rawValue)）が違う")
        }
        var result = await post(push, deviceToken: deviceToken, environment: environment, credentials: credentials)
        if result.status == 403, result.reason == "ExpiredProviderToken" {
            jwt = nil
            result = await post(push, deviceToken: deviceToken, environment: environment, credentials: credentials)
        }
        return result
    }

    /// 存在しないトークン（0 を 64 字）に送り、APNs の答えを返す（`taskboard apns check`）。鍵の環境の制限は見ない（両方の環境の答えを見るため）
    public func probe(topic: String, environment: PushEnvironment) async -> APNsResult {
        guard let credentials = credentials() else { return APNsResult(status: nil, reason: "APNs の鍵が入っていない") }
        let push = APNsPush(
            alert: .init(title: "taskboard", subtitle: "", body: "apns check"), sound: false, threadID: nil, category: nil, custom: [:], topic: topic,
            collapseID: nil, expiration: now().addingTimeInterval(60))
        return await post(push, deviceToken: Self.probeToken, environment: environment, credentials: credentials)
    }

    static let probeToken = String(repeating: "0", count: 64)

    private func token(_ credentials: APNsCredentials) throws -> String {
        let current = now()
        if let jwt, current.timeIntervalSince(jwt.issuedAt) < Self.tokenLifetime, current >= jwt.issuedAt { return jwt.token }
        let token = try APNsJWT.make(credentials: credentials, issuedAt: current)
        jwt = (token, current)
        return token
    }

    private func post(_ push: APNsPush, deviceToken: String, environment: PushEnvironment, credentials: APNsCredentials) async -> APNsResult {
        let bearer: String
        do {
            bearer = try token(credentials)
        } catch {
            return APNsResult(status: nil, reason: "JWT を作れない")
        }
        let host = environment == .sandbox ? Self.sandboxHost : Self.productionHost
        var request = URLRequest(url: host.appending(path: "3/device/\(deviceToken)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("bearer \(bearer)", forHTTPHeaderField: "authorization")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(push.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(push.expiration.timeIntervalSince1970)), forHTTPHeaderField: "apns-expiration")
        if let collapseID = push.collapseID { request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id") }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = push.payload()
        do {
            let response = try await transport.post(request)
            let reason = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["reason"] as? String
            return APNsResult(status: response.status, reason: reason, protocolName: response.protocolName)
        } catch {
            // URLError の文には URL（端末のトークン）が入るので、種類だけを出す
            return APNsResult(status: nil, reason: "APNs に繋がらない（\((error as? URLError)?.code.rawValue.description ?? String(describing: type(of: error)))）")
        }
    }
}
