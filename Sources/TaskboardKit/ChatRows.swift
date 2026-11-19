import Foundation

/// チャットの行の並び。ツールの結果は呼び出しの行に入れるので行にしない（呼び出しが無い結果だけ行にする）。
/// 組にするときは、続いたツールの呼び出しと Claude Code が差し込んだ文（2 件以上）を 1 つの組にまとめ、畳んで出す。
/// 思考は、呼び出しの間に挟まるものだけ組に入れる（組の前と後ろの思考は 1 行で出す。呼び出しごとに思考が付くと、入れないと組が 1 件ずつに切れる）。
/// サブエージェントの発言は本筋の行にせず、起こした Agent の呼び出しの下に並べる（`subagents`）
public enum ChatRows {
    public enum Row: Identifiable, Hashable, Sendable {
        case message(ChatMessage)
        case tools([ChatMessage])

        /// 組は最初の行から作り、後ろに行が増えても変わらない
        public var id: String {
            switch self {
            case .message(let message): message.id
            case .tools(let members): "tools/" + (members.first?.id ?? "")
            }
        }

        /// 前・次の人の発言へ送るときに止まる行
        public var isPrompt: Bool {
            if case .message(let message) = self { message.isHumanPrompt } else { false }
        }
    }

    /// 前・次の人の発言へ送るときの行き先（`cursor` は前に送った発言）。次が無ければ nil で、呼ぶ側が下端へ戻す
    public static func promptStep(_ rows: [Row], forward: Bool, from cursor: String?) -> String? {
        let prompts = rows.filter(\.isPrompt).map(\.id)
        guard let index = cursor.flatMap(prompts.firstIndex(of:)) else { return forward ? nil : prompts.last }
        if forward { return index + 1 < prompts.count ? prompts[index + 1] : nil }
        return prompts[max(index - 1, 0)]
    }

    /// `parent` の中の行（nil なら本筋）。サブエージェントの中の行は `subagents` の 1 組を渡す
    public static func rows(_ messages: [ChatMessage], groupsTools: Bool, parent: String? = nil) -> [Row] {
        let calls = Set(messages.filter { $0.kind == .toolUse }.compactMap(\.toolID))
        var rows: [Row] = []
        var run: [ChatMessage] = []
        func flush() {
            let start = run.firstIndex { !$0.isThinking } ?? run.endIndex
            let end = run.lastIndex { !$0.isThinking }.map { $0 + 1 } ?? start
            rows += run[..<start].map(Row.message)
            if end - start > 1 { rows.append(.tools(Array(run[start..<end]))) } else if start < end { rows.append(.message(run[start])) }
            rows += run[end...].map(Row.message)
            run = []
        }
        for message in messages where message.parentToolID == parent {
            if message.kind == .toolResult, message.toolID.map(calls.contains) == true { continue }
            if groupsTools, message.kind == .toolUse || message.isInjected || message.isThinking {
                run.append(message)
                continue
            }
            flush()
            rows.append(.message(message))
        }
        flush()
        return rows
    }

    /// サブエージェントの発言を、起こした Agent の呼び出しの `toolID` ごとに古い順で
    public static func subagents(_ messages: [ChatMessage]) -> [String: [ChatMessage]] {
        Dictionary(grouping: messages.filter(\.isSubagent)) { $0.parentToolID ?? "" }
    }

    /// サブエージェントの発言（入れ子のサブエージェントの分も。10,000 件で打ち切る）。`subagents` は `subagents(_:)` の結果
    public static func descendants(of toolID: String, in subagents: [String: [ChatMessage]]) -> [ChatMessage] {
        var found: [ChatMessage] = []
        var queue = [toolID]
        while let id = queue.popLast(), found.count < 10_000 {
            let children = subagents[id] ?? []
            found += children
            queue += children.compactMap { $0.kind == .toolUse ? $0.toolID : nil }
        }
        return found
    }

    /// 発言 1 件の行の形。アプリの SwiftUI の行（iPhone・iPad）と AppKit の行（Mac）が同じ規則で振り分ける
    public enum MessageShape: Hashable, Sendable {
        case toolCall
        case thinking
        case notice(TaskboardNotice)
        case injected
        /// 人の発言・アシスタントの返事・知らせの 1 行
        case plain
    }

    public static func shape(of message: ChatMessage) -> MessageShape {
        if message.kind == .toolUse { return .toolCall }
        if message.isThinking { return .thinking }
        if message.kind == .text, let notice = message.taskboardNotice { return .notice(notice) }
        if message.kind == .text, message.isInjected { return .injected }
        return .plain
    }
}
