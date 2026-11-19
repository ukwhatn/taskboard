import Foundation

/// 生成中の文を、差分の届く速さにかかわらず一定の間隔で見せる進め方（Claude Desktop の生成中の文と同じ値）。
/// 見せていない分を約 `targetLag` 秒で出し切るように 1 歩の間隔を決め、英数字の単語の途中と、行の中で閉じていない `**`・`` ` ``・`~~`・リンクの途中では切らない
public enum StreamingPace {
    /// 1 歩で見せる字数（見せていない分が多ければ広げる）
    public static let step = 22
    /// 見せていない分を出し切るまでの目安（秒）
    public static let targetLag = 0.55
    public static let minInterval = 0.025
    public static let maxInterval = 0.15
    /// 単語の切れ目を探して先へ延ばす字数
    static let wordReach = 16
    /// 閉じていない記号の閉じを探して先へ延ばす字数
    static let markerReach = 400

    public struct Step: Equatable, Sendable {
        /// 見せる終わり（UTF-8 の位置）
        public var shown: Int
        /// 次の歩までの秒
        public var wait: Double
    }

    /// `text` を `shown`（UTF-8 の位置）まで見せているときの次の歩。切れる所が無ければ `shown` のまま `maxInterval` 待つ
    public static func next(_ text: String, shown: Int) -> Step {
        let utf8 = text.utf8
        guard shown < utf8.count else { return Step(shown: utf8.count, wait: maxInterval) }
        let start = utf8.index(utf8.startIndex, offsetBy: max(0, shown))
        let backlog = text[start...].count
        let interval = min(max(targetLag * Double(step) / Double(backlog), minInterval), maxInterval)
        let count = max(step, Int((Double(backlog) * interval / targetLag).rounded(.up)))
        let candidate = text.index(start, offsetBy: min(count, backlog))
        guard let end = cut(text, after: start, near: candidate) else { return Step(shown: shown, wait: maxInterval) }
        return Step(shown: utf8.distance(from: utf8.startIndex, to: end), wait: interval)
    }

    /// `candidate` の近くで切ってよい所。単語の切れ目へ先に延ばし、無ければ戻す。行の中で閉じていない記号があれば、同じ行で閉じた後まで延ばすか、
    /// 行が終わっていればその行の終わりまで、どちらでもなければ記号の手前まで戻す
    static func cut(_ text: String, after start: String.Index, near candidate: String.Index) -> String.Index? {
        guard let end = wordCut(text, after: start, near: candidate) else { return nil }
        var markers = InlineMarkers()
        var index = text[..<end].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        var token = index
        while index < end {
            token = index
            index = markers.step(text, at: index)
        }
        if index == end, markers.firstOpen == nil { return end }
        // 切る位置をまたいだ記号は、その頭で開いたとみなす
        let open = [markers.firstOpen, index > end ? token : nil].compactMap { $0 }.min() ?? end
        var reach = markerReach
        while index < text.endIndex, text[index] != "\n", reach > 0 {
            index = markers.step(text, at: index)
            reach -= 1
            if markers.firstOpen == nil, isWordBoundary(text, at: index) { return index }
        }
        if index < text.endIndex, text[index] == "\n" { return index }
        return open > start ? open : nil
    }

    /// 英数字の単語の途中で切らない。先へ `wordReach` 字まで切れ目を探し、無ければ `start` の後ろへ戻って探す
    private static func wordCut(_ text: String, after start: String.Index, near candidate: String.Index) -> String.Index? {
        var forward = candidate
        for _ in 0...wordReach {
            if isWordBoundary(text, at: forward) { return forward }
            guard forward < text.endIndex else { break }
            forward = text.index(after: forward)
        }
        var backward = candidate
        while backward > start {
            if isWordBoundary(text, at: backward) { return backward }
            backward = text.index(before: backward)
        }
        return nil
    }

    /// 前と後ろの字がどちらも英数字なら単語の途中。文の終わりは、最後の字が英数字なら単語が続くかもしれない
    static func isWordBoundary(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        guard index < text.endIndex else { return !isWordCharacter(before) }
        return !(isWordCharacter(before) && isWordCharacter(text[index]))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    /// 1 行の中の行内の記号の開き。行内のコードの中では、ほかの記号を数えない
    struct InlineMarkers {
        private var code: (at: String.Index, length: Int)?
        private var bold: String.Index?
        private var strike: String.Index?
        private var link: (at: String.Index, inURL: Bool)?
        /// 文の終わりの `*`・`~`・`` ` ``。次の字が届くまで、記号かどうか（何字の記号か）が分からない
        private var pending: String.Index?

        var firstOpen: String.Index? {
            [code?.at, bold, strike, link?.at, pending].compactMap { $0 }.min()
        }

        /// `index` から始まる 1 つ（記号か 1 字）を数えて、次の位置を返す
        mutating func step(_ text: String, at index: String.Index) -> String.Index {
            let character = text[index]
            let next = text.index(after: index)
            let following = next < text.endIndex ? text[next] : nil
            if character == "`" {
                let run = text[index...].prefix { $0 == "`" }
                if run.endIndex == text.endIndex {
                    pending = index
                } else if let open = code {
                    if run.count == open.length { code = nil }
                } else {
                    code = (index, run.count)
                }
                return run.endIndex
            }
            guard code == nil else { return next }
            if character == "*" || character == "~" {
                guard let following else {
                    pending = index
                    return next
                }
                guard following == character else { return next }
                if character == "*" { bold = bold == nil ? index : nil } else { strike = strike == nil ? index : nil }
                return text.index(after: next)
            }
            switch character {
            case "[" where link == nil:
                link = (index, false)
            case "]" where link?.inURL == false:
                if following == "(" {
                    link?.inURL = true
                    return text.index(after: next)
                }
                // 次の字がまだ届いていなければ、リンクかどうか分からないので開いたままにする
                if following != nil { link = nil }
            case ")" where link?.inURL == true:
                link = nil
            default:
                break
            }
            return next
        }
    }
}
