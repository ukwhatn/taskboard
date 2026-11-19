import Foundation

/// 音声入力を入力欄に差し込む位置。聞き始めたときの文と選択の前後を持ち、聞き取った文（途中の文も）を差し込んだ文とカーソルを返す。
/// 途中の文は聞き取るたびに置き換わるので、毎回聞き始めたときの文から組む
public struct DictationDraft: Equatable, Sendable {
    public let before: String
    public let after: String

    /// `selection` が nil なら末尾に足す。範囲を選んでいれば、その範囲を聞き取った文に置き換える
    public init(draft: String, selection: Range<String.Index>?) {
        guard let selection else {
            before = draft
            after = ""
            return
        }
        before = String(draft[..<selection.lowerBound])
        after = String(draft[selection.upperBound...])
    }

    public func inserting(_ spoken: String) -> (text: String, cursor: String.Index) {
        let head = before + spoken
        let text = head + after
        return (text, text.index(text.startIndex, offsetBy: head.count))
    }
}

/// 音声認識と校正に渡す語彙。開いている会話のタスクの題と番号、会話の最近の発言に出た番号のような語と英数字の語（識別子・ファイル名・技術語）
public enum DictationVocabulary {
    /// Whisper の prompt は 223 トークンで切られるので、新しい発言の語から 100 語まで
    public static let limit = 100

    /// `#12`、`r#3`、`PROJ-12` の形。前後が ASCII の英数字なら語の途中なので取らない（日本語の文字には続いてよい）
    private static var numberLike: Regex<(Substring, Substring)> { /(?:^|[^A-Za-z0-9_#-])([A-Za-z]+#\d+|#\d+|[A-Z][A-Z0-9]{1,9}-\d+)(?![A-Za-z0-9_])/ }
    /// 英字で始まる 2 字以上の語。`.`・`_`・`/`・`-` でつないだ `ConversationService.swift`・`feature/9y-voice` は 1 語にする
    private static var wordLike: Regex<(Substring, Substring)> { /(?:^|[^A-Za-z0-9_#])([A-Za-z][A-Za-z0-9]*(?:[._\/-][A-Za-z0-9]+)*)(?![A-Za-z0-9_#])/ }

    /// 題と番号を先に、発言（人とアシスタントの文。ツールと思考は読まない）の語を新しい発言から並べる。1 つの発言の中では番号のような語を先に置く。同じ語は 1 回だけ
    public static func phrases(taskTitle: String?, taskNumber: Int?, messages: [ChatMessage]) -> [String] {
        var phrases: [String] = []
        var seen: Set<String> = []
        func add(_ phrase: String) {
            guard phrases.count < limit, !phrase.isEmpty, seen.insert(phrase).inserted else { return }
            phrases.append(phrase)
        }
        if let title = taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines) { add(title) }
        if let taskNumber { add("#\(taskNumber)") }
        let numberLike = numberLike
        let wordLike = wordLike
        for message in messages.reversed() where message.kind == .text && !message.isThinking {
            guard phrases.count < limit else { break }
            for match in message.text.matches(of: numberLike) { add(String(match.output.1)) }
            for match in message.text.matches(of: wordLike) where match.output.1.count >= 2 { add(String(match.output.1)) }
        }
        return phrases
    }
}
