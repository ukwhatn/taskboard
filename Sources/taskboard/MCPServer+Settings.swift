import Foundation
import MCP
import TaskboardKit

/// アプリの設定画面で変えられる daemon の設定のうち、案件・タスク・マシンの tool に収まらないもの（Slack の連携・作業ディレクトリの星・端末・Codex のコネクタ・端末のアプリの設定）と、
/// board_update の起動の既定の読み方
extension TaskboardTools {
    static let launchDefaultsProperties: [String: Value] = [
        "launch_kind": property("string", Copy.text("agent.tool.board_update.launch_kind"), enum: AgentKind.allCases.map(\.rawValue)),
        "launch_model": property("string", Copy.text("agent.tool.board_update.launch_model")),
        "launch_effort": property("string", Copy.text("agent.tool.board_update.launch_effort"), enum: Effort.allCases.map(\.rawValue)),
        "launch_agent_args": property("array", Copy.text("agent.tool.board_update.launch_agent_args"), items: property("string")),
        "launch_cwd": property("string", Copy.text("agent.tool.board_update.launch_cwd")),
        "launch_worktree": property("boolean", Copy.text("agent.tool.board_update.launch_worktree")),
        "clear_launch_defaults": property("boolean", Copy.text("agent.tool.board_update.clear_launch_defaults")),
    ]

    static let settingTools: [ToolEntry] = [
        ToolEntry(
            name: "board_slack_update", description: Copy.text("agent.tool.board_slack_update"),
            inputSchema: schema([
                "board": property("string", Copy.text("agent.tool.board_update.board")),
                "allowed_users": property("array", Copy.text("agent.tool.board_slack_update.allowed_users"), items: property("string")),
                "routes": property("array", Copy.text("agent.tool.board_slack_update.routes"), items: schema([
                    "channel_id": property("string"), "task_id": property("integer"),
                ], required: ["channel_id", "task_id"])),
                "bot_token_file": property("string", Copy.text("agent.tool.board_slack_update.bot_token_file")),
                "app_token_file": property("string", Copy.text("agent.tool.board_slack_update.app_token_file")),
                "remove": property("boolean", Copy.text("agent.tool.board_slack_update.remove")),
                "confirm": confirmProperty,
            ], required: ["board"])) { tools, args in try await tools.boardSlackUpdate(args) },
        ToolEntry(
            name: "devices", description: Copy.text("agent.tool.devices"),
            inputSchema: schema([
                "pair": property("boolean", Copy.text("agent.tool.devices.pair")),
                "revoke": property("string", Copy.text("agent.tool.devices.revoke")),
                "confirm": confirmProperty,
            ])) { tools, args in try await tools.devices(args) },
        ToolEntry(
            name: "codex_connectors", description: Copy.text("agent.tool.codex_connectors"),
            inputSchema: schema([
                "refresh": property("boolean", Copy.text("agent.tool.codex_connectors.refresh")),
                "login": property("string", Copy.text("agent.tool.codex_connectors.login")),
                "callback_url": property("string", Copy.text("agent.tool.codex_connectors.callback_url")),
                "cancel_login": property("string", Copy.text("agent.tool.codex_connectors.cancel_login")),
                "login_id": property("string", Copy.text("agent.tool.codex_connectors.login_id")),
                "logout": property("string", Copy.text("agent.tool.codex_connectors.logout")),
                "confirm": confirmProperty,
            ])) { tools, args in try await tools.codexConnectors(args) },
        ToolEntry(
            name: "app_settings", description: Copy.text("agent.tool.app_settings"),
            inputSchema: schema([
                "client": property("string", Copy.text("agent.tool.app_settings.client")),
                "set": .object([
                    "type": .string("object"),
                    "description": .string(Copy.text("agent.tool.app_settings.set")),
                    "properties": .object(Dictionary(uniqueKeysWithValues: ClientPref.allCases.map { ($0.rawValue, appSettingProperty($0)) })),
                    "additionalProperties": .bool(false),
                ]),
            ])) { tools, args in try await tools.appSettings(args) },
        ToolEntry(
            name: "workdir_bookmarks", description: Copy.text("agent.tool.workdir_bookmarks"),
            inputSchema: schema([
                "add": property("array", Copy.text("agent.tool.workdir_bookmarks.add"), items: property("string")),
                "remove": property("array", Copy.text("agent.tool.workdir_bookmarks.remove"), items: property("string")),
            ])) { tools, args in try await tools.workdirBookmarks(args) },
    ]

    // MARK: 起動の既定

    /// board_update の launch_* から、送る起動の既定（全体の置き換え）。指定が無ければ nil。
    /// モデルか effort だけのときは、今の既定（無ければ `LaunchChoice.standard`）の残りの項目を保つ
    func launchDefaultsEdit(_ args: [String: Value], current: LaunchDefaults?) async throws -> LaunchDefaults? {
        let keys = Self.launchDefaultsProperties.keys.filter { $0 != "clear_launch_defaults" }
        guard keys.contains(where: { args[$0] != nil }) else { return nil }
        var defaults = current ?? LaunchDefaults(kind: LaunchChoice.standard.kind, agentArgs: LaunchChoice.standard.args)
        if let raw = args.string("launch_kind") {
            guard let kind = AgentKind(rawValue: raw) else { throw ToolError.invalid(Self.invalidChoice("launch_kind", AgentKind.allCases.map(\.rawValue))) }
            if kind != defaults.kind {
                defaults.kind = kind
                defaults.agentArgs = kind == .claude ? LaunchChoice.standard.args : []
            }
        }
        if let cwd = args.string("launch_cwd") { defaults.cwd = cwd }
        if let worktree = args.bool("launch_worktree") { defaults.worktree = worktree }
        let model = args.string("launch_model")
        let effort = args.string("launch_effort")
        if let raw = args.array("launch_agent_args") {
            guard model == nil, effort == nil else { throw ToolError.invalid(Copy.text("agent.mcp.settings.launchArgs")) }
            defaults.agentArgs = raw.compactMap(\.stringValue)
        } else if model != nil || effort != nil {
            var choice = LaunchChoice(kind: defaults.kind, args: defaults.agentArgs)
            if let effort {
                guard let value = Effort(rawValue: effort) else { throw ToolError.invalid(Self.invalidChoice("launch_effort", Effort.allCases.map(\.rawValue))) }
                if defaults.kind == .claude { choice.select(effort: value) } else { choice.select(codexEffort: value.rawValue) }
            }
            if let model {
                if defaults.kind == .claude {
                    choice.select(model: try claudeModel(model, field: "launch_model", in: await claudeModels()))
                } else {
                    choice.select(codexModel: model.isEmpty ? nil : model)
                }
            }
            defaults.agentArgs = choice.args
        }
        return defaults
    }

    static func describe(launchDefaults defaults: LaunchDefaults?) -> String {
        guard let defaults else { return Copy.text("agent.mcp.settings.launch.none") }
        return Copy.text("agent.mcp.settings.launch", [
            "kind": defaults.kind.rawValue,
            "args": defaults.agentArgs.isEmpty ? "-" : defaults.agentArgs.joined(separator: " "),
            "cwd": defaults.cwd.isEmpty ? "-" : defaults.cwd,
            "worktree": defaults.worktree ? "on" : "off",
        ])
    }

    // MARK: Slack

    private func boardSlackUpdate(_ args: [String: Value]) async throws -> String {
        let snapshot = try await client.snapshot()
        let board = try Self.board(args.string("board"), in: snapshot.boards)
        let current = try await client.boardSlack(id: board.id)
        if args.bool("remove") == true {
            guard current.configured else { throw ToolError.invalid(Copy.text("agent.mcp.settings.slack.unconfigured", ["name": board.name])) }
            guard Self.isConfirmed(args) else { return Self.confirmation([Copy.text("agent.mcp.settings.slack.removeTarget", ["name": board.name, "slack": Self.describe(slack: current)])]) }
            try await client.deleteBoardSlack(id: board.id)
            return Copy.text("agent.mcp.settings.slack.removed", ["name": board.name])
        }
        let botToken = try Self.secret(fromFile: args.string("bot_token_file"), field: "bot_token_file")
        let appToken = try Self.secret(fromFile: args.string("app_token_file"), field: "app_token_file")
        guard current.configured || (botToken != nil && appToken != nil) else {
            throw ToolError.invalid(Copy.text("agent.mcp.settings.slack.unconfigured", ["name": board.name]))
        }
        guard args["allowed_users"] != nil || args["routes"] != nil || botToken != nil || appToken != nil else { throw ToolError.invalid(Copy.text("agent.mcp.manage.remove")) }
        let users = args.strings("allowed_users") ?? current.allowedUsers.map(\.id)
        var routes = current.routes.map { SlackRouteUpdate(channelID: $0.channelID, taskNumber: $0.taskNumber) }
        if let raw = args.array("routes") {
            routes = try raw.map { value in
                guard let object = value.objectValue, let channel = object["channel_id"]?.stringValue,
                    let number = object["task_id"]?.intValue ?? object["task_id"]?.stringValue.flatMap(Int.init)
                else { throw ToolError.invalid(Copy.text("agent.mcp.settings.slack.route")) }
                guard snapshot.tasks.contains(where: { $0.number == number }) else { throw ToolError.invalid(Copy.text("agent.mcp.core.snapshot", ["number": "\(number)"])) }
                return SlackRouteUpdate(channelID: channel, taskNumber: number)
            }
        }
        let updated = try await client.updateBoardSlack(id: board.id, BoardSlackUpdate(botToken: botToken, appToken: appToken, allowedUsers: users, routes: routes))
        var lines = [Copy.text("agent.mcp.settings.slack.updated", ["name": board.name]), "- " + Self.describe(slack: updated)]
        lines += updated.allowedUsers.map { "  - " + Copy.text("agent.mcp.settings.slack.user", ["id": $0.id, "name": $0.name ?? "-"]) }
        lines += updated.routes.map { "  - " + Copy.text("agent.mcp.settings.slack.routeLine", ["channel": $0.channelName.map { "#" + $0 } ?? $0.channelID, "number": "\($0.taskNumber)"]) }
        return lines.joined(separator: "\n")
    }

    /// token はファイルから読み、値を tool の引数と応答に載せない（会話の記録に残さないため）
    static func secret(fromFile path: String?, field: String) throws -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError.invalid(Copy.text("agent.mcp.settings.secret.unreadable", ["field": field])) }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ToolError.invalid(Copy.text("agent.mcp.settings.secret.unreadable", ["field": field])) }
        return value
    }

    // MARK: 端末

    private func devices(_ args: [String: Value]) async throws -> String {
        if let id = args.string("revoke"), !id.isEmpty {
            guard let device = try await client.devices().first(where: { $0.id == id }) else { throw ToolError.invalid(Copy.text("agent.mcp.settings.device.missing", ["id": id])) }
            guard Self.isConfirmed(args) else { return Self.confirmation([Copy.text("agent.mcp.settings.device.revokeTarget", ["name": device.name, "id": device.id])]) }
            try await client.revokeDevice(id)
            return Copy.text("agent.mcp.settings.device.revoked", ["name": device.name, "id": device.id])
        }
        var lines: [String] = []
        if args.bool("pair") == true {
            let code = try await client.createPairing()
            lines.append(Copy.text("agent.mcp.settings.device.paired", ["code": code.display, "expires": Self.formatted(code.expiresAt)]))
        }
        let devices = try await client.devices()
        lines.append(Copy.text("agent.mcp.settings.device.header"))
        lines += devices.isEmpty ? [Copy.text("agent.mcp.settings.bookmark.none")] : devices.map { device in
            "- " + Copy.text("agent.mcp.settings.device.line", [
                "name": device.name, "id": device.id, "platform": device.platform.rawValue,
                "seen": device.lastSeenAt.map(Self.formatted) ?? "-",
            ])
        }
        return lines.joined(separator: "\n")
    }

    static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Codex のコネクタ

    private func codexConnectors(_ args: [String: Value]) async throws -> String {
        var lines: [String] = []
        var info: CodexMachineInfo?
        if let name = args.string("logout"), !name.isEmpty {
            guard Self.isConfirmed(args) else { return Self.confirmation([Copy.text("agent.mcp.settings.codex.logoutTarget", ["name": name])]) }
            info = try await client.logoutCodexConnector(name: name)
            lines.append(Copy.text("agent.mcp.settings.codex.loggedOut", ["name": name]))
        } else if let name = args.string("login"), !name.isEmpty {
            let login = try await client.startCodexLogin(name: name)
            lines.append(Copy.text("agent.mcp.settings.codex.login", ["name": name, "url": login.authorizationURL, "id": login.loginId]))
        } else if let url = args.string("callback_url"), !url.isEmpty {
            guard let id = args.string("login_id"), !id.isEmpty else { throw ToolError.missing("login_id") }
            try await client.sendCodexCallback(CodexConnectorCallbackRequest(loginId: id, callbackURL: url))
            lines.append(Copy.text("agent.mcp.settings.codex.callback"))
        } else if let id = args.string("cancel_login"), !id.isEmpty {
            try await client.cancelCodexLogin(loginId: id)
            lines.append(Copy.text("agent.mcp.settings.codex.cancelled"))
        } else if args.bool("refresh") == true {
            info = try await client.refreshCodexConnectors()
        }
        let machine: CodexMachineInfo
        if let info { machine = info } else { machine = try await client.codexMachine() }
        lines.append(Copy.text("agent.mcp.settings.codex.header"))
        let connectors = machine.connectors ?? []
        lines += connectors.isEmpty ? [Copy.text("agent.mcp.settings.bookmark.none")] : connectors.map { connector in
            "- " + Copy.text("agent.mcp.settings.codex.line", [
                "name": connector.name, "auth": connector.authStatus ?? "-", "tools": "\(connector.toolCount)",
            ])
        }
        for login in machine.logins ?? [] {
            lines.append("- " + Copy.text("agent.mcp.settings.codex.loginLine", ["name": login.name, "id": login.id, "state": login.state.rawValue]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 端末（アプリ）の設定

    static func appSettingProperty(_ pref: ClientPref) -> Value {
        switch pref.kind {
        case .bool: property("boolean")
        case .number(let range): .object(["type": .string("number"), "minimum": .double(range.lowerBound), "maximum": .double(range.upperBound)])
        case .string(let choices): choices.isEmpty ? property("string") : property("string", enum: choices)
        case .strings(let choices): property("array", items: choices.isEmpty ? property("string") : property("string", enum: choices))
        }
    }

    private func appSettings(_ args: [String: Value]) async throws -> String {
        var clients = try await client.clientPrefs()
        if let raw = args["set"] {
            guard let object = raw.objectValue, !object.isEmpty else { throw ToolError.invalid(Copy.text("agent.mcp.prefs.shape")) }
            guard let name = args.string("client"), !name.isEmpty else { throw ToolError.missing("client") }
            let matches = clients.filter { $0.clientID == name || $0.name == name }
            guard matches.count == 1, let target = matches.first else {
                throw ToolError.invalid(Copy.text("agent.mcp.prefs.client", ["client": name, "list": clients.map { "\($0.name) (\($0.clientID))" }.joined(separator: ", ")]))
            }
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            var values: [String: ClientPrefEntry] = [:]
            for (key, value) in object {
                guard let pref = ClientPref(rawValue: key) else { throw ToolError.invalid(Copy.text("agent.prefs.unknown", ["key": key])) }
                let parsed = try Self.clientPrefValue(value, pref: pref)
                if let problem = pref.problem(parsed) { throw ToolError.invalid(problem) }
                values[key] = ClientPrefEntry(value: parsed, at: now)
            }
            let updated = try await client.reportClientPrefs(id: target.clientID, ClientPrefsReport(values: values))
            clients = clients.map { $0.clientID == updated.clientID ? updated : $0 }
        }
        var lines = [Copy.text("agent.mcp.prefs.header")]
        if clients.isEmpty { lines.append(Copy.text("agent.mcp.settings.bookmark.none")) }
        for prefs in clients where args.string("client").map({ $0 == prefs.clientID || $0 == prefs.name }) ?? true {
            lines.append("## " + Copy.text("agent.mcp.prefs.client.line", ["name": prefs.name, "id": prefs.clientID, "platform": prefs.platform.rawValue, "reported": Self.formatted(prefs.reportedAt)]))
            for pref in ClientPref.allCases {
                lines.append("- \(pref.rawValue): " + (prefs.values[pref.rawValue]?.value.display ?? Copy.text("agent.mcp.prefs.unset")))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func clientPrefValue(_ value: Value, pref: ClientPref) throws -> ClientPrefValue {
        switch pref.kind {
        case .bool:
            if let bool = value.boolValue { return .bool(bool) }
        case .number:
            if let number = value.doubleValue ?? value.intValue.map(Double.init) { return .number(number) }
        case .string:
            if let text = value.stringValue { return .string(text) }
        case .strings:
            if let items = value.arrayValue { return .strings(items.compactMap(\.stringValue)) }
        }
        throw ToolError.invalid(Copy.text("agent.prefs.type", ["key": pref.rawValue]))
    }

    // MARK: 作業ディレクトリの星

    private func workdirBookmarks(_ args: [String: Value]) async throws -> String {
        let add = args.strings("add") ?? []
        let remove = args.strings("remove") ?? []
        let current = try await client.workingDirectories()
        for path in remove {
            guard let bookmark = current.bookmarks.first(where: { $0.path == path }) else {
                throw ToolError.invalid(Copy.text("agent.mcp.settings.bookmark.missing", ["path": path]))
            }
            try await client.deleteWorkdirBookmark(id: bookmark.id)
        }
        for path in add where !current.isBookmarked(path) || remove.contains(path) {
            _ = try await client.addWorkdirBookmark(path: path)
        }
        let after = try await client.workingDirectories()
        var lines = [Copy.text("agent.mcp.settings.bookmark.header")]
        lines += after.bookmarks.isEmpty ? [Copy.text("agent.mcp.settings.bookmark.none")] : after.bookmarks.map { "- " + $0.path }
        if !after.recent.isEmpty { lines.append(Copy.text("agent.mcp.settings.bookmark.recent") + after.recent.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
