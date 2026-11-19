import ArgumentParser
import Foundation
import Testing
import TestSupport

@testable import taskboard

@Suite("install-hooks: settings.json の編集")
struct HooksEditTests {
    /// 切り替え前の実機の settings.json と同じ形（他のキーと kairan / herdr の hook は残る）。
    static let before = """
        {
          "model": "opus",
          "permissions": { "allow": ["Bash(ls:*)"] },
          "hooks": {
            "PreToolUse": [
              { "matcher": "Agent", "hooks": [ { "type": "command", "command": "python3 \\"$HOME/.claude/hooks/agent-model-required.py\\"", "timeout": 5 } ] }
            ],
            "SessionStart": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/herdr-agent-state.sh session", "timeout": 10 } ] }
            ],
            "UserPromptSubmit": [
              { "hooks": [ { "type": "command", "command": "if [ -x \\"$HOME/.claude/hooks/taskherd-sync.py\\" ]; then python3 \\"$HOME/.claude/hooks/taskherd-sync.py\\" prompt; fi", "timeout": 15 } ] }
            ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "if command -v kairan >/dev/null 2>&1; then kairan hook stop; else exit 0; fi", "timeout": 3900, "statusMessage": "kairan: 回答を待っています", "asyncRewake": true } ] },
              { "hooks": [ { "type": "command", "command": "if [ -x \\"$HOME/.claude/hooks/taskherd-sync.py\\" ]; then python3 \\"$HOME/.claude/hooks/taskherd-sync.py\\" stop; fi", "timeout": 30 } ] }
            ]
          }
        }
        """

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-hooks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        let groups = ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
    }

    @Test("taskherd-sync と kairan の hook を外し、SessionStart・Stop・PostToolUse・UserPromptSubmit に taskboard を足す。他は触らない")
    func planReplacesTaskherd() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "settings.json")
        try Data(Self.before.utf8).write(to: url)

        let plan = try HooksEdit.load(url).plan()
        #expect(!plan.unchanged)
        #expect(plan.summary.count == 7, "UserPromptSubmit と Stop から taskherd を外す 2 件、Stop から kairan を外す 1 件、4 つのイベントに足す 4 件: \(plan.summary)")
        let root = plan.root
        let pending = #"if [ -n "$CLAUDE_CODE_SESSION_ID" ] && [ -e "$HOME/Library/Application Support/taskboard/feedback-pending/$CLAUDE_CODE_SESSION_ID" ] && [ -x "$HOME/.local/bin/taskboard" ]; then "$HOME/.local/bin/taskboard" hook "#
        #expect(commands(root, "UserPromptSubmit") == [pending + "prompt; else exit 0; fi"], "taskherd は外れ、taskboard の印を見る hook だけになる")
        #expect(commands(root, "PostToolUse") == [pending + "tool; else exit 0; fi"])
        let toolGroup = try #require(((root["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]])?.first)
        #expect(toolGroup["matcher"] == nil, "全部のツールの後に走る")
        #expect((toolGroup["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 10)
        #expect(commands(root, "SessionStart") == ["bash ~/.claude/hooks/herdr-agent-state.sh session", "if [ -x \"$HOME/.local/bin/taskboard\" ]; then \"$HOME/.local/bin/taskboard\" hook session; else exit 0; fi"])
        #expect(commands(root, "Stop") == ["if [ -x \"$HOME/.local/bin/taskboard\" ]; then \"$HOME/.local/bin/taskboard\" hook stop; else exit 0; fi"], "kairan の Stop hook は外れる（回答の二重注入を防ぐ）")
        #expect(commands(root, "PreToolUse").count == 1)
        #expect(root["model"] as? String == "opus")
        #expect((root["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls:*)"])
        let sessionGroups = try #require((root["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])
        #expect(sessionGroups.last?["matcher"] as? String == "*")
        let stopHooks = try #require(((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.last?["hooks"] as? [[String: Any]])
        #expect(stopHooks.first?["timeout"] as? Int == 3900, "人の回答を待つので kairan と同じ長さ")
        #expect(stopHooks.first?["asyncRewake"] as? Bool == true)
        #expect(stopHooks.first?["statusMessage"] as? String == "taskboard: 回答を待っています")

        try plan.write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#"if [ -x \"$HOME/.local/bin/taskboard\" ]; then \"$HOME/.local/bin/taskboard\" hook session; else exit 0; fi"#), "スラッシュをエスケープしない: \(text)")
        #expect(!text.contains(#"\/"#))
        #expect(!text.contains(#"" : "#), "Claude Code と同じ `\": \"` 区切り")
        #expect(text.contains("\n  \"hooks\": {\n    \"PostToolUse\": [\n      {\n        \"hooks\": [\n          {\n            \"command\": "), "2 スペースの入れ子（キーは辞書順）")
        #expect(text.contains("\"asyncRewake\": true") && text.contains("\"timeout\": 3900"), "Bool と数が崩れない")
        #expect(text.contains("\"taskboard: 回答を待っています\""), "日本語をエスケープしない")
        let reloaded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(reloaded?.keys.sorted() == plan.root.keys.sorted())
        #expect(text.hasSuffix("\n"))

        let second = try HooksEdit.load(url).plan()
        #expect(second.unchanged, "2 回目は何も変えない: \(second.summary)")
    }

    @Test("build のパスを直書きした古い taskboard の hook は、同じ hook の新しい command に差し替える")
    func planReplacesStalePath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "settings.json")
        try Data(Self.before.utf8).write(to: url)
        try HooksEdit.load(url).plan(executable: "/Users/a/dev/taskboard/.build/debug/taskboard").write(to: url)
        let plan = try HooksEdit.load(url).plan()
        #expect(plan.summary.contains { $0.hasPrefix("SessionStart: taskboard の hook を 1 個差し替える") }, "\(plan.summary)")
        #expect(commands(plan.root, "SessionStart") == ["bash ~/.claude/hooks/herdr-agent-state.sh session", "if [ -x \"$HOME/.local/bin/taskboard\" ]; then \"$HOME/.local/bin/taskboard\" hook session; else exit 0; fi"])
        #expect(commands(plan.root, "Stop") == ["if [ -x \"$HOME/.local/bin/taskboard\" ]; then \"$HOME/.local/bin/taskboard\" hook stop; else exit 0; fi"], "古い方は残らない")
    }

    @Test("フェーズ 4 の形（Stop の timeout 30、asyncRewake なし）は、同じ場所で 3900 + asyncRewake に差し替える")
    func planUpgradesStopHook() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "settings.json")
        let phase4 = """
            {
              "hooks": {
                "Stop": [
                  { "hooks": [ { "type": "command", "command": "if command -v kairan >/dev/null 2>&1; then kairan hook stop; else exit 0; fi", "timeout": 3900, "statusMessage": "kairan: 回答を待っています", "asyncRewake": true } ] },
                  { "hooks": [ { "type": "command", "command": "\\"$HOME/.local/bin/taskboard\\" hook stop", "timeout": 30 } ] },
                  { "hooks": [ { "type": "command", "command": "echo after", "timeout": 5 } ] }
                ],
                "SessionStart": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "\\"$HOME/.local/bin/taskboard\\" hook session", "timeout": 10 } ] } ]
              }
            }
            """
        try Data(phase4.utf8).write(to: url)
        let plan = try HooksEdit.load(url).plan()
        #expect(!plan.unchanged)
        #expect(commands(plan.root, "Stop") == ["if [ -x \"$HOME/.local/bin/taskboard\" ]; then \"$HOME/.local/bin/taskboard\" hook stop; else exit 0; fi", "echo after"], "順序は保つ: \(commands(plan.root, "Stop"))")
        let stop = try #require(((plan.root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(stop[0]["timeout"] as? Int == 3900 && stop[0]["asyncRewake"] as? Bool == true)
        #expect(plan.summary.contains { $0.hasPrefix("Stop: taskboard の hook を 1 個差し替える") }, "\(plan.summary)")
        #expect(plan.summary.contains { $0.hasPrefix("SessionStart: taskboard の hook を 1 個差し替える") }, "素の形は存在確認で包んだ形に差し替える: \(plan.summary)")
        try plan.write(to: url)
        #expect(try HooksEdit.load(url).plan().unchanged)
    }

    @Test("hooks が無い settings.json にも足せる")
    func planOnEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "settings.json")
        try Data("{}".utf8).write(to: url)
        let plan = try HooksEdit.load(url).plan()
        #expect(commands(plan.root, "SessionStart") == ["if [ -x \"$HOME/.local/bin/taskboard\" ]; then \"$HOME/.local/bin/taskboard\" hook session; else exit 0; fi"])
        #expect(commands(plan.root, "Stop") == ["if [ -x \"$HOME/.local/bin/taskboard\" ]; then \"$HOME/.local/bin/taskboard\" hook stop; else exit 0; fi"])
    }

    @Test("空打ちが失敗したら backup から元に戻す")
    func applyRestoresOnProbeFailure() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "settings.json")
        try Data(Self.before.utf8).write(to: url)
        let edit = try HooksEdit.load(url)
        let plan = edit.plan()

        await #expect(throws: ValidationError.self) {
            _ = try await InstallHooks.apply(plan: plan, edit: edit, settingsURL: url, backupDirectory: dir.appending(path: "backups")) { 1 }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.before, "元のバイト列に戻る")
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "backups").path)
        #expect(backups.count == 1 && backups[0].hasPrefix("settings.json.") && backups[0].hasSuffix(".bak"))

        let backup = try await InstallHooks.apply(plan: plan, edit: edit, settingsURL: url, backupDirectory: dir.appending(path: "backups")) { 0 }
        #expect(try HooksEdit.load(url).plan().unchanged)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("ツールのたびの hook は、このセッションの印があるときだけ taskboard を呼ぶ（support ディレクトリのパスに空白がある）")
    func pendingCommandRunsOnlyWithMarker() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = try SharedExecutable(name: "tb-test-hook-taskboard.sh", script: "#!/bin/sh\necho \"called $*\"\n").link(in: bin, as: "taskboard")
        let command = HooksEdit.pendingCommand(executable: HooksEdit.portableExecutable, sub: "tool")

        func run(session: String?) throws -> (String, Int32) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            if let session { env["CLAUDE_CODE_SESSION_ID"] = session }
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
        }

        #expect(try run(session: "sess-1") == ("", 0), "印が無ければ呼ばない")
        let markers = home.appending(path: "Library/Application Support/taskboard/feedback-pending", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markers.appending(path: "sess-1").path, contents: nil)
        #expect(try run(session: "sess-1") == ("called hook tool\n", 0))
        #expect(try run(session: "sess-2") == ("", 0), "ほかのセッションの印では呼ばない")
        #expect(try run(session: nil) == ("", 0), "セッションの ID が無ければ呼ばない")
        try FileManager.default.removeItem(at: fake)
        #expect(try run(session: "sess-1") == ("", 0), "taskboard を入れていない Mac では黙る")
    }

    @Test("ターンの途中の hook の出力は hookSpecificOutput の additionalContext")
    func pendingOutputShape() throws {
        let text = try #require(Hook.pendingOutput(event: "PostToolUse", text: "回答が届きました", sessionTitle: nil))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PostToolUse")
        #expect(specific["additionalContext"] as? String == "回答が届きました")
        #expect(specific["sessionTitle"] == nil)
        #expect(root.count == 1, "最上位に置くと Claude Code は黙って無視する（docs）")
    }

    @Test("UserPromptSubmit は会話の題だけでも出し、回答も題も無ければ何も出さない")
    func promptOutputTitle() throws {
        let text = try #require(Hook.pendingOutput(event: "UserPromptSubmit", text: nil, sessionTitle: "#476 新しい題"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(specific["sessionTitle"] as? String == "#476 新しい題")
        #expect(specific["additionalContext"] == nil)
        #expect(Hook.pendingOutput(event: "UserPromptSubmit", text: nil, sessionTitle: nil) == nil)
    }

    @Test("最上位がオブジェクトでない・壊れた JSON は読めない（書く前に止まる）")
    func brokenSettings() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "settings.json")
        try Data("{\"hooks\": ".utf8).write(to: url)
        #expect(throws: (any Error).self) { try HooksEdit.load(url) }
        try Data("[]".utf8).write(to: url)
        #expect(throws: ValidationError.self) { try HooksEdit.load(url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[]")
    }
}
