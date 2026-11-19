import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

// transcript の行は Claude Code 2.1.29x の実物と同じ鍵の並び（type → message → uuid → toolUseResult）で組む。
// 画像の行で、uuid が行の中ほどにあり先頭にも末尾にも無いことを、大きい行の読み方が前提にしている
private func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), as: UTF8.self)
}

private func call(_ uuid: String, id: String, name: String, input: [String: Any]) -> String {
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(json(input))}]},"uuid":"\#(uuid)","timestamp":"2026-10-06T08:00:00.000Z"}"#
}

/// 結果の行。`content` は tool_result の中身（文字列か block の配列）、`result` は行の上位の toolUseResult
private func result(_ uuid: String, id: String, content: Any, result: Any) -> String {
    let block = #"{"tool_use_id":"\#(id)","type":"tool_result","content":\#(json(content))}"#
    return #"{"type":"user","message":{"role":"user","content":[\#(block)]},"uuid":"\#(uuid)","timestamp":"2026-10-06T08:00:01.000Z","toolUseResult":\#(json(result)),"sessionId":"s"}"#
}

private var hunk: [String: Any] { ["oldStart": 3, "oldLines": 3, "newStart": 3, "newLines": 4, "lines": [" let a = 1", "-let b = 2", "+let b = 3", "+let c = 4", " let d = 5"]] }

private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 1, count: 24)

/// 画像の Read の結果の行。辞書から組むと鍵が並べ替わるので、実物の並びのまま文字で組む
private func imageLine(_ uuid: String, id: String, base64: String) -> String {
    let block = #"{"tool_use_id":"\#(id)","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"\#(base64)","media_type":"image/png"}}]}"#
    let file = #"{"base64":"\#(base64)","type":"image/png","originalSize":1027536,"dimensions":{"originalWidth":3600,"originalHeight":2300,"displayWidth":2000,"displayHeight":1278}}"#
    return #"{"type":"user","message":{"role":"user","content":[\#(block)]},"uuid":"\#(uuid)","timestamp":"2026-10-06T08:00:01.000Z","toolUseResult":{"type":"image","file":\#(file)},"sessionId":"s"}"#
}

/// 画像を添えた人の発言の行。実物（2.1.29x）と同じに、本文と画像が先、uuid・時刻・貼った画像の番号が後ろ
private func humanImageLine(_ uuid: String, text: String, images: [String], meta: Bool = false) -> String {
    let blocks = [#"{"type":"text","text":\#(json(text))}"#] + images.map { #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#($0)"}}"# }
    let pasted = (1...images.count).map(String.init).joined(separator: ",")
    return #"{"parentUuid":"p0","isSidechain":false,"promptId":"pr1","type":"user","message":{"role":"user","content":[\#(blocks.joined(separator: ","))]},"uuid":"\#(uuid)","timestamp":"2026-10-06T08:00:02.000Z","imagePasteIds":[\#(pasted)]\#(meta ? #","isMeta":true"# : ""),"permissionMode":"default"}"#
}

/// ターンの途中に取り込まれた、画像を添えた発言（`attachment` の `queued_command`）
private func queuedImageLine(_ source: String, base64: String) -> String {
    #"{"type":"attachment","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"これも"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(base64)"}}],"source_uuid":"\#(source)","commandMode":"prompt","origin":{"kind":"human"}},"uuid":"line-\#(source)","timestamp":"2026-10-06T08:00:03.000Z"}"#
}

/// 1 行ずつ流し、結果の行のメッセージとその行の頭の位置を返す
private func feed(_ lines: [String], chunk: Int = .max) -> (messages: [ChatMessage], starts: [UInt64]) {
    var cursor = TranscriptCursor()
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    var out: [ChatMessage] = []
    var offset = 0
    while offset < data.count {
        let end = min(offset + chunk, data.count)
        out += cursor.feed(data[offset..<end])
        offset = end
    }
    var starts: [UInt64] = []
    var position: UInt64 = 0
    for line in lines {
        starts.append(position)
        position += UInt64(line.utf8.count + 1)
    }
    return (out, starts)
}

@Suite("transcript の行からファイルの情報を取る")
struct TranscriptFilesParserTests {
    @Test("Read の文は、パス・読んだ範囲・全体の行の数。中身の全文は載せない")
    func readText() throws {
        let lines = [
            call("a1", id: "t1", name: "Read", input: ["file_path": "/repo/Sources/App.swift", "offset": 10, "limit": 3]),
            result(
                "u1", id: "t1", content: "10\tlet a = 1\n11\tlet b = 2\n12\tlet c = 3",
                result: ["type": "text", "file": ["filePath": "/repo/Sources/App.swift", "content": "let a = 1\nlet b = 2\nlet c = 3", "numLines": 3, "startLine": 10, "totalLines": 50]]),
        ]
        let (messages, starts) = feed(lines)
        let file = try #require(messages.last?.files?.first)
        #expect(messages.last?.files?.count == 1 && messages.last?.toolID == "t1")
        #expect(file == ChatFile(path: "/repo/Sources/App.swift", action: .read, firstLine: 10, lineCount: 3, totalLines: 50, offset: starts[1]))
        #expect(messages.first?.files == nil, "呼び出しの行には載せない")
    }

    @Test("Read の画像は、結果にパスが無いので呼び出しの file_path を使う。種類・元の大きさ・元の幅と高さ")
    func readImage() throws {
        let lines = [
            call("a1", id: "t2", name: "Read", input: ["file_path": "/Users/me/Desktop/画面 1.png"]),
            imageLine("u1", id: "t2", base64: pngBytes.base64EncodedString()),
        ]
        let (messages, starts) = feed(lines)
        let file = try #require(messages.last?.files?.first)
        #expect(file == ChatFile(path: "/Users/me/Desktop/画面 1.png", action: .image, mediaType: "image/png", bytes: 1_027_536, width: 3600, height: 2300, offset: starts[1]))
    }

    @Test("Write の新規は書いた行の数を足した数にする。diff は持たない（structuredPatch が空）")
    func writeCreate() throws {
        let content = "# 見出し\n\n本文の 1 行目\n本文の 2 行目\n"
        let lines = [
            call("a1", id: "t3", name: "Write", input: ["file_path": "/repo/docs/新しい.md", "content": content]),
            result(
                "u1", id: "t3", content: "File created successfully at: /repo/docs/新しい.md",
                result: ["type": "create", "filePath": "/repo/docs/新しい.md", "content": content, "structuredPatch": [], "originalFile": NSNull(), "userModified": false]),
        ]
        let file = try #require(feed(lines).messages.last?.files?.first)
        #expect(file.action == .created && file.path == "/repo/docs/新しい.md")
        #expect(file.added == 4 && file.removed == 0 && file.hunks.isEmpty && !file.hunksOmitted)
    }

    @Test("Write の上書きと Edit は structuredPatch の hunk と、足した・消した行の数")
    func writeUpdateAndEdit() throws {
        let update = result(
            "u1", id: "t4", content: "The file /repo/a.swift has been updated.",
            result: ["type": "update", "filePath": "/repo/a.swift", "content": "…", "structuredPatch": [hunk], "originalFile": "…", "userModified": false])
        let edit = result(
            "u2", id: "t5", content: "The file /repo/b.swift has been updated.",
            result: [
                "filePath": "/repo/b.swift", "oldString": "let b = 2", "newString": "let b = 3\nlet c = 4", "originalFile": "…", "structuredPatch": [hunk],
                "userModified": false, "replaceAll": false,
            ])
        let (messages, starts) = feed([update, edit])
        let expected = ChatDiffHunk(oldStart: 3, oldLines: 3, newStart: 3, newLines: 4, lines: hunk["lines"] as! [String])
        #expect(messages[0].files == [ChatFile(path: "/repo/a.swift", action: .edited, hunks: [expected], added: 2, removed: 1, offset: starts[0])])
        #expect(messages[1].files == [ChatFile(path: "/repo/b.swift", action: .edited, hunks: [expected], added: 2, removed: 1, offset: starts[1])])
    }

    @Test("Bash の bashEditDiff は変えたファイルごとに 1 つ。diff の無い Bash と拒否の文字列はファイルの情報を持たない")
    func bash() throws {
        let edited = result(
            "u1", id: "t6", content: "",
            result: [
                "stdout": "", "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": false,
                "bashEditDiff": ["files": [["filePath": "/repo/a.txt", "hunks": [hunk]], ["filePath": "/repo/b.txt", "hunks": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 0, "lines": ["-消した行"]]]]]],
            ])
        let plain = result("u2", id: "t7", content: "ok", result: ["stdout": "ok", "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": false])
        let rejected = result("u3", id: "t8", content: "User rejected tool use", result: "User rejected tool use")
        let messages = feed([edited, plain, rejected]).messages
        #expect(messages[0].files?.map(\.path) == ["/repo/a.txt", "/repo/b.txt"])
        #expect(messages[0].files?.map { "\($0.added)/\($0.removed)" } == ["2/1", "0/1"])
        #expect(messages[0].files?.allSatisfy { $0.action == .edited } == true)
        #expect(messages[1].files == nil && messages[2].files == nil)
    }

    @Test("32KB を超える diff は載せず、行の数だけを残して口から取らせる")
    func largeDiff() throws {
        let lines = (0..<2000).map { "+追加した行 \($0) の文" }
        let big = result(
            "u1", id: "t9", content: "ok",
            result: ["filePath": "/repo/big.txt", "structuredPatch": [["oldStart": 0, "oldLines": 0, "newStart": 1, "newLines": 2000, "lines": lines]], "originalFile": ""])
        let file = try #require(feed([big]).messages.first?.files?.first)
        #expect(file.hunksOmitted && file.hunks.isEmpty && file.added == 2000)
    }

    @Test("1MB を超える画像の Read の行は、先頭と末尾から呼び出しの id・種類・大きさを取り、パスは呼び出しから。読み取りの境目で切れても同じ")
    func largeImage() throws {
        let base64 = String(repeating: "QUFB", count: 200_000)  // 800,000 バイトが 2 つで行は 1.6MB
        let lines = [call("a1", id: "toolu_01Big", name: "Read", input: ["file_path": "/repo/shot.png"]), imageLine("u1", id: "toolu_01Big", base64: base64)]
        for chunk in [Int.max, 300_007, 4_000] {
            let (messages, starts) = feed(lines, chunk: chunk)
            let message = try #require(messages.last)
            #expect(message.kind == .toolResult && message.toolID == "toolu_01Big" && message.id.hasPrefix("large-"), "\(chunk)")
            #expect(
                message.files == [ChatFile(path: "/repo/shot.png", action: .image, mediaType: "image/png", bytes: 1_027_536, width: 3600, height: 2300, offset: starts[1])],
                "\(chunk)")
        }
    }

    @Test("1MB を超える Read の文の行は、読んだことと呼び出しのパスだけ。tool_result でない大きい行は今までどおりの印")
    func largeTextAndOther() throws {
        let text = String(repeating: "あ", count: 400_000)
        let lines = [
            call("a1", id: "t10", name: "Read", input: ["file_path": "/repo/huge.log"]),
            result("u1", id: "t10", content: text, result: ["type": "text", "file": ["filePath": "/repo/huge.log", "content": text, "numLines": 1, "startLine": 1, "totalLines": 1]]),
            #"{"type":"user","message":{"role":"user","content":"\#(String(repeating: "x", count: 1_100_000))"},"uuid":"u2"}"#,
        ]
        let (messages, starts) = feed(lines, chunk: 500_000)
        #expect(messages[1].files == [ChatFile(path: "/repo/huge.log", action: .read, offset: starts[1])])
        #expect(messages[2].kind == .notice && messages[2].toolID == nil && messages[2].files == nil)
    }

    @Test("1MB を超える、画像を添えた人の発言の行は、先頭の本文と末尾の uuid・時刻・画像の数から発言を作る。読み取りの境目で切れても同じ。差し込まれた行は今までどおりの印")
    func largeHumanImages() throws {
        let base64 = String(repeating: "QUFB", count: 200_000)
        let text = "この\"画面\"を直して\n2行目"
        let uuid = "c1a2b3c4-0000-4000-8000-000000000001"
        let lines = [humanImageLine(uuid, text: text, images: [base64, base64]), humanImageLine("c1a2b3c4-0000-4000-8000-000000000002", text: "差し込み", images: [base64, base64], meta: true)]
        for chunk in [Int.max, 300_007, 4_000] {
            let (messages, starts) = feed(lines, chunk: chunk)
            let message = try #require(messages.first)
            #expect(message.id == "\(uuid)#0" && message.kind == .text && message.role == .user && message.text == text, "\(chunk)")
            #expect(message.images == [ChatImage(index: 0, offset: starts[0]), ChatImage(index: 1, offset: starts[0])], "\(chunk)")
            #expect(message.at == ISO8601DateFormatter().date(from: "2026-10-06T08:00:02Z"), "\(chunk)")
            #expect(messages.count == 2 && messages[1].kind == .notice && messages[1].images == nil, "\(chunk)")
        }
    }

    @Test("行の頭の位置は、途中から読み始めた cursor でもファイルの中の位置で数える")
    func offsets() throws {
        let first = result("u1", id: "t1", content: "a", result: ["type": "create", "filePath": "/repo/a", "content": "a", "structuredPatch": []])
        let second = result("u2", id: "t2", content: "b", result: ["type": "create", "filePath": "/repo/b", "content": "b", "structuredPatch": []])
        var cursor = TranscriptCursor(offset: 1_000)
        let messages = cursor.feed(Data((first + "\n" + second + "\n").utf8))
        #expect(messages.compactMap { $0.files?.first?.offset } == [1_000, 1_000 + UInt64(first.utf8.count) + 1])
        #expect(cursor.position == 1_000 + UInt64(first.utf8.count + second.utf8.count) + 2)
    }
}

@Suite("チャットのファイルの中身の口")
struct ChatFileRoutesTests {
    private let machine = MachineID(rawValue: "m-files")
    private let sessionID = "22222222-aaaa-bbbb-cccc-000000000001"

    private struct World {
        let service: ServiceWorld
        /// transcript を書いた会話
        let id: String
        let dependencies: APIServer.Dependencies
        /// 行ごとの頭の位置（transcript の中）
        let starts: [UInt64]
        var state: DaemonState { service.state }
    }

    private func world(_ lines: [String]) async throws -> World {
        let service = try await ServiceWorld.make()
        let conversation = try await service.service.start(service.request())
        try service.write(conversation.agentSessionID, lines)
        var dependencies = APIServer.Dependencies()
        dependencies.store = service.store
        dependencies.conversations = service.service
        var starts: [UInt64] = []
        var position: UInt64 = 0
        for line in lines {
            starts.append(position)
            position += UInt64(line.utf8.count + 1)
        }
        return World(service: service, id: conversation.id, dependencies: dependencies, starts: starts)
    }

    private func get(_ client: some TestClientProtocol, _ uri: String) async throws -> TestResponse {
        try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer daemon-token"])
    }

    private func kind(_ response: TestResponse) throws -> String? {
        try WireJSON.decoder().decode(DaemonRejection.Body.self, from: response.body).error.params?["kind"]
    }

    private var lines: [String] {
        [
            call("a1", id: "t1", name: "Read", input: ["file_path": "/repo/App.swift"]),
            result("u1", id: "t1", content: "1\tlet a = 1", result: ["type": "text", "file": ["filePath": "/repo/App.swift", "content": "let a = 1\n日本語の行\n", "numLines": 2, "startLine": 1, "totalLines": 2]]),
            imageLine("u2", id: "t2", base64: pngBytes.base64EncodedString()),
            result(
                "u3", id: "t3", content: "updated",
                result: ["filePath": "/repo/b.swift", "originalFile": "let a = 1\nlet b = 2\nlet d = 5\n", "structuredPatch": [hunk], "userModified": false]),
            result(
                "u4", id: "t4", content: "",
                result: ["stdout": "", "bashEditDiff": ["files": [["filePath": "/repo/x.txt", "hunks": [hunk]], ["filePath": "/repo/y.txt", "hunks": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 0, "lines": ["-消した行"]]]]]]]),
        ]
    }

    @Test("Read の文は記録された時点の中身を text/plain で返す（ディスクのファイルは読まない）")
    func text() async throws {
        let w = try await world(lines)
        defer { w.service.cleanUp() }
        try await APIServer.application(state: w.state, token: "daemon-token", port: 0, dependencies: w.dependencies).test(.router) { client in
            let response = try await get(client, "/v1/conversations/\(w.id)/files/t1?at=\(w.starts[1])")
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "text/plain; charset=utf-8")
            #expect(String(buffer: response.body) == "let a = 1\n日本語の行\n")
        }
    }

    @Test("画像は base64 を解いたバイト列を、先頭のバイトで決めた Content-Type で返す")
    func image() async throws {
        let w = try await world(lines)
        defer { w.service.cleanUp() }
        try await APIServer.application(state: w.state, token: "daemon-token", port: 0, dependencies: w.dependencies).test(.router) { client in
            let response = try await get(client, "/v1/conversations/\(w.id)/files/t2?at=\(w.starts[2])")
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "image/png")
            #expect(Data(buffer: response.body) == pngBytes)
        }
    }

    @Test("Edit は unified diff、part=original は変える前の全文。Bash は path でファイルを選ぶ")
    func diffAndOriginal() async throws {
        let w = try await world(lines)
        defer { w.service.cleanUp() }
        try await APIServer.application(state: w.state, token: "daemon-token", port: 0, dependencies: w.dependencies).test(.router) { client in
            let diff = try await get(client, "/v1/conversations/\(w.id)/files/t3?at=\(w.starts[3])")
            #expect(diff.headers[.contentType] == "text/x-diff; charset=utf-8")
            #expect(String(buffer: diff.body) == "@@ -3,3 +3,4 @@\n let a = 1\n-let b = 2\n+let b = 3\n+let c = 4\n let d = 5")
            let original = try await get(client, "/v1/conversations/\(w.id)/files/t3?at=\(w.starts[3])&part=original")
            #expect(String(buffer: original.body) == "let a = 1\nlet b = 2\nlet d = 5\n")
            let second = try await get(client, "/v1/conversations/\(w.id)/files/t4?at=\(w.starts[4])&path=%2Frepo%2Fy.txt")
            #expect(String(buffer: second.body) == "@@ -1,1 +1,0 @@\n-消した行")
            // Bash の行に変える前の全文は無い
            #expect(try await get(client, "/v1/conversations/\(w.id)/files/t4?at=\(w.starts[4])&part=original").status == .notFound)
        }
    }

    @Test("無い id は 404（kind は file）、知らない会話も 404。別の行の位置・行の頭でない位置・末尾より先の位置は transcript を探し直して返す")
    func notFound() async throws {
        let w = try await world(lines)
        defer { w.service.cleanUp() }
        try await APIServer.application(state: w.state, token: "daemon-token", port: 0, dependencies: w.dependencies).test(.router) { client in
            let missing = try await get(client, "/v1/conversations/\(w.id)/files/t9?at=\(w.starts[1])")
            #expect(missing.status == .notFound)
            #expect(try kind(missing) == "file")
            for offset in [w.starts[2], w.starts[1] + 5, 999_999_999] {
                let response = try await get(client, "/v1/conversations/\(w.id)/files/t1?at=\(offset)")
                #expect(response.status == .ok, "\(offset)")
            }
            #expect(try await get(client, "/v1/conversations/missing/files/t1?at=\(w.starts[1])").status == .notFound)
            #expect(try await get(client, "/v1/conversations/\(w.id)/files/t1?at=0&part=all").status == .badRequest)
            #expect(try await get(client, "/v1/conversations/\(w.id)/files/..%2Fx?at=0").status == .badRequest)
        }
    }

    @Test("端末の token でも読める。token が無ければ 401")
    func deviceToken() async throws {
        let w = try await world(lines)
        defer { w.service.cleanUp() }
        let store = try Store(inMemory: machine)
        try store.insertDevice(DeviceInfo(id: "d1", name: "iPhone", platform: .ios, createdAt: Date()), tokenHash: DeviceAuth.hash(token: "token-d1"))
        var dependencies = w.dependencies
        dependencies.store = store
        await dependencies.deviceAuth.load(try store.devices())
        try await APIServer.application(state: w.state, token: "daemon-token", port: 0, dependencies: dependencies).test(.router) { client in
            let device = try await client.execute(uri: "/v1/conversations/\(w.id)/files/t1?at=\(w.starts[1])", method: .get, headers: [.authorization: "Bearer token-d1"])
            #expect(device.status == .ok)
            let anonymous = try await client.execute(uri: "/v1/conversations/\(w.id)/files/t1?at=\(w.starts[1])", method: .get)
            #expect(anonymous.status == .unauthorized)
        }
    }

    @Test("人の発言の画像は、行の uuid と順番で返す。位置が無くても末尾から探し、取り込まれた発言は source_uuid で引く。無い画像は 404、形の違う引数は 400")
    func userImages() async throws {
        let second = pngBytes + Data([9, 9])
        let uuid = "d1a2b3c4-0000-4000-8000-000000000001"
        let w = try await world([
            humanImageLine(uuid, text: "見て", images: [pngBytes.base64EncodedString(), second.base64EncodedString()]),
            queuedImageLine("d1a2b3c4-0000-4000-8000-000000000002", base64: second.base64EncodedString()),
        ])
        defer { w.service.cleanUp() }
        try await APIServer.application(state: w.state, token: "daemon-token", port: 0, dependencies: w.dependencies).test(.router) { client in
            let first = try await get(client, "/v1/conversations/\(w.id)/images/\(uuid)/0?at=\(w.starts[0])")
            #expect(first.status == .ok && first.headers[.contentType] == "image/png" && Data(buffer: first.body) == pngBytes)
            #expect(Data(buffer: try await get(client, "/v1/conversations/\(w.id)/images/\(uuid)/1").body) == second, "位置が無ければ探す")
            #expect(Data(buffer: try await get(client, "/v1/conversations/\(w.id)/images/\(uuid)/1?at=\(w.starts[1])").body) == second, "位置が別の行なら探す")
            #expect(Data(buffer: try await get(client, "/v1/conversations/\(w.id)/images/d1a2b3c4-0000-4000-8000-000000000002/0").body) == second)
            for uri in ["/v1/conversations/\(w.id)/images/\(uuid)/2", "/v1/conversations/\(w.id)/images/d1a2b3c4-0000-4000-8000-00000000000/0"] {
                let response = try await get(client, uri)
                let rejected = try kind(response)
                #expect(response.status == .notFound && rejected == "file", "\(uri)")
            }
            #expect(try await get(client, "/v1/conversations/missing/images/\(uuid)/0").status == .notFound)
            for uri in ["/v1/conversations/\(w.id)/images/short/0", "/v1/conversations/\(w.id)/images/\(uuid)/-1", "/v1/conversations/\(w.id)/images/\(uuid)/x", "/v1/conversations/\(w.id)/images/\(uuid)/0?at=a"] {
                #expect(try await get(client, uri).status == .badRequest, "\(uri)")
            }
        }
    }

    @Test("1MB を超える画像の行も、口は行を全部読んで返す")
    func largeImageLine() async throws {
        let big = pngBytes + Data(repeating: 2, count: 900_000)
        let w = try await world([call("a1", id: "t1", name: "Read", input: ["file_path": "/repo/shot.png"]), imageLine("u1", id: "t1", base64: big.base64EncodedString())])
        defer { w.service.cleanUp() }
        try await APIServer.application(state: w.state, token: "daemon-token", port: 0, dependencies: w.dependencies).test(.router) { client in
            let response = try await get(client, "/v1/conversations/\(w.id)/files/t1?at=\(w.starts[1])")
            #expect(response.status == .ok && Data(buffer: response.body) == big)
        }
    }
}

@Suite("位置を持たない札の中身を transcript から探す")
struct TranscriptFilesLookupTests {
    private func transcript(_ lines: [String]) throws -> (url: URL, starts: [UInt64]) {
        let url = FileManager.default.temporaryDirectory.appending(path: "lookup-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        var starts: [UInt64] = []
        var position: UInt64 = 0
        for line in lines {
            starts.append(position)
            position += UInt64(line.utf8.count + 1)
        }
        return (url, starts)
    }

    /// 同じ id の字を持つが結果の行でない行（attachment）が、結果の行より後ろにある
    private var lines: [String] {
        [
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            call("a1", id: "t1", name: "Read", input: ["file_path": "/repo/App.swift"]),
            result("u1", id: "t1", content: "1\tlet a = 1", result: ["type": "text", "file": ["filePath": "/repo/App.swift", "content": "let a = 1\n日本語の行\n", "numLines": 2, "startLine": 1, "totalLines": 2]]),
            imageLine("u2", id: "t2", base64: pngBytes.base64EncodedString()),
            #"{"type":"attachment","attachment":{"type":"hook_success","tool_use_id":"t1"}}"#,
            result("u3", id: "t3", content: "updated", result: ["filePath": "/repo/b.swift", "originalFile": "let a = 1\n", "structuredPatch": [hunk]]),
        ]
    }

    @Test("位置が無くても、合わなくても、末尾から id の結果の行を探して返す。結果の行でない一致は飛ばす")
    func search() throws {
        let (url, starts) = try transcript(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptFiles.content(in: url, toolID: "t1", at: nil, path: nil, part: .content) == .text("let a = 1\n日本語の行\n"))
        #expect(TranscriptFiles.content(in: url, toolID: "t1", at: starts[3], path: nil, part: .content) == .text("let a = 1\n日本語の行\n"))
        #expect(TranscriptFiles.content(in: url, toolID: "t2", at: 0, path: nil, part: .content) == .image(pngBytes, contentType: "image/png"))
        #expect(TranscriptFiles.content(in: url, toolID: "t3", at: nil, path: nil, part: .original) == .text("let a = 1\n"))
        #expect(TranscriptFiles.content(in: url, toolID: "t9", at: nil, path: nil, part: .content) == nil)
        #expect(TranscriptFiles.content(in: url, toolID: "t", at: nil, path: nil, part: .content) == nil, "id の前方一致では当てない")
    }

    @Test("小さいチャンクで読んでも、チャンクをまたぐ一致と、前のチャンクに続く長い行の頭を取る。末尾の行から順に渡す")
    func smallChunks() throws {
        let (url, starts) = try transcript(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        for chunk in [1, 7, 64, 1 << 20] {
            var found: [UInt64] = []
            TranscriptFiles.lineStarts(containing: Data(#""tool_use_id":"t1""#.utf8), in: url, chunk: chunk) { start in
                found.append(start)
                return false
            }
            #expect(found == [starts[4], starts[2]], "chunk \(chunk)")
        }
        var first: [UInt64] = []
        TranscriptFiles.lineStarts(containing: Data(#""type":"queue-operation""#.utf8), in: url, chunk: 5) { start in
            first.append(start)
            return true
        }
        #expect(first == [0], "先頭の行は位置 0")
    }
}
