import SwiftUI
import TaskboardKit

/// 巻き戻しの確認。dry run で変わるファイルと行の数を出し、ファイルも戻すかを選ぶ。
/// ファイルを戻せない（E2 までに送った指示・dry run の失敗）ときは、会話だけを巻き戻す
struct ConversationRewindSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let conversation: Conversation
    let feed: ConversationFeed

    @State private var preview: ConversationLoad<ConversationRewindResponse> = .idle
    @State private var restoreFiles = true
    @State private var sending = false
    @State private var failure: UserFacingError?

    /// `preview` は確かめた結果を渡して描く（snapshot 用）
    init(message: ChatMessage, conversation: Conversation, feed: ConversationFeed, preview: ConversationLoad<ConversationRewindResponse> = .idle) {
        self.message = message
        self.conversation = conversation
        self.feed = feed
        _preview = State(initialValue: preview)
    }

    var body: some View {
        SheetScaffold(title: String(localized: "会話の巻き戻し"), error: failure?.text, onCancel: { dismiss() }) {
            Section("巻き戻すメッセージ") {
                Text(message.text).lineLimit(4).textSelection(.enabled)
                Text("このメッセージより後の会話を消し、メッセージの本文を入力欄に戻します。").textRole(.secondary)
                if feed.messages.contains(where: \.isCompactBoundary) {
                    Text("戻せるのは、最後に会話を圧縮した後のメッセージだけです。").textRole(.secondary)
                }
            }
            Section("ファイル") { files }
        } actions: {
            Button("巻き戻す") { rewind() }
                .buttonStyle(.borderedProminent)
                .disabled(sending || !preview.isSettled)
        }
        .task {
            guard case .idle = preview else { return }
            preview = .loading
            do {
                preview = .loaded(try await feed.previewRewind(message.id, agentSessionID: conversation.agentSessionID))
            } catch {
                // 確かめられなくても、会話だけは巻き戻せる
                preview = .failed(UserFacingError("ファイルの変更を確認できませんでした", error: error) ?? UserFacingError("ファイルの変更を確認できませんでした"))
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        switch preview {
        case .idle, .loading:
            ProgressView("読み込み中…").controlSize(.small)
        case .loaded(let response) where response.canRewind == true:
            let changed = response.filesChanged ?? []
            if changed.isEmpty {
                Text("戻すファイルはありません。").textRole(.secondary)
            } else {
                Toggle(isOn: $restoreFiles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ファイルも戻す")
                        HStack(spacing: Space.inline) {
                            Text("\(changed.count)個のファイルが変わります")
                            DiffCounts(insertions: response.insertions, deletions: response.deletions)
                        }
                        .textRole(.secondary)
                    }
                }
                ForEach(changed.prefix(ConversationMetrics.rewindFileLimit), id: \.self) { path in
                    Text(verbatim: path).textRole(.mono).lineLimit(1).truncationMode(.middle)
                }
                if changed.count > ConversationMetrics.rewindFileLimit {
                    Text("ほか\(changed.count - ConversationMetrics.rewindFileLimit)件").textRole(.secondary)
                }
            }
        case .loaded:
            Text("このメッセージの時点のファイルの記録がないため、ファイルは戻せません。会話だけを巻き戻します。").textRole(.secondary)
        case .failed(let failure):
            Text("\(failure.text)会話だけを巻き戻します。").textRole(.secondary)
        }
    }

    /// ファイルを戻せるときだけ、選んだとおりにファイルも戻す
    private var filesSelected: Bool {
        guard let response = preview.value, response.canRewind == true, !(response.filesChanged ?? []).isEmpty else { return false }
        return restoreFiles
    }

    private func rewind() {
        sending = true
        failure = nil
        Task {
            do {
                try await feed.rewind(message.id, agentSessionID: conversation.agentSessionID, files: filesSelected)
                dismiss()
            } catch {
                failure = UserFacingError("巻き戻せませんでした", error: error)
            }
            sending = false
        }
    }
}

extension ConversationLoad {
    /// 読み終えた（読めたか、失敗した）
    var isSettled: Bool {
        switch self {
        case .loaded, .failed: true
        case .idle, .loading: false
        }
    }
}
