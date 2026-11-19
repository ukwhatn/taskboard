import Foundation
import MCP
import TaskboardKit

/// 会話が 4 か所に置く部品の tool。予算と書式の検証は daemon の書き込みの入口で行い、ここは引数を部品の型に読むだけ
extension TaskboardTools {
    static let panelPartSchema: Value = .object([
        "type": .string("object"),
        "description": .string(Copy.prompt("panel-parts")),
        "properties": .object([
            "id": property("string", Copy.text("agent.tool.panel.id")),
            "kind": property("string", Copy.text("agent.tool.panel.kind"), enum: PanelContent.Kind.allCases.map(\.rawValue)),
            "place": property("string", Copy.text("agent.tool.panel.place"), enum: PanelPlace.allCases.map(\.rawValue)),
            "bind": .object([
                "type": .string("object"),
                "description": .string(Copy.text("agent.tool.panel.bind")),
                "properties": .object([
                    "source": property("string", enum: PanelBinding.Source.allCases.map(\.rawValue)),
                    "group": property("string", Copy.text("agent.tool.panel.bind.group")),
                ]),
            ]),
        ]),
        "required": .array([.string("id"), .string("kind")]),
    ])

    static let panelTools: [ToolEntry] = [
        ToolEntry(
            name: "panel_set",
            description: Copy.text("agent.tool.panel_set"),
            inputSchema: schema([
                "task_id": currentTaskIDProperty,
                "parts": property("array", Copy.text("agent.tool.panel_set.parts"), items: panelPartSchema),
            ], required: ["parts"])) { tools, args in try await tools.panelSet(args) },
        ToolEntry(
            name: "panel_update",
            description: Copy.text("agent.tool.panel_update"),
            inputSchema: schema([
                "task_id": currentTaskIDProperty,
                "part": panelPartSchema,
                "remove": property("string", Copy.text("agent.tool.panel_update.remove")),
                "position": property("integer", Copy.text("agent.tool.panel_update.position")),
            ])) { tools, args in try await tools.panelUpdate(args) },
    ]

    private func panelSet(_ args: [String: Value]) async throws -> String {
        guard let value = args["parts"] else { throw ToolError.missing("parts") }
        let parts = try Self.decodePanel([PanelPartSpec].self, value, name: "parts")
        let number = try await resolveTaskNumber(args)
        let result = try await client.setPanel(task: number, PanelSetRequest(parts: parts, requester: requester))
        return Self.panelResult(result, number: number, key: "agent.mcp.panel.set")
    }

    private func panelUpdate(_ args: [String: Value]) async throws -> String {
        let part = try args["part"].map { try Self.decodePanel(PanelPartSpec.self, $0, name: "part") }
        let remove = args.string("remove").flatMap { $0.isEmpty ? nil : $0 }
        guard part != nil || remove != nil else { throw ToolError.missing("part") }
        let number = try await resolveTaskNumber(args)
        let result = try await client.updatePanelPart(
            task: number, PanelUpdateRequest(part: part, remove: remove, position: args.int("position"), requester: requester))
        return Self.panelResult(result, number: number, key: "agent.mcp.panel.updated")
    }

    /// 引数を部品の型に読む。文字列で渡された JSON も読む（配列を文字列にして渡すクライアントがある）
    static func decodePanel<T: Decodable>(_ type: T.Type, _ value: Value, name: String) throws -> T {
        let data: Data
        if let text = value.stringValue {
            data = Data(text.utf8)
        } else {
            data = try JSONEncoder().encode(value)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw ToolError.invalid(Copy.text("agent.mcp.panel.decode", ["name": name, "detail": Self.describe(error)]))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        let path: ([any CodingKey]) -> String = { keys in
            keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case .keyNotFound(let key, let context): return Copy.text("agent.mcp.panel.decode.missing", ["path": path(context.codingPath + [key])])
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return Copy.text("agent.mcp.panel.decode.value", ["path": path(context.codingPath), "detail": context.debugDescription])
        @unknown default: return "\(error)"
        }
    }

    static func panelResult(_ result: PanelWriteResult, number: Int, key: String) -> String {
        var lines = [Copy.text(key, ["number": "\(number)", "count": "\(result.panel.parts.count)"])]
        lines += panelSummary(result.panel)
        if !result.warnings.isEmpty {
            lines.append(Copy.text("agent.mcp.panel.warnings"))
            lines += result.warnings.map { "- " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// 部品ごとに id・種類・更新の時刻（紐づけと古さ）の 1 行。`task_get` も同じ行を出す
    static func panelSummary(_ panel: OverviewPanel) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return panel.parts.map { part in
            var notes: [String] = []
            if let bind = part.spec.bind { notes.append(Copy.text("agent.mcp.panel.summary.bound", ["source": bind.source.rawValue])) }
            if panel.isStale(part) { notes.append(Copy.text("agent.mcp.panel.summary.stale", ["turns": "\(panel.turn - part.updatedTurn)"])) }
            if case .draft = part.spec.content {
                notes.append(part.answer == nil ? Copy.text("agent.mcp.panel.summary.waiting") : Copy.text("agent.mcp.panel.summary.approved"))
            }
            let tail = notes.isEmpty ? "" : " ・ " + notes.joined(separator: " ・ ")
            return "- \(part.id)（\(part.spec.content.kind.rawValue)・\(part.spec.place.rawValue)）" + Copy.text("agent.mcp.panel.summary.updated", ["at": formatter.string(from: part.updatedAt)]) + tail
        }
    }
}
