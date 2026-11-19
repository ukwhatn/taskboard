import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("入力欄の @ の候補の口：GET /v1/conversations/{id}/workfiles", .serialized)
struct WorkFileRouteTests {
    private let token = "daemon-token"

    private func headers() -> HTTPFields { [.authorization: "Bearer \(token)"] }

    private func git(_ root: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func write(_ root: URL, _ path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    /// 会話の記録が作業ディレクトリ `cwd` を指す service を載せた app
    private func serve(cwd: String, _ body: @escaping @Sendable (any TestClientProtocol, String) async throws -> Void) async throws {
        let world = try await ServiceWorld.make()
        defer { world.pump.cancel() }
        let record = try world.store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: "s-\(UUID().uuidString)", cwd: cwd, runner: .none))
        var dependencies = APIServer.Dependencies()
        dependencies.store = world.store
        dependencies.conversations = world.service
        let app = APIServer.application(state: world.state, token: token, port: 0, dependencies: dependencies)
        try await app.test(.router) { client in try await body(client, record.id) }
    }

    private func files(_ client: some TestClientProtocol, _ id: String, _ query: String) async throws -> ConversationWorkFilesResponse {
        let response = try await client.execute(uri: "/v1/conversations/\(id)/workfiles?\(query)", method: .get, headers: headers())
        #expect(response.status == .ok)
        return try WireJSON.decoder().decode(ConversationWorkFilesResponse.self, from: response.body)
    }

    @Test("git の repo：打った文字に合うファイルを相対パスで返す。無視したファイル・.git・repo の外は出さず、パスの指定（..・絶対パス・cwd）は引く場所を変えない")
    func repoAndExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tb-wf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try write(repo, ".gitignore")
        try Data("secret.txt\nnode_modules/\n".utf8).write(to: repo.appending(path: ".gitignore"))
        try write(repo, "src/Chat.swift")
        try write(repo, "secret.txt")
        try write(repo, "node_modules/dep/index.js")
        try write(root, "outside.txt")
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "add", "-A")

        try await serve(cwd: repo.resolvingSymlinksInPath().path) { client, id in
            let found = try await files(client, id, "q=chat")
            #expect(found.files.map(\.path) == ["src/Chat.swift"] && !found.truncated)
            let all = try await files(client, id, "q=&limit=20").files.map(\.path)
            #expect(!all.contains("secret.txt") && !all.contains { $0.hasPrefix("node_modules") || $0.hasPrefix(".git/") })
            #expect(all.allSatisfy { !$0.hasPrefix("/") && !$0.contains("..") }, "返すのは cwd からの相対パスだけ")
            // 打った文字に .. や絶対パスを入れても、合うのは cwd の中の名前だけ（引く場所は変わらない）
            let parent = try await files(client, id, "q=../outside").files
            let absolute = try await files(client, id, "q=/etc/passwd").files
            #expect(parent.isEmpty && absolute.isEmpty)
            // 会話の記録の cwd が引く場所の全て。cwd・path の指定は受けない
            let forced = try await files(client, id, "q=outside&cwd=\(root.path)&path=\(root.path)")
            #expect(forced.files.isEmpty)
        }
    }

    @Test("repo でないフォルダ：歩いて返し、node_modules の下は入らない")
    func plainFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tb-wf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "docs/設計.md")
        try write(root, "node_modules/dep/設計.md")
        try await serve(cwd: root.resolvingSymlinksInPath().path) { client, id in
            let found = try await files(client, id, "q=設計").files.map(\.path)
            #expect(found == ["docs/設計.md"])
        }
    }

    @Test("入力の検証：q は 100 字まで、limit は 1〜20。知らない会話は 404")
    func validation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tb-wf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await serve(cwd: root.path) { client, id in
            func status(_ uri: String) async throws -> HTTPResponse.Status {
                try await client.execute(uri: uri, method: .get, headers: headers()).status
            }
            let base = "/v1/conversations/\(id)/workfiles"
            let limitZero = try await status("\(base)?q=a&limit=0")
            let limitOver = try await status("\(base)?q=a&limit=21")
            let queryOver = try await status("\(base)?q=\(String(repeating: "a", count: MentionTyping.maxQueryLength + 1))")
            let queryMax = try await status("\(base)?q=\(String(repeating: "a", count: MentionTyping.maxQueryLength))")
            let unknown = try await status("/v1/conversations/unknown/workfiles?q=a")
            let anonymous = try await client.execute(uri: "\(base)?q=a", method: .get).status
            #expect(limitZero == .badRequest && limitOver == .badRequest && queryOver == .badRequest)
            #expect(queryMax == .ok)
            #expect(unknown == .notFound)
            #expect(anonymous == .unauthorized)
        }
    }

    /// 測り（`TB_MEASURE_AT` に大きな repo かフォルダのパスがあるときだけ）。1 回目（一覧づくり）と 2 回目（控え）の @ の時間と、
    /// 同じ間に /v1/state を 5ms ごとに引いた応答時間（最大と 95 パーセンタイル）を 3 回出す。回ごとに新しい service（控えが空）
    @Test("測り：@ の 1 回目と 2 回目、その間の /v1/state の応答")
    func measure() async throws {
        guard let path = ProcessInfo.processInfo.environment["TB_MEASURE_AT"] else { return }
        for run in 1...3 {
            try await serve(cwd: path) { client, id in
                @Sendable func poll(until stop: @escaping @Sendable () -> Bool) async throws -> [Double] {
                    var samples: [Double] = []
                    while !stop() {
                        let started = ContinuousClock.now
                        let response = try await client.execute(uri: "/v1/state", method: .get, headers: headers())
                        #expect(response.status == .ok)
                        samples.append(Self.millis(since: started))
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    return samples
                }
                func summary(_ samples: [Double]) -> String {
                    let sorted = samples.sorted()
                    let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                    return String(format: "n=%d p50=%.1f p95=%.1f max=%.1f", sorted.count, sorted.isEmpty ? 0 : sorted[sorted.count / 2], p95, sorted.last ?? 0)
                }
                // 何も引かない間の /v1/state（基準）
                let idleStop = Stopper()
                let idle = Task { try await poll(until: { idleStop.stopped }) }
                try await Task.sleep(for: .milliseconds(500))
                idleStop.stop()
                let baseline = try await idle.value

                var lines: [String] = []
                for (label, query) in [("1回目", "q=file12"), ("2回目", "q=file1")] {
                    let stop = Stopper()
                    let polling = Task { try await poll(until: { stop.stopped }) }
                    try await Task.sleep(for: .milliseconds(50))
                    let started = ContinuousClock.now
                    let result = try await files(client, id, query)
                    let took = Self.millis(since: started)
                    stop.stop()
                    let during = try await polling.value
                    lines.append(String(format: "%@ @=%.1fms 件=%d truncated=%@ /v1/state[%@]", label, took, result.files.count, "\(result.truncated)", summary(during)))
                }
                print("MEASURE run=\(run) path=\(path) 基準 /v1/state[\(summary(baseline))] " + lines.joined(separator: " | "))
            }
        }
    }

    private static func millis(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private final class Stopper: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var stopped: Bool { lock.withLock { value } }
        func stop() { lock.withLock { value = true } }
    }
}
