import SwiftUI
import TaskboardKit

/// 入力欄の書きかけ（文とカーソル）と、`/` の候補の選択・Esc で閉じた下書き。セッションと会話の入力欄が `@State` に持ち、
/// 書きかけは `ChatDraftTexts` へ書き戻す（`composerDraftSync`）
struct ComposerInput {
    var draft: String
    /// 入力欄のカーソル（文の途中の `/` の候補に使う）
    var selection: TextSelection?
    var commandSelection = 0
    /// Esc で閉じたときの下書き。打ち直すとまた出す
    var dismissedCommandDraft: String?

    init(draft: String, selection: TextSelection?) {
        self.draft = draft
        self.selection = selection
    }

    @MainActor
    init(_ key: ConversationKey, in drafts: ChatDraftTexts) {
        self.init(draft: drafts.text(for: key), selection: drafts.selection(for: key))
    }

    /// 候補を Esc で閉じた後、まだ打ち直していない
    var isDismissed: Bool { draft == dismissedCommandDraft }

    /// 打ちかけの `/` の語。Esc で閉じていれば nil
    var slashTyping: SlashTyping? {
        isDismissed ? nil : SlashTyping.find(in: draft, selection: selection)
    }

    mutating func dismissSuggestions() { dismissedCommandDraft = draft }

    /// 打ちかけの語を選んだ名前と空白に替える。空白が入ると候補は閉じ、続けて引数や文を書ける
    mutating func complete(_ name: String) {
        guard let typing = SlashTyping.find(in: draft, selection: selection) else { return }
        replace(typing.completing(name, in: draft))
    }

    /// 文を置き換え、カーソルを `cursor` に置く
    mutating func replace(_ completed: (text: String, cursor: String.Index)) {
        draft = completed.text
        selection = TextSelection(insertionPoint: completed.cursor)
    }
}

extension View {
    /// 書きかけが変わるたびに `ChatDraftTexts` へ書き戻す。文が変わったら候補の選択を頭に戻し、`edited` を呼ぶ
    func composerDraftSync(
        _ input: Binding<ComposerInput>, to key: ConversationKey, in drafts: ChatDraftTexts, edited: @escaping (String) -> Void = { _ in }
    ) -> some View {
        onChange(of: input.wrappedValue.draft) { _, draft in
            input.wrappedValue.commandSelection = 0
            edited(draft)
            drafts.set(draft, selection: input.wrappedValue.selection, for: key)
        }
        .onChange(of: input.wrappedValue.selection) { _, selection in drafts.set(input.wrappedValue.draft, selection: selection, for: key) }
    }
}

extension UserFacingError {
    /// 質問に答える前の送信
    static let awaitingAnswer = UserFacingError(
        "送信できませんでした", cause: String(localized: "会話が質問への回答を待っています"), remedy: String(localized: "上の質問に答えてください"))
}
