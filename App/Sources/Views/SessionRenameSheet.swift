import SwiftUI
import TaskboardKit

/// 名前を付け直している会話（`.sheet(item:)` に渡す。`ConversationKey.id` は会話 ID で、マシンをまたいで重なりうる）
struct RenameTarget: Identifiable, Hashable {
    let conversation: ConversationKey
    var id: ConversationKey { conversation }
}

/// 会話の名前の付け直し。daemon の会話の記録の名前（自動の題とは別の欄）に持たせ、付けていればどの画面でも題として出す（`Conversation.title`）
struct SessionRenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: ConversationKey
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        SheetScaffold(
            title: String(localized: "セッションの名前の変更"), subtitle: current.title, error: error, width: 440,
            onCancel: { dismiss() }
        ) {
            Section {
                StackedField(String(localized: "名前")) {
                    TextField("名前", text: $name, prompt: Text(verbatim: ""))
                        .focused($focused)
                        .onSubmit(save)
                }
            } footer: {
                Text("空にすると、自動で付いたタイトルに戻ります。")
            }
        } actions: {
            // 名前を入れて確定するだけのシートなので ↩ で確定する（docs/ui-system.md「使わない書き方」）
            Button("変更", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
        }
        .onAppear {
            name = current.name ?? ""
            focused = true
        }
    }

    /// 題（シートの副題）と、今付けている名前
    private var current: (title: String?, name: String?) {
        let conversation = model.fleet.conversation(for: target)
        return (conversation?.displayTitle, conversation?.customTitle)
    }

    private func save() {
        guard let accepted = acceptedName else {
            error = UserFacingError(
                "名前を変更できませんでした", cause: String(localized: "名前が長すぎるか、改行を含んでいます"),
                remedy: String(localized: "改行なしの\(nameLimit)文字以内にしてください")
            ).text
            return
        }
        saving = true
        error = nil
        Task {
            do {
                try await model.renameConversation(target, to: accepted)
                dismiss()
            } catch {
                self.error = UserFacingError("名前を変更できませんでした", error: error)?.text
                saving = false
            }
        }
    }

    /// 送る名前（空なら外す）。使えない名前なら nil
    private var acceptedName: String? {
        guard let title = ConversationInput.title(name) else { return "" }
        return ConversationInput.acceptsTitle(title) ? title : nil
    }

    private var nameLimit: Int { ConversationInput.titleLimit }
}

/// 会話の右クリックと会話の画面の［ほかの操作］の名前の項目
struct ConversationNameMenuItems: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        if model.canWrite(conversation.machine), conversation.purpose != .orchestrator {
            Button("名前を変更…", systemImage: "pencil") { model.renaming = RenameTarget(conversation: conversation.key) }
            if conversation.customTitle != nil {
                Button("付けた名前を外す", systemImage: "xmark.circle") { model.clearConversationName(conversation.key) }
            }
        }
    }
}
