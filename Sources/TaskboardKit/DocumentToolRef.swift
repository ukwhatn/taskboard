import Foundation

/// 会話の中の taskboard の `doc_publish`・`ask_user` の呼び出しが載せた文書と質問。ツールの結果の文（`MCPServer` の describe）から読む
public struct DocumentToolRef: Hashable, Sendable {
    /// 文書を開く taskboard の URL（`taskboard://task/<machine>/<task>/doc/<doc>`）
    public var url: URL
    public var docName: String
    /// 質問を付けたときの質問の束
    public var askID: Int64?
    public var questionCount: Int?

    public init(url: URL, docName: String, askID: Int64? = nil, questionCount: Int? = nil) {
        self.url = url
        self.docName = docName
        self.askID = askID
        self.questionCount = questionCount
    }

    /// Claude Code も codex（`CodexItem`）も、MCP のツールを `mcp__<server>__<tool>` の名前で渡す
    static let toolNames: Set<String> = ["mcp__taskboard__doc_publish", "mcp__taskboard__ask_user"]

    /// taskboard の `doc_publish`・`ask_user` の結果なら、その文書と質問。ほかのツールと、アプリの URL の行が無い結果（失敗・前の版）は nil
    public static func parse(toolName: String?, result: String) -> DocumentToolRef? {
        guard let toolName, toolNames.contains(toolName) else { return nil }
        var url: URL?
        var docName: String?
        var askID: Int64?
        var questionCount: Int?
        for line in result.split(separator: "\n") {
            if let value = line.wholeMatch(of: #/- アプリ: (taskboard://\S+)/#)?.1 {
                url = URL(string: String(value))
            } else if let match = line.firstMatch(of: #/^- 文書: \[\d+\] (.+?) ・ rev /#) {
                docName = String(match.1)
            } else if let value = line.wholeMatch(of: #/- ask_id: (\d+)/#)?.1 {
                askID = Int64(value)
            } else if let value = line.wholeMatch(of: #/- 質問: (\d+) 問/#)?.1 {
                questionCount = Int(value)
            }
        }
        guard let url, let docName else { return nil }
        return DocumentToolRef(url: url, docName: docName, askID: askID, questionCount: questionCount)
    }

    /// 会話の発言のうち、`doc_publish`・`ask_user` の呼び出しと結果の組が載せた文書と質問（発言の順）
    public static func refs(in messages: [ChatMessage]) -> [DocumentToolRef] {
        var names: [String: String] = [:]
        var refs: [DocumentToolRef] = []
        for message in messages {
            guard let toolID = message.toolID else { continue }
            switch message.kind {
            case .toolUse:
                if let name = message.toolName, toolNames.contains(name) { names[toolID] = name }
            case .toolResult:
                if !message.isError, let ref = parse(toolName: names[toolID], result: message.text) { refs.append(ref) }
            default: continue
            }
        }
        return refs
    }
}
