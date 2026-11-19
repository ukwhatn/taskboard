import Foundation
import MCP
import TaskboardKit

/// 予定（wake。決めた時刻に会話へ指示を送る）の tool
extension TaskboardTools {
    static let wakeTools: [ToolEntry] = [
        ToolEntry(
            name: "wake_create",
            description:
                Copy.text("agent.tool.wake_create"),
            inputSchema: schema([
                "at": property("string", Copy.text("agent.tool.wake_create.at")),
                "prompt": property("string", Copy.text("agent.tool.wake_create.prompt")),
                "conversation_id": property("string", Copy.text("agent.tool.wake_create.conversation_id")),
                "task_id": property("integer", Copy.text("agent.tool.wake_create.task_id")),
                "close": property("boolean", Copy.text("agent.tool.wake_create.close")),
            ], required: ["at", "prompt"])) { tools, args in try await tools.wakeCreate(args) },
        ToolEntry(
            name: "wake_list",
            description: Copy.text("agent.tool.wake_list"),
            inputSchema: schema(["all": property("boolean")])) { tools, args in try await tools.wakeList(args) },
        ToolEntry(
            name: "wake_cancel",
            description: Copy.text("agent.tool.wake_cancel"),
            inputSchema: schema(["id": property("integer")], required: ["id"])) { tools, args in try await tools.wakeCancel(args) },
    ]

    private func wakeCreate(_ args: [String: Value]) async throws -> String {
        guard let given = args.string("at"), !given.isEmpty else { throw ToolError.missing("at") }
        guard let at = Self.wakeTime(given) else { throw ToolError.invalid(Copy.text("agent.mcp.wakes.wakeCreate", ["given": "\(given)"])) }
        guard let prompt = args.string("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.missing("prompt") }
        let close = args.bool("close") == true
        if close, conversationID == nil { throw ToolError.invalid(Copy.text("agent.mcp.wakes.close")) }
        if args["task_id"] != nil, args["conversation_id"] != nil { throw ToolError.invalid(Copy.text("agent.mcp.wakes.close.2")) }
        let snapshot = try await client.snapshot()
        var request = WakeCreateRequest(
            at: at, prompt: prompt, closeConversationID: close ? conversationID : nil, createdBy: conversationID ?? agentSessionID, cwd: cwd)
        if let given = args.string("conversation_id"), !given.isEmpty {
            request.conversationID = try Self.conversation(given, in: snapshot.conversations).id
        } else if args["task_id"] == nil, let own = conversationID {
            request.conversationID = own
        } else {
            request.taskNumber = try await resolveTaskNumber(args)
        }
        let wake = try await client.createWake(request)
        return Self.report(Copy.text("agent.mcp.wakes.wake"), wake: wake, snapshot: snapshot, own: conversationID, next: Copy.text("agent.mcp.wakes.wake.2"))
    }

    private func wakeList(_ args: [String: Value]) async throws -> String {
        let snapshot = try await client.snapshot()
        var wakes = try await client.wakes()
        if args.bool("all") != true {
            let task = try? await currentTask(in: snapshot)?.number
            wakes = wakes.filter { wake in
                guard wake.state == .pending else { return false }
                guard conversationID != nil || task != nil else { return true }
                let conversationTask = wake.conversationID.flatMap { id in snapshot.conversations.first { $0.id == id }?.taskNumber }
                return wake.conversationID == conversationID || (task != nil && (wake.taskNumber == task || conversationTask == task))
            }
        }
        guard !wakes.isEmpty else { return args.bool("all") == true ? Copy.text("agent.mcp.wakes.conversationTask") : Copy.text("agent.mcp.wakes.conversationTask.2") }
        return ([Copy.text("agent.mcp.wakes.conversationTask.3", ["wakes": "\(wakes.count)"])] + wakes.map { "- " + Self.describe(wake: $0, snapshot: snapshot, own: conversationID) }).joined(separator: "\n")
    }

    private func wakeCancel(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("id") else { throw ToolError.missing("id") }
        let wake = try await client.cancelWake(id: id)
        return Self.report(Copy.text("agent.mcp.wakes.wake.3"), wake: wake, snapshot: try await client.snapshot(), own: conversationID, next: nil)
    }

    /// 届け先（会話か、タスクの lead）
    static func target(wake: Wake, snapshot: StateSnapshot, own: String?) -> String {
        if let id = wake.conversationID {
            let conversation = snapshot.conversations.first { $0.id == id }
            return Copy.text("agent.mcp.conversations.line", ["id": "\(id.prefix(8))"]) + (conversation?.title.map { "「\($0)」" } ?? "") + (id == own ? Copy.text("agent.mcp.wakes.conversation") : "")
                + (wake.taskNumber.map { Copy.text("agent.mcp.wakes.conversation.2", ["value": "\($0)"]) } ?? "")
        }
        return wake.taskNumber.map { Copy.text("agent.mcp.wakes.conversation.3", ["value": "\($0)"]) } ?? ""
    }

    /// 指示の頭・終了・届けた時刻・失敗。無い項目は出さない
    static func details(wake: Wake) -> [String] {
        var details: [String] = []
        if let first = wake.prompt.split(separator: "\n").first.map({ String($0.prefix(120)) }) { details.append(Copy.text("agent.mcp.wakes.details", ["value": "\(first)"])) }
        if wake.closesCreator { details.append(Copy.text("agent.mcp.wakes.details.2")) }
        if let at = wake.deliveredAt { details.append(Copy.text("agent.mcp.wakes.details.3", ["agentTime": "\(Wake.agentTime(at))"])) }
        if let failure = wake.failure { details.append((wake.state == .failed ? Copy.text("agent.mcp.wakes.details.4") : Copy.text("agent.mcp.wakes.details.5")) + failure) }
        return details
    }

    /// 一覧の 1 件。1 行目に id・状態・時刻・届け先、続く行に項目
    static func describe(wake: Wake, snapshot: StateSnapshot, own: String?) -> String {
        let head = "[\(wake.wakeID)] \(wake.state.rawValue) \(Wake.agentTime(wake.at)) → \(target(wake: wake, snapshot: snapshot, own: own))"
        return ([head] + details(wake: wake).map { "  - " + $0 }).joined(separator: "\n")
    }

    /// 作成・取り消しの結果
    static func report(_ heading: String, wake: Wake, snapshot: StateSnapshot, own: String?, next: String?) -> String {
        var lines = [heading, "- id: \(wake.wakeID)", Copy.text("agent.mcp.wakes.lines", ["state": "\(wake.state.rawValue)"]), Copy.text("agent.mcp.wakes.lines.2", ["agentTime": "\(Wake.agentTime(wake.at))"]), Copy.text("agent.mcp.wakes.lines.3", ["target": "\(target(wake: wake, snapshot: snapshot, own: own))"])]
        lines += details(wake: wake).map { "- " + $0 }
        if let next { lines.append(Copy.text("agent.mcp.core.operations.3") + next) }
        return lines.joined(separator: "\n")
    }

    /// ISO 8601 の日時。オフセットを省くと `timeZone` の時刻。秒は省いてよい
    static func wakeTime(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces)
        let offset = ISO8601DateFormatter()
        offset.formatOptions = [.withInternetDateTime]
        if let date = offset.date(from: value) { return date }
        offset.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = offset.date(from: value) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: value) { return date }
        }
        return nil
    }
}
