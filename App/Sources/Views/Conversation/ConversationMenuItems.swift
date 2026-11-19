import SwiftUI
import TaskboardKit

/// 会話の右クリック・長押しのメニュー
struct ConversationMenuItems: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        Button("開く", systemImage: "text.bubble") { model.navigate(to: .conversation(conversation.key), from: .link) }
        ConversationNameMenuItems(conversation: conversation)
        if conversation.engine == .claude {
            ClaudeAccountMenu(accounts: model.claudeAccounts(on: conversation.machine), current: conversation.account) { account in
                model.switchAccount(SessionAccountRequest(conversationID: conversation.id, account: account), on: conversation.machine)
            }
            .disabled(!model.canWrite(conversation.machine))
        }
        ConversationEndItems(conversation: conversation)
    }
}

/// ［終了］。会話のメニューと会話の画面の上の帯で同じものを出す。書き込めなければ押せない
struct ConversationEndItems: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        Button("終了", systemImage: "xmark.circle") { model.close(conversation: conversation.key) }
            .disabled(!model.canWrite(conversation.machine))
    }
}
