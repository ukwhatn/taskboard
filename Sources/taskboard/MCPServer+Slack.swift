import Foundation
import MCP
import TaskboardKit

/// Slack から届いた依頼を読む・返す tool。依頼は「[taskboard 通知] Slack から依頼が届いた」で会話に入り、その「依頼の id」を渡す
extension TaskboardTools {
    static let slackTools: [ToolEntry] = [
        ToolEntry(
            name: "slack_get",
            description:
                Copy.text("agent.tool.slack_get"),
            inputSchema: schema(["request": property("integer", Copy.text("agent.tool.slack_get.request"))], required: ["request"])) { tools, args in
                try await tools.slackGet(args)
            },
        ToolEntry(
            name: "slack_reply",
            description:
                Copy.text("agent.tool.slack_reply"),
            inputSchema: schema([
                "request": property("integer", Copy.text("agent.tool.slack_get.request")),
                "text": property("string", Copy.text("agent.tool.slack_reply.text")),
                "status": property(
                    "string", Copy.text("agent.mcp.slack.slackTools"),
                    enum: SlackRequestStatus.allCases.map(\.rawValue)),
            ], required: ["request", "text"])) { tools, args in try await tools.slackReply(args) },
    ]

    private func slackGet(_ args: [String: Value]) async throws -> String {
        guard let id = args.int("request") else { throw ToolError.missing("request") }
        let detail = try await client.slackRequest(Int64(id))
        var lines = [
            Copy.text("agent.mcp.slack.lines", ["id": "\(detail.id)"]),
            Copy.text("agent.mcp.slack.lines.2", ["name": "\(detail.user.name ?? detail.user.id)", "id": "\(detail.user.id)"]),
            Copy.text("agent.mcp.slack.lines.3") + (detail.channelName.map { "#\($0)" } ?? detail.channelID),
        ]
        if let permalink = detail.permalink { lines.append(Copy.text("agent.mcp.slack.lines.4", ["permalink": "\(permalink)"])) }
        lines += [Copy.text("agent.mcp.slack.lines.5"), detail.text]
        if !detail.shared.isEmpty {
            lines.append(Copy.text("agent.mcp.slack.lines.6"))
            for message in detail.shared { lines += Self.slackLines(message) }
        }
        if !detail.thread.isEmpty {
            lines.append(Copy.text("agent.mcp.slack.lines.7"))
            for message in detail.thread { lines += Self.slackLines(message) }
        }
        if let viewing = detail.viewing {
            let name = "#" + (viewing.channelName ?? viewing.channelID)
            if viewing.readable {
                lines.append(Copy.text("agent.mcp.slack.name", ["name": "\(name)"]))
                for message in viewing.recent { lines += Self.slackLines(message) }
            } else {
                lines.append(Copy.text("agent.mcp.slack.name.2", ["name": "\(name)"]))
            }
        }
        lines.append(Copy.text("agent.mcp.slack.name.3", ["id": "\(detail.id)"]))
        return lines.joined(separator: "\n")
    }

    private static func slackLines(_ message: SlackMessage) -> [String] {
        ["--- " + [message.author, message.permalink].compactMap { $0 }.joined(separator: " "), message.text]
    }

    private func slackReply(_ args: [String: Value]) async throws -> String {
        guard let id = args.int("request") else { throw ToolError.missing("request") }
        guard let text = args.string("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.missing("text") }
        let status = try args.string("status").map { raw in
            guard let value = SlackRequestStatus(rawValue: raw) else { throw ToolError.invalid(Copy.text("agent.mcp.slack.status")) }
            return value
        }
        let result = try await client.replySlack(request: Int64(id), text: text, status: status)
        return Copy.text("agent.mcp.slack.result") + (result.permalink.map { Copy.text("agent.mcp.slack.result.2", ["value": "\($0)"]) } ?? "")
    }
}
