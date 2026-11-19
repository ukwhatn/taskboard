import Foundation
import MCP
import TaskboardKit

/// `usage_history`: 貯めた利用状況をエージェントが読める文にまとめる
extension TaskboardTools {
    func usageHistory(_ args: [String: Value]) async throws -> String {
        let days = args.int("days") ?? 7
        guard (1...90).contains(days) else { throw ToolError.invalid(Copy.text("agent.mcp.usage.days")) }
        let now = Date()
        let query = UsageHistoryQuery(from: now.addingTimeInterval(-Double(days) * 86_400), to: now, bucketSeconds: days <= 2 ? 3600 : 86_400)
        return Self.describe(history: try await client.usageHistory(query), days: days)
    }

    static func describe(history: UsageHistory, days: Int) -> String {
        var lines = [Copy.text("agent.mcp.usage.lines", ["days": "\(days)"]) + (history.recordingSince.map { Copy.text("agent.mcp.usage.lines.2", ["time": "\(time($0))"]) } ?? Copy.text("agent.mcp.usage.lines.3"))]
        func tokens(_ value: Int) -> String {
            value >= 1_000_000_000 ? String(format: "%.1fB", Double(value) / 1_000_000_000) : value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000) : value >= 1000 ? "\(value / 1000)k" : "\(value)"
        }
        func breakdown(_ counts: TokenCounts) -> String {
            Copy.text("agent.mcp.usage.breakdown", ["tokens": "\(tokens(counts.total))", "tokens2": "\(tokens(counts.input))", "tokens3": "\(tokens(counts.cacheWrite))", "tokens4": "\(tokens(counts.cacheRead))", "tokens5": "\(tokens(counts.output))"])
        }

        let byModel = Dictionary(grouping: history.tokens) { "\($0.engine.label) \($0.model.isEmpty ? "（model 不明）" : $0.model)" }
            .mapValues { buckets in (buckets.reduce(0) { $0 + $1.requests }, buckets.reduce(TokenCounts()) { $0 + $1.tokens }) }
            .sorted { $0.value.1.total > $1.value.1.total }
        lines.append("")
        lines.append(Copy.text("agent.mcp.usage.byModel"))
        if byModel.isEmpty { lines.append(Copy.text("agent.mcp.usage.byModel.2")) }
        for (model, value) in byModel { lines.append(Copy.text("agent.mcp.usage.byModel.3", ["model": "\(model)", "value": "\(value.0)", "breakdown": "\(breakdown(value.1))"])) }

        lines.append("")
        lines.append(Copy.text("agent.mcp.usage.byModel.4", ["sessions": "\(history.sessions.count)", "sessionCount": "\(history.sessionCount)"]))
        if !history.sessions.isEmpty {
            let total = history.sessions.reduce(0) { $0 + $1.tokens.total }
            lines.append(Copy.text("agent.mcp.usage.total", ["sessions": "\(history.sessions.count)", "tokens": "\(tokens(total / history.sessions.count))"]))
        }
        for session in history.sessions.prefix(15) {
            let place = session.title ?? session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
            lines.append(
                Copy.text("agent.mcp.usage.place", ["label": "\(session.engine.label)", "session": "\(session.session.prefix(8))", "place": "\(place)", "requests": "\(session.requests)", "breakdown": "\(breakdown(session.tokens))"])
                    + (session.maxContext.map { Copy.text("agent.mcp.usage.place.2", ["tokens": "\(tokens($0))"]) } ?? "") + Copy.text("agent.mcp.usage.place.3", ["compactions": "\(session.compactions)"]))
        }

        lines.append("")
        lines.append(Copy.text("agent.mcp.usage.place.4"))
        let skills = Dictionary(grouping: history.skills) { "\($0.engine.label) \($0.name)" }.sorted {
            $0.value.reduce(0) { $0 + $1.count } > $1.value.reduce(0) { $0 + $1.count }
        }
        if skills.isEmpty { lines.append(Copy.text("agent.mcp.usage.byModel.2")) }
        for (name, counts) in skills {
            let model = counts.filter { $0.source == .model }.reduce(0) { $0 + $1.count }
            let command = counts.filter { $0.source == .command }.reduce(0) { $0 + $1.count }
            let last = counts.map(\.lastAt).max().map(time) ?? ""
            lines.append(Copy.text("agent.mcp.usage.last", ["name": "\(name)", "model": "\(model)", "command": "\(command)", "value": "\(last)"]))
        }

        lines.append("")
        lines.append(Copy.text("agent.mcp.usage.last.2"))
        let compactions = history.compactions
        if compactions.isEmpty { lines.append(Copy.text("agent.mcp.usage.byModel.2")) }
        for (label, trigger) in [(Copy.text("agent.mcp.usage.compactions"), UsageHistory.Compaction.Trigger.auto), (Copy.text("agent.mcp.usage.compactions.2"), .manual)] {
            let befores = compactions.filter { $0.trigger == trigger }.compactMap(\.before).sorted()
            guard !befores.isEmpty else { continue }
            lines.append(Copy.text("agent.mcp.usage.befores", ["label": "\(label)", "befores": "\(befores.count)", "tokens": "\(tokens(befores[0]))", "tokens2": "\(tokens(befores[befores.count / 2]))", "tokens3": "\(tokens(befores[befores.count - 1]))"]))
        }
        let codex = compactions.filter { $0.trigger == nil }
        if !codex.isEmpty { lines.append(Copy.text("agent.mcp.usage.codex", ["codex": "\(codex.count)"])) }

        lines.append("")
        lines.append(Copy.text("agent.mcp.usage.codex.2"))
        let samples = history.samples
        lines.append(Copy.text("agent.mcp.usage.samples", ["samples": "\(samples.map(\.claudeActive).max() ?? 0)", "samples2": "\(samples.map(\.codexActive).max() ?? 0)"]))
        let peaks: [(String, Double?)] = [
            (Copy.text("agent.mcp.usage.peaks"), samples.compactMap(\.claudeFiveHour).max()), (Copy.text("agent.mcp.usage.peaks.2"), samples.compactMap(\.claudeSevenDay).max()),
            (Copy.text("agent.mcp.usage.peaks.3"), samples.compactMap(\.codexPrimary).max()), (Copy.text("agent.mcp.usage.peaks.4"), samples.compactMap(\.codexSecondary).max()),
            (Copy.text("agent.mcp.usage.peaks.5"), samples.compactMap(\.codexMonthly).max()),
        ]
        let shown = peaks.compactMap { name, value in value.map { "\(name) \(percent($0))" } }
        lines.append(Copy.text("agent.mcp.usage.shown") + (shown.isEmpty ? Copy.text("agent.mcp.usage.shown.2") : shown.joined(separator: "、")))
        return lines.joined(separator: "\n")
    }
}
