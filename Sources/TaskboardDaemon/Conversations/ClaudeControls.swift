import Foundation
import TaskboardKit

/// CLI の制御要求の応答から、daemon が外に出す形を作る
enum ClaudeControls {
    /// `initialize` の応答と `system/commands_changed` の `commands`。名前の無い項目は落とす
    static func commands(_ value: Any?) -> [ConversationCommand]? {
        guard let items = value as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let hint = (item["argumentHint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let aliases = (item["aliases"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
            return ConversationCommand(
                name: name, description: item["description"] as? String ?? "", argumentHint: hint, builtin: item["builtin"] as? Bool, aliases: aliases)
        }
    }

    /// `initialize` の応答の中身（`payloadJSON`）から `commands`
    static func commands(initializePayload payload: String?) -> [ConversationCommand]? {
        guard let payload, let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        return commands(object["commands"])
    }

    /// `initialize` の応答の中身から、モデルの一覧と CLI の版。`default`（`--model` を渡さないのと同じ）と、名前の無い項目は落とす。
    /// `supportsEffort` が無いか false のモデルは effort を選べない
    static func models(initializePayload payload: String?) -> (models: [ClaudeMachineInfo.Model], version: String?)? {
        guard let payload, let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            let items = object["models"] as? [[String: Any]]
        else { return nil }
        let models = items.compactMap { item -> ClaudeMachineInfo.Model? in
            guard let value = item["value"] as? String, !value.isEmpty, value != "default", let resolved = item["resolvedModel"] as? String, !resolved.isEmpty
            else { return nil }
            let efforts = item["supportsEffort"] as? Bool == true ? (item["supportedEffortLevels"] as? [String] ?? []) : nil
            return ClaudeMachineInfo.Model(
                value: value, resolvedModel: resolved, displayName: (item["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value,
                description: item["description"] as? String, efforts: efforts)
        }
        return models.isEmpty ? nil : (models, object["claude_code_version"] as? String)
    }

    /// `mcp_status` の応答を、決めた項目だけに組み直す。`config`（stdio の env・HTTP の headers）と `error`（server が返した文）は写さない
    static func mcpStatus(payload: String?) -> ConversationMcpStatus {
        guard let payload, let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            let servers = object["mcpServers"] as? [[String: Any]]
        else { return ConversationMcpStatus(mcpServers: []) }
        return ConversationMcpStatus(
            mcpServers: servers.compactMap { server in
                guard let name = server["name"] as? String, let status = server["status"] as? String else { return nil }
                let info = server["serverInfo"] as? [String: Any]
                return ConversationMcpServer(
                    name: name, status: status, scope: server["scope"] as? String, source: server["source"] as? String,
                    serverName: info?["name"] as? String, serverVersion: info?["version"] as? String, toolCount: (server["tools"] as? [Any])?.count,
                    transport: (server["config"] as? [String: Any])?["type"] as? String)
            })
    }

    /// `mcp_authenticate` の応答から、開くページと 2 つの印だけを写す（callback の port・state は写さない）。印が欠けた応答は nil
    static func mcpAuthentication(payload: String?) -> ConversationMcpAuthentication? {
        guard let object = object(payload), let requiresUserAction = object["requiresUserAction"] as? Bool,
            let callbackExpected = object["callbackExpected"] as? Bool
        else { return nil }
        return ConversationMcpAuthentication(authURL: object["authUrl"] as? String, requiresUserAction: requiresUserAction, callbackExpected: callbackExpected)
    }

    /// `get_context_usage` の応答の `percentage`（0〜100 に丸める）
    static func contextPercent(payload: String?) -> Int? {
        guard let payload, let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            let value = (object["percentage"] as? NSNumber)?.doubleValue, value.isFinite
        else { return nil }
        return min(100, max(0, Int(value.rounded())))
    }

    /// `get_context_usage` の応答の、コンテキストに入っているトークン（`totalTokens`）と上限（`maxTokens`）
    static func contextFill(payload: String?) -> (tokens: Int, window: Int)? {
        guard let object = object(payload), let tokens = (object["totalTokens"] as? NSNumber)?.intValue,
            let window = (object["maxTokens"] as? NSNumber)?.intValue, window > 0
        else { return nil }
        return (tokens, window)
    }

    /// `get_context_usage` の応答の区分（`categories` の `name`・`tokens`・`kind`）。応答の残り（MCP の tool・skill の一覧など、80KB ほど）は写さない
    static func contextBreakdown(payload: String?, agentSessionID: String) -> ConversationContextBreakdown? {
        guard let object = object(payload), let fill = contextFill(payload: payload) else { return nil }
        let categories = (object["categories"] as? [[String: Any]] ?? []).compactMap { item -> ConversationContextBreakdown.Category? in
            guard let name = item["name"] as? String, let tokens = (item["tokens"] as? NSNumber)?.intValue else { return nil }
            let kind = (item["kind"] as? String).flatMap(ConversationContextBreakdown.Category.Kind.init(rawValue:)) ?? .other
            return ConversationContextBreakdown.Category(name: String(name.prefix(200)), tokens: tokens, kind: kind)
        }
        return ConversationContextBreakdown(
            agentSessionID: agentSessionID, categories: categories, totalTokens: fill.tokens, maxTokens: fill.window,
            autoCompactThreshold: (object["autoCompactThreshold"] as? NSNumber)?.intValue)
    }

    /// `generate_session_title` の応答の題（2.1.310 で実測。persist のときは 2 回目から description を替えても同じ題を返す）
    static func sessionTitle(payload: String?) -> String? {
        guard let title = (object(payload)?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// `get_usage` の応答の `rate_limits` の 5 時間と 1 週間の窓。`utilization` は 0〜100、`resets_at` は ISO 8601（2.1.303 で実測。
    /// `rate_limit_event` の `utilization` は 0〜1 で違う）。窓が無い契約は null
    static func usageWindows(payload: String?) -> (fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        guard let limits = object(payload)?["rate_limits"] as? [String: Any] else { return (nil, nil) }
        func window(_ key: String, seconds: Int) -> UsageWindow? {
            guard let item = limits[key] as? [String: Any], let utilization = (item["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (item["resets_at"] as? String).flatMap { text in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            }
            return UsageWindow(usedPercent: utilization, resetsAt: resets, windowSeconds: seconds)
        }
        return (window("five_hour", seconds: 18_000), window("seven_day", seconds: 604_800))
    }

    // MARK: 読む画面とその場の操作（2.1.303 で実測）

    /// `export_conversation` の `{text, default_filename}`
    static func export(payload: String?) -> ConversationExport? {
        guard let object = object(payload), let text = object["text"] as? String else { return nil }
        return ConversationExport(text: text, defaultFilename: (object["default_filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "conversation.txt")
    }

    /// `get_task_output` の `{output, total_bytes, truncated}`
    static func taskOutput(payload: String?) -> ConversationTaskOutput? {
        guard let object = object(payload), let output = object["output"] as? String else { return nil }
        return ConversationTaskOutput(
            output: output, totalBytes: (object["total_bytes"] as? NSNumber)?.intValue ?? output.utf8.count, truncated: object["truncated"] as? Bool ?? false)
    }

    /// `list_permission_rules` の `state` の規則と作業フォルダ。規則の読み下し（`description`）は英語の文なので写さない
    static func permissionRules(payload: String?) -> ConversationPermissionRules? {
        guard let state = object(payload)?["state"] as? [String: Any] else { return nil }
        let rules = (state["rules"] as? [[String: Any]] ?? []).compactMap { item -> ConversationPermissionRules.Rule? in
            guard let behavior = item["behavior"] as? String, let rule = item["rule"] as? String else { return nil }
            let source = item["source"] as? String ?? ""
            return ConversationPermissionRules.Rule(
                behavior: behavior, source: source, rule: rule, editable: ConversationSettingsScope(rawValue: source) != nil)
        }
        let directories = (state["workspaceDirectories"] as? [[String: Any]] ?? []).compactMap { item -> ConversationPermissionRules.Directory? in
            guard let path = item["path"] as? String else { return nil }
            return ConversationPermissionRules.Directory(path: path, source: item["source"] as? String ?? "")
        }
        return ConversationPermissionRules(rules: rules, directories: directories)
    }

    /// `get_hooks_listing` の `hooks`（出どころは元の名前。説明の文は英語なので写さない。動くものは `commandText`）。
    /// 書き換えられる行（`editable`）には、置き換え・外すときに指す鍵を付ける
    static func hooks(payload: String?) -> ConversationHooks? {
        guard let items = object(payload)?["hooks"] as? [[String: Any]] else { return nil }
        return ConversationHooks(
            hooks: items.compactMap { item in
                guard let event = item["event"] as? String else { return nil }
                let source = item["source"] as? String ?? ""
                let editable = item["editable"] as? [String: Any]
                let key = editable.flatMap { editable in
                    (editable["config"] as? [String: Any]).flatMap {
                        ClaudeSettingsEdits.hookKey(event: event, source: source, matcher: editable["matcher"] as? String ?? "", config: $0)
                    }
                }
                return ConversationHooks.Hook(
                    event: event, matcher: item["matcher"] as? String ?? "", source: source, plugin: item["pluginName"] as? String,
                    type: item["type"] as? String ?? "", command: item["commandText"] as? String ?? item["displayText"] as? String ?? "",
                    timeoutSeconds: (item["timeout"] as? NSNumber)?.intValue, statusMessage: item["statusMessage"] as? String, editKey: key,
                    // 書き換えは、一覧の行の中身を引けて（鍵がある）、層が書ける 3 つのどれかのときだけ受ける（ClaudeSettingsEdits.invocation）
                    editable: key != nil && ConversationSettingsScope(rawValue: source) != nil)
            })
    }

    /// `get_memory_dialog` の `files` と、自動のメモリ（`auto_memory`）とその整理（`auto_dream`）の切り替え。状態の文（`status`）は英語なので写さない
    static func memory(payload: String?) -> ConversationMemory? {
        guard let object = object(payload), let items = object["files"] as? [[String: Any]] else { return nil }
        func toggle(_ key: String) -> ConversationMemory.Toggle? {
            guard let item = object[key] as? [String: Any], let enabled = item["enabled"] as? Bool else { return nil }
            return ConversationMemory.Toggle(enabled: enabled, toggleable: item["toggleable"] as? Bool ?? false)
        }
        return ConversationMemory(
            files: items.compactMap { item in
                guard let path = item["path"] as? String else { return nil }
                return ConversationMemory.File(kind: item["kind"] as? String ?? "other", path: path, exists: item["exists"] as? Bool ?? true)
            }, autoMemory: toggle("auto_memory"), autoDream: toggle("auto_dream"))
    }

    /// `get_sandbox_dialog`。依存の誤り・制限の一覧（英語の文とパスの並び）は写さず、依存が足りないかだけ
    static func sandbox(payload: String?) -> ConversationSandbox? {
        guard let object = object(payload), let supported = object["supported"] as? Bool, let mode = object["mode"] as? String else { return nil }
        let errors = (object["dependencies"] as? [String: Any])?["errors"] as? [Any] ?? []
        return ConversationSandbox(
            supported: supported, locked: object["locked"] as? Bool ?? false, enabled: object["enabled"] as? Bool ?? false, mode: mode,
            autoAllowAvailable: object["auto_allow_available"] as? Bool ?? false, allowUnsandboxedCommands: object["unsandboxed_fallback"] as? Bool ?? false,
            excludedCommands: object["excluded_commands"] as? [String] ?? [], missingDependencies: !errors.isEmpty)
    }

    /// `get_skills_dialog` の `skills`
    static func skills(payload: String?) -> ConversationSkills? {
        guard let items = object(payload)?["skills"] as? [[String: Any]] else { return nil }
        return ConversationSkills(
            skills: items.compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                return ConversationSkills.Skill(
                    name: name, displayName: item["display_name"] as? String ?? name, description: item["description"] as? String ?? "",
                    source: item["source"] as? String ?? "", tokens: (item["tokens"] as? NSNumber)?.intValue, state: item["state"] as? String ?? "on")
            })
    }

    /// `side_question` の `{response, synthetic}`
    static func sideAnswer(payload: String?) -> ConversationSideAnswer? {
        (object(payload)?["response"] as? String).map(ConversationSideAnswer.init(response:))
    }

    /// `register_repo_root` の `{directory}`
    static func directoryAdded(payload: String?) -> ConversationDirectoryAdded? {
        (object(payload)?["directory"] as? String).map(ConversationDirectoryAdded.init(directory:))
    }

    /// `set_cwd` の答え。`ok` は替えた後の作業フォルダ（実体のパス）、`needs_trust` は信頼が要るフォルダ、`rejected` は理由。
    /// `message`（パスを含む CLI の文）は写さない
    static func cwdChange(payload: String?) -> ConversationCwdChange? {
        guard let object = object(payload), let status = object["status"] as? String else { return nil }
        switch status {
        case "ok":
            guard let cwd = object["cwd"] as? String, !cwd.isEmpty else { return nil }
            return ConversationCwdChange(outcome: .moved, directory: cwd)
        case "needs_trust": return ConversationCwdChange(outcome: .needsTrust, directory: object["directory"] as? String)
        case "rejected": return ConversationCwdChange(outcome: .rejected, reason: object["reason"] as? String)
        default: return ConversationCwdChange(outcome: .unknown)
        }
    }

    /// `claude_authenticate` の答え。どちらのページも https でなければ nil
    static func login(payload: String?) -> ConversationLogin? {
        guard let object = object(payload), let manual = (object["manualUrl"] as? String).flatMap(OAuthLinks.openable), manual.scheme == "https",
            let automatic = (object["automaticUrl"] as? String).flatMap(OAuthLinks.openable), automatic.scheme == "https"
        else { return nil }
        return ConversationLogin(manualURL: manual.absoluteString, automaticURL: automatic.absoluteString)
    }

    /// `claude_oauth_wait_for_completion` の答えにアカウントがあるか（中身は写さない）
    static func loginAccount(payload: String?) -> Bool {
        object(payload)?["account"] is [String: Any]
    }

    /// ログインのページの `state`（貼ったコードがこの流れのものかを照らし合わせる）
    static func loginState(_ login: ConversationLogin) -> String? {
        URLComponents(string: login.manualURL)?.queryItems?.first { $0.name == "state" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// ログインのページに出たコード（`<code>#<state>`。CLI の TUI と同じ分け方）。前後の空白は落とす
    static func loginCode(_ text: String?) -> (code: String, state: String)? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.utf8.count <= OAuthLinks.callbackLimit else { return nil }
        let parts = trimmed.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// `cancel_async_message` の応答。待ち行列から取り下げたら true（CLI が先に始めていたら false）
    static func cancelled(payload: String?) -> Bool {
        object(payload)?["cancelled"] as? Bool == true
    }

    private static func object(_ payload: String?) -> [String: Any]? {
        payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// `rewind_files` の応答（dry run は `filesChanged`・`insertions`・`deletions`、本番は `skippedLinks`、断ると `canRewind: false` と `error`）。
    /// 2.1.302 で実測。`canRewind` が無ければ nil
    static func rewind(payload: String?) -> ConversationRewindResponse? {
        guard let payload, let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            let canRewind = object["canRewind"] as? Bool
        else { return nil }
        return ConversationRewindResponse(
            canRewind: canRewind, error: (object["error"] as? String).map { String($0.prefix(500)) }, filesChanged: object["filesChanged"] as? [String],
            insertions: (object["insertions"] as? NSNumber)?.intValue, deletions: (object["deletions"] as? NSNumber)?.intValue,
            skippedLinks: (object["skippedLinks"] as? NSNumber)?.intValue)
    }
}
