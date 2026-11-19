import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// コメントの欄の下に固定する、レビューの送信。総括は書くと下書きに保存し、下書きのコメントと返信と一緒にセッションへ送る
struct ReviewComposer: View {
    @Environment(AppModel.self) private var model
    let task: TaskKey
    let draftCount: Int
    let sent: () async -> Void

    @State private var summary = ""
    @State private var loaded = false
    @State private var sending = false
    @State private var failure: UserFacingError?

    var body: some View {
        let hasSummary = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let connected = model.canWrite(task.machine)
        VStack(alignment: .leading, spacing: Space.row) {
            Text("レビューの総括").textRole(.caption)
            MultilineTextField(label: String(localized: "レビューの総括"), text: $summary, lines: 2...5, font: .callout, style: .roundedBorder)
            if let failure {
                FailureText(failure)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(
                    draftCount > 0
                        ? String(localized: "下書き\(draftCount)件と一緒に送信します。")
                        : hasSummary ? String(localized: "総括だけを送信します。") : String(localized: "総括を書くか、コメントを下書きに追加すると送信できます。")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.row)
                Button(sending ? "送信しています…" : "レビューを送信") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || (draftCount == 0 && !hasSummary) || !connected)
            }
        }
        .task(id: task) {
            guard !loaded, connected, let draft = try? await model.reviewDraft(task: task) else { return }
            summary = draft.review?.summary ?? ""
            loaded = true
        }
        // 書いた総括は少し待ってから下書きに保存する（開き直しても残る）
        .task(id: summary) {
            guard loaded, connected else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            try? await model.saveReviewSummary(task: task, summary: summary)
        }
    }

    private func send() {
        sending = true
        failure = nil
        Task {
            do {
                try await model.submitReview(task: task, summary: summary)
                summary = ""
                await sent()
            } catch {
                failure = UserFacingError("レビューを送信できませんでした", error: error)
            }
            sending = false
        }
    }
}
