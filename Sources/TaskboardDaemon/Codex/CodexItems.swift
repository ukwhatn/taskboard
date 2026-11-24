import Foundation
import TaskboardKit

/// codex の thread の item（`ThreadItem`）のうち、会話の画面に写すもの。知らない種類は `other` にして読み飛ばす
enum CodexItem: Decodable, Equatable, Sendable {
    /// `clientId` は送ったときの `clientUserMessageId`
    case userMessage(id: String, clientID: String?, text: String, images: Int)
    case agentMessage(id: String, text: String)
    /// Plan モードの提案の計画。完成した item の本文が正で、`item/plan/delta` の連結と一致するとは限らない
    case plan(id: String, text: String)
    case reasoning(id: String)
    case command(id: String, command: String, output: String?, exitCode: Int?, status: String)
    case fileChange(id: String, changes: [FileChange], status: String)
    case mcpToolCall(id: String, server: String, tool: String, arguments: String, status: String, result: String?, error: String?)
    case webSearch(id: String, query: String)
    /// サブエージェントへの呼び出し（`collabAgentToolCall`。wait・sendInput など）。0.162.1 は子の thread を載せない（`receiverThreadIds` が空）
    case agent(id: String, tool: String, prompt: String?, status: String)
    /// サブエージェントの始まりと終わり（`subAgentActivity`。`kind` は started・interacted・interrupted・completed）。`thread` は子の thread。
    /// started の id は起こした呼び出しの id、completed の id は別の値なので、2 つは `thread` で組にする
    case subagent(id: String, kind: String, thread: String, path: String?)
    /// 画像を見た（`imageView`）
    case imageView(id: String, path: String)
    /// 動的なツール（`dynamicToolCall`）。`name` は namespace があれば「namespace.tool」、`output` は結果の文の部分をつないだもの
    case dynamicTool(id: String, name: String, arguments: String, status: String, output: String?, success: Bool?)
    /// 画像の生成（`imageGeneration`）。`limited` は利用枠の上限で作れなかった（`failure` の唯一の種類が usageLimitExceeded）
    case imageGeneration(id: String, prompt: String?, status: String, savedPath: String?, generated: Bool, limited: Bool)
    /// レビューの始まり（`enteredReviewMode`。`review` は対象の説明）と終わり（`exitedReviewMode`。指摘の本文は続く agentMessage で届く）
    case review(id: String, entered: Bool, review: String)
    case other(id: String?, type: String)

    struct FileChange: Decodable, Equatable, Sendable {
        var path: String
        var kind: String
        var diff: String

        private enum CodingKeys: String, CodingKey { case path, kind, diff }
        private struct Kind: Decodable { var type: String }

        init(path: String, kind: String, diff: String) {
            self.path = path
            self.kind = kind
            self.diff = diff
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            kind = (try? c.decode(Kind.self, forKey: .kind).type) ?? "update"
            diff = (try? c.decode(String.self, forKey: .diff)) ?? ""
        }
    }

    var id: String? {
        switch self {
        case .userMessage(let id, _, _, _), .agentMessage(let id, _), .plan(let id, _), .reasoning(let id), .command(let id, _, _, _, _), .fileChange(let id, _, _),
            .mcpToolCall(let id, _, _, _, _, _, _), .webSearch(let id, _), .agent(let id, _, _, _), .subagent(let id, _, _, _), .imageView(let id, _),
            .dynamicTool(let id, _, _, _, _, _), .imageGeneration(let id, _, _, _, _, _), .review(let id, _, _):
            id
        case .other(let id, _): id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, clientId, content, text, command, aggregatedOutput, exitCode, status, changes, server, tool, arguments, result, error, query, prompt,
            kind, agentThreadId, agentPath, path, namespace, contentItems, success, revisedPrompt, savedPath, failure, review
    }

    private struct Content: Decodable {
        var type: String
        var text: String?
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let id = try? c.decode(String.self, forKey: .id)
        func string(_ key: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        guard let id else {
            self = .other(id: nil, type: type)
            return
        }
        switch type {
        case "userMessage":
            let content = (try? c.decode([Content].self, forKey: .content)) ?? []
            self = .userMessage(
                id: id, clientID: string(.clientId), text: content.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n"),
                images: content.filter { $0.type == "localImage" || $0.type == "image" }.count)
        case "agentMessage":
            self = .agentMessage(id: id, text: string(.text) ?? "")
        case "plan":
            self = .plan(id: id, text: string(.text) ?? "")
        case "reasoning":
            self = .reasoning(id: id)
        case "commandExecution":
            self = .command(
                id: id, command: string(.command) ?? "", output: string(.aggregatedOutput), exitCode: try? c.decodeIfPresent(Int.self, forKey: .exitCode),
                status: string(.status) ?? "")
        case "fileChange":
            self = .fileChange(id: id, changes: (try? c.decode([FileChange].self, forKey: .changes)) ?? [], status: string(.status) ?? "")
        case "mcpToolCall":
            self = .mcpToolCall(
                id: id, server: string(.server) ?? "", tool: string(.tool) ?? "", arguments: Self.json(c, .arguments), status: string(.status) ?? "",
                result: (try? c.decodeIfPresent(JSONText.self, forKey: .result))?.text, error: (try? c.decodeIfPresent(JSONText.self, forKey: .error))?.text)
        case "webSearch":
            self = .webSearch(id: id, query: string(.query) ?? "")
        case "collabAgentToolCall":
            self = .agent(id: id, tool: string(.tool) ?? "", prompt: string(.prompt), status: string(.status) ?? "")
        case "subAgentActivity":
            guard let thread = string(.agentThreadId) else {
                self = .other(id: id, type: type)
                return
            }
            self = .subagent(id: id, kind: string(.kind) ?? "", thread: thread, path: string(.agentPath))
        case "imageView":
            self = .imageView(id: id, path: string(.path) ?? "")
        case "dynamicToolCall":
            let tool = string(.tool) ?? ""
            let output = (try? c.decodeIfPresent([Content].self, forKey: .contentItems))?.map { $0.compactMap { $0.type == "inputText" ? $0.text : nil }.joined(separator: "\n") }
            self = .dynamicTool(
                id: id, name: string(.namespace).map { "\($0).\(tool)" } ?? tool, arguments: Self.json(c, .arguments), status: string(.status) ?? "",
                output: output, success: try? c.decodeIfPresent(Bool.self, forKey: .success))
        case "imageGeneration":
            // result は画像の base64 で大きいので、できたかだけを見る
            self = .imageGeneration(
                id: id, prompt: string(.revisedPrompt), status: string(.status) ?? "", savedPath: string(.savedPath), generated: !(string(.result) ?? "").isEmpty,
                limited: c.contains(.failure) && (try? c.decodeNil(forKey: .failure)) == false)
        case "enteredReviewMode", "exitedReviewMode":
            self = .review(id: id, entered: type == "enteredReviewMode", review: string(.review) ?? "")
        default:
            self = .other(id: id, type: type)
        }
    }

    private static func json(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String {
        (try? c.decodeIfPresent(JSONText.self, forKey: key))?.text ?? ""
    }
}

/// 任意の JSON の値を、詰めた JSON の文字列で持つ
private struct JSONText: Decodable {
    var text: String

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            text = string
        } else if let object = try? value.decode([String: JSONText].self) {
            text = "{" + object.keys.sorted().map { "\"\($0)\":\(object[$0]!.quoted)" }.joined(separator: ",") + "}"
        } else if let array = try? value.decode([JSONText].self) {
            text = "[" + array.map(\.quoted).joined(separator: ",") + "]"
        } else if let bool = try? value.decode(Bool.self) {
            text = bool ? "true" : "false"
        } else if let number = try? value.decode(Double.self) {
            text = number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        } else {
            text = "null"
        }
        isString = (try? value.decode(String.self)) != nil
    }

    private var isString = false
    private var quoted: String {
        guard isString, let data = try? JSONEncoder().encode(text) else { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

/// codex の item を会話の発言（`ChatMessage`）に写す。生成中の流れ（`item/completed`）と履歴（`thread/items/list`）の両方が使う
enum CodexItems {
    /// ツールの名前は、アプリが Claude の名前で見分けている所（コマンド・ファイルの札・サブエージェント）に合わせる
    static let commandTool = "Bash"
    static let fileTool = "Edit"
    /// 会話の圧縮の item（`item/started` で始まり `item/completed` で終わる。0.162.1 の型）
    static let compactionType = "contextCompaction"
    static let agentTool = "Agent"
    static let webSearchTool = "WebSearch"
    static let imageViewTool = "Read"
    static let imageGenerationTool = "ImageGeneration"

    /// 終わった item の発言。人の発言の id は送ったときの uuid（アプリが先に出した発言と重ねる）
    static func messages(_ item: CodexItem, at: Date?) -> [ChatMessage] {
        switch item {
        case .userMessage(let id, let clientID, let text, let images):
            var messages: [ChatMessage] = []
            if RunResultText.isResult(text) {
                messages.append(ChatMessage(id: clientID?.lowercased() ?? id, role: .user, kind: .notice, text: ConversationScreenText.runResultSent, at: at))
            } else if !text.isEmpty {
                messages.append(ChatMessage(id: clientID?.lowercased() ?? id, role: .user, kind: .text, text: text, at: at))
            }
            if images > 0 {
                messages.append(ChatMessage(id: id + "-images", role: .user, kind: .notice, text: "画像 \(images) 枚", at: at))
            }
            return messages
        case .agentMessage(let id, let text), .plan(let id, let text):
            return text.isEmpty ? [] : [ChatMessage(id: id, role: .assistant, kind: .text, text: text, at: at)]
        case .reasoning, .other:
            return []
        case .command(let id, let command, let output, let exitCode, let status):
            let use = ChatMessage(id: id, role: .assistant, kind: .toolUse, text: command, toolName: commandTool, toolID: id, at: at)
            guard status != "inProgress" else { return [use] }
            let failed = status == "failed" || status == "declined" || (exitCode ?? 0) != 0
            let text = status == "declined" ? "実行しなかった（拒否）" : output ?? ""
            return [use, result(id, text: text, isError: failed, at: at)]
        case .fileChange(let id, let changes, let status):
            let summary = changes.map(\.path).joined(separator: "\n")
            let use = ChatMessage(id: id, role: .assistant, kind: .toolUse, text: summary, toolName: fileTool, toolID: id, at: at)
            guard status != "inProgress" else { return [use] }
            var done = result(id, text: status == "declined" ? "変更しなかった（拒否）" : summary, isError: status == "failed" || status == "declined", at: at)
            if status == "completed" { done.files = changes.map(file) }
            return [use, done]
        case .mcpToolCall(let id, let server, let tool, let arguments, let status, let result, let error):
            let use = ChatMessage(id: id, role: .assistant, kind: .toolUse, text: arguments, toolName: "mcp__\(server)__\(tool)", toolID: id, at: at)
            guard status != "inProgress" else { return [use] }
            return [use, self.result(id, text: error ?? result ?? "", isError: error != nil || status == "failed", at: at)]
        case .webSearch(let id, let query):
            return [ChatMessage(id: id, role: .assistant, kind: .toolUse, text: query, toolName: webSearchTool, toolID: id, at: at)]
        case .agent(let id, let tool, let prompt, let status):
            let use = ChatMessage(id: id, role: .assistant, kind: .toolUse, text: prompt ?? tool, toolName: agentTool, toolID: id, at: at)
            guard status != "inProgress" else { return [use] }
            return [use, result(id, text: tool, isError: status == "failed", at: at)]
        case .imageView(let id, let path):
            return [ChatMessage(id: id, role: .assistant, kind: .toolUse, text: path, toolName: imageViewTool, toolID: id, at: at), result(id, text: path, isError: false, at: at)]
        case .dynamicTool(let id, let name, let arguments, let status, let output, let success):
            let use = ChatMessage(id: id, role: .assistant, kind: .toolUse, text: arguments, toolName: name, toolID: id, at: at)
            guard status != "inProgress" else { return [use] }
            return [use, result(id, text: output ?? "", isError: status == "failed" || success == false, at: at)]
        case .imageGeneration(let id, let prompt, let status, let savedPath, let generated, let limited):
            let use = ChatMessage(id: id, role: .assistant, kind: .toolUse, text: prompt ?? "", toolName: imageGenerationTool, toolID: id, at: at)
            if limited { return [use, result(id, text: "画像を生成できませんでした。利用枠の上限に達しています。", isError: true, at: at)] }
            if status == "failed" { return [use, result(id, text: "", isError: true, at: at)] }
            guard generated || savedPath != nil else { return [use] }
            return [use, result(id, text: savedPath ?? "", isError: false, at: at)]
        case .review(let id, let entered, let review):
            let text = entered ? (review.isEmpty ? "コードレビューを始めました" : "コードレビューを始めました（\(review)）") : "コードレビューが終わりました"
            return [ChatMessage(id: id, role: .user, kind: .notice, text: text, at: at)]
        case .subagent(let id, let kind, let thread, let path):
            // 子の発言を並べる行。toolID は子の thread（終わりの item と組にし、子の発言の parentToolID にする）
            switch kind {
            case "started":
                return [ChatMessage(id: id, role: .assistant, kind: .toolUse, text: path ?? thread, toolName: agentTool, toolID: thread, at: at)]
            case "completed", "interrupted":
                return [ChatMessage(id: id, role: .user, kind: .toolResult, text: kind, toolID: thread, isError: kind == "interrupted", at: at)]
            default:
                return []
            }
        }
    }

    /// `thread` の子の発言の parentToolID（`spawner` はその子を起こした thread。nil は本筋）。子を起こした行の toolID と同じ値
    static func subagentParent(_ thread: String, spawnedIn spawner: String?) -> String {
        spawner.map { subagentID(thread, thread: $0) } ?? thread
    }

    /// サブエージェントの thread の item の発言。本筋の item と id が重ならないよう thread で分け、起こした呼び出しの行の toolID を付ける
    static func subagentMessages(_ item: CodexItem, at: Date?, thread: String, parentToolID: String) -> [ChatMessage] {
        messages(item, at: at).map { message in
            var message = message
            message.id = subagentID(message.id, thread: thread)
            message.toolID = message.toolID.map { subagentID($0, thread: thread) }
            message.parentToolID = parentToolID
            return message
        }
    }

    static func subagentID(_ id: String, thread: String) -> String { "\(thread)/\(id)" }

    /// 発言の id（`messages` が付けたもの）の元の item の id か、人の発言の送った uuid
    static func itemID(ofMessage messageID: String) -> String {
        for suffix in ["-result", "-images"] where messageID.hasSuffix(suffix) { return String(messageID.dropLast(suffix.count)) }
        return messageID
    }

    static func matches(_ item: CodexItem, itemID: String) -> Bool {
        if item.id == itemID { return true }
        if case .userMessage(_, let clientID?, _, _) = item { return clientID.lowercased() == itemID.lowercased() }
        return false
    }

    private static func result(_ id: String, text: String, isError: Bool, at: Date?) -> ChatMessage {
        let bytes = text.utf8.count
        let clipped = bytes > ChatMessage.resultLimit ? String(decoding: Data(text.utf8.prefix(ChatMessage.resultLimit)), as: UTF8.self) : text
        return ChatMessage(
            id: id + "-result", role: .user, kind: .toolResult, text: clipped, toolID: id, isError: isError, fullBytes: bytes > ChatMessage.resultLimit ? bytes : nil,
            at: at)
    }

    private static func file(_ change: CodexItem.FileChange) -> ChatFile {
        let hunks = ChatDiffHunk.parse(unified: change.diff)
        // offset は transcript の中の位置（中身の口の `at`）。codex の会話に transcript は無い
        return ChatFile(
            path: change.path, action: change.kind == "add" ? .created : .edited, hunks: hunks, added: hunks.reduce(0) { $0 + $1.added },
            removed: hunks.reduce(0) { $0 + $1.removed }, offset: 0)
    }
}
