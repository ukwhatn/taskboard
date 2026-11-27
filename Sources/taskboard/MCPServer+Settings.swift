import Foundation
import MCP
import TaskboardKit

/// アプリの設定画面で変えられる daemon の設定のうち、案件・タスク・マシンの tool に収まらないもの（Slack の連携・作業ディレクトリの星）と、
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
            ], required: ["board"])) { tools, args in try await tools.boardSlackUpdate(args) },
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
        guard current.configured else { throw ToolError.invalid(Copy.text("agent.mcp.settings.slack.unconfigured", ["name": board.name])) }
        guard args["allowed_users"] != nil || args["routes"] != nil else { throw ToolError.invalid(Copy.text("agent.mcp.manage.remove")) }
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
        let updated = try await client.updateBoardSlack(id: board.id, BoardSlackUpdate(allowedUsers: users, routes: routes))
        var lines = [Copy.text("agent.mcp.settings.slack.updated", ["name": board.name]), "- " + Self.describe(slack: updated)]
        lines += updated.allowedUsers.map { "  - " + Copy.text("agent.mcp.settings.slack.user", ["id": $0.id, "name": $0.name ?? "-"]) }
        lines += updated.routes.map { "  - " + Copy.text("agent.mcp.settings.slack.routeLine", ["channel": $0.channelName.map { "#" + $0 } ?? $0.channelID, "number": "\($0.taskNumber)"]) }
        return lines.joined(separator: "\n")
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
