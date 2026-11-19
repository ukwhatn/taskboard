import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("会話の履歴：transcript を後ろから読み、cursor で前へ送る")
struct ConversationHistoryTests {
    private let session = "6f1d2b8e-0000-4000-8000-000000000001"

    private func line(_ uuid: String, _ content: Any) -> String {
        let object: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": "2026-10-19T00:00:00.000Z", "message": ["role": "user", "content": content]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// 一時の projects の下に transcript を置き、その projects を返す
    private func projects(_ lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "tb-history-\(UUID().uuidString)")
        let dir = root.appending(path: "-w")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appending(path: "\(session).jsonl"))
        return root
    }

    private func record(_ session: String? = nil) -> ConversationRecord {
        ConversationRecord(taskNumber: nil, agentSessionId: session ?? self.session, cwd: "/w", runner: .host)
    }

    /// cursor が尽きるまで読み、ページごとの発言を古い順に並べ直す
    private func readAll(_ root: URL, limit: Int) throws -> (pages: [[ChatMessage]], all: [ChatMessage]) {
        var pages: [[ChatMessage]] = []
        var cursor: String?
        repeat {
            let page = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: cursor, limit: limit)
            pages.append(page.messages)
            cursor = page.nextCursor
        } while cursor != nil && pages.count < 100
        return (pages, pages.reversed().flatMap { $0 })
    }

    @Test("新しい方から limit 件ずつ返し、cursor は「会話 ID.行の頭の位置」。最も古い行まで返したら cursor は無い。日本語と英語の発言をそのまま返す")
    func paging() throws {
        let texts = ["はじめの発言", "second message", "三つ目 with English", "4th", "最後の発言"]
        let lines = texts.enumerated().map { line("u\($0.offset + 1)", $0.element) }
        let root = try projects(lines)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: nil, limit: 2)
        #expect(first.messages.map(\.id) == ["u4", "u5"] && first.messages.map(\.text) == ["4th", "最後の発言"])
        #expect(first.agentSessionID == session)
        let offset = lines[0...2].reduce(0) { $0 + $1.utf8.count + 1 }
        #expect(first.nextCursor == "\(session).\(offset)")

        let second = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: first.nextCursor, limit: 2)
        #expect(second.messages.map(\.text) == ["second message", "三つ目 with English"])
        let last = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: second.nextCursor, limit: 2)
        #expect(last.messages.map(\.id) == ["u1"] && last.nextCursor == nil)

        #expect(try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: nil, limit: 0).messages.map(\.id) == ["u5"])
    }

    @Test("1 回に読むのは 4MB まで。読み切れなければそこまでの分と cursor を返し、たどるとチャンクの境目をまたぐ行も欠けずに全部そろう")
    func readLimit() throws {
        let body = String(repeating: "あ", count: 100_000)  // 300KB
        let lines = (1...20).map { line("big-\($0)", "\($0):\(body)") }
        let root = try projects(lines)
        defer { try? FileManager.default.removeItem(at: root) }

        let (pages, all) = try readAll(root, limit: ConversationHistoryResponse.maxLimit)
        #expect(pages.count > 1)
        #expect(pages[0].count < 20)
        #expect(pages[0].reduce(0) { $0 + $1.text.utf8.count } <= ConversationHistory.readLimit + 400_000)
        #expect(all.map(\.id) == (1...20).map { "big-\($0)" })
        #expect(all.allSatisfy { $0.text.hasSuffix(body) })
    }

    @Test("1MB を超える行は中身を読まず「省きました」の印にし、id は行の頭の位置。前後の行はそのまま読む")
    func largeLine() throws {
        let before = line("u1", "前の発言")
        let large = line("u2", String(repeating: "x", count: 1_500_000))
        let root = try projects([before, large, line("u3", "後の発言")])
        defer { try? FileManager.default.removeItem(at: root) }

        let page = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: nil, limit: 50)
        #expect(page.messages.count == 3 && page.nextCursor == nil)
        #expect(page.messages.first?.text == "前の発言" && page.messages.last?.text == "後の発言")
        let marker = page.messages[1]
        #expect(marker.id == "large-\(before.utf8.count + 1)")
        #expect(marker.kind == .notice && marker.fullBytes == large.utf8.count)
        #expect(marker.text == "大きい出力（1.4MB）を省きました")
    }

    @Test("別の会話 ID の cursor（/clear の後）は末尾から読み、形の違う cursor は InvalidCursor。transcript が無ければ空")
    func cursors() throws {
        let root = try projects([line("u1", "a"), line("u2", "b")])
        defer { try? FileManager.default.removeItem(at: root) }

        let other = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: "0aa11bb2-0000-4000-8000-000000000009.5", limit: 1)
        #expect(other.messages.map(\.id) == ["u2"])
        let beyond = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: "\(session).999999", limit: 1)
        #expect(beyond.messages.map(\.id) == ["u2"])
        #expect(throws: ConversationHistory.InvalidCursor.self) {
            try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record(), projects: root), before: "no-offset", limit: 1)
        }

        let missing = try ConversationHistory.read(lineage: TranscriptLineage(unrecorded: record("7e2c3d4f-0000-4000-8000-000000000002"), projects: root), before: nil, limit: 10)
        #expect(missing.messages.isEmpty && missing.nextCursor == nil && missing.agentSessionID == "7e2c3d4f-0000-4000-8000-000000000002")
    }

    @Test("check の照らし合わせ：stream-json で届いた発言の id が transcript に全部あれば空、無いものだけを返す")
    func checkMissing() {
        let transcript = Data(
            [line("u1", "テキストの発言"), line("u3", [["type": "text", "text": "block の発言"]]), "", "not json"].joined(separator: "\n").utf8)
        #expect(ClaudeCheck.missing(["u1", "u3#0"], inTranscript: transcript).isEmpty)
        #expect(ClaudeCheck.missing(["u1", "u2", "u3"], inTranscript: transcript) == ["u2", "u3"])
        #expect(ClaudeCheck.missing(["u1"], inTranscript: Data()) == ["u1"])
        #expect(ClaudeCheck.missing([], inTranscript: Data()).isEmpty)
    }
}
