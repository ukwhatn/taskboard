import Foundation
import MCP
import TaskboardKit

/// GitHub の issue・PR と、このマシンのコマンドの監視（動きがあったら会話へ通知する）の tool
extension TaskboardTools {
    static let watchTools: [ToolEntry] = [
        ToolEntry(
            name: "watch_create",
            description:
                Copy.text("agent.tool.watch_create"),
            inputSchema: schema([
                "url": property("string", Copy.text("agent.tool.watch_create.url")),
                "repo": property("string", Copy.text("agent.tool.watch_create.repo")),
                "query": property("string", Copy.text("agent.tool.watch_create.query")),
                "events": property("array", Copy.text("agent.tool.watch_create.events"), items: property("string", enum: itemEvents.map(\.rawValue))),
                "tag_pattern": property("string", Copy.text("agent.tool.watch_create.tag_pattern")),
                "command": property("string", Copy.text("agent.tool.watch_create.command")),
                "condition": property("string", Copy.text("agent.tool.watch_create.condition"), enum: CommandWatchSpec.Condition.allCases.map(\.rawValue)),
                "pattern": property("string", Copy.text("agent.tool.watch_create.pattern")),
                "interval_seconds": property("integer", Copy.text("agent.tool.watch_create.interval_seconds", ["lowerBound": "\(CommandWatchSpec.intervals.lowerBound)", "upperBound": "\(CommandWatchSpec.intervals.upperBound)", "defaultInterval": "\(CommandWatchSpec.defaultInterval)"])),
                "timeout_seconds": property("integer", Copy.text("agent.tool.watch_create.timeout_seconds", ["standard": "\(CommandWatchSpec.checkTimeouts.standard)", "limit": "\(CommandWatchSpec.checkTimeouts.limit)", "standard2": "\(CommandWatchSpec.finishTimeouts.standard)", "limit2": "\(CommandWatchSpec.finishTimeouts.limit)"])),
                "cwd": property("string", Copy.text("agent.tool.watch_create.cwd")),
                "prompt": property("string", Copy.text("agent.tool.watch_create.prompt")),
                "conversation_id": property("string", Copy.text("agent.tool.wake_create.conversation_id")),
                "task_id": property("integer", Copy.text("agent.tool.watch_create.task_id")),
                "once": property("boolean", Copy.text("agent.tool.watch_create.once")),
                "link": property("boolean", Copy.text("agent.tool.mcp.watches.link")),
                "expires_at": property("string", Copy.text("agent.tool.mcp.watches.expires_at")),
            ])) { tools, args in try await tools.watchCreate(args) },
        ToolEntry(
            name: "watch_list",
            description: Copy.text("agent.tool.watch_list"),
            inputSchema: schema(["all": property("boolean")])) { tools, args in try await tools.watchList(args) },
        ToolEntry(
            name: "watch_cancel",
            description: Copy.text("agent.tool.watch_cancel"),
            inputSchema: schema(["id": property("integer")], required: ["id"])) { tools, args in try await tools.watchCancel(args) },
    ]

    /// url の監視で選べる種類（opened は repo の監視の出来事、devin_* は Devin のセッションのリンクの知らせ）
    private static let itemEvents = LinkNotice.Kind.allCases.filter { $0 != .opened && !$0.isDevin }

    private func watchCreate(_ args: [String: Value]) async throws -> String {
        let url = args.string("url").flatMap { $0.isEmpty ? nil : $0 }
        let repo = args.string("repo").flatMap { $0.isEmpty ? nil : $0 }
        let command = try Self.commandSpec(args)
        switch [url != nil, repo != nil, command != nil].filter({ $0 }).count {
        case 0: throw ToolError.missing(Copy.text("agent.mcp.watches.command"))
        case 1: break
        default: throw ToolError.invalid(Copy.text("agent.mcp.watches.command.2"))
        }
        var events: [LinkNotice.Kind] = []
        for value in args.array("events") ?? [] {
            guard let raw = value.stringValue, let kind = LinkNotice.Kind(rawValue: raw), Self.itemEvents.contains(kind) else {
                throw ToolError.invalid(Copy.text("agent.mcp.watches.events", ["value": "\(value)", "itemEvents": "\(Self.itemEvents.map(\.rawValue).joined(separator: "・"))"]))
            }
            events.append(kind)
        }
        var expiresAt: Date?
        if let given = args.string("expires_at"), !given.isEmpty {
            guard let date = Self.wakeTime(given) else { throw ToolError.invalid(Copy.text("agent.mcp.watches.expiresAt", ["given": "\(given)"])) }
            expiresAt = date
        }
        if args["task_id"] != nil, args["conversation_id"] != nil { throw ToolError.invalid(Copy.text("agent.mcp.wakes.close.2")) }
        let snapshot = try await client.snapshot()
        var request = WatchCreateRequest(
            url: url, repo: repo, query: args.string("query"), command: command, events: events, tagPattern: args.string("tag_pattern"), prompt: args.string("prompt"), once: args.bool("once") == true,
            expiresAt: expiresAt,
            createdBy: conversationID ?? agentSessionID, link: args.bool("link"))
        if let given = args.string("conversation_id"), !given.isEmpty {
            request.conversationID = try Self.conversation(given, in: snapshot.conversations).id
        } else if args["task_id"] == nil, let own = conversationID {
            request.conversationID = own
        } else {
            request.taskNumber = try await resolveTaskNumber(args)
        }
        let created = try await client.createWatch(request)
        guard let watch = created.watch else { return Self.linkInsteadReport(created.link, prompt: request.prompt) }
        var lines = Self.reportLines(created.existing ? Copy.text("agent.mcp.watches.lines") : Copy.text("agent.mcp.watches.lines.2"), watch: watch, snapshot: snapshot, own: conversationID)
        if let tag = watch.tag, watch.state != .active {
            lines.append(Copy.text("agent.mcp.watches.lines.3", ["tag": "\(tag)"]))
        } else if let state = created.snapshot.map(Self.describe(snapshot:)) {
            lines.append(Copy.text("agent.mcp.watches.lines.4", ["state": "\(state)"]))
        } else if watch.kind == .command {
            if watch.command?.condition != .finishes {
                lines.append(Copy.text("agent.mcp.watches.lines.5"))
            }
        } else if watch.kind == .repo, watch.fetchedAt != nil, watch.error == nil {
            lines.append(Copy.text("agent.mcp.watches.lines.6"))
        } else if let error = watch.error {
            lines.append(Copy.text("agent.mcp.watches.lines.7", ["error": "\(error)"]))
        } else {
            lines.append(Copy.text("agent.mcp.watches.lines.8"))
        }
        switch created.link {
        case .linked(let number): lines.append(Copy.text("agent.mcp.watches.linked", ["number": "\(number)"]))
        case .linkedElsewhere(let number): lines.append(Copy.text("agent.mcp.watches.linkedElsewhere", ["number": "\(number)"]))
        case .alreadyLinked, nil: break
        }
        lines.append(Copy.text("agent.mcp.watches.alreadyLinked"))
        return lines.joined(separator: "\n")
    }

    /// 監視を作らず、PR をリンクして指示をリンクのメモに残したとき（`WatchCreateRequest.coveredByLinkNotices`）
    static func linkInsteadReport(_ link: AutoLinkResult?, prompt: String?) -> String {
        let number: Int? =
            switch link {
            case .linked(let number), .alreadyLinked(let number): number
            case .linkedElsewhere, nil: nil
            }
        var lines = [
            Copy.text("agent.mcp.watches.lines.9"),
            Copy.text("agent.mcp.watches.lines.10", ["number": "\(number.map(String.init) ?? "?")"]),
        ]
        if case .linked = link { lines.append(Copy.text("agent.mcp.watches.linked", ["number": "\(number.map(String.init) ?? "?")"])) }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(Copy.text("agent.mcp.watches.linked.2"))
        }
        lines.append(Copy.text("agent.mcp.watches.linked.3"))
        return lines.joined(separator: "\n")
    }

    private func watchList(_ args: [String: Value]) async throws -> String {
        let snapshot = try await client.snapshot()
        var watches = try await client.watches()
        if args.bool("all") != true {
            let task = try? await currentTask(in: snapshot)?.number
            watches = watches.filter { watch in
                guard watch.state == .active else { return false }
                guard conversationID != nil || task != nil else { return true }
                let conversationTask = watch.conversationID.flatMap { id in snapshot.conversations.first { $0.id == id }?.taskNumber }
                return watch.conversationID == conversationID || (task != nil && (watch.taskNumber == task || conversationTask == task))
            }
        }
        guard !watches.isEmpty else { return args.bool("all") == true ? Copy.text("agent.mcp.watches.conversationTask") : Copy.text("agent.mcp.watches.conversationTask.2") }
        return ([Copy.text("agent.mcp.watches.conversationTask.3", ["watches": "\(watches.count)"])] + watches.map { "- " + Self.describe(watch: $0, snapshot: snapshot, own: conversationID) }).joined(separator: "\n")
    }

    private func watchCancel(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("id") else { throw ToolError.missing("id") }
        let watch = try await client.cancelWatch(id: id)
        return Self.reportLines(Copy.text("agent.mcp.watches.watch"), watch: watch, snapshot: try await client.snapshot(), own: conversationID).joined(separator: "\n")
    }

    /// command の引数。command が無ければ nil
    private static func commandSpec(_ args: [String: Value]) throws -> CommandWatchSpec? {
        let others = ["condition", "pattern", "interval_seconds", "timeout_seconds", "cwd"].filter { args[$0] != nil }
        guard let command = args.string("command").flatMap({ $0.isEmpty ? nil : $0 }) else {
            guard others.isEmpty else { throw ToolError.invalid(Copy.text("agent.mcp.watches.others", ["others": "\(others.joined(separator: "・"))"])) }
            return nil
        }
        guard let raw = args.string("condition") else { throw ToolError.missing("condition") }
        guard let condition = CommandWatchSpec.Condition(rawValue: raw) else {
            throw ToolError.invalid(Copy.text("agent.mcp.watches.others.2", ["raw": "\(raw)", "allCases": "\(CommandWatchSpec.Condition.allCases.map(\.rawValue).joined(separator: "・"))"]))
        }
        return CommandWatchSpec(
            command: command, cwd: args.string("cwd"), condition: condition, pattern: args.string("pattern"),
            intervalSeconds: args.int("interval_seconds"), timeoutSeconds: args.int("timeout_seconds"))
    }

    /// 対象（URL か、repo の新しい issue・PR か、コマンドの 1 行目）
    private static func subject(of watch: Watch) -> String {
        if let command = watch.command {
            return Copy.text("agent.mcp.watches.subject") + MarkdownCode.inline(String((command.command.split(separator: "\n").first ?? "").prefix(120)))
        }
        return watch.url ?? watch.repo.map { Copy.text("agent.mcp.watches.subject.2", ["value": "\($0)"]) } ?? ""
    }

    private static func destination(of watch: Watch, snapshot: StateSnapshot, own: String?) -> String {
        if let id = watch.conversationID {
            let conversation = snapshot.conversations.first { $0.id == id }
            return Copy.text("agent.mcp.conversations.line", ["id": "\(id.prefix(8))"]) + (conversation?.title.map { "「\($0)」" } ?? "") + (id == own ? Copy.text("agent.mcp.wakes.conversation") : "")
        }
        return watch.taskNumber.map { Copy.text("agent.mcp.wakes.conversation.3", ["value": "\($0)"]) } ?? ""
    }

    /// 検索語・通知する動き・タグ・条件・取得の状態・指示の頭。無い項目は出さない
    private static func details(watch: Watch) -> [String] {
        var details: [String] = []
        if let query = watch.query { details.append(Copy.text("agent.mcp.watches.details", ["query": "\(query)"])) }
        if let command = watch.command {
            details.append(Copy.text("agent.mcp.watches.details.2", ["condition": "\(command.condition.rawValue)"]) + (command.pattern.map { "（\($0)）" } ?? ""))
            if command.condition != .finishes { details.append(Copy.text("agent.mcp.watches.details.3", ["interval": "\(command.interval)"])) }
            details.append(Copy.text("agent.mcp.watches.details.4", ["timeout": "\(command.timeout)"]))
            if let cwd = command.cwd { details.append(Copy.text("agent.mcp.watches.details.5", ["cwd": "\(cwd)"])) }
        }
        if !watch.events.isEmpty { details.append(Copy.text("agent.mcp.watches.details.6") + watch.events.map(\.rawValue).joined(separator: "・")) }
        if let pattern = watch.tagPattern { details.append(Copy.text("agent.mcp.watches.details.7", ["pattern": "\(pattern)"])) }
        if let tag = watch.tag { details.append(Copy.text("agent.mcp.watches.details.8", ["tag": "\(tag)"])) }
        if watch.once, watch.command?.condition != .finishes { details.append(Copy.text("agent.mcp.watches.details.9")) }
        if let at = watch.expiresAt { details.append(Copy.text("agent.mcp.watches.details.10", ["agentTime": "\(Wake.agentTime(at))"])) }
        if watch.state == .active {
            if watch.kind == .command {
                details.append(watch.fetchedAt.map { Copy.text("agent.mcp.watches.details.11", ["agentTime": "\(Wake.agentTime($0))"]) } ?? Copy.text("agent.mcp.watches.details.12"))
            } else {
                details.append(watch.fetchedAt.map { Copy.text("agent.mcp.watches.details.13", ["agentTime": "\(Wake.agentTime($0))"]) } ?? Copy.text("agent.mcp.watches.details.14"))
            }
        }
        if let error = watch.error { details.append((watch.kind == .command ? Copy.text("agent.mcp.watches.details.15") : Copy.text("agent.mcp.watches.details.16")) + error) }
        if let first = watch.prompt?.split(separator: "\n").first.map({ String($0.prefix(120)) }) { details.append(Copy.text("agent.mcp.wakes.details", ["value": "\(first)"])) }
        return details
    }

    /// 一覧の 1 件。1 行目に id・状態・対象・届け先、続く行に項目
    static func describe(watch: Watch, snapshot: StateSnapshot, own: String?) -> String {
        var head = "[\(watch.watchID)] \(watch.state.rawValue)"
        if let ending = watch.ending { head += "（\(ending.rawValue)）" }
        head += " \(subject(of: watch)) → \(destination(of: watch, snapshot: snapshot, own: own))"
        return ([head] + details(watch: watch).map { "  - " + $0 }).joined(separator: "\n")
    }

    /// 作成・取り消しの結果の項目
    static func reportLines(_ heading: String, watch: Watch, snapshot: StateSnapshot, own: String?) -> [String] {
        var state = watch.state.rawValue
        if let ending = watch.ending { state += "（\(ending.rawValue)）" }
        return [heading, "- id: \(watch.watchID)", Copy.text("agent.mcp.wakes.lines", ["state": "\(state)"]), Copy.text("agent.mcp.watches.state", ["subject": "\(subject(of: watch))"]), Copy.text("agent.mcp.watches.state.2", ["destination": "\(destination(of: watch, snapshot: snapshot, own: own))"])]
            + details(watch: watch).map { "- " + $0 }
    }

    /// 基準にする状態の 1 行（open か・draft・CI・conflict、issue は open か）
    static func describe(snapshot: LinkSnapshot) -> String {
        switch snapshot {
        case .pullRequest(let pr):
            var parts = [pr.state.rawValue.lowercased() + (pr.isDraft ? "（draft）" : "")]
            if let checks = pr.checks {
                parts.append(checks.isRunning ? Copy.text("agent.mcp.watches.parts") : checks.isFailing ? Copy.text("agent.mcp.watches.parts.2") : Copy.text("agent.mcp.watches.parts.3"))
            }
            if pr.mergeable == .conflicting { parts.append(Copy.text("agent.mcp.watches.parts.4")) }
            return parts.joined(separator: "・")
        case .issue(let issue):
            return issue.state.lowercased() + (issue.stateReason.flatMap { $0.isEmpty ? nil : "（\($0.lowercased())）" } ?? "")
        }
    }
}
