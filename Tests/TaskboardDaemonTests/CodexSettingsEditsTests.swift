import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("codex の設定の書き込みの読み替え")
struct CodexSettingsEditsTests {
    private static let file = "/Users/u/.codex/config.toml"

    private func layer(_ toml: [String: Any]) -> CodexSettingsEdits.UserLayer {
        CodexSettingsEdits.UserLayer(file: Self.file, version: "sha256:v1", config: toml)
    }

    private func json(_ write: CodexSettingsEdits.Write) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: write.edits, options: [.sortedKeys]), as: UTF8.self)
    }

    private func reason(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as ConversationError {
            return error.params["reason"] ?? error.code.rawValue
        } catch {
            return "\(error)"
        }
    }

    private func item(_ key: String, event: String = "preToolUse", command: String? = "echo a", hash: String = "sha256:h1", managed: Bool = false)
        -> CodexSettingsEdits.HookItem
    {
        let path = key.split(separator: ":").first.map(String.init) ?? ""
        return .init(key: key, event: event, sourcePath: path, command: command, currentHash: hash, managed: managed)
    }

    @Test("user の層は config/read の layers から、ファイルと版と中身を取る。user の層が無ければ nil")
    func userLayer() {
        let read: [String: Any] = [
            "layers": [
                ["name": ["type": "project", "dotCodexFolder": "/w/.codex"], "version": "sha256:p", "config": ["model": "x"]],
                ["name": ["type": "user", "file": Self.file], "version": "sha256:u", "config": ["approval_policy": "never"]],
            ]
        ]
        let found = CodexSettingsEdits.userLayer(read)
        #expect(found?.file == Self.file && found?.version == "sha256:u" && found?.config["approval_policy"] as? String == "never")
        #expect(CodexSettingsEdits.userLayer(["layers": []]) == nil)
    }

    @Test("権限の設定：表の鍵だけを書き、真偽の鍵は true・false だけ、nil で鍵を消す。承認と sandbox と profile は権限のモードが勝ち、workspace-write の値と振り先は次に開いたときから")
    func permissionSetting() throws {
        #expect(try json(CodexSettingsEdits.permissionSetting(key: "approval_policy", value: "never")) == #"[{"keyPath":"approval_policy","mergeStrategy":"replace","value":"never"}]"#)
        #expect(
            try json(CodexSettingsEdits.permissionSetting(key: "sandbox_workspace_write.network_access", value: "true"))
                == #"[{"keyPath":"sandbox_workspace_write.network_access","mergeStrategy":"replace","value":true}]"#)
        #expect(try json(CodexSettingsEdits.permissionSetting(key: "approvals_reviewer", value: nil)) == #"[{"keyPath":"approvals_reviewer","mergeStrategy":"replace","value":null}]"#)
        for key in ["approval_policy", "sandbox_mode", "default_permissions"] {
            #expect(try CodexSettingsEdits.permissionSetting(key: key, value: "x").effect == .permissionMode, "\(key)")
        }
        for key in ["approvals_reviewer", "sandbox_workspace_write.network_access", "sandbox_workspace_write.exclude_tmpdir_env_var", "sandbox_workspace_write.exclude_slash_tmp"] {
            #expect(try CodexSettingsEdits.permissionSetting(key: key, value: key.hasPrefix("sandbox") ? "false" : "user").effect == .nextOpen, "\(key)")
        }
        // 表に無い鍵（MCP の server のヘッダなど）と、型の合わない値は書かない
        #expect(reason { try CodexSettingsEdits.permissionSetting(key: "mcp_servers.ctx.http_headers.KEY", value: "x") } == "invalid_request")
        #expect(reason { try CodexSettingsEdits.permissionSetting(key: "sandbox_workspace_write.network_access", value: "yes") } == "invalid_request")
        #expect(reason { try CodexSettingsEdits.permissionSetting(key: "approval_policy", value: "") } == "invalid_request")
    }

    @Test("MCP の server：ユーザーの設定にある server の enabled だけを書く。ほかの層だけにあるものは locked、どこにも無いものは not_found、点を含む名前は書かない")
    func mcpServer() throws {
        let user = layer(["mcp_servers": ["ctx": ["command": "/bin/ctx"]]])
        let merged: [String: Any] = ["mcp_servers": ["ctx": ["command": "/bin/ctx"], "repo": ["command": "/bin/repo"]]]
        let write = try CodexSettingsEdits.mcpServer(name: "ctx", enabled: false, layer: user, config: merged)
        #expect(try json(write) == #"[{"keyPath":"mcp_servers.ctx.enabled","mergeStrategy":"replace","value":false}]"#)
        #expect(write.effect == .now)
        #expect(reason { try CodexSettingsEdits.mcpServer(name: "repo", enabled: false, layer: user, config: merged) } == "locked")
        #expect(reason { try CodexSettingsEdits.mcpServer(name: "nope", enabled: false, layer: user, config: merged) } == "not_found")
        #expect(reason { try CodexSettingsEdits.mcpServer(name: "a.b", enabled: false, layer: user, config: merged) } == "invalid_request")
    }

    @Test("skill：一覧にある名前のパスを引く。無い名前は not_found、同じ名前が 2 つあればパスで選ぶ（選べなければ ambiguous）。状態は on と off だけ")
    func skill() throws {
        let list: [String: Any] = [
            "data": [
                [
                    "cwd": "/w",
                    "skills": [
                        ["name": "lint", "path": "/Users/u/.codex/skills/lint/SKILL.md"], ["name": "lint", "path": "/w/.codex/skills/lint/SKILL.md"],
                        ["name": "commit", "path": "/Users/u/.codex/skills/commit/SKILL.md"],
                    ],
                ]
            ]
        ]
        #expect(try CodexSettingsEdits.skillPath(list, name: "commit", path: nil) == "/Users/u/.codex/skills/commit/SKILL.md")
        #expect(try CodexSettingsEdits.skillPath(list, name: "lint", path: "/w/.codex/skills/lint/SKILL.md") == "/w/.codex/skills/lint/SKILL.md")
        #expect(reason { try CodexSettingsEdits.skillPath(list, name: "lint", path: nil) } == "ambiguous")
        #expect(reason { try CodexSettingsEdits.skillPath(list, name: "zebra", path: nil) } == "not_found")
        #expect(try CodexSettingsEdits.skillEnabled("on") && !(try CodexSettingsEdits.skillEnabled("off")))
        #expect(reason { try CodexSettingsEdits.skillEnabled("name-only") } == "invalid_request")
    }

    @Test("hook を足す：出来事の配列の後ろに group を足す。matcher が空なら鍵を省き、時間の上限と表示の文は Claude と同じ名前。command だけ、codex の出来事だけ、ユーザーの設定だけ")
    func addHook() throws {
        let user = layer(["hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "echo a"]]]]]])
        let body = ConversationSettingsEdit.HookBody(type: "command", command: "echo b", timeout: 7, statusMessage: "確かめています")
        let write = try CodexSettingsEdits.hook(op: .add, scope: .user, event: "PreToolUse", matcher: "", body: body, target: nil, layer: user)
        #expect(
            try json(write)
                == #"[{"keyPath":"hooks.PreToolUse","mergeStrategy":"replace","value":[{"hooks":[{"command":"echo a","type":"command"}]},{"hooks":[{"command":"echo b","statusMessage":"確かめています","timeout":7,"type":"command"}]}]}]"#
        )
        let matched = try CodexSettingsEdits.hook(op: .add, scope: .user, event: "Stop", matcher: "Bash", body: .init(type: "command", command: "x"), target: nil, layer: layer([:]))
        #expect(try json(matched) == #"[{"keyPath":"hooks.Stop","mergeStrategy":"replace","value":[{"hooks":[{"command":"x","type":"command"}],"matcher":"Bash"}]}]"#)
        #expect(reason { try CodexSettingsEdits.hook(op: .add, scope: .user, event: "Stop", matcher: "", body: .init(type: "prompt", prompt: "p"), target: nil, layer: user) } == "invalid_request")
        #expect(reason { try CodexSettingsEdits.hook(op: .add, scope: .user, event: "NotAnEvent", matcher: "", body: body, target: nil, layer: user) } == "invalid_request")
        #expect(reason { try CodexSettingsEdits.hook(op: .add, scope: .project, event: "Stop", matcher: "", body: body, target: nil, layer: user) } == "invalid_request")
    }

    @Test("hook を外す：handler を外し、空になった group と出来事も消す。後ろの hook の信頼の鍵を詰め直し、外した hook の信頼は消す。ほかのファイルの hook は locked、中身が替わっていれば not_found")
    func removeHook() throws {
        let prefix = "\(Self.file):pre_tool_use"
        let user = layer([
            "hooks": [
                "PreToolUse": [["hooks": [["type": "command", "command": "echo a"]]], ["matcher": "Bash", "hooks": [["type": "command", "command": "echo b"]]]],
                "state": [
                    "\(prefix):0:0": ["trusted_hash": "sha256:a", "enabled": true], "\(prefix):1:0": ["trusted_hash": "sha256:b"],
                    "/w/.codex/hooks.json:pre_tool_use:1:0": ["enabled": false],
                ],
            ]
        ])
        let write = try CodexSettingsEdits.hook(op: .remove, scope: .user, event: "PreToolUse", matcher: "", body: nil, target: item("\(prefix):0:0"), layer: user)
        #expect(
            try json(write)
                == #"[{"keyPath":"hooks.PreToolUse","mergeStrategy":"replace","value":[{"hooks":[{"command":"echo b","type":"command"}],"matcher":"Bash"}]},{"keyPath":"hooks.state","mergeStrategy":"replace","value":{"\/Users\/u\/.codex\/config.toml:pre_tool_use:0:0":{"trusted_hash":"sha256:b"},"\/w\/.codex\/hooks.json:pre_tool_use:1:0":{"enabled":false}}}]"#
        )
        let only = layer(["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo a"]]]]]])
        let last = try CodexSettingsEdits.hook(op: .remove, scope: .user, event: "Stop", matcher: "", body: nil, target: item("\(Self.file):stop:0:0", event: "stop"), layer: only)
        #expect(try json(last) == #"[{"keyPath":"hooks.Stop","mergeStrategy":"replace","value":null},{"keyPath":"hooks.state","mergeStrategy":"replace","value":null}]"#)
        #expect(
            reason {
                try CodexSettingsEdits.hook(op: .remove, scope: .user, event: "PreToolUse", matcher: "", body: nil, target: item("/w/.codex/hooks.json:pre_tool_use:1:0"), layer: user)
            } == "locked")
        #expect(
            reason {
                try CodexSettingsEdits.hook(op: .remove, scope: .user, event: "PreToolUse", matcher: "", body: nil, target: item("\(prefix):0:0", command: "echo z"), layer: user)
            } == "not_found")
        #expect(reason { try CodexSettingsEdits.hook(op: .remove, scope: .user, event: "PreToolUse", matcher: "", body: nil, target: item("\(prefix):5:0"), layer: user) } == "not_found")
    }

    @Test("hook を置き換える：同じ出来事と matcher なら handler をその場で替える（信頼の鍵は動かない）。matcher か出来事が替われば、外してから足す")
    func replaceHook() throws {
        let prefix = "\(Self.file):pre_tool_use"
        let user = layer([
            "hooks": [
                "PreToolUse": [["hooks": [["type": "command", "command": "echo a"], ["type": "command", "command": "echo b"]]]],
                "state": ["\(prefix):0:1": ["trusted_hash": "sha256:b"]],
            ]
        ])
        let body = ConversationSettingsEdit.HookBody(type: "command", command: "echo c")
        let inPlace = try CodexSettingsEdits.hook(op: .replace, scope: .user, event: "PreToolUse", matcher: "", body: body, target: item("\(prefix):0:0"), layer: user)
        #expect(
            try json(inPlace)
                == #"[{"keyPath":"hooks.PreToolUse","mergeStrategy":"replace","value":[{"hooks":[{"command":"echo c","type":"command"},{"command":"echo b","type":"command"}]}]}]"#
        )
        let moved = try CodexSettingsEdits.hook(op: .replace, scope: .user, event: "Stop", matcher: "", body: body, target: item("\(prefix):0:0"), layer: user)
        #expect(
            try json(moved)
                == #"[{"keyPath":"hooks.PreToolUse","mergeStrategy":"replace","value":[{"hooks":[{"command":"echo b","type":"command"}]}]},{"keyPath":"hooks.Stop","mergeStrategy":"replace","value":[{"hooks":[{"command":"echo c","type":"command"}]}]},{"keyPath":"hooks.state","mergeStrategy":"replace","value":{"\/Users\/u\/.codex\/config.toml:pre_tool_use:0:0":{"trusted_hash":"sha256:b"}}}]"#
        )
    }

    @Test("hook の有効と信頼：信頼は今の中身の hash を書き、外すと hash だけを消す。中身が空になった鍵は消す。管理者の hook は locked")
    func hookState() throws {
        let key = "/w/.codex/hooks.json:stop:0:0"
        let user = layer(["hooks": ["state": [key: ["enabled": false, "trusted_hash": "sha256:old"]]]])
        let trusted = try CodexSettingsEdits.hookState(target: item(key, hash: "sha256:new"), enabled: true, trusted: true, layer: user)
        #expect(
            try json(trusted)
                == #"[{"keyPath":"hooks.state","mergeStrategy":"replace","value":{"\/w\/.codex\/hooks.json:stop:0:0":{"enabled":true,"trusted_hash":"sha256:new"}}}]"#)
        let untrusted = try CodexSettingsEdits.hookState(target: item(key), enabled: nil, trusted: false, layer: user)
        #expect(try json(untrusted) == #"[{"keyPath":"hooks.state","mergeStrategy":"replace","value":{"\/w\/.codex\/hooks.json:stop:0:0":{"enabled":false}}}]"#)
        let cleared = try CodexSettingsEdits.hookState(target: item(key), enabled: nil, trusted: false, layer: layer(["hooks": ["state": [key: ["trusted_hash": "x"]]]]))
        #expect(try json(cleared) == #"[{"keyPath":"hooks.state","mergeStrategy":"replace","value":null}]"#)
        #expect(reason { try CodexSettingsEdits.hookState(target: item(key, managed: true), enabled: false, trusted: nil, layer: user) } == "locked")
        #expect(reason { try CodexSettingsEdits.hookState(target: item(key), enabled: nil, trusted: nil, layer: user) } == "invalid_request")
    }

    @Test("hook の鍵：hooks/list の key と中身の hash から作り、中身が替わると替わる（64 字の 16 進）")
    func editKey() {
        let a = item("/f:stop:0:0", hash: "sha256:1").editKey
        #expect(a.count == 64 && a.allSatisfy(\.isHexDigit))
        #expect(a != item("/f:stop:0:0", hash: "sha256:2").editKey && a != item("/f:stop:0:1", hash: "sha256:1").editKey)
        #expect(item("/a:b/c.json:stop:3:4").position! == ("/a:b/c.json:stop", 3, 4))
    }

    @Test("結果：次に開いたときから効くものは needsRestart、権限のモードが勝つものは overriddenBy が permission_mode、上の層が上書きしていればその層の名前")
    func result() {
        #expect(CodexSettingsEdits.result(.now, response: ["status": "ok"]) == .init())
        #expect(CodexSettingsEdits.result(.nextOpen, response: ["status": "ok"]) == .init(needsRestart: true))
        #expect(CodexSettingsEdits.result(.permissionMode, response: ["status": "ok"]) == .init(overriddenBy: "permission_mode"))
        let overridden: [String: Any] = [
            "status": "okOverridden", "overriddenMetadata": ["message": "英語の文", "overridingLayer": ["name": ["type": "system", "file": "/etc/codex/managed_config.toml"]]],
        ]
        #expect(CodexSettingsEdits.result(.nextOpen, response: overridden) == .init(needsRestart: true, overriddenBy: "system"))
    }

    @Test("書き込みの失敗の理由：版の衝突は conflict、検証の誤りは invalid、書けない層は locked、ほかは other")
    func reasons() throws {
        func line(_ code: String?) throws -> CodexRPCLine {
            let data = code.map { #","data":{"config_write_error_code":"\#($0)"}"# } ?? ""
            return try #require(CodexRPCLine(Data(#"{"id":"1","error":{"code":-32600,"message":"m"\#(data)}}"#.utf8)))
        }
        #expect(CodexSettingsEdits.reason(try line("configVersionConflict")) == "conflict")
        #expect(CodexSettingsEdits.reason(try line("configValidationError")) == "invalid")
        #expect(CodexSettingsEdits.reason(try line("configLayerReadonly")) == "locked")
        #expect(CodexSettingsEdits.reason(try line(nil)) == "other")
    }
}
