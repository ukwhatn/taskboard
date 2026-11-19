import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("TUI の起動の引数を会話の項目に読み替える")
struct ConversationArgumentsTests {
    /// モデルの一覧を受けていない daemon（控えの一覧）
    private func convert(_ args: [String], models: ClaudeModels = ClaudeModels(nil)) -> ConversationArguments.Converted? {
        ConversationArguments.convert(args, models: models)
    }

    private func settingsFile() throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "tb-args-\(UUID().uuidString).json")
        try Data(#"{"permissions":{"allow":[],"deny":[]}}"#.utf8).write(to: url)
        return url.path
    }

    @Test("オーケストレーターと定期起動の引数（3 台の実データの形）")
    func realArguments() throws {
        let settings = try settingsFile()
        defer { try? FileManager.default.removeItem(atPath: settings) }
        #expect(
            convert(["--dangerously-skip-permissions", "--model", "claude-opus-5-5[1m]", "--effort", "medium"])
                == .init(model: "claude-opus-5-5[1m]", effort: "medium", permissionMode: "bypassPermissions", extraArgs: []))
        #expect(
            convert(["--dangerously-skip-permissions", "--model", "claude-sonnet-5", "--effort", "medium"])
                == .init(model: "claude-sonnet-5", effort: "medium", permissionMode: "bypassPermissions", extraArgs: []))
        #expect(
            convert(["--permission-mode", "dontAsk", "--settings", settings, "--model", "claude-opus-5-5[1m]", "--effort", "high"])
                == .init(model: "claude-opus-5-5[1m]", effort: "high", permissionMode: "dontAsk", extraArgs: ["--settings", settings]))
        #expect(
            convert(["--dangerously-skip-permissions", "--permission-mode", "dontAsk", "--settings", settings, "--model", "opus"])
                == .init(model: "opus", effort: nil, permissionMode: "bypassPermissions", extraArgs: ["--settings", settings]))
    }

    @Test("空の引数は確認ありのモードで戻す（人が taskboard の外で起こした TUI と同じ）")
    func empty() {
        #expect(convert([]) == .init(model: nil, effort: nil, permissionMode: "default", extraArgs: []))
    }

    @Test("tool の一覧は次の旗まで取る")
    func toolLists() {
        #expect(
            convert(["--disallowedTools", "Agent", "Workflow", "--dangerously-skip-permissions"])?.extraArgs
                == ["--disallowedTools", "Agent", "Workflow"])
        #expect(convert(["--allowed-tools", "Bash(echo:*)"])?.extraArgs == ["--allowed-tools", "Bash(echo:*)"])
        #expect(convert(["--disallowedTools=Agent"])?.extraArgs == ["--disallowedTools", "Agent"])
        #expect(convert(["--disallowedTools", "--model", "opus"]) == nil)
    }

    @Test("モデルはマシンの一覧で確かめる（一覧の版つきの名前は通し、一覧に無い名前は読み替えない）")
    func listedModels() {
        let models = ClaudeModels(ClaudeMachineInfo(models: [
            .init(value: "sonnet", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet 5.5", efforts: ["low"]),
            .init(value: "claude-opus-4-8", resolvedModel: "claude-opus-4-8", displayName: "Opus 4.8", efforts: ["low"]),
        ]))
        #expect(convert(["--model", "claude-opus-4-8"], models: models)?.model == "claude-opus-4-8")
        #expect(convert(["--model", "sonnet"], models: models)?.model == "sonnet")
        #expect(convert(["--model", "claude-opus-4-8"]) == nil, "控えの一覧に無い")
        #expect(convert(["--model", "fable"], models: models) == nil)
    }

    @Test("= の形の値")
    func inlineValues() {
        #expect(convert(["--model=opus", "--effort=high"]) == .init(model: "opus", effort: "high", permissionMode: "default", extraArgs: []))
    }

    @Test("会話に渡せない引数があれば読み替えない")
    func rejects() throws {
        #expect(convert(["--remote-control"]) == nil)
        #expect(convert(["--resume", "6f1d2b8e-0000-4000-8000-0000000000a1"]) == nil)
        #expect(convert(["--plugin-dir", "/tmp"]) == nil)
        #expect(convert(["-p"]) == nil)
        #expect(convert(["--model", "gpt-5"]) == nil)
        #expect(convert(["--effort", "huge"]) == nil)
        #expect(convert(["--model", "opus", "--model", "fable"]) == nil)
        #expect(convert(["--permission-mode", "yolo"]) == nil)
        #expect(convert(["--settings", "/nonexistent/settings.json"]) == nil)
        #expect(convert(["--settings", "relative.json"]) == nil)
        #expect(convert(["--settings"]) == nil)
        #expect(convert(["--dangerously-skip-permissions=true"]) == nil)
        #expect(convert(["--add-dir", "/tmp", "日本語の文"]) == nil)
    }

    @Test("記録の extraArgs は convert が作れる形だけ")
    func extraArgs() throws {
        let settings = try settingsFile()
        defer { try? FileManager.default.removeItem(atPath: settings) }
        #expect(ConversationArguments.acceptsExtra([]))
        #expect(ConversationArguments.acceptsExtra(["--settings", settings, "--disallowedTools", "Agent", "Workflow"]))
        #expect(!ConversationArguments.acceptsExtra(["--model", "opus"]))
        #expect(!ConversationArguments.acceptsExtra(["--remote-control"]))
        #expect(!ConversationArguments.acceptsExtra(Array(repeating: "--add-dir=/tmp", count: 17)))
    }
}
