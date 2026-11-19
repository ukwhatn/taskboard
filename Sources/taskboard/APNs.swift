import ArgumentParser
import Foundation
import TaskboardDaemon
import TaskboardKit

/// `taskboard apns`: iPhone・iPad への通知（APNs）の鍵の置き場。鍵の中身は出力・ログ・引数に出さない
struct APNs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apns",
        abstract: "APNs の鍵を入れる・確かめる（iPhone・iPad への通知）",
        subcommands: [Install.self, Status.self, Remove.self, Check.self, Test.self]
    )

    struct SupportOption: ParsableArguments {
        @Option(name: .long, help: "token と machine-id を置くディレクトリ（鍵はその下の apns/）")
        var supportDir: String?

        func store() throws -> APNsKeyStore {
            let paths = try Paths(directory: supportDir.map { URL(fileURLWithPath: $0, isDirectory: true) })
            return APNsKeyStore(directory: paths.apnsDirectory)
        }
    }

    static func describe(_ config: APNsConfig) -> [String] {
        ["Key ID: \(config.keyID)", "Team ID: \(config.teamID)", "環境: \(config.environment?.rawValue ?? "端末が登録した環境")"]
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "鍵（.p8）を apns/ に権限 600 で写し、Key ID・Team ID・環境を apns.json に書く")

        @Option(name: .long, help: "鍵のファイル。- なら標準入力から読む")
        var keyFile: String
        @Option(name: .long, help: "Key ID（英数 10 字）")
        var keyID: String
        @Option(name: .long, help: "Team ID（英数 10 字）")
        var teamID: String
        @Option(name: .long, help: "この環境の端末だけに送る（sandbox / production）。省くと端末が登録した環境に送る")
        var environment: PushEnvironment?
        @OptionGroup var support: SupportOption

        func run() async throws {
            let pem: String
            if keyFile == "-" {
                pem = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            } else {
                guard let data = FileManager.default.contents(atPath: keyFile) else { throw ValidationError("\(keyFile) を読めない") }
                pem = String(decoding: data, as: UTF8.self)
            }
            for line in try Self.install(pem: pem, keyID: keyID, teamID: teamID, environment: environment, store: try support.store()) {
                print(line)
            }
        }

        static func install(pem: String, keyID: String, teamID: String, environment: PushEnvironment?, store: APNsKeyStore) throws -> [String] {
            do {
                let config = try store.install(keyPEM: pem, keyID: keyID, teamID: teamID, environment: environment)
                return ["鍵を入れた: \(store.directory.path)"] + APNs.describe(config)
            } catch let error as APNsKeyError {
                throw ValidationError(error.description)
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "鍵が入っているか、Key ID・Team ID・環境、鍵のファイルの権限を出す（中身は出さない）")
        @OptionGroup var support: SupportOption

        func run() async throws {
            for line in try Self.lines(store: try support.store()) { print(line) }
        }

        static func lines(store: APNsKeyStore) throws -> [String] {
            do {
                guard let status = try store.status() else { return ["鍵は入っていない: \(store.directory.path)"] }
                return ["鍵が入っている: \(store.directory.path)"] + APNs.describe(status.config) + ["鍵のファイルの権限: \(status.keyPermissions)"]
            } catch let error as APNsKeyError {
                throw ValidationError(error.description)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "鍵と設定を消す")
        @OptionGroup var support: SupportOption

        func run() async throws {
            let store = try support.store()
            print(try store.remove() ? "鍵を消した: \(store.directory.path)" : "鍵は入っていない: \(store.directory.path)")
        }
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "鍵で JWT を作り、sandbox と production に存在しないトークンで 1 回ずつ送って APNs の答えを出す（端末の要らない確かめ方）",
            discussion: "鍵が正しければ 400 BadDeviceToken、鍵か Key ID・Team ID が違えば 403 InvalidProviderToken が返る")
        @Option(name: .long, help: "apns-topic（アプリの bundle ID）")
        var topic = "uk.whatn.taskboard.ios"
        @OptionGroup var support: SupportOption

        func run() async throws {
            let store = try support.store()
            guard try store.status() != nil else { throw ValidationError("鍵は入っていない: \(store.directory.path)") }
            let sender = APNsSender(keys: store)
            for environment in PushEnvironment.allCases {
                let result = await sender.probe(topic: topic, environment: environment)
                print(Self.line(environment: environment, result: result))
            }
        }

        static func line(environment: PushEnvironment, result: APNsResult) -> String {
            "\(environment.rawValue): \(result.status.map(String.init) ?? "-") \(result.reason ?? "")（\(result.protocolName ?? "版は不明")）"
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "動いている daemon から、登録のある全端末にテストの通知を送る")
        @OptionGroup var common: CommonOptions

        func run() async throws {
            let endpoint = try Daemon.localEndpoint(port: common.port, supportDirectory: common.supportDirectoryURL)
            let results = try await DaemonClient(endpoint: endpoint).testPush()
            if results.isEmpty { print("通知の登録のある端末が無い") }
            for result in results {
                print("\(result.deviceName)（\(result.deviceID)）: \(result.status.map(String.init) ?? "-") \(result.reason ?? "")")
            }
        }
    }
}

extension PushEnvironment: ExpressibleByArgument {}
