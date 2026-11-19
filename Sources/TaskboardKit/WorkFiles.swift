import Foundation

/// 会話の作業ディレクトリのファイルかフォルダ。`path` は作業ディレクトリからの相対で、フォルダは末尾に `/` が付く
public struct WorkFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var isDirectory: Bool

    public var id: String { path }

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    /// 一覧に出す名前（フォルダの末尾の `/` を除いた最後の部分）
    public var name: String {
        String((isDirectory ? path.dropLast() : path[...]).split(separator: "/").last ?? "")
    }

    /// 名前の手前の部分（`src/views/` など）。作業ディレクトリ直下なら空
    public var parent: String {
        String(path.dropLast(name.count + (isDirectory ? 1 : 0)))
    }
}

/// `GET /v1/conversations/{id}/workfiles?q=&limit=`。打った文字に合う順
public struct ConversationWorkFilesResponse: Codable, Hashable, Sendable {
    public var files: [WorkFile]
    /// 一覧が件数・時間の上限で途中までだった（候補に出ないファイルがある）
    public var truncated: Bool

    public init(files: [WorkFile], truncated: Bool = false) {
        self.files = files
        self.truncated = truncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([WorkFile].self, forKey: .files)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    public static let maxLimit = 20
    public static let defaultLimit = 8
}

/// 入力欄でいま打っている `@` の語。`@` は文の頭か空白・改行の後にあり、カーソルまでに空白が無い（Claude Code の `@` の書き方）
public struct MentionTyping: Hashable, Sendable {
    /// `@` の後からカーソルまでの打ちかけ（`@` だけなら空）
    public var query: String
    /// 選んだパスで置き換える範囲（`@` から、カーソルの後ろの語の終わりまで）
    public var range: Range<String.Index>

    /// これより長い打ちかけは、パスの指定とは見ない（長い文の中を後ろへ探し続けない）
    public static let maxQueryLength = 100

    /// `cursor` が nil なら文の終わりにあるものとして探す
    public static func find(in draft: String, cursor: String.Index? = nil) -> MentionTyping? {
        let end = cursor ?? draft.endIndex
        var start = end
        var length = 0
        // `@` の 1 字の分だけ、打ちかけの上限より 1 つ多く戻る
        while start > draft.startIndex, length <= maxQueryLength + 1 {
            let previous = draft.index(before: start)
            if draft[previous].isWhitespace { break }
            start = previous
            length += 1
        }
        guard start < end, length <= maxQueryLength + 1, draft[start] == "@" else { return nil }
        let wordEnd = draft[end...].firstIndex(where: \.isWhitespace) ?? draft.endIndex
        return MentionTyping(query: String(draft[draft.index(after: start)..<end]), range: start..<wordEnd)
    }

    /// 語を `@パス` に置き換えた文と、その後ろのカーソル。空白を含むパスは `@"…"` にする（Claude Code の書き方）。
    /// 後ろに空白が無ければ 1 つ足し、あればその後ろにカーソルを置く（続けて文を書ける）。フォルダなら末尾の `/` までで、続けて奥を選べるよう空白は足さない
    public func completing(_ file: WorkFile, in draft: String) -> (text: String, cursor: String.Index) {
        let quoted = file.path.contains(where: \.isWhitespace) && !file.path.contains("\"")
        let mention = quoted ? "@\"\(file.path)\"" : "@\(file.path)"
        let rest = draft[range.upperBound...]
        let restStartsWithSpace = rest.first?.isWhitespace == true
        let gap = file.isDirectory ? "" : restStartsWithSpace ? String(rest.prefix(1)) : " "
        let head = draft[..<range.lowerBound] + mention + gap
        let text = head + rest.dropFirst(!file.isDirectory && restStartsWithSpace ? 1 : 0)
        return (text, text.index(text.startIndex, offsetBy: head.count))
    }
}
