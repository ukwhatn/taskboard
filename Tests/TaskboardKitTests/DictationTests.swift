import Foundation
import Testing

@testable import TaskboardKit

@Suite("音声入力の差し込み")
struct DictationDraftTests {
    @Test("カーソルの位置に聞き取った文を差し込み、カーソルを文の後ろに置く")
    func insertsAtCursor() {
        let draft = "前の文。後ろの文"
        let cursor = draft.index(draft.startIndex, offsetBy: 4)
        let insertion = DictationDraft(draft: draft, selection: cursor..<cursor)
        let result = insertion.inserting("真ん中")
        #expect(result.text == "前の文。真ん中後ろの文")
        #expect(result.text[result.cursor...] == "後ろの文")
    }

    @Test("範囲を選んでいれば、選んだ文を聞き取った文に置き換える")
    func replacesSelection() {
        let draft = "abc DEF ghi"
        let lower = draft.index(draft.startIndex, offsetBy: 4), upper = draft.index(lower, offsetBy: 3)
        let result = DictationDraft(draft: draft, selection: lower..<upper).inserting("デフ")
        #expect(result.text == "abc デフ ghi")
        #expect(result.text[result.cursor...] == " ghi")
    }

    @Test("カーソルが分からなければ末尾に足す")
    func appendsWithoutCursor() {
        let result = DictationDraft(draft: "書きかけ", selection: nil).inserting("の続き")
        #expect(result.text == "書きかけの続き")
        #expect(result.cursor == result.text.endIndex)
    }

    @Test("何も聞き取れなければ、聞き始める前の文とカーソルに戻る")
    func emptyRestores() {
        let draft = "そのまま"
        let cursor = draft.index(after: draft.startIndex)
        let result = DictationDraft(draft: draft, selection: cursor..<cursor).inserting("")
        #expect(result.text == "そのまま")
        #expect(result.text[result.cursor...] == "のまま")
    }

    @Test("空の欄に入れる")
    func emptyDraft() {
        let result = DictationDraft(draft: "", selection: nil).inserting("こんにちは")
        #expect(result.text == "こんにちは")
        #expect(result.cursor == result.text.endIndex)
    }

    @Test("途中の文を何度入れ替えても、聞き始める前の文の前後は変わらない")
    func volatileReplacements() {
        let insertion = DictationDraft(draft: "A|B", selection: nil)
        _ = insertion.inserting("途中")
        #expect(insertion.inserting("確定した文").text == "A|B確定した文")
    }
}

@Suite("音声入力の語彙")
struct DictationVocabularyTests {
    private func message(_ text: String, role: ChatMessage.Role = .assistant, kind: ChatMessage.Kind = .text) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: role, kind: kind, text: text)
    }

    @Test("タスクの題と番号を先に、発言に出た番号のような語を新しい発言から並べる")
    func collects() {
        let messages = [
            message("PROJ-12 と #40 を見ました"),
            message("r#3 と #41 を直します", role: .user),
        ]
        let phrases = DictationVocabulary.phrases(taskTitle: "音声入力の追加", taskNumber: 172, messages: messages)
        #expect(phrases == ["音声入力の追加", "#172", "r#3", "#41", "PROJ-12", "#40"])
    }

    @Test("同じ語は 1 回だけにする")
    func deduplicates() {
        let phrases = DictationVocabulary.phrases(taskTitle: nil, taskNumber: 5, messages: [message("#5 と #5、#6"), message("#6")])
        #expect(phrases == ["#5", "#6"])
    }

    @Test("ツールの入出力と思考は読まない")
    func skipsToolsAndThinking() {
        let messages = [
            message("#900", kind: .toolResult),
            message("#901", kind: .toolUse),
            ChatMessage(id: "t", role: .assistant, kind: .text, text: "#902", thinking: true),
        ]
        #expect(DictationVocabulary.phrases(taskTitle: nil, taskNumber: nil, messages: messages).isEmpty)
    }

    @Test("語は上限の数までにする")
    func capsAtLimit() {
        let text = (1...300).map { "#\($0)" }.joined(separator: " ")
        let phrases = DictationVocabulary.phrases(taskTitle: "題", taskNumber: nil, messages: [message(text)])
        #expect(phrases.count == DictationVocabulary.limit)
        #expect(phrases.first == "題")
    }

    @Test("題が空白だけなら入れない。番号の無い発言からは何も取らない")
    func emptyInputs() {
        #expect(DictationVocabulary.phrases(taskTitle: "  ", taskNumber: nil, messages: [message("番号はありません")]).isEmpty)
    }
}
