import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("会話の画像とファイルの保存")
struct AttachmentRoutesTests {
    private let machine = MachineID(rawValue: "m-attach")
    private let daemonToken = "daemon-token"
    /// PNG の先頭 8 バイトと、中身の代わりのバイト（daemon は先頭だけで種類を決める）
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 100)

    private struct Fixture {
        let world: ServiceWorld
        let conversation: String
        let dependencies: APIServer.Dependencies
        let root: URL
        var state: DaemonState { world.state }
        var attachments: URL { root.appending(path: "attachments", directoryHint: .isDirectory) }

        func remove() {
            world.cleanUp()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let world = try await ServiceWorld.make()
        let conversation = try await world.service.start(world.request())
        let root = FileManager.default.temporaryDirectory.appending(path: "attach-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var dependencies = APIServer.Dependencies()
        dependencies.store = world.store
        dependencies.conversations = world.service
        dependencies.attachments = AttachmentStore(directory: root.appending(path: "attachments", directoryHint: .isDirectory))
        try world.store.insertDevice(DeviceInfo(id: "d1", name: "iPhone", platform: .ios, createdAt: Date()), tokenHash: DeviceAuth.hash(token: "token-d1"))
        await dependencies.deviceAuth.load(try world.store.devices())
        return Fixture(world: world, conversation: conversation.id, dependencies: dependencies, root: root)
    }

    private func app(_ fixture: Fixture) -> APIServer.App {
        APIServer.application(state: fixture.state, token: daemonToken, port: 0, dependencies: fixture.dependencies)
    }

    private func headers(_ token: String, type: String = "image/png") -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: type]
    }

    private func upload(_ client: some TestClientProtocol, _ f: Fixture, conversation: String? = nil, _ data: Data, token: String = "token-d1") async throws
        -> TestResponse
    {
        try await client.execute(
            uri: "/v1/conversations/\(conversation ?? f.conversation)/attachments", method: .post, headers: headers(token), body: ByteBuffer(bytes: data))
    }

    private func code(_ response: TestResponse) throws -> DaemonRejection.Body.Inner {
        try WireJSON.decoder().decode(DaemonRejection.Body.self, from: response.body).error
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    // MARK: 保存

    @Test("端末の token で画像を置ける。attachments/ は 700、ファイルは 600 で、種類は先頭のバイトで決める")
    func saves() async throws {
        let f = try await makeFixture()
        defer { f.remove() }
        try await app(f).test(.router) { client in
            // Content-Type が違っても、中身が PNG なら png で置く
            let response = try await client.execute(
                uri: "/v1/conversations/\(f.conversation)/attachments", method: .post, headers: headers("token-d1", type: "application/octet-stream"),
                body: ByteBuffer(bytes: png))
            #expect(response.status == .ok)
            let saved = try WireJSON.decoder().decode(AttachmentUploadResponse.self, from: response.body)
            #expect(saved.id.hasSuffix(".png"))
            #expect(saved.path == f.attachments.appending(path: saved.id).path)
            #expect(FileManager.default.contents(atPath: saved.path) == png)
            #expect(try permissions(URL(fileURLWithPath: saved.path)) == 0o600)
            #expect(try permissions(f.attachments) == 0o700)

            let byDaemon = try await upload(client, f, Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]), token: daemonToken)
            #expect(byDaemon.status == .ok)
            #expect(try WireJSON.decoder().decode(AttachmentUploadResponse.self, from: byDaemon.body).id.hasSuffix(".jpg"))
        }
    }

    @Test("画像でないものは 415、空は 400、上限を超えたら 413 で、どれも置かない")
    func rejectsContent() async throws {
        let f = try await makeFixture()
        defer { f.remove() }
        try await app(f).test(.router) { client in
            let text = try await upload(client, f, Data("画像ではありません".utf8))
            #expect(text.status == .unsupportedMediaType)
            #expect(try code(text).code == DaemonErrorCode.attachmentUnsupported.rawValue)
            let tiff = try await upload(client, f, Data("MM\u{0}*".utf8) + Data(repeating: 0, count: 20))
            #expect(try code(tiff).code == DaemonErrorCode.attachmentUnsupported.rawValue)

            let empty = try await upload(client, f, Data())
            #expect(empty.status == .badRequest)

            let large = try await upload(client, f, png + Data(repeating: 0, count: ChatAttachment.maxBytes))
            #expect(large.status == .contentTooLarge)
            let body = try code(large)
            #expect(body.code == DaemonErrorCode.attachmentTooLarge.rawValue)
            #expect(body.params == ["limit": "5"])

            let exact = try await upload(client, f, png + Data(repeating: 0, count: ChatAttachment.maxBytes - png.count))
            #expect(exact.status == .ok)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: f.attachments.path)
        #expect(files.count == 1)
    }

    @Test("知らない会話には 404 で、何も置かない")
    func rejectsUnknownConversation() async throws {
        let f = try await makeFixture()
        defer { f.remove() }
        try await app(f).test(.router) { client in
            let response = try await upload(client, f, conversation: "00000000-0000-4000-8000-000000000000", png)
            #expect(response.status == .notFound)
        }
        #expect(!FileManager.default.fileExists(atPath: f.attachments.path))
    }

    @Test("置き場が無ければ 503")
    func unavailableWithoutStore() async throws {
        let f = try await makeFixture()
        defer { f.remove() }
        var dependencies = f.dependencies
        dependencies.attachments = nil
        let app = APIServer.application(state: f.state, token: daemonToken, port: 0, dependencies: dependencies)
        try await app.test(.router) { client in
            let response = try await upload(client, f, png)
            #expect(response.status == .serviceUnavailable)
        }
    }

    // MARK: 古いファイル

    @Test("保存日数を過ぎたファイルを消す。形の違う名前のファイルには触らない")
    func purgesOldFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "attach-purge-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 保存のたびに古いファイルを消すので、「今」はファイルの実際の変更時刻に揃える（未来に置くと、作ったばかりのファイルが消える）
        let now = Date()
        let store = AttachmentStore(directory: directory, now: { now })
        let old = try store.save(png)
        let fresh = try store.save(png)
        let other = directory.appending(path: "memo.txt")
        try Data("残す".utf8).write(to: other)
        let past = now.addingTimeInterval(-ChatAttachment.retention - 60)
        for path in [old.path, other.path] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)
        }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ChatAttachment.retention + 60)], ofItemAtPath: fresh.path)

        #expect(store.purge() == 1)
        #expect(store.file(id: old.id) == nil)
        #expect(store.file(id: fresh.id) != nil)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("画像でないファイルは files/<UUID>/<名前> に置き（ディレクトリは 700、ファイルは 600）、名前のディレクトリの部分と頭の . は外す。上限を超えたら置かない。保存日数を過ぎたら消す")
    func savesFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "attach-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let store = AttachmentStore(directory: directory, now: { now })
        let saved = try store.saveFile(Data("中身".utf8), name: "見積 v2.pdf")
        let url = URL(fileURLWithPath: saved.path)
        #expect(url.lastPathComponent == "見積 v2.pdf" && url.deletingLastPathComponent().lastPathComponent == saved.id)
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().path == directory.appending(path: "files").path)
        #expect(try Data(contentsOf: url) == Data("中身".utf8))
        #expect(try permissions(url) == 0o600 && permissions(url.deletingLastPathComponent()) == 0o700)
        #expect(URL(fileURLWithPath: try store.saveFile(Data("x".utf8), name: "../../etc/.passwd").path).lastPathComponent == "passwd")
        #expect(URL(fileURLWithPath: try store.saveFile(Data("x".utf8), name: "..").path).lastPathComponent == "file")
        #expect(throws: AttachmentStoreError.tooLarge) { try store.saveFile(Data(count: ChatAttachment.maxFileBytes + 1), name: "big.bin") }

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ChatAttachment.retention - 60)], ofItemAtPath: url.deletingLastPathComponent().path)
        #expect(store.purge() == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("id は小文字の UUID と送れる形式の拡張子だけ")
    func validIDs() {
        let uuid = UUID().uuidString.lowercased()
        #expect(AttachmentStore.isValidID("\(uuid).png"))
        #expect(AttachmentStore.isValidID("\(uuid).jpg"))
        #expect(AttachmentStore.isValidID("\(uuid).webp"))
        #expect(!AttachmentStore.isValidID("\(uuid).jpeg"))
        #expect(!AttachmentStore.isValidID("\(uuid).png.png"))
        #expect(!AttachmentStore.isValidID("\(uuid.uppercased()).png"))
        #expect(!AttachmentStore.isValidID("../\(uuid).png"))
        #expect(!AttachmentStore.isValidID("token"))
        #expect(!AttachmentStore.isValidID(""))
    }
}
