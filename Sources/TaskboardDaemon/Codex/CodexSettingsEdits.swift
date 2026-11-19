import CryptoKit
import Foundation
import TaskboardKit

/// `edit_settings` を codex app-server の `config/batchWrite` の edits に読み替える（0.162.1 で実測）。
/// codex が書けるのはユーザーの `config.toml` だけなので、今の中身は `config/read` の user の層から読み、表と配列は丸ごと書き直す
/// （`upsert` は入れ子の表を深く混ぜ、鍵を外せない）
enum CodexSettingsEdits {
    /// `config/read`（`includeLayers`）の user の層
    struct UserLayer {
        var file: String
        var version: String
        var config: [String: Any]
    }

    static func userLayer(_ result: [String: Any]?) -> UserLayer? {
        let layers = result?["layers"] as? [[String: Any]] ?? []
        guard let layer = layers.first(where: { ($0["name"] as? [String: Any])?["type"] as? String == "user" }),
            let file = (layer["name"] as? [String: Any])?["file"] as? String, let version = layer["version"] as? String
        else { return nil }
        return UserLayer(file: file, version: version, config: layer["config"] as? [String: Any] ?? [:])
    }

    /// 書いた値が効く時
    enum Effect: Equatable {
        /// 動いている thread に効く（`reloadUserConfig` で読み直させる）
        case now
        /// 次に thread を開いたとき（始める・戻す）から効く
        case nextOpen
        /// taskboard の会話には効かない。thread を開くときと turn ごとに渡す承認の方針と sandbox が勝つ
        case permissionMode
    }

    struct Write {
        /// `config/batchWrite` の edits（`keyPath`・`value`・`mergeStrategy`）
        var edits: [[String: Any]]
        var effect: Effect
    }

    // MARK: 権限の設定

    private enum ValueType { case text, bool }

    /// 書ける権限の鍵。ほかの鍵（MCP の server のヘッダなど）は書かせない
    private static let permissionKeys: [String: (type: ValueType, effect: Effect)] = [
        "approval_policy": (.text, .permissionMode),
        "sandbox_mode": (.text, .permissionMode),
        "default_permissions": (.text, .permissionMode),
        // taskboard は承認の振り先を渡さないので、開いたときの設定が効く
        "approvals_reviewer": (.text, .nextOpen),
        // workspace-write の細かい値は、開くときに渡す sandbox に重なる
        "sandbox_workspace_write.network_access": (.bool, .nextOpen),
        "sandbox_workspace_write.exclude_tmpdir_env_var": (.bool, .nextOpen),
        "sandbox_workspace_write.exclude_slash_tmp": (.bool, .nextOpen),
    ]

    static func permissionSetting(key: String, value: String?) throws -> Write {
        guard let entry = permissionKeys[key] else { throw ConversationError.invalid("権限の鍵 \(key) は書けない") }
        let typed: Any
        switch (entry.type, value) {
        case (_, nil): typed = NSNull()
        case (.text, let text?):
            guard !text.isEmpty else { throw ConversationError.invalid("値が空") }
            typed = text
        case (.bool, "true"): typed = true
        case (.bool, "false"): typed = false
        case (.bool, _): throw ConversationError.invalid("\(key) は true か false")
        }
        return Write(edits: [replace(key, typed)], effect: entry.effect)
    }

    // MARK: MCP の server

    static func mcpServer(name: String, enabled: Bool, layer: UserLayer, config: [String: Any]?) throws -> Write {
        // 鍵は点で切るので、点を含む名前は書けない
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw ConversationError.invalid("MCP の server の名前 \(name) は書けない")
        }
        guard (layer.config["mcp_servers"] as? [String: Any])?[name] != nil else {
            // ほかの層の server にユーザーの設定で enabled だけを書くと、中身の無い server の表ができる
            let elsewhere = (config?["mcp_servers"] as? [String: Any])?[name] != nil
            throw ConversationError.settingsRejected(elsewhere ? "locked" : "not_found")
        }
        return Write(edits: [replace("mcp_servers.\(name).enabled", enabled)], effect: .now)
    }

    // MARK: skill

    /// `skills/list` の今の作業フォルダの分から、書く skill のパスを引く（codex は無い名前でも断らずに書く）
    static func skillPath(_ result: [String: Any]?, name: String, path: String?) throws -> String {
        let skills = (result?["data"] as? [[String: Any]] ?? []).flatMap { $0["skills"] as? [[String: Any]] ?? [] }
        let matches = Set(
            skills.compactMap { skill -> String? in
                guard skill["name"] as? String == name, let found = skill["path"] as? String else { return nil }
                return path == nil || path == found ? found : nil
            })
        guard let first = matches.first else { throw ConversationError.settingsRejected("not_found") }
        guard matches.count == 1 else { throw ConversationError.settingsRejected("ambiguous") }
        return first
    }

    static func skillEnabled(_ state: String) throws -> Bool {
        switch state {
        case "on": return true
        case "off": return false
        default: throw ConversationError.invalid("codex の skill は on か off")
        }
    }

    // MARK: hook

    /// `hooks/list` の 1 行。`key` は「設定のファイルのパス:出来事:配列の位置:handler の位置」
    struct HookItem {
        var key: String
        var event: String
        var sourcePath: String
        var command: String?
        var currentHash: String
        var managed: Bool

        /// 読む画面の `editKey`。中身が替わると鍵も替わるので、見た中身と違う hook を書き換えない・信頼しない
        var editKey: String {
            SHA256.hash(data: Data("\(key)\n\(currentHash)".utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// 鍵の頭（パスと出来事）と、出来事の配列の位置・その中の handler の位置
        var position: (prefix: String, group: Int, handler: Int)? {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 4, let group = Int(parts[parts.count - 2]), let handler = Int(parts[parts.count - 1]) else { return nil }
            return (parts.dropLast(2).joined(separator: ":"), group, handler)
        }
    }

    static func hookItems(_ result: [String: Any]?) -> [HookItem] {
        (result?["data"] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap(hookItem)
    }

    static func hookItem(_ item: [String: Any]) -> HookItem? {
        guard let key = item["key"] as? String, let event = item["eventName"] as? String, let hash = item["currentHash"] as? String else { return nil }
        return HookItem(
            key: key, event: event, sourcePath: item["sourcePath"] as? String ?? "", command: item["command"] as? String, currentHash: hash,
            managed: item["isManaged"] as? Bool ?? false)
    }

    /// codex の hook の出来事（`HookEventName`）。設定の鍵は頭を大文字にした形（`preToolUse` → `PreToolUse`）。知らない名前は codex が黙って無視する
    static let events = [
        "preToolUse", "permissionRequest", "postToolUse", "preCompact", "postCompact", "sessionStart", "sessionEnd", "userPromptSubmit", "subagentStart",
        "subagentStop", "stop", "interrupt",
    ].map { $0.prefix(1).uppercased() + $0.dropFirst() }

    static func hook(
        op: ConversationSettingsEdit.Op, scope: ConversationSettingsScope, event: String, matcher: String, body: ConversationSettingsEdit.HookBody?,
        target: HookItem?, layer: UserLayer
    ) throws -> Write {
        guard scope == .user else { throw ConversationError.invalid("codex の hook はユーザーの設定にだけ書ける") }
        var hooks = layer.config["hooks"] as? [String: Any] ?? [:]
        var changed: Set<String> = []
        if op != .add {
            guard let target else { throw ConversationError.invalid("書き換える hook の鍵（editKey）が無い") }
            // hooks.json やほかの層の hook はここでは書き換えない
            guard !target.managed, target.sourcePath == layer.file else { throw ConversationError.settingsRejected("locked") }
            let targetEvent = target.event.prefix(1).uppercased() + target.event.dropFirst()
            guard let position = target.position, var groups = hooks[targetEvent] as? [[String: Any]], groups.indices.contains(position.group),
                var handlers = groups[position.group]["hooks"] as? [[String: Any]], handlers.indices.contains(position.handler),
                handlers[position.handler]["command"] as? String == target.command
            else { throw ConversationError.settingsRejected("not_found") }
            let sameGroup = targetEvent == event && (groups[position.group]["matcher"] as? String ?? "") == matcher
            if op == .replace, sameGroup {
                // 中身が替わるので、codex は信頼を modified にする（もう一度信頼するまで動かない）
                handlers[position.handler] = try handler(body)
                groups[position.group]["hooks"] = handlers
                hooks[targetEvent] = groups
                changed.insert(targetEvent)
            } else {
                handlers.remove(at: position.handler)
                let groupRemoved = handlers.isEmpty
                if groupRemoved { groups.remove(at: position.group) } else { groups[position.group]["hooks"] = handlers }
                hooks[targetEvent] = groups.isEmpty ? nil : groups
                changed.insert(targetEvent)
                let state = shifted(
                    hooks["state"] as? [String: Any] ?? [:], prefix: position.prefix, group: position.group, handler: position.handler, groupRemoved: groupRemoved)
                hooks["state"] = state.isEmpty ? nil : state
                changed.insert("state")
            }
            if op == .remove || sameGroup { return hookWrite(hooks, changed) }
        }
        guard events.contains(event) else { throw ConversationError.invalid("hook の出来事 \(event) は codex に無い") }
        var group: [String: Any] = ["hooks": [try handler(body)]]
        if !matcher.isEmpty { group["matcher"] = matcher }
        hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        changed.insert(event)
        return hookWrite(hooks, changed)
    }

    /// hook の有効と信頼。信頼は、読む画面で見た中身（`editKey` に入っている hash）と今の中身が同じときだけ与える
    static func hookState(target: HookItem, enabled: Bool?, trusted: Bool?, layer: UserLayer) throws -> Write {
        guard enabled != nil || trusted != nil else { throw ConversationError.invalid("替える設定が無い") }
        guard !target.managed else { throw ConversationError.settingsRejected("locked") }
        var state = (layer.config["hooks"] as? [String: Any])?["state"] as? [String: Any] ?? [:]
        var entry = state[target.key] as? [String: Any] ?? [:]
        if let enabled { entry["enabled"] = enabled }
        switch trusted {
        case true?: entry["trusted_hash"] = target.currentHash
        case false?: entry["trusted_hash"] = nil
        case nil: break
        }
        state[target.key] = entry.isEmpty ? nil : entry
        return Write(edits: [replace("hooks.state", state.isEmpty ? NSNull() : state)], effect: .now)
    }

    private static func handler(_ body: ConversationSettingsEdit.HookBody?) throws -> [String: Any] {
        guard let body else { throw ConversationError.invalid("hook の中身が要る") }
        // codex 0.162.1 は prompt の hook を読み飛ばす（"prompt hooks are not supported yet"）
        guard body.type == "command", let command = body.command, !command.isEmpty else { throw ConversationError.invalid("codex の hook は command だけ") }
        var handler: [String: Any] = ["type": "command", "command": command]
        if let timeout = body.timeout { handler["timeout"] = timeout }
        if let statusMessage = body.statusMessage { handler["statusMessage"] = statusMessage }
        return handler
    }

    /// 配列から hook を外すと後ろの hook の位置が詰まり、信頼の鍵（位置を含む）がずれるので、同じファイルの同じ出来事の鍵を詰め直す
    static func shifted(_ state: [String: Any], prefix: String, group: Int, handler: Int, groupRemoved: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in state {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 4, parts.dropLast(2).joined(separator: ":") == prefix, let g = Int(parts[parts.count - 2]), let h = Int(parts[parts.count - 1])
            else {
                result[key] = value
                continue
            }
            if g == group && (groupRemoved || h == handler) { continue }
            let moved = groupRemoved ? (g > group ? (g - 1, h) : (g, h)) : (g == group && h > handler ? (g, h - 1) : (g, h))
            result["\(prefix):\(moved.0):\(moved.1)"] = value
        }
        return result
    }

    private static func hookWrite(_ hooks: [String: Any], _ changed: Set<String>) -> Write {
        Write(edits: changed.sorted().map { replace("hooks.\($0)", hooks[$0] ?? NSNull()) }, effect: .now)
    }

    private static func replace(_ keyPath: String, _ value: Any) -> [String: Any] {
        ["keyPath": keyPath, "value": value, "mergeStrategy": "replace"]
    }

    // MARK: 結果

    /// 書き込みの応答から結果を作る。`okOverridden` は上書きしている層の名前を返す（codex の英語の文は返さない）
    static func result(_ effect: Effect, response: [String: Any]?) -> ConversationSettingsEditResult {
        let layer = response?["status"] as? String == "okOverridden"
            ? (((response?["overriddenMetadata"] as? [String: Any])?["overridingLayer"] as? [String: Any])?["name"] as? [String: Any])?["type"] as? String
            : nil
        return ConversationSettingsEditResult(
            needsRestart: effect == .nextOpen, overriddenBy: effect == .permissionMode ? "permission_mode" : layer)
    }

    /// 書き込みの失敗（`config_write_error_code`）の理由の種類
    static func reason(_ line: CodexRPCLine) -> String {
        let error = ((try? JSONSerialization.jsonObject(with: line.data)) as? [String: Any])?["error"] as? [String: Any]
        switch (error?["data"] as? [String: Any])?["config_write_error_code"] as? String {
        case "configVersionConflict": return "conflict"
        case "configValidationError": return "invalid"
        case "configLayerReadonly": return "locked"
        default: return "other"
        }
    }
}
