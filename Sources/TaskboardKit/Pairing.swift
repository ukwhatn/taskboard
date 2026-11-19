import Foundation

/// `POST /v1/pairings` の応答。5 分で切れる一度きりのコード
public struct PairingCode: Codable, Hashable, Sendable {
    /// Crockford base32 の 8 文字（`-` は付けない）
    public var code: String
    public var expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }

    /// 画面に出す形（「ABCD-EFGH」）
    public var display: String {
        code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code
    }

    /// 人が打った・読んだコードを daemon が比べる形にする。8 文字の Crockford base32 でなければ nil
    public static func normalize(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == 8, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }

    /// I・L・O・U を除いた 32 文字
    public static let alphabet: Set<Character> = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
}

/// 端末の種類。daemon はこの 3 つしか受け付けない
public enum DevicePlatform: String, Codable, Hashable, Sendable, CaseIterable {
    case ios
    case ipados
    case macos
}

/// `POST /v1/pair`（daemon の token は送らない。Access の内側）
public struct PairRequest: Codable, Hashable, Sendable {
    public var code: String
    /// 1〜64 字
    public var name: String
    public var platform: DevicePlatform

    public init(code: String, name: String, platform: DevicePlatform) {
        self.code = code
        self.name = name
        self.platform = platform
    }

    public static let nameLimit = 64
}

public struct PairResponse: Codable, Hashable, Sendable {
    /// daemon の `device` 表の行 id
    public var deviceID: String
    /// 端末の token。daemon は SHA-256 だけを持つので、ここでしか受け取れない
    public var token: String
    public var machineID: String

    public init(deviceID: String, token: String, machineID: String) {
        self.deviceID = deviceID
        self.token = token
        self.machineID = machineID
    }
}

/// ペアリングした端末。`GET /v1/devices` と `devices.updated`
public struct DeviceInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var platform: DevicePlatform
    public var createdAt: Date
    public var lastSeenAt: Date?
    /// 端末の token で `GET /v1/devices` を呼んだときの自分の行だけ true。イベントでは常に false
    public var current: Bool

    public init(id: String, name: String, platform: DevicePlatform, createdAt: Date, lastSeenAt: Date? = nil, current: Bool = false) {
        self.id = id
        self.name = name
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.current = current
    }
}

/// QR に載せる中身。`{"taskboardPair":1,"url":…,"code":…,"access":…,"name":…}` の JSON。
/// URI の形にしないのは、標準のカメラが URI と見て同じ scheme を登録した別のアプリに渡すことがあり、Access の secret が漏れるため（アプリ内のスキャナだけで読む）
public struct PairingPayload: Hashable, Sendable {
    public var url: URL
    public var code: String
    public var access: AccessCredential?
    /// 接続先に付ける名前の初期値（QR を出した側での名前）
    public var name: String

    public init(url: URL, code: String, access: AccessCredential?, name: String) {
        self.url = url
        self.code = code
        self.access = access
        self.name = name
    }

    static let version = 1

    private struct Wire: Codable {
        var taskboardPair: Int
        var url: URL
        var code: String
        var access: AccessCredential?
        var name: String
    }

    public var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Wire(taskboardPair: Self.version, url: url, code: code, access: access, name: name))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// 版・URL・コードのどれかが違えば nil
    public static func decode(_ text: String) -> PairingPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let wire = try? JSONDecoder().decode(Wire.self, from: Data(trimmed.utf8)), wire.taskboardPair == version else { return nil }
        guard let scheme = wire.url.scheme?.lowercased(), ["http", "https"].contains(scheme), wire.url.host() != nil else { return nil }
        guard let code = PairingCode.normalize(wire.code) else { return nil }
        return PairingPayload(url: wire.url, code: code, access: wire.access, name: wire.name)
    }
}

/// daemon が自分で返す 401・403 に付けるヘッダ。無い 401 は Cloudflare Access が返したもの
public enum DaemonAuthHeader {
    public static let name = "X-Taskboard-Auth"
    /// 401: token が違う・止められた
    public static let invalid = "invalid"
    /// 403: 端末の token では使えない経路
    public static let forbidden = "forbidden"
    /// 端末を止めたときに WebSocket を閉じる close code
    public static let revokedCloseCode: UInt16 = 4401
}
