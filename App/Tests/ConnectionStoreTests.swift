import Foundation
import Security
import TaskboardKit
import Testing
@testable import Taskboard

/// 接続先の資格情報の Keychain。本物の項目に触らないよう、テスト用の service 名で読み書きする
@Suite(.serialized) struct ConnectionStoreTests {
    private let service = "uk.whatn.taskboard.test.connection.\(UUID().uuidString)"
    private let publication = "uk.whatn.taskboard.test.publication.\(UUID().uuidString)"

    private func connection(_ name: String) -> SavedConnection {
        SavedConnection(
            id: UUID(), name: name, url: URL(string: "https://\(name).example.com")!, token: "t-\(name)",
            access: AccessCredential(clientID: "id", clientSecret: "secret"), pairedDeviceID: nil)
    }

    @Test("保存した接続先は名前の順で読め、消すと読めなくなる")
    func roundTrip() throws {
        let studio = connection("studio"), home = connection("home")
        defer { [studio, home].forEach { ConnectionStore.delete(id: $0.id, service: service) } }
        try ConnectionStore.save(studio, service: service)
        try ConnectionStore.save(home, service: service)
        #expect(ConnectionStore.load(service: service) == [home, studio])
        var renamed = studio
        renamed.name = "studio 2"
        try ConnectionStore.save(renamed, service: service)
        #expect(ConnectionStore.load(service: service).map(\.name) == ["home", "studio 2"])
        ConnectionStore.delete(id: home.id, service: service)
        #expect(ConnectionStore.load(service: service) == [renamed])
    }

    @Test("前の版が旧来の置き場に書いた項目も読める")
    func readsLegacyItem() throws {
        let legacy = connection("legacy")
        defer { ConnectionStore.delete(id: legacy.id, service: service) }
        // 前の版の書き方（kSecUseDataProtectionKeychain を付けない）
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: legacy.id.uuidString,
            kSecValueData as String: try JSONEncoder().encode(legacy), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(ConnectionStore.load(service: service) == [legacy])
        // 2 回目も同じ 1 件（写した後に元を消すか、写せなければ元のまま）
        #expect(ConnectionStore.load(service: service) == [legacy])
    }

    @Test("「この Mac」の公開 URL を保存して読める")
    func publicationRoundTrip() throws {
        defer {
            for realm in [true, false] {
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: publication]
                #if os(macOS)
                query[kSecUseDataProtectionKeychain as String] = realm
                #endif
                SecItemDelete(query as CFDictionary)
            }
        }
        #expect(ConnectionStore.loadPublication(service: publication) == nil)
        let endpoint = PublishedEndpoint(url: URL(string: "https://mac.example.com")!, access: nil)
        try ConnectionStore.savePublication(endpoint, service: publication)
        #expect(ConnectionStore.loadPublication(service: publication) == endpoint)
    }
}
