import Foundation

/// チャットの入力欄で `/` から選べる skill と command と、Claude Code の組み込みのコマンド（`GET /v1/commands?cwd=`）。daemon のマシンの Claude Code が読むもの
public struct SlashCommand: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case skill
        case command
        /// Claude Code の組み込みのコマンドと同梱の skill（daemon が持つ固定の一覧）
        case builtin
    }

    public enum Scope: String, Codable, Sendable {
        /// `~/.claude`
        case user
        /// 作業ディレクトリかその親の `.claude`
        case project
        /// Claude Code に入っている
        case builtin
    }

    public var name: String
    public var description: String
    public var kind: Kind
    public var scope: Scope

    public var id: String { name }

    public init(name: String, description: String, kind: Kind, scope: Scope) {
        self.name = name
        self.description = description
        self.kind = kind
        self.scope = scope
    }

    /// 頭が合うものを先に、名前の途中に含むものを後に並べる。大文字と小文字は区別しない。
    /// `leading` が false（文の途中の `/`）なら組み込みを外す
    public static func matching(_ typed: String, in commands: [SlashCommand], leading: Bool = true, limit: Int = 8) -> [SlashCommand] {
        let commands = leading ? commands : commands.filter { $0.kind != .builtin }
        guard !typed.isEmpty else { return Array(commands.prefix(limit)) }
        let head = commands.filter { $0.name.range(of: typed, options: [.caseInsensitive, .anchored]) != nil }
        let inner = commands.filter { command in
            !head.contains(command) && command.name.range(of: typed, options: .caseInsensitive) != nil
        }
        return Array((head + inner).prefix(limit))
    }
}

/// 入力欄でいま打っている `/` の語。`/` は文の頭か空白・改行の後にあり、カーソルまでに空白も 2 つめの `/` も無い
public struct SlashTyping: Hashable, Sendable {
    /// `/` の後からカーソルまでの打ちかけ（`/` だけなら空）
    public var name: String
    /// `/` が文の頭にあるか。Claude Code の組み込みと taskboard の操作は、文の頭に書いたときだけ効く
    public var leading: Bool
    /// 選んだ名前で置き換える範囲（`/` から、カーソルの後ろの語の終わりまで）
    public var range: Range<String.Index>

    /// `cursor` が nil なら文の終わりにあるものとして探す
    public static func find(in draft: String, cursor: String.Index? = nil) -> SlashTyping? {
        let end = cursor ?? draft.endIndex
        let start = draft[..<end].lastIndex(where: \.isWhitespace).map { draft.index(after: $0) } ?? draft.startIndex
        guard start < end, draft[start] == "/" else { return nil }
        let name = draft[draft.index(after: start)..<end]
        guard !name.contains("/") else { return nil }
        let wordEnd = draft[end...].firstIndex(where: \.isWhitespace) ?? draft.endIndex
        return SlashTyping(name: String(name), leading: start == draft.startIndex, range: start..<wordEnd)
    }

    /// 入力欄のカーソルを `draft` の位置に直す。入力欄の選択は入力欄の文の UTF-16 の位置で来て、下書きを書き換えた直後は前の文の位置が残る。
    /// 下書きより先を指す UTF-16 の位置は `String.Index(_:within:)` が落とす（日本語の文では `<= endIndex` を抜ける。`utf16Offset(in:)` も落ちる）ので、
    /// 符号ごとの数（非推奨の `encodedOffset`）を UTF-16 の数までに限る。UTF-8 の位置も同じ数で切るので、日本語の後ろを指すと nil
    public static func cursor(_ index: String.Index, in draft: String) -> String.Index? {
        guard index.encodedOffset <= draft.utf16.count else { return nil }
        return String.Index(index, within: draft)
    }

    /// 語を `/name` に置き換えた文と、その後ろのカーソル。後ろに空白が無ければ 1 つ足す（続けて引数や文を書ける）
    public func completing(_ name: String, in draft: String) -> (text: String, cursor: String.Index) {
        let rest = draft[range.upperBound...]
        let head = draft[..<range.lowerBound] + "/" + name + (rest.first?.isWhitespace == true ? String(rest.prefix(1)) : " ")
        let text = head + rest.dropFirst(rest.first?.isWhitespace == true ? 1 : 0)
        return (text, text.index(text.startIndex, offsetBy: head.count))
    }
}
