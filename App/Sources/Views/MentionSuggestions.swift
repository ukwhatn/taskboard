import SwiftUI
import TaskboardKit

extension MentionTyping {
    /// 入力欄のカーソルの手前で探す。カーソルが分からなければ文の終わりで探し、範囲を選んでいるときは出さない
    static func find(in draft: String, selection: TextSelection?) -> MentionTyping? {
        guard let selection else { return find(in: draft) }
        guard case .selection(let range) = selection.indices, range.isEmpty, let cursor = SlashTyping.cursor(range.lowerBound, in: draft) else { return nil }
        return find(in: draft, cursor: cursor)
    }
}

extension SlashSuggestion {
    /// `@` の候補の 1 行。ファイルの名前を主に、親のフォルダを説明に出す（`/` の候補と同じ部品で出す）
    init(_ file: WorkFile) {
        self.init(
            name: file.name, description: file.parent, badge: file.isDirectory ? String(localized: "フォルダ") : nil, prefix: "", id: file.path)
    }
}
