import Foundation

extension MachineState {
    /// タスクの状況の 1 文。終了していない会話のうち、最後にターンが終わったものの最後の応答の頭。終端の列のタスクでは出さない
    public func situation(of task: BoardTask) -> ConversationReply? {
        guard !isTerminal(task) else { return nil }
        return conversations(of: task).filter { !$0.isClosed }.compactMap(\.lastReply).max { $0.at < $1.at }
    }
}

extension CardSignals {
    /// カードの状況の 1 文。終了していない会話のうち最後にターンが終わったものの最後の応答の頭。完了・見送りの列では出さない（古い記録なので）
    public var situation: ConversationReply? {
        guard !terminal else { return nil }
        return conversations.filter { !$0.isClosed }.compactMap(\.lastReply).max { $0.at < $1.at }
    }
}

extension ConversationReply {
    /// 最後の応答の頭の 1 文。最初の文（「。」「！」「？」までか、英語の文の終わりの「. 」「! 」「? 」か、改行まで）。
    /// 頭の Markdown の印（見出しの #、箇条の - * と番号、引用の >）と、強調の ** __ と行内のコードの ` は外す。
    /// 見張り盤の札・iPhone の一覧・ボードのカードは、どれもこれを出す
    public var headline: String {
        let first = text.split(separator: "\n").lazy.map { Self.stripMarkers(String($0)) }.first { !$0.isEmpty }
        return first.map(Self.firstSentence) ?? ""
    }

    private static func stripMarkers(_ line: String) -> String {
        var line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        line = line.trimmingCharacters(in: .whitespaces)
        if let range = line.range(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)+"#, options: .regularExpression) {
            line.removeSubrange(range)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func firstSentence(_ line: String) -> String {
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if "。！？".contains(character) { return String(line[..<next]) }
            if ".!?".contains(character), next < line.endIndex, line[next] == " " { return String(line[..<next]) }
            index = next
        }
        return line
    }
}
