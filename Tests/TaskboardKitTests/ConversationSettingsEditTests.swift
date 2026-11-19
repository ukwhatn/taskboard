import Foundation
import Testing

@testable import TaskboardKit

@Suite("設定の書き込みの要求（Kit）")
struct ConversationSettingsEditTests {
    @Test("target で中身を分けた JSON と往復する。省いた欄は省いたまま")
    func roundTrips() throws {
        let cases: [(ConversationSettingsEdit, String)] = [
            (.permissionRule(op: .add, behavior: "allow", rules: ["Bash(npm test:*)"], scope: .local),
             #"{"behavior":"allow","op":"add","rules":["Bash(npm test:*)"],"scope":"localSettings","target":"permission_rule"}"#),
            (.hook(op: .remove, scope: .user, event: "Stop", matcher: "", hook: nil, editKey: "k"),
             #"{"editKey":"k","event":"Stop","matcher":"","op":"remove","scope":"userSettings","target":"hook"}"#),
            (.memory(autoMemory: false, autoDream: nil), #"{"autoMemory":false,"target":"memory"}"#),
            (.skill(name: "demo", state: "off"), #"{"name":"demo","state":"off","target":"skill"}"#),
            (.sandbox(mode: "regular", allowUnsandboxedCommands: nil), #"{"mode":"regular","target":"sandbox"}"#),
            (.skill(name: "lint", path: "/w/.codex/skills/lint/SKILL.md", state: "on"),
             #"{"name":"lint","path":"\/w\/.codex\/skills\/lint\/SKILL.md","state":"on","target":"skill"}"#),
            (.permissionSetting(key: "sandbox_workspace_write.network_access", value: "true"),
             #"{"key":"sandbox_workspace_write.network_access","target":"permission_setting","value":"true"}"#),
            (.permissionSetting(key: "approvals_reviewer", value: nil), #"{"key":"approvals_reviewer","target":"permission_setting"}"#),
            (.hookState(editKey: "k", enabled: nil, trusted: true), #"{"editKey":"k","target":"hook_state","trusted":true}"#),
            (.mcpServer(name: "ctx", enabled: false), #"{"enabled":false,"name":"ctx","target":"mcp_server"}"#),
            (.plugin(op: .install, id: "cmdp@m", scope: .user, acceptCommand: "fe01"),
             #"{"acceptCommand":"fe01","id":"cmdp@m","op":"install","scope":"userSettings","target":"plugin"}"#),
            (.plugin(op: .purge, id: "p@m", confirm: true, confirmDigest: "d1"), #"{"confirm":true,"confirmDigest":"d1","id":"p@m","op":"purge","target":"plugin"}"#),
            (.marketplace(op: .remove, name: "m", confirm: true, confirmDigest: "d2"), #"{"confirm":true,"confirmDigest":"d2","name":"m","op":"remove","target":"marketplace"}"#),
            (.marketplace(op: .add, source: "/tmp/m", scope: .project), #"{"op":"add","scope":"projectSettings","source":"\/tmp\/m","target":"marketplace"}"#),
            (.marketplace(op: .remove, name: "m"), #"{"name":"m","op":"remove","target":"marketplace"}"#),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (edit, json) in cases {
            #expect(String(decoding: try encoder.encode(edit), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(ConversationSettingsEdit.self, from: Data(json.utf8)) == edit)
        }
        // hook の matcher を省いた要求は空の matcher
        let bare = try JSONDecoder().decode(
            ConversationSettingsEdit.self, from: Data(#"{"target":"hook","op":"add","scope":"userSettings","event":"Stop","hook":{"type":"command","command":"x"}}"#.utf8))
        #expect(bare == .hook(op: .add, scope: .user, event: "Stop", matcher: "", hook: .init(type: "command", command: "x"), editKey: nil))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ConversationSettingsEdit.self, from: Data(#"{"target":"nope"}"#.utf8)) }
    }

    @Test("書き込みは Claude と codex で使え、書ける設定は engine ごとに違う。sandbox の読む画面は Claude だけ。知らない engine は使えない。前の版の要求（edit なし）も読める")
    func capabilities() throws {
        #expect(Conversation.Engine.claude.supports(ConversationControlRequest.Kind.editSettings) && Conversation.Engine.codex.supports(ConversationControlRequest.Kind.editSettings))
        #expect(Conversation.Engine.claude.supports(ConversationControlRequest.Kind.sandbox) && !Conversation.Engine.codex.supports(ConversationControlRequest.Kind.sandbox))
        #expect(Conversation.Engine.claude.supports(ConversationControlRequest.Kind.plugins) && Conversation.Engine.codex.supports(ConversationControlRequest.Kind.plugins))
        let claude: Set<ConversationSettingsEdit.Target> = [.permissionRule, .hook, .memory, .skill, .sandbox, .plugin, .marketplace]
        let codex: Set<ConversationSettingsEdit.Target> = [.permissionSetting, .hook, .hookState, .skill, .mcpServer, .plugin, .marketplace]
        for target in ConversationSettingsEdit.Target.allCases {
            #expect(Conversation.Engine.claude.supports(edit: target) == claude.contains(target), "\(target)")
            #expect(Conversation.Engine.codex.supports(edit: target) == codex.contains(target), "\(target)")
            #expect(!Conversation.Engine.unknown.supports(edit: target))
        }
        let old = try JSONDecoder().decode(ConversationControlRequest.self, from: Data(#"{"kind":"hooks"}"#.utf8))
        #expect(old.kind == .hooks && old.edit == nil)
    }

    @Test("入れられる plugin の絞り込み：id・名前・説明に文字を含むもの（大文字と小文字は区別しない、日本語も）。空なら全部。200 件までで、数は全体")
    func filtersAvailablePlugins() {
        let plugins = (0..<230).map { ConversationPlugins.Plugin(id: "t\($0)@m", name: "t\($0)", marketplace: "m", installed: false) }
            + [.init(id: "z@m", name: "Zebra", marketplace: "m", description: "縞の馬", installed: false)]
        let all = ConversationPlugins.filtered(plugins, query: "  ")
        #expect(all.plugins.count == ConversationPlugins.availableLimit && all.total == 231)
        #expect(ConversationPlugins.filtered(plugins, query: "zEB").plugins.map(\.id) == ["z@m"])
        #expect(ConversationPlugins.filtered(plugins, query: "縞").plugins.map(\.id) == ["z@m"])
        #expect(ConversationPlugins.filtered(plugins, query: "t22").total == 11)
        #expect(ConversationPlugins.filtered([], query: nil).total == 0)
    }

    @Test("確かめた後の送り直し：コマンドを見た plugin は sha256 を、設定が消える確認は confirm と digest を付け、ほかの欄はそのまま。plugin と marketplace 以外は替えない")
    func resendsAfterReview() {
        #expect(
            ConversationSettingsEdit.plugin(op: .install, id: "cmdp@m", scope: .user).accepting(command: "fe01")
                == .plugin(op: .install, id: "cmdp@m", scope: .user, acceptCommand: "fe01"))
        #expect(
            ConversationSettingsEdit.plugin(op: .update, id: "p@m", acceptCommand: "old").accepting(command: "new")
                == .plugin(op: .update, id: "p@m", acceptCommand: "new"))
        #expect(
            ConversationSettingsEdit.plugin(op: .uninstall, id: "p@m", scope: .project, confirm: true, confirmDigest: "d1").confirming(digest: "d2")
                == .plugin(op: .uninstall, id: "p@m", scope: .project, confirm: true, confirmDigest: "d2"))
        #expect(
            ConversationSettingsEdit.marketplace(op: .remove, name: "m", scope: .user).confirming(digest: "d3")
                == .marketplace(op: .remove, name: "m", scope: .user, confirm: true, confirmDigest: "d3"))
        let memory = ConversationSettingsEdit.memory(autoMemory: true, autoDream: nil)
        #expect(memory.accepting(command: "x") == memory && memory.confirming(digest: "x") == memory)
    }
}
