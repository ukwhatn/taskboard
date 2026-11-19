import Foundation
import MCP
import TaskboardKit

/// Devin のセッションの起動・様子・メッセージの tool。起動したセッションはタスクにリンクし、daemon が見張る（返答待ち・PR・終了をリンクの通知で届ける）
extension TaskboardTools {
    static let devinTools: [ToolEntry] = [
        ToolEntry(
            name: "devin_start",
            description:
                Copy.text("agent.tool.devin_start"),
            inputSchema: schema([
                "prompt": property("string", Copy.text("agent.tool.devin_start.prompt")),
                "prompt_file": property("string", Copy.text("agent.tool.devin_start.prompt_file")),
                "max_acu_limit": property("integer", Copy.text("agent.tool.devin_start.max_acu_limit")),
                "title": property("string", Copy.text("agent.tool.devin_start.title")),
                "tags": property("array", Copy.text("agent.tool.devin_start.tags"), items: property("string")),
                "task_id": property("integer", Copy.text("agent.tool.devin_start.task_id")),
                "account": property("string", Copy.text("agent.tool.devin_start.account")),
            ], required: ["max_acu_limit"])) { tools, args in try await tools.devinStart(args) },
        ToolEntry(
            name: "devin_get",
            description: Copy.text("agent.tool.devin_get"),
            inputSchema: schema(["session": property("string", Copy.text("agent.tool.devin_get.session"))], required: ["session"])) { tools, args in
                try await tools.devinGet(args)
            },
        ToolEntry(
            name: "devin_message",
            description: Copy.text("agent.tool.devin_message"),
            inputSchema: schema([
                "session": property("string", Copy.text("agent.tool.devin_get.session")),
                "message": property("string", Copy.text("agent.tool.devin_message.message")),
            ], required: ["session", "message"])) { tools, args in try await tools.devinMessage(args) },
    ]

    private func devinStart(_ args: [String: Value]) async throws -> String {
        let inline = args.string("prompt").flatMap { $0.isEmpty ? nil : $0 }
        let file = args.string("prompt_file").flatMap { $0.isEmpty ? nil : $0 }
        guard (inline == nil) != (file == nil) else { throw inline == nil ? ToolError.missing(Copy.text("agent.mcp.devin.file")) : ToolError.invalid(Copy.text("agent.mcp.devin.file.2")) }
        let prompt: String
        if let file {
            let absolute = file.hasPrefix("/") ? file : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: file).standardizedFileURL.path
            guard let data = FileManager.default.contents(atPath: absolute), let text = String(data: data, encoding: .utf8) else {
                throw ToolError.invalid(Copy.text("agent.mcp.devin.absolute", ["absolute": "\(absolute)"]))
            }
            prompt = text
        } else {
            prompt = inline ?? ""
        }
        guard let limit = args.int("max_acu_limit"), limit > 0 else { throw ToolError.missing(Copy.text("agent.mcp.devin.absolute.2")) }
        let number = try await resolveTaskNumber(args)
        let tags = (args.array("tags") ?? []).compactMap(\.stringValue)
        let started = try await client.startDevin(DevinStartRequest(prompt: prompt, title: args.string("title"), tags: tags, maxAcuLimit: limit, taskNumber: number, account: args.string("account")))
        var lines = [
            started.existing ? Copy.text("agent.mcp.devin.lines") : Copy.text("agent.mcp.devin.lines.2"),
            "- URL: \(started.url)",
            "- id: \(started.sessionID)",
            Copy.text("agent.mcp.devin.lines.3", ["account": "\(started.account)"]),
        ]
        switch started.link {
        case .linked(let task), .alreadyLinked(let task): lines.append(Copy.text("agent.mcp.devin.linked", ["task": "\(task)"]))
        case .linkedElsewhere(let task): lines.append(Copy.text("agent.mcp.devin.linkedElsewhere", ["task": "\(task)"]))
        case nil: break
        }
        lines.append(Copy.text("agent.mcp.devin.linkedElsewhere.2"))
        return lines.joined(separator: "\n")
    }

    private func devinGet(_ args: [String: Value]) async throws -> String {
        let id = try Self.devinSessionID(args)
        let detail = try await client.devinSession(id: id)
        var lines = [
            Copy.text("agent.mcp.devin.lines.4", ["apiID": "\(DevinSession.apiID(detail.sessionID))"]),
            Copy.text("agent.mcp.devin.lines.5", ["status": "\(detail.state.status)", "describe": "\(Self.describe(phase: detail.state.phase))"]),
        ]
        if !detail.state.title.isEmpty { lines.append(Copy.text("agent.mcp.devin.lines.6", ["title": "\(detail.state.title)"])) }
        if let pr = detail.state.pullRequestURL { lines.append("- PR: \(pr)") }
        if let account = detail.account { lines.append(Copy.text("agent.mcp.devin.lines.3", ["account": "\(account)"])) }
        lines.append(Copy.text("agent.mcp.devin.lines.7"))
        if detail.omitted > 0 { lines.append(Copy.text("agent.mcp.devin.lines.8", ["omitted": "\(detail.omitted)"])) }
        lines.append(Copy.text("agent.mcp.devin.lines.9"))
        for message in detail.messages {
            let who =
                switch message.type {
                case "devin_message": "Devin"
                case "user_message", "initial_user_message": Copy.text("agent.mcp.devin.who")
                default: message.type
                }
            lines.append("--- \(who)" + (message.at.map { " \($0)" } ?? "") + (message.clipped ? Copy.text("agent.mcp.devin.who.2") : ""))
            lines.append(message.text)
        }
        return lines.joined(separator: "\n")
    }

    private func devinMessage(_ args: [String: Value]) async throws -> String {
        let id = try Self.devinSessionID(args)
        guard let message = args.string("message"), !message.isEmpty else { throw ToolError.missing("message") }
        let sent = try await client.messageDevin(id: id, DevinMessageRequest(message: message))
        if let refused = sent.refused { return Copy.text("agent.mcp.devin.sent", ["refused": "\(refused)"]) }
        return Copy.text("agent.mcp.devin.sent.2")
    }

    private static func devinSessionID(_ args: [String: Value]) throws -> String {
        guard let raw = args.string("session"), !raw.isEmpty else { throw ToolError.missing("session") }
        guard let id = DevinSession.id(from: raw) else { throw ToolError.invalid(Copy.text("agent.mcp.devin.devinSessionID", ["raw": "\(raw)"])) }
        return id
    }

    static func describe(phase: DevinLinkState.Phase) -> String {
        switch phase {
        case .working: Copy.text("agent.mcp.devin.working")
        case .waiting: Copy.text("agent.mcp.devin.waiting")
        case .finished: Copy.text("agent.mcp.devin.finished")
        case .expired: Copy.text("agent.mcp.devin.expired")
        case .other: Copy.text("agent.mcp.devin.other")
        }
    }
}
