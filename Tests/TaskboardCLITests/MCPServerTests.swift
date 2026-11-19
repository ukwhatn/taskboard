import Foundation
import Testing

@testable import taskboard

@Suite("taskboard mcp")
struct MCPServerTests {
    /// `swift test` が置いた `taskboard` の実行ファイル（test bundle と同じ products ディレクトリ）。
    private final class BundleMarker {}

    static func builtExecutable() -> URL? {
        var dir = Bundle(for: BundleMarker.self).bundleURL
        for _ in 0..<6 {
            let candidate = dir.appending(path: "taskboard")
            if FileManager.default.isExecutableFile(atPath: candidate.path), !candidate.hasDirectoryPath { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Codex の object-valued experimental capability でも initialize できる")
    func codexInitialize() async throws {
        let executable = try #require(Self.builtExecutable())
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.160.1"}}}"#
        stdin.fileHandleForWriting.write(Data((initialize + "\n").utf8))
        let output = stdout.fileHandleForReading.availableData
        try stdin.fileHandleForWriting.close()
        process.terminate()
        process.waitUntilExit()

        let line = try #require(String(data: output, encoding: .utf8)?.split(separator: "\n").first)
        let response = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try #require(response["result"] as? [String: Any], "initialize の応答: \(response)")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "taskboard")
    }

    @Test("stdout は JSON-RPC だけ。tools/list は 67 個を返し、daemon が居ないときの tools/call は isError で返る")
    func stdoutIsJSONRPCOnly() async throws {
        let executable = try #require(Self.builtExecutable(), "taskboard の実行ファイルが見つからない: bundle=\(Bundle(for: BundleMarker.self).bundleURL.path) argv0=\(CommandLine.arguments[0])")
        let support = FileManager.default.temporaryDirectory.appending(path: "taskboard-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let process = Process()
        process.executableURL = executable
        // port 1 には何も居ない: daemon 不在の経路を通す
        process.arguments = ["mcp", "--support-dir", support.path, "--port", "1"]
        process.environment = ProcessInfo.processInfo.environment.filter { $0.key != "HERDR_PANE_ID" }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"board_overview","arguments":{}}}"#,
        ]
        stdin.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        var output = Data()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
            // 応答の順は決まっていない（SDK は要求を並べて処理し、負荷があると早く失敗する tools/call が tools/list より先に返る）。3 つそろうまで読む。
            // tools/list の応答は 1 通で 16KB を超え、pipe から複数回に分かれて届く。id が見えた時点では行が途中なので、末尾が改行になるまで読む
            let text = String(decoding: output, as: UTF8.self).replacingOccurrences(of: " ", with: "")
            if text.hasSuffix("\n"), (1...3).allSatisfy({ text.contains("\"id\":\($0),") || text.contains("\"id\":\($0)}") }) { break }
        }
        try stdin.fileHandleForWriting.close()
        process.terminate()
        process.waitUntilExit()

        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3, "initialize / tools/list / tools/call の 3 応答: \(lines)")
        var byID: [Int: [String: Any]] = [:]
        for line in lines {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "stdout の各行は JSON: \(line)")
            #expect(object["jsonrpc"] as? String == "2.0")
            if let id = object["id"] as? Int { byID[id] = object }
        }
        let initResult = try #require(byID[1]?["result"] as? [String: Any])
        #expect((initResult["serverInfo"] as? [String: Any])?["name"] as? String == "taskboard")

        let tools = try #require((byID[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(
            names == [
                "board_overview", "task_get", "session_guide", "task_create", "task_update", "work_list", "work_add", "work_update", "session_list", "session_start",
                "doc_publish", "doc_list", "ask_user", "review_request", "feedback_list", "comment_reply", "session_prompt", "session_account",
                "schedule_list", "schedule_create", "schedule_update", "schedule_run",
                "board_create", "board_update", "board_delete", "task_delete", "work_delete", "doc_read", "doc_delete", "ask_cancel",
                "schedule_delete", "schedule_runs",
                "health", "session_stop", "session_exit", "session_resume", "session_history", "session_rename",
                "orchestrator_status", "orchestrator_start", "orchestrator_restart", "orchestrator_prompt", "settings_get", "settings_update",
                "inbox_list", "inbox_dismiss", "inbox_restore", "prs_list", "prs_refresh", "usage_get", "usage_history",
                "session_answer", "session_fork", "session_control",
                "wake_create", "wake_list", "wake_cancel", "watch_create", "watch_list", "watch_cancel", "devin_start", "devin_get", "devin_message", "slack_get", "slack_reply", "panel_set", "panel_update",
            ])
        #expect(tools.count == names.count, "同じ名前の tool が無い")
        for tool in tools {
            #expect((tool["description"] as? String)?.isEmpty == false, "説明の無い tool: \(tool["name"] ?? "")")
            #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }

        let call = try #require(byID[3]?["result"] as? [String: Any])
        #expect(call["isError"] as? Bool == true, "daemon が居ないので失敗として返る: \(call)")
        let content = try #require(call["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
    }
}
