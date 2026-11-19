import Foundation
import Testing

@testable import TaskboardKit

@Suite("入力欄の ↑↓ の履歴")
struct ComposerHistoryTests {
    private let entries = ["最初", "次", "最後"]

    @Test("↑ で新しい発言から古い方へ辿り、いちばん古い所で止まる")
    func walksBack() {
        var history = ComposerHistory()
        #expect(history.previous(in: entries, current: "") == "最後")
        #expect(history.previous(in: entries, current: "最後") == "次")
        #expect(history.previous(in: entries, current: "次") == "最初")
        #expect(history.previous(in: entries, current: "最初") == nil, "これより古い発言は無い")
        #expect(history.recalled == "最初")
    }

    @Test("↓ で新しい方へ戻り、いちばん新しい発言の次は辿り始める前の文に戻って終える")
    func walksForwardAndRestores() {
        var history = ComposerHistory()
        _ = history.previous(in: entries, current: "書きかけ")
        _ = history.previous(in: entries, current: "最後")
        #expect(history.next(in: entries) == "最後")
        #expect(history.next(in: entries) == "書きかけ")
        #expect(!history.isRecalling && history.recalled == nil)
        #expect(history.next(in: entries) == nil, "呼び戻していなければ何もしない")
    }

    @Test("履歴が空なら何も呼び戻さない")
    func empty() {
        var history = ComposerHistory()
        #expect(history.previous(in: [], current: "x") == nil)
        #expect(!history.isRecalling)
    }

    @Test("呼び戻した文を打ち直したら終える。同じ文のままなら続ける")
    func editEnds() {
        var history = ComposerHistory()
        _ = history.previous(in: entries, current: "")
        history.edited(to: "最後")
        #expect(history.isRecalling)
        history.edited(to: "最後 に足した")
        #expect(!history.isRecalling)
        #expect(history.previous(in: entries, current: "最後 に足した") == "最後", "終えた後の ↑ は新しい方から辿り直す")
    }

    @Test("辿っている間に履歴が縮んだら、辿り始める前の文に戻す")
    func shrinkingHistory() {
        var history = ComposerHistory()
        _ = history.previous(in: entries, current: "元")
        _ = history.previous(in: entries, current: "最後")
        #expect(history.next(in: ["最初"]) == "元")
        #expect(!history.isRecalling)
    }

    @Test("人の発言だけを古い順に取る。差し込まれた文・サブエージェント・空・続けて同じ文は除き、ファイルの見出しは外す")
    func entriesFromMessages() {
        func message(_ id: String, _ role: ChatMessage.Role, _ text: String, kind: ChatMessage.Kind = .text) -> ChatMessage {
            ChatMessage(id: id, role: role, kind: kind, text: text)
        }
        var injected = message("i", .user, "Skill の本文")
        injected.injected = true
        var sub = message("s", .user, "サブエージェントへの指示")
        sub.parentToolID = "t-1"
        let withFiles = message("f", .user, "<uploaded_files>\n<file><file_path>/tmp/a.txt</file_path></file>\n</uploaded_files>\n\nこれを読んで")
        let messages = [
            message("1", .user, "最初"), message("2", .assistant, "答え"), injected, sub, message("3", .user, "  "),
            message("4", .user, "結果", kind: .toolResult), message("5", .user, "次"), message("6", .user, "次"), withFiles,
        ]
        #expect(ComposerHistory.entries(from: messages) == ["最初", "次", "これを読んで"])
    }
}
