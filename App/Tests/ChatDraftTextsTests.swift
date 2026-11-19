import Foundation
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 入力欄の書きかけの文（`ChatDraftTexts`）。開き方を替えたり別のセッションへ移ったりして入力欄が作り直されても残り、送ったら消える
@MainActor
@Suite struct ChatDraftTextsTests {
    private let conversation = ConversationKey(machine: MachineID(rawValue: "m1"), id: "c-1")
    private let other = ConversationKey(machine: MachineID(rawValue: "m1"), id: "c-2")

    private func store() -> UserDefaults {
        let name = "tb-draft-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("打つのが止まってしばらくすると、言われなくても外に書く")
    func savesAfterPause() async throws {
        let defaults = store()
        let drafts = ChatDraftTexts(store: defaults)
        drafts.set("止まったら残す", selection: nil, for: conversation)
        try await Task.sleep(for: ChatDraftTexts.saveDelay + .milliseconds(500))
        #expect(ChatDraftTexts(store: defaults).text(for: conversation) == "止まったら残す")
    }

    @Test("書いた文とカーソルを鍵ごとに返し、空にすると消す")
    func keepsPerKey() {
        let drafts = ChatDraftTexts(store: store())
        let text = "途中まで書いた指示"
        drafts.set(text, selection: TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: 3)), for: conversation)
        drafts.set("別の会話の文", selection: nil, for: other)
        #expect(drafts.text(for: conversation) == text)
        #expect(drafts.selection(for: conversation) == TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: 3)))
        #expect(drafts.text(for: other) == "別の会話の文")
        drafts.set("", selection: nil, for: conversation)
        #expect(drafts.text(for: conversation) == "")
        #expect(drafts.selection(for: conversation) == nil)
    }

    @Test("アプリを起こし直したら書きかけの文を戻す。カーソルは戻さない")
    func persistsAcrossLaunch() {
        let defaults = store()
        let first = ChatDraftTexts(store: defaults)
        first.set("会話の書きかけ", selection: nil, for: conversation)
        // 打つのが止まるか、アプリが終わる・裏に回るまでは外に書かない（同じ保存先を読む @AppStorage の画面を描き直さないため）
        #expect(ChatDraftTexts(store: defaults).text(for: conversation) == "")
        first.flush()
        let relaunched = ChatDraftTexts(store: defaults)
        #expect(relaunched.text(for: conversation) == "会話の書きかけ")
        first.set("", selection: nil, for: conversation)
        first.flush()
        #expect(ChatDraftTexts(store: defaults).text(for: conversation) == "")
    }
}
