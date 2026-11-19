import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("Claude Code の計画（tasks/<会話 ID>/*.json）")
struct ClaudeTaskListTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tasklist-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: String, _ name: String, in config: URL, session: String = "s1") throws {
        let folder = config.appending(path: "tasks/\(session)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: name))
    }

    @Test("番号の順（10 は 2 の後）に読み、CLI の状態を読み替える。進めている間の文は空なら外す。知らない状態・壊れたファイル・json でないファイルは読まない")
    func reads() throws {
        let config = try directory()
        defer { try? FileManager.default.removeItem(at: config) }
        try write(#"{"id":"10","subject":"確かめる","description":"","activeForm":"","status":"pending","blocks":[],"blockedBy":[]}"#, "10.json", in: config)
        try write(#"{"id":"2","subject":"直す（daemon）","description":"直す","activeForm":"直している","status":"in_progress","blocks":[],"blockedBy":["1"]}"#, "2.json", in: config)
        try write(#"{"id":"1","subject":"Investigate","description":"x","status":"completed","blocks":[],"blockedBy":[]}"#, "1.json", in: config)
        try write(#"{"id":"3","subject":"消した","status":"deleted"}"#, "3.json", in: config)
        try write("{", "4.json", in: config)
        try write("1", ".highwatermark", in: config)
        let items = ClaudeTaskList.read("s1", environment: ["CLAUDE_CONFIG_DIR": config.path])
        #expect(
            items == [
                ConversationPlanItem(id: "1", title: "Investigate", status: .completed),
                ConversationPlanItem(id: "2", title: "直す（daemon）", activeTitle: "直している", status: .inProgress),
                ConversationPlanItem(id: "10", title: "確かめる", status: .pending),
            ])
    }

    @Test("CLAUDE_CONFIG_DIR が無ければ ~/.claude の下。フォルダが無い・項目が無い・会話 ID がパスを抜ける形なら nil")
    func missing() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: ".claude", directoryHint: .isDirectory)
        #expect(ClaudeTaskList.read("s1", environment: [:], home: home) == nil)
        try write("1", ".highwatermark", in: config)
        #expect(ClaudeTaskList.read("s1", environment: [:], home: home) == nil)
        try write(#"{"id":"1","subject":"a","status":"pending"}"#, "1.json", in: config)
        #expect(ClaudeTaskList.read("s1", environment: [:], home: home)?.map(\.title) == ["a"])
        try write(#"{"id":"1","subject":"b","status":"pending"}"#, "1.json", in: config, session: "other")
        #expect(ClaudeTaskList.read("../other", environment: [:], home: home) == nil)
        #expect(ClaudeTaskList.read("", environment: [:], home: home) == nil)
    }
}
