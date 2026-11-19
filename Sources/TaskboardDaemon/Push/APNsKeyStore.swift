// ui-copy:ignore-file
// このファイルの文（鍵の置き場の失敗）は CLI の出力と daemon のログに出て、画面には出ない
import CryptoKit
import Foundation
import TaskboardKit

/// APNs の鍵（`.p8`）を daemon が送るときに読むための設定。`apns.json` に置く
public struct APNsConfig: Codable, Hashable, Sendable {
    public var keyID: String
    public var teamID: String
    /// 付けたら、この環境に登録した端末だけに送る（鍵がその環境専用のとき）。nil なら端末が登録した環境に送る
    public var environment: PushEnvironment?

    public init(keyID: String, teamID: String, environment: PushEnvironment? = nil) {
        self.keyID = keyID
        self.teamID = teamID
        self.environment = environment
    }

    /// その環境の端末に送るか
    public func allows(_ environment: PushEnvironment) -> Bool {
        self.environment == nil || self.environment == environment
    }
}

/// 送るときに使う鍵と設定
public struct APNsCredentials: Sendable {
    public var config: APNsConfig
    public var key: P256.Signing.PrivateKey
}

public enum APNsKeyError: Error, CustomStringConvertible, Equatable {
    case invalidKey
    case invalidKeyID
    case invalidTeamID
    case unreadable(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .invalidKey: "鍵を P-256 の秘密鍵（.p8 の PEM）として読めない"
        case .invalidKeyID: "Key ID は英数 10 字"
        case .invalidTeamID: "Team ID は英数 10 字"
        case .unreadable(let path): "\(path) を読めない"
        case .writeFailed(let path): "\(path) に書けない"
        }
    }
}

/// support ディレクトリの下の `apns/`（700）に、鍵 `AuthKey.p8` と設定 `apns.json`（どちらも 600）を置く。
/// Keychain に入れないのは、launchd の daemon からも ssh で入れた CLI からも同じように読むため
public struct APNsKeyStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var keyFile: URL { directory.appending(path: "AuthKey.p8") }
    public var configFile: URL { directory.appending(path: "apns.json") }

    /// Key ID と Team ID は Apple の形（英数 10 字）
    public static func isValidID(_ id: String) -> Bool {
        id.count == 10 && id.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// 鍵が P-256 の秘密鍵として読めることを確かめてから書く。読めなければ何も書かない
    @discardableResult
    public func install(keyPEM: String, keyID: String, teamID: String, environment: PushEnvironment?) throws -> APNsConfig {
        guard Self.isValidID(keyID) else { throw APNsKeyError.invalidKeyID }
        guard Self.isValidID(teamID) else { throw APNsKeyError.invalidTeamID }
        guard (try? P256.Signing.PrivateKey(pemRepresentation: keyPEM)) != nil else { throw APNsKeyError.invalidKey }
        let config = APNsConfig(keyID: keyID, teamID: teamID, environment: environment)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw APNsKeyError.writeFailed(directory.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writePrivate(Data(keyPEM.utf8), to: keyFile)
        try Self.writePrivate(try encoder.encode(config), to: configFile)
        return config
    }

    /// 入っていなければ nil。鍵が読めなければ投げる
    public func load() throws -> APNsCredentials? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: keyFile.path), fm.fileExists(atPath: configFile.path) else { return nil }
        guard let data = fm.contents(atPath: configFile.path), let config = try? JSONDecoder().decode(APNsConfig.self, from: data) else {
            throw APNsKeyError.unreadable(configFile.path)
        }
        guard let pem = fm.contents(atPath: keyFile.path).map({ String(decoding: $0, as: UTF8.self) }) else {
            throw APNsKeyError.unreadable(keyFile.path)
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { throw APNsKeyError.invalidKey }
        return APNsCredentials(config: config, key: key)
    }

    /// 鍵と設定の変更時刻と大きさ。変わっていたら daemon が読み直す
    struct Stamp: Hashable, Sendable {
        var key: String
        var config: String
    }

    /// install は一時ファイルを rename で置くので、inode の番号も見る（同じ秒に書き直しても取りこぼさない）
    func stamp() -> Stamp {
        func attributes(_ url: URL) -> String {
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "" }
            return [values[.modificationDate], values[.size], values[.systemFileNumber]].map { "\($0 ?? "")" }.joined(separator: "|")
        }
        return Stamp(key: attributes(keyFile), config: attributes(configFile))
    }

    public struct Status: Sendable, Equatable {
        public var config: APNsConfig
        /// 鍵のファイルの権限（8 進の 3 桁）
        public var keyPermissions: String
    }

    /// 入っていなければ nil。鍵の中身は読まない
    public func status() throws -> Status? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configFile.path) || fm.fileExists(atPath: keyFile.path) else { return nil }
        guard let data = fm.contents(atPath: configFile.path), let config = try? JSONDecoder().decode(APNsConfig.self, from: data) else {
            throw APNsKeyError.unreadable(configFile.path)
        }
        guard let mode = (try? fm.attributesOfItem(atPath: keyFile.path))?[.posixPermissions] as? NSNumber else {
            throw APNsKeyError.unreadable(keyFile.path)
        }
        return Status(config: config, keyPermissions: String(mode.intValue & 0o777, radix: 8))
    }

    /// 消したら true、無ければ false
    @discardableResult
    public func remove() throws -> Bool {
        let fm = FileManager.default
        var removed = false
        for url in [keyFile, configFile] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            removed = true
        }
        if let rest = try? fm.contentsOfDirectory(atPath: directory.path), rest.isEmpty { try? fm.removeItem(at: directory) }
        return removed
    }

    /// 600 で作った一時ファイルに書いてから置き換える（書いている途中に他の人が読める権限の時間を作らない）
    private static func writePrivate(_ data: Data, to url: URL) throws {
        guard SecretFile.write(data, to: url) else { throw APNsKeyError.writeFailed(url.path) }
    }
}
