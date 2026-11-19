import Foundation
import OSLog
import Security
import TaskboardKit

/// 手で足したリモートの daemon。URL・token・Access の service token をまとめて Keychain に置く（UserDefaults には何も書かない）
struct SavedConnection: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var url: URL
    var token: String
    var access: AccessCredential?
    /// QR・コードで追加したときの、daemon の `device` の行 id。token は端末の token。daemon の token を手で入れた接続は nil
    var pairedDeviceID: String?

    var fleetID: String { "conn:\(id.uuidString)" }
    var endpoint: DaemonEndpoint { DaemonEndpoint(baseURL: url, token: token, access: access) }
}

/// 「この Mac」を iPhone・iPad から開くときの URL と Access。接続先の一覧には入れない（入れると同じ daemon への接続がもう 1 本できる）
struct PublishedEndpoint: Codable, Hashable, Sendable {
    var url: URL
    var access: AccessCredential?
}

/// Keychain の generic password に 1 接続 1 項目で持つ。account は接続の id、中身は JSON。
///
/// Mac では data protection keychain（`kSecUseDataProtectionKeychain`）に置く。旧来の file keychain は、アプリを作り直すたびに
/// 「Taskboard がキーチェーンの項目を使おうとしています」の確認を出していた。前の版が file keychain に書いた項目は、読めたときに
/// data protection 側へ写し、読み直して同じ値が取れたときだけ元を消す。ad hoc 署名のビルド（test host）は data protection 側を使えない
/// （errSecMissingEntitlement）ので、旧来の側だけで動く
enum ConnectionStore {
    static let service = "uk.whatn.taskboard.connection"
    static let publicationService = "uk.whatn.taskboard.publication"
    private static let logger = Logger(subsystem: "uk.whatn.taskboard", category: "keychain")

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status): String(localized: "Keychainに書き込めません（\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))）")
            }
        }
    }

    /// 項目の置き場。`modern` は data protection keychain、`legacy` は旧来の file keychain（iOS では同じもの）
    enum Realm: CaseIterable {
        case modern, legacy

        func apply(to query: inout [String: Any]) {
            #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] = self == .modern
            #endif
        }
    }

    /// data protection 側が使えないビルド（ad hoc 署名）では旧来の側だけを使う。最初の問い合わせの結果を覚える
    nonisolated(unsafe) private static var modernUnavailable = false

    static func load(service: String = service) -> [SavedConnection] {
        // 新しい側を使えないビルドでは、書くのも読むのも旧来の側だけ
        if modernUnavailable {
            return (listAccounts(service: service, realm: .legacy) ?? [])
                .compactMap { read(service: service, account: $0, realm: .legacy) as SavedConnection? }
                .sorted { $0.name < $1.name }
        }
        let accounts = listAccounts(service: service, realm: .modern) ?? []
        var connections: [SavedConnection] = accounts.compactMap { read(service: service, account: $0, realm: .modern) }
        // 前の版が旧来の側に書いた項目を写す。新しい側に同じ account があれば、新しい側を正とする
        let known = Set(connections.map(\.id.uuidString))
        for account in (listAccounts(service: service, realm: .legacy) ?? []) where !known.contains(account) {
            if let connection: SavedConnection = read(service: service, account: account, realm: .legacy) {
                connections.append(connection)
                migrate(connection, service: service, account: account, label: "Taskboard: \(connection.name)")
            }
        }
        return connections.sorted { $0.name < $1.name }
    }

    static func loadPublication(service: String = publicationService) -> PublishedEndpoint? {
        value(service: service, account: "local", label: "Taskboard: このMacの公開URL")
    }

    static func savePublication(_ endpoint: PublishedEndpoint, service: String = publicationService) throws {
        try setValue(endpoint, service: service, account: "local", label: "Taskboard: このMacの公開URL")
    }

    /// 接続先の一覧と別の service に置く 1 件の値（公開 URL・ブラウザの資格情報）。前の版が旧来の側に書いた値は読めたときに写す
    static func value<T: Codable & Equatable>(service: String, account: String, label: String) -> T? {
        if modernUnavailable { return read(service: service, account: account, realm: .legacy) }
        if let modern: T = read(service: service, account: account, realm: .modern) { return modern }
        guard let legacy: T = read(service: service, account: account, realm: .legacy) else { return nil }
        migrate(legacy, service: service, account: account, label: label)
        return legacy
    }

    static func setValue<T: Encodable>(_ value: T, service: String, account: String, label: String) throws {
        try write(value, service: service, account: account, label: label)
    }

    static func removeValue(service: String, account: String) {
        for realm in Realm.allCases { delete(service: service, account: account, realm: realm) }
    }

    static func save(_ connection: SavedConnection, service: String = service) throws {
        try write(connection, service: service, account: connection.id.uuidString, label: "Taskboard: \(connection.name)")
    }

    static func delete(id: UUID, service: String = service) {
        removeValue(service: service, account: id.uuidString)
    }

    // MARK: 読み書き

    /// macOS の Keychain は「全件 + 中身」の問い合わせを errSecParam で断る（実測）ので、属性で全件を引いてから 1 件ずつ中身を読む。
    /// nil は問い合わせ自体が通らなかったとき（data protection 側が使えないなど）
    private static func listAccounts(service: String, realm: Realm) -> [String]? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        realm.apply(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            note(status, realm: realm)
            return nil
        }
    }

    private static func read<T: Decodable>(service: String, account: String, realm: Realm) -> T? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true,
        ]
        realm.apply(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { note(status, realm: realm) }
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, service: String, account: String, label: String) throws {
        let realm: Realm = modernUnavailable ? .legacy : .modern
        do {
            try write(value, service: service, account: account, label: label, realm: realm)
        } catch Failure.keychain(errSecMissingEntitlement) where realm == .modern {
            modernUnavailable = true
            try write(value, service: service, account: account, label: label, realm: .legacy)
        }
    }

    private static func write<T: Encodable>(_ value: T, service: String, account: String, label: String, realm: Realm) throws {
        let data = try JSONEncoder().encode(value)
        var match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        realm.apply(to: &match)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = label
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw Failure.keychain(status)
        }
    }

    private static func delete(service: String, account: String, realm: Realm) {
        var match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        realm.apply(to: &match)
        SecItemDelete(match as CFDictionary)
    }

    /// 旧来の側の項目を data protection 側へ写す。書けて、読み直して同じ値が取れたときだけ元を消す（失敗はログに出すだけで、その回は旧来の値で動く）
    private static func migrate<T: Codable & Equatable>(_ value: T, service: String, account: String, label: String) {
        #if os(macOS)
        do {
            try write(value, service: service, account: account, label: label, realm: .modern)
        } catch Failure.keychain(let status) {
            note(status, realm: .modern)
            if status == errSecMissingEntitlement { modernUnavailable = true }
            return
        } catch {
            return
        }
        guard let copied: T = read(service: service, account: account, realm: .modern), copied == value else {
            logger.warning("keychain item was written but could not be read back; keeping the legacy item (\(service, privacy: .public)/\(account, privacy: .public))")
            return
        }
        delete(service: service, account: account, realm: .legacy)
        #endif
    }

    private static func note(_ status: OSStatus, realm: Realm) {
        if realm == .modern, status == errSecMissingEntitlement { modernUnavailable = true }
        logger.warning("keychain query failed: \(status) (\(realm == .modern ? "data protection" : "legacy", privacy: .public))")
    }
}
