import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// 設定を書く CLI の偽物。起こされた引数・環境・stdin・作業フォルダを控え、決めた終わり方を返す
private final class FakeSettingsCLI: @unchecked Sendable {
    struct Call {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var input: [String: Any]
        var cwd: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var outcome = Subprocess.Outcome(status: 0, stdout: Data(#"{"ok":true}"#.utf8), stderr: Data(), timedOut: false, overflowed: false)

    func answer(status: Int32, stdout: String, stderr: String = "") {
        lock.withLock { outcome = Subprocess.Outcome(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: false, overflowed: false) }
    }

    var all: [Call] { lock.withLock { calls } }

    func run(_ executable: String, _ arguments: [String], _ environment: [String: String], _ input: Data, _ cwd: String) -> Subprocess.Outcome {
        lock.withLock {
            calls.append(Call(executable: executable, arguments: arguments, environment: environment, input: (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:], cwd: cwd))
            return outcome
        }
    }
}

@Suite("Claude の設定の書き込み（偽の CLI の子）", .serialized)
struct ClaudeSettingsEditsTests {
    private let machine = MachineID(rawValue: "m-settings")

    private func make(logs: LogLines = LogLines()) async throws -> (ClaudeConversation, FakeHost, FakeSettingsCLI) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        let saved = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w/app", model: "haiku", runner: .none))
        let host = FakeHost()
        let cli = FakeSettingsCLI()
        var timing = ConversationTiming()
        timing.control = .seconds(2)
        timing.stopResult = .milliseconds(300)
        timing.stopInput = .milliseconds(300)
        timing.stopTerm = .milliseconds(300)
        var context = ClaudeConversation.Context(
            shared: ConversationContext(
                machine: machine, store: store, host: host, launch: { EngineLaunch(executable: "/x/claude", environment: ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/c", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1"]) },
                attachments: nil, guide: { _ in nil }, becameIdle: { _ in }, logger: logs.logger, timing: timing))
        context.settingsCLI = { cli.run($0, $1, $2, $3, $4) }
        let conversation = ClaudeConversation(record: saved, context: context)
        await host.connect(conversation.inbox, key: saved.id)
        return (conversation, host, cli)
    }

    private func edit(_ conversation: ClaudeConversation, _ edit: ConversationSettingsEdit) async throws -> ConversationSettingsEditResult {
        let response = try await conversation.control(ConversationControlRequest(kind: .editSettings, edit: edit))
        return try WireJSON.decoder().decode(ConversationSettingsEditResult.self, from: Data(try #require(response.payloadJSON).utf8))
    }

    @Test("規則を足す：確かめた版の CLI の edit-permission-rules を会話の作業フォルダで起こし、Claude Code の中の印を外した環境で stdin に編集を渡す")
    func addsPermissionRule() async throws {
        let (conversation, _, cli) = try await make()
        try await conversation.start(resume: false)
        cli.answer(status: 0, stdout: #"{"ok":true,"warnings":["note"],"stored":["Bash(npm test:*)"]}"#)
        let result = try await edit(conversation, .permissionRule(op: .add, behavior: "allow", rules: ["Bash(npm test:*)"], scope: .local))
        // CLI の注意の文は書いた値を引用しうるので、応答に入れない
        #expect(result == ConversationSettingsEditResult(stored: ["Bash(npm test:*)"], needsRestart: false))
        let call = try #require(cli.all.last)
        #expect(call.executable == "/x/claude" && call.arguments == ["edit-permission-rules", "--json"] && call.cwd == "/w/app")
        #expect(call.environment == ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/c"])
        #expect(call.input["op"] as? String == "add" && call.input["rules"] as? [String] == ["Bash(npm test:*)"])
        #expect(call.input["behavior"] as? String == "allow" && call.input["destination"] as? String == "localSettings")
    }

    @Test("断られたら session_command_failed で理由の種類だけを返す。CLI の文は書いた値（規則の秘密）を引用するので、応答にもログにも出さない。止まった会話では CLI を起こさない")
    func rejectsAndNeedsLiveConversation() async throws {
        let logs = LogLines()
        let (conversation, _, cli) = try await make(logs: logs)
        do {
            _ = try await edit(conversation, .memory(autoMemory: false, autoDream: nil))
            Issue.record("止まった会話で書いた")
        } catch let error as ConversationError {
            #expect(error.code == .conversationStopped)
        }
        #expect(cli.all.isEmpty)
        try await conversation.start(resume: false)
        cli.answer(status: 1, stdout: "", stderr: #""Bash(curl -H 'Authorization: Bearer SECRET-TOKEN':*)" is already in the allow rules in user settings"#)
        do {
            _ = try await edit(conversation, .permissionRule(op: .add, behavior: "allow", rules: ["Bash(curl -H 'Authorization: Bearer SECRET-TOKEN':*)"], scope: .user))
            Issue.record("断りを成功にした")
        } catch let error as ConversationError {
            #expect(error.code == .sessionCommandFailed && error.status == 409 && error.params == ["reason": "duplicate"])
            #expect(!error.description.contains("already"))
        }
        #expect(!logs.joined.contains("SECRET-TOKEN") && logs.joined.contains("conversation settings rejected"))
    }

    @Test("hook：一覧の書き換えられる行に鍵を付け、その鍵で外すと一覧に出た元の中身（timeout などの欄も）を target に渡す")
    func removesHookByListingKey() async throws {
        let (conversation, host, cli) = try await make()
        try await conversation.start(resume: false)
        await host.setReply(
            "get_hooks_listing",
            #"{"hooks":[{"event":"PostToolUse","matcher":"Edit","source":"localSettings","type":"command","displayText":"確かめ","commandText":"echo t","timeout":7,"statusMessage":"確かめ","editable":{"matcher":"Edit","config":{"type":"command","command":"echo t","timeout":7,"statusMessage":"確かめ"}}},{"event":"Stop","matcher":"","source":"pluginHook","pluginName":"p","type":"command","commandText":"x"},{"event":"Stop","matcher":"","source":"policySettings","type":"command","commandText":"y","editable":{"matcher":"","config":{"type":"command","command":"y"}}}]}"#)
        let listing = try WireJSON.decoder().decode(
            ConversationHooks.self, from: Data(try #require(try await conversation.control(ConversationControlRequest(kind: .hooks)).payloadJSON).utf8))
        #expect(listing.hooks.map(\.timeoutSeconds) == [7, nil, nil] && listing.hooks.map(\.statusMessage) == ["確かめ", nil, nil])
        #expect(listing.hooks[1].editKey == nil)
        // 書き換えられるかは、鍵があり層が書ける 3 つのどれかか（plugin の hook と、中身を引けても管理者の層の hook は書き換えない）
        #expect(listing.hooks.map(\.editable) == [true, false, false])
        let key = try #require(listing.hooks[0].editKey)
        // 鍵は中身のハッシュで、中身（コマンド）を含まない
        #expect(key.count == 64 && !key.contains("echo"))
        _ = try await edit(conversation, .hook(op: .remove, scope: .local, event: "PostToolUse", matcher: "Edit", hook: nil, editKey: key))
        let call = try #require(cli.all.last)
        #expect(call.arguments == ["edit-hook", "--json"])
        #expect(call.input["op"] as? String == "remove" && call.input["source"] as? String == "localSettings" && call.input["event"] as? String == "PostToolUse")
        let target = try #require(call.input["target"] as? [String: Any])
        #expect(target["event"] as? String == "PostToolUse" && target["matcher"] as? String == "Edit")
        let config = try #require(target["hook"] as? [String: Any])
        #expect(config["command"] as? String == "echo t" && config["timeout"] as? Int == 7 && config["statusMessage"] as? String == "確かめ")
        #expect(call.input["hook"] == nil)

        // 一覧を開いた後に変わった（鍵が今の一覧に無い）hook は書かない
        do {
            _ = try await edit(conversation, .hook(op: .remove, scope: .local, event: "PostToolUse", matcher: "Edit", hook: nil, editKey: String(repeating: "0", count: 64)))
            Issue.record("無い hook を外した")
        } catch let error as ConversationError {
            #expect(error.code == .sessionCommandFailed && error.params == ["reason": "not_found"])
        }
        // 鍵の層と違う層では書かない
        do {
            _ = try await edit(conversation, .hook(op: .remove, scope: .user, event: "PostToolUse", matcher: "Edit", hook: nil, editKey: key))
            Issue.record("違う層で書いた")
        } catch let error as ConversationError {
            #expect(error.code == .invalidRequest)
        }
    }

    @Test("読む画面：外せる規則（ユーザー・作業フォルダの設定）に印を付け、メモリの切り替えと sandbox の状態を写す（英語の状態の文と依存の誤りの文は写さない）")
    func readoutsForEditing() async throws {
        let (conversation, host, _) = try await make()
        try await conversation.start(resume: false)
        await host.setReply(
            "list_permission_rules",
            #"{"state":{"rules":[{"behavior":"allow","source":"localSettings","rule":"Bash(npm test:*)"},{"behavior":"deny","source":"policySettings","rule":"WebFetch"}],"workspaceDirectories":[]}}"#)
        await host.setReply(
            "get_memory_dialog",
            #"{"files":[],"auto_memory":{"enabled":true,"toggleable":true,"status":"on"},"auto_dream":{"shown":false,"enabled":false,"toggleable":false,"status":"off while auto-memory is off","detail":""}}"#)
        await host.setReply(
            "get_sandbox_dialog",
            #"{"supported":true,"locked":false,"overrides_locked":false,"enabled":true,"enabled_in_settings":true,"mode":"regular","auto_allow_available":true,"no_sandbox_allowed":true,"unsandboxed_fallback":true,"dependencies":{"errors":["bwrap is missing"],"warnings":[]},"excluded_commands":["docker"],"restrictions":{}}"#)
        func read<T: Decodable>(_ kind: ConversationControlRequest.Kind, _ type: T.Type) async throws -> T {
            try WireJSON.decoder().decode(type, from: Data(try #require(try await conversation.control(ConversationControlRequest(kind: kind)).payloadJSON).utf8))
        }
        #expect(try await read(.permissionRules, ConversationPermissionRules.self).rules.map(\.editable) == [true, false])
        let memory = try await read(.memory, ConversationMemory.self)
        #expect(memory.autoMemory == .init(enabled: true, toggleable: true) && memory.autoDream == .init(enabled: false, toggleable: false))
        let sandbox = try await read(.sandbox, ConversationSandbox.self)
        #expect(
            sandbox
                == ConversationSandbox(
                    supported: true, locked: false, enabled: true, mode: "regular", autoAllowAvailable: true, allowUnsandboxedCommands: true,
                    excludedCommands: ["docker"], missingDependencies: true))
    }

    @Test("読み替え：書く先ごとのサブコマンドと stdin の JSON（2.1.304 で実測した形）")
    func invocations() throws {
        func json(_ edit: ConversationSettingsEdit) throws -> (String, String) {
            let invocation = try ClaudeSettingsEdits.invocation(edit)
            return (invocation.subcommand, String(decoding: invocation.input, as: UTF8.self))
        }
        #expect(
            try json(.permissionRule(op: .remove, behavior: "deny", rules: ["WebFetch(domain:example.com)"], scope: .project))
                == ("edit-permission-rules", #"{"behavior":"deny","op":"remove","rule":"WebFetch(domain:example.com)","source":"projectSettings"}"#))
        #expect(
            try json(.hook(op: .add, scope: .user, event: "PreToolUse", matcher: "Bash", hook: .init(type: "command", command: "echo hi", timeout: 5), editKey: nil))
                == ("edit-hook", #"{"event":"PreToolUse","hook":{"command":"echo hi","timeout":5,"type":"command"},"matcher":"Bash","op":"add","source":"userSettings"}"#))
        #expect(try json(.memory(autoMemory: nil, autoDream: true)) == ("edit-memory-settings", #"{"autoDreamEnabled":true}"#))
        #expect(try json(.skill(name: "demo", state: "name-only")) == ("edit-skill-overrides", #"{"name":"demo","state":"name-only"}"#))
        #expect(try json(.sandbox(mode: "regular", allowUnsandboxedCommands: false)) == ("edit-sandbox-settings", #"{"allowUnsandboxedCommands":false,"mode":"regular"}"#))
        for broken: ConversationSettingsEdit in [
            .permissionRule(op: .remove, behavior: "allow", rules: ["a", "b"], scope: .user), .permissionRule(op: .replace, behavior: "allow", rules: ["a"], scope: .user),
            .hook(op: .add, scope: .user, event: "Stop", matcher: "", hook: nil, editKey: nil),
            .hook(op: .replace, scope: .user, event: "Stop", matcher: "", hook: .init(type: "command", command: "x"), editKey: "壊れた鍵"),
            .memory(autoMemory: nil, autoDream: nil), .sandbox(mode: nil, allowUnsandboxedCommands: nil),
        ] {
            #expect(throws: ConversationError.self, "\(broken)") { try ClaudeSettingsEdits.invocation(broken) }
        }
    }

    @Test("答え：成功は ok の行、hook の断りは code、ほかは CLI の文で理由の種類に分ける。終わらなかった子は失敗")
    func answers() throws {
        func outcome(_ status: Int32, _ out: String, _ err: String = "", timedOut: Bool = false) -> Subprocess.Outcome {
            Subprocess.Outcome(status: status, stdout: Data(out.utf8), stderr: Data(err.utf8), timedOut: timedOut, overflowed: false)
        }
        #expect(try ClaudeSettingsEdits.answer(outcome(0, #"{"ok":true,"written":{"name":"demo","state":"off"},"changed":true}"#)) == .written(.init(), warnings: 0))
        #expect(
            try ClaudeSettingsEdits.answer(
                outcome(1, #"{"ok":false,"error":"edit_hook: an identical hook is already configured for PreToolUse in userSettings","code":"duplicate"}"#, "edit_hook: ..."))
                == .rejected(reason: "duplicate", status: 1))
        let cases: [(String, String)] = [
            ("rule not found: no deny rule with this exact value in project local settings", "not_found"),
            ("This setting cannot be changed from an editor started inside a Claude Code session. Start the editor outside the session and try again.", "locked"),
            ("Sandbox settings are set by a higher-priority configuration and cannot be changed here.", "locked"),
            ("the user settings file has errors and could not be loaded; fix it by hand first", "file_error"),
            ("Not a skill state edit (state: Invalid option: expected one of \"on\"|\"name-only\"|\"user-invocable-only\"|\"off\").", "invalid"),
            ("予期しない失敗", "other"),
        ]
        for (message, reason) in cases {
            #expect(try ClaudeSettingsEdits.answer(outcome(1, "", message)) == .rejected(reason: reason, status: 1), "\(message)")
        }
        #expect(throws: ConversationError.self) { try ClaudeSettingsEdits.answer(outcome(0, "", timedOut: true)) }
    }

    @Test("hook の鍵：中身のハッシュで、中身・層・出来事・matcher のどれが違っても別の鍵になる。一覧の書き換えられる行だけを鍵で引ける（日本語と記号を含む）")
    func hookKeys() throws {
        let config: [String: Any] = ["type": "command", "command": "echo '確かめ' && exit 0", "timeout": 7]
        let key = try #require(ClaudeSettingsEdits.hookKey(event: "PreToolUse", source: "userSettings", matcher: "Bash|Edit", config: config))
        #expect(key.count == 64)
        var other = config
        other["timeout"] = 8
        let variants = [
            ClaudeSettingsEdits.hookKey(event: "PreToolUse", source: "userSettings", matcher: "Bash|Edit", config: other),
            ClaudeSettingsEdits.hookKey(event: "PreToolUse", source: "localSettings", matcher: "Bash|Edit", config: config),
            ClaudeSettingsEdits.hookKey(event: "PostToolUse", source: "userSettings", matcher: "Bash|Edit", config: config),
            ClaudeSettingsEdits.hookKey(event: "PreToolUse", source: "userSettings", matcher: "Bash", config: config),
        ]
        #expect(Set(variants.compactMap { $0 } + [key]).count == 5)
        let listing = #"{"hooks":[{"event":"PreToolUse","source":"userSettings","matcher":"Bash|Edit","editable":{"matcher":"Bash|Edit","config":{"type":"command","command":"echo '確かめ' && exit 0","timeout":7}}},{"event":"Stop","source":"pluginHook"}]}"#
        let targets = ClaudeSettingsEdits.hookTargets(listing: listing)
        #expect(targets.map(\.key) == [key])
        #expect(targets.first?.target.config["command"] as? String == "echo '確かめ' && exit 0")
        #expect(ClaudeSettingsEdits.hookTargets(listing: nil).isEmpty && ClaudeSettingsEdits.hookTargets(listing: "not json").isEmpty)
    }
}
