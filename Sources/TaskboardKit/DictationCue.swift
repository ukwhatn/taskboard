import Foundation

/// 音声入力の区切りの最後の、送信の合図の言葉（「送信」「送信して」）。合図は校正の前の文で見分け、合図を除いた本文だけを校正に渡す
/// （校正が合図を消したり言い換えたりしても、送るかどうかは変わらない）。
/// 「メールを送信」「Slack に送信」のように助詞に続く「送信」は話の中身なので合図にしない。「送って」は会話への指示によく出る動詞なので合図にしない
public enum DictationCue {
    public struct Split: Equatable, Sendable {
        /// 合図を除いた文（合図だけを話したなら空）
        public var body: String
        public var send: Bool
    }

    /// 長いものから比べる
    static let words = ["送信して", "送信"]
    /// 直前にあると「送信」が文の中身になる助詞
    static let particles: Set<Character> = ["を", "が", "は", "も", "の", "に", "と", "で", "へ", "や"]
    /// 区切りの終わりと合図の前後で読み飛ばす文字
    static let trailing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。．.、,，!！?？…・"))

    public static func split(_ text: String) -> Split {
        let trimmed = trimmingEnd(text, trailing)
        guard let word = words.first(where: { trimmed.hasSuffix($0) }) else { return Split(body: text, send: false) }
        let head = String(trimmed.dropLast(word.count))
        let joint = trimmingEnd(head, .whitespacesAndNewlines)
        if let last = joint.last {
            // 句読点や空白で区切っていれば合図。区切らずに続くときは、助詞の後の「送信」を文の中身とみなす
            let separated = joint.count != head.count || last.unicodeScalars.allSatisfy(trailing.contains)
            if !separated, particles.contains(last) { return Split(body: text, send: false) }
        }
        return Split(body: trimmingEnd(head, CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "、,，"))), send: true)
    }

    private static func trimmingEnd(_ text: String, _ set: CharacterSet) -> String {
        var text = Substring(text)
        while let last = text.last, last.unicodeScalars.allSatisfy(set.contains) { text = text.dropLast() }
        return String(text)
    }
}

/// 入力欄に入れた音声入力の区切り（文の頭からの字数と、入れた文）。校正した文に置き換えるときに、入力欄のどこにあるかを探す
public struct DictationSpan: Equatable, Sendable {
    public var start: Int
    public var text: String

    public init(start: Int, text: String) {
        self.start = start
        self.text = text
    }

    /// 入れた位置にまだあればそこを、ずれていれば（前に文を打ち足した・消した）入れた位置に近いものを `replacement` に置き換える。
    /// 区切りの文を打ち直していて見つからなければ nil（置き換えない）
    public func replacing(with replacement: String, in draft: String) -> (text: String, span: DictationSpan)? {
        guard !text.isEmpty else { return nil }
        let characters = Array(draft)
        let needle = Array(text)
        guard characters.count >= needle.count else { return nil }
        var found: Int?
        for offset in 0...(characters.count - needle.count) where characters[offset..<offset + needle.count].elementsEqual(needle) {
            if found.map({ abs(offset - start) < abs($0 - start) }) ?? true { found = offset }
            if offset == start { break }
        }
        guard let offset = found else { return nil }
        let result = String(characters[..<offset]) + replacement + String(characters[(offset + needle.count)...])
        return (result, DictationSpan(start: offset, text: replacement))
    }
}

/// 合図の言葉で送った文を、会話が待っている問い（AskUserQuestion・request_user_input）への回答にする。
/// 文が選択肢の名前（推奨の印を外した名前）か番号（「1番」「2つ目」「最初」）と一致すれば、その選択肢を選んだ回答にする（送るのは印の付いたままの label）。
/// 一致しなければ自由記述の回答にする。問いが 2 問以上なら、どれか 1 問の選択肢の名前とだけ一致したときに限ってその問いに答え、決められなければ `undetermined`
public enum DictationAnswer {
    public enum Outcome: Equatable, Sendable {
        /// 選択肢を選んだ回答
        case selected(AskAnswer)
        /// 自由記述の回答
        case freeText(AskAnswer)
        /// どの問いへの回答か決められない（会話への発言として扱う）
        case undetermined
    }

    public static func match(_ text: String, questions: [AskQuestion]) -> Outcome {
        let spoken = normalized(text)
        guard !spoken.isEmpty, !questions.isEmpty, !questions.contains(where: \.isSecret) else { return .undetermined }
        let core = strippingEnding(spoken)
        var labelled: [(AskQuestion, AskOption)] = []
        for question in questions {
            for option in question.options where [spoken, core].contains(normalized(option.displayLabel)) { labelled.append((question, option)) }
        }
        if labelled.count == 1, let (question, option) = labelled.first {
            return .selected(AskAnswer(questionID: question.id, selected: [option.label]))
        }
        guard questions.count == 1, let question = questions.first, labelled.isEmpty else { return .undetermined }
        if let index = number(core, count: question.options.count) {
            return .selected(AskAnswer(questionID: question.id, selected: [question.options[index].label]))
        }
        return .freeText(AskAnswer(questionID: question.id, selected: [], freeText: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// NFKC・小文字にし、空白と句読点と記号を除く
    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !drop.contains($0) }))
    }

    /// 「〜でお願いします」「〜にします」のような言い添え（長いものから外す）
    private static let endings = ["でおねがいします", "でお願いします", "をえらびます", "を選びます", "を選択", "でいいです", "にします", "にして", "でいい", "です", "で"]

    private static func strippingEnding(_ text: String) -> String {
        guard let ending = endings.first(where: { text.hasSuffix($0) && text.count > $0.count }) else { return text }
        return String(text.dropLast(ending.count))
    }

    private static let kanji: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8]

    /// 「1」「1番」「1番目」「1つ目」「選択肢1」「一番」「最初」「最後」を 0 からの番号にする。選択肢の数を超えたら nil
    static func number(_ text: String, count: Int) -> Int? {
        var rest = Substring(text)
        if rest.hasPrefix("選択肢") { rest = rest.dropFirst(3) }
        for suffix in ["番目", "つ目", "個目", "番"] where rest.hasSuffix(suffix) && rest.count > suffix.count {
            rest = rest.dropLast(suffix.count)
            break
        }
        let value: Int? =
            switch rest {
            case "最初": 1
            case "最後": count
            default: Int(rest) ?? (rest.count == 1 ? rest.first.flatMap { kanji[$0] } : nil)
            }
        guard let value, (1...count).contains(value) else { return nil }
        return value - 1
    }
}
