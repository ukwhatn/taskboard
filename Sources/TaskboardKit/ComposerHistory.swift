import Foundation

/// 入力欄の ↑↓ で呼び戻す、会話の人の発言の辿り方。呼び戻している間は、今出している文と、辿り始める前の文（↓ で戻る先）を持つ。
/// 履歴は呼び出しのたびに渡す（daemon からは取らず、会話の画面が持つ発言から作る）
public struct ComposerHistory: Equatable, Sendable {
    /// 新しい方から数えた、今出している発言の位置。呼び戻していなければ nil
    private var position: Int?
    private var original = ""
    /// 今出している発言の文。打ち直されて違う文になったら呼び戻しを終える（`edited(to:)`）
    public private(set) var recalled: String?

    public init() {}

    public var isRecalling: Bool { position != nil }

    /// 古い方の発言へ。`entries` は古い順。これ以上古い発言が無ければ nil（文はそのまま）
    public mutating func previous(in entries: [String], current: String) -> String? {
        let next = (position ?? -1) + 1
        guard next < entries.count else { return nil }
        if position == nil { original = current }
        return show(next, in: entries)
    }

    /// 新しい方の発言へ。いちばん新しい発言の次は、辿り始める前の文に戻って呼び戻しを終える。呼び戻していなければ nil
    public mutating func next(in entries: [String]) -> String? {
        guard let position else { return nil }
        guard position > 0, position < entries.count else {
            let text = original
            end()
            return text
        }
        return show(position - 1, in: entries)
    }

    /// 欄の文が `text` になった。呼び戻した文と違えば、打ち直したものとして呼び戻しを終える
    public mutating func edited(to text: String) {
        if let recalled, recalled != text { end() }
    }

    public mutating func end() {
        position = nil
        recalled = nil
        original = ""
    }

    private mutating func show(_ index: Int, in entries: [String]) -> String {
        position = index
        let text = entries[entries.count - 1 - index]
        recalled = text
        return text
    }

    /// 会話の発言から、呼び戻せる人の発言を古い順に取り出す。Claude Code が差し込んだ文とサブエージェントの中は除き、
    /// 添付したファイルの見出しは外す。空の文と、続けて同じ文は 1 つにする
    public static func entries(from messages: [ChatMessage]) -> [String] {
        var entries: [String] = []
        for message in messages where message.isHumanPrompt && !message.isSubagent {
            let text = (MentionedFiles.split(message.text)?.text ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != entries.last { entries.append(text) }
        }
        return entries
    }
}
