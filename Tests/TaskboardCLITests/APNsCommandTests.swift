import ArgumentParser
import CryptoKit
import Foundation
import TaskboardDaemon
import Testing

@testable import taskboard

@Suite("taskboard apns: 鍵の置き場")
struct APNsCommandTests {
    private func tempStore() throws -> APNsKeyStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-apns-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return APNsKeyStore(directory: dir.appending(path: "apns"))
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @Test("install は鍵と設定を 600、置き場を 700 で置き、出力に鍵の中身を出さない")
    func install() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let lines = try APNs.Install.install(pem: pem, keyID: "ABCDE12345", teamID: "TEAM123456", environment: .sandbox, store: store)
        #expect(lines == ["鍵を入れた: \(store.directory.path)", "Key ID: ABCDE12345", "Team ID: TEAM123456", "環境: sandbox"])
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        #expect(!lines.joined().contains(String(body.prefix(16))))
        #expect(try permissions(store.keyFile) == 0o600)
        #expect(try permissions(store.configFile) == 0o600)
        #expect(try permissions(store.directory) == 0o700)
        #expect(try String(contentsOf: store.keyFile, encoding: .utf8) == pem)
        let config = try JSONDecoder().decode(APNsConfig.self, from: Data(contentsOf: store.configFile))
        #expect(config == APNsConfig(keyID: "ABCDE12345", teamID: "TEAM123456", environment: .sandbox))
        #expect(try store.load()?.key.publicKey.rawRepresentation == P256.Signing.PrivateKey(pemRepresentation: pem).publicKey.rawRepresentation)

        // 入れ直しても権限は 600 のまま。環境を省けば端末が登録した環境
        _ = try APNs.Install.install(pem: pem, keyID: "ABCDE12345", teamID: "TEAM123456", environment: nil, store: store)
        #expect(try permissions(store.keyFile) == 0o600)
        #expect(try APNs.Status.lines(store: store) == [
            "鍵が入っている: \(store.directory.path)", "Key ID: ABCDE12345", "Team ID: TEAM123456", "環境: 端末が登録した環境", "鍵のファイルの権限: 600",
        ])
    }

    @Test("読めない鍵・形の違う Key ID と Team ID は断り、何も書かない")
    func rejects() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let cases: [(String, String, String, String)] = [
            ("-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----\n", "ABCDE12345", "TEAM123456", "P-256"),
            (pem, "SHORT", "TEAM123456", "Key ID"),
            (pem, "ABCDE12345", "TEAM12345!", "Team ID"),
            (pem, "ABCDE12345あ", "TEAM123456", "Key ID"),
        ]
        for (key, keyID, teamID, word) in cases {
            #expect {
                try APNs.Install.install(pem: key, keyID: keyID, teamID: teamID, environment: nil, store: store)
            } throws: { error in
                (error as? ValidationError)?.message.contains(word) == true && !"\(error)".contains("not a key")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: store.keyFile.path))
        #expect(try APNs.Status.lines(store: store) == ["鍵は入っていない: \(store.directory.path)"])
    }

    @Test("remove は鍵と設定を消す。無ければ false")
    func remove() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        _ = try APNs.Install.install(pem: P256.Signing.PrivateKey().pemRepresentation, keyID: "ABCDE12345", teamID: "TEAM123456", environment: nil, store: store)
        #expect(try store.remove())
        #expect(!FileManager.default.fileExists(atPath: store.keyFile.path))
        #expect(!FileManager.default.fileExists(atPath: store.configFile.path))
        #expect(try !store.remove())
        #expect(try store.load() == nil)
    }

    @Test("引数: --key-file - と --environment を読む")
    func parse() throws {
        let command = try APNs.Install.parse(["--key-file", "-", "--key-id", "ABCDE12345", "--team-id", "TEAM123456", "--environment", "production"])
        #expect(command.keyFile == "-")
        #expect(command.environment == .production)
        #expect(throws: (any Error).self) { try APNs.Install.parse(["--key-file", "-", "--key-id", "A", "--team-id", "B", "--environment", "staging"]) }
    }
}
