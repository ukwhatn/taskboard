import Foundation
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// チャットと会話の入力欄の共通の部品: `/` の候補のキーと、下書きの画像の持ち主
@MainActor
@Suite struct ChatComposerTests {
    @Test("候補が出ている間の ↑↓ は端で回り、↩ と Tab は今の候補を選び、Esc は閉じる。修飾キー付きの ↩ と、候補が無いときは入力欄に任せる")
    func slashKeys() {
        #expect(SlashCommandKeys.action(for: .upArrow, modifiers: [], count: 3, selection: 0) == .moved(to: 2))
        #expect(SlashCommandKeys.action(for: .downArrow, modifiers: [], count: 3, selection: 2) == .moved(to: 0))
        #expect(SlashCommandKeys.action(for: .return, modifiers: [], count: 3, selection: 1) == .pick(1))
        #expect(SlashCommandKeys.action(for: .tab, modifiers: [], count: 2, selection: 5) == .pick(1), "候補が減って選択が外れていたら最後の候補")
        #expect(SlashCommandKeys.action(for: .escape, modifiers: [], count: 1, selection: 0) == .dismiss)
        #expect(SlashCommandKeys.action(for: .return, modifiers: .shift, count: 3, selection: 0) == nil)
        #expect(SlashCommandKeys.action(for: .return, modifiers: .command, count: 3, selection: 0) == nil)
        #expect(SlashCommandKeys.action(for: .return, modifiers: [], count: 0, selection: 0) == nil)
        #expect(SlashCommandKeys.action(for: "a", modifiers: [], count: 3, selection: 0) == nil)
    }

    @Test("画像の下書きは会話ごとに持ち、画面を離れても model に残る")
    func draftsByOwner() {
        AppDefaults.useScratch("test-chat-composer")
        let model = AppModel(options: LaunchOptions(scenario: "settings"))
        let machine = MachineID(rawValue: "m")
        let other = ConversationKey(machine: machine, id: "c2")
        let conversation = ConversationKey(machine: machine, id: "c1")
        let image = ChatDraftImage(data: Data([1]), type: .png)
        model.setChatImages([image], for: conversation)
        #expect(model.chatImages(for: conversation) == [image])
        #expect(model.chatImages(for: other).isEmpty)
        model.setChatImages([], for: conversation)
        #expect(model.chatImageDrafts.isEmpty, "空にしたら持ち主ごと消す")
    }
}
