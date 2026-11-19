import Foundation
import TaskboardKit

/// 文書・質問・レビューのコメント
extension AppModel {
    /// 開いている文書がこのタスクのものなら、その文書（タスクのパネルの帯の下と、iPhone のタスクの画面のシートに出す）
    func openDoc(in task: TaskKey) -> DocKey? {
        guard let key = openDoc, let doc = fleet.document(for: key), doc.taskNumber == task.number, doc.machine == task.machine else { return nil }
        return key
    }

    func documentContent(_ key: DocKey, rev: Int?) async throws -> DocContent {
        try await requireSource(key.machine).documentContent(id: key.id, rev: rev)
    }

    func documentRevisions(_ key: DocKey) async throws -> [DocRevision] {
        try await requireSource(key.machine).documentRevisions(id: key.id)
    }

    func comments(_ key: DocKey) async throws -> [DocComment] {
        try await requireSource(key.machine).comments(doc: key.id)
    }

    func asks(task key: TaskKey) async throws -> [Ask] {
        try await requireSource(key.machine).asks(task: key.number)
    }

    func answer(_ ask: Ask, _ answers: [AskAnswer]) async throws {
        _ = try await requireSource(ask.machine).answerAsk(id: ask.askID, AskAnswerRequest(answers: answers))
    }

    /// 答えずに質問を閉じる（チャットで話して済んだとき）。エージェントには何も届けない
    func cancelAsk(_ ask: Ask) async throws {
        try await requireSource(ask.machine).cancelAsk(id: ask.askID)
    }

    func addComment(_ key: DocKey, rev: Int, anchor: CommentAnchor?, body: String) async throws -> DocComment {
        try await requireSource(key.machine).createComment(doc: key.id, CommentCreateRequest(rev: rev, anchor: anchor, body: body))
    }

    func updateComment(_ comment: DocComment, on machine: MachineID, body: String) async throws {
        _ = try await requireSource(machine).updateComment(id: comment.id, CommentUpdateRequest(body: body))
    }

    func deleteComment(_ comment: DocComment, on machine: MachineID) async throws {
        try await requireSource(machine).deleteComment(id: comment.id)
    }

    func reviewDraft(task key: TaskKey) async throws -> ReviewDraft {
        try await requireSource(key.machine).reviewDraft(task: key.number)
    }

    /// 総括の下書きを保存する（開き直しても残す）
    func saveReviewSummary(task key: TaskKey, summary: String) async throws {
        _ = try await requireSource(key.machine).setReviewSummary(task: key.number, ReviewSummaryRequest(summary: summary))
    }

    func resolveComment(_ comment: DocComment, on machine: MachineID, _ resolved: Bool) async throws -> DocComment {
        try await requireSource(machine).resolveComment(id: comment.id, resolved: resolved)
    }

    /// 人の返信。レビューの送信まで draft のまま（セッションには送信でまとめて届く）
    func replyComment(_ comment: DocComment, on machine: MachineID, body: String) async throws -> CommentReply {
        try await requireSource(machine).replyComment(id: comment.id, CommentReplyRequest(author: .human, body: body, resolve: false))
    }

    /// 総括を保存して送る。送った時点で draft のコメントと返信がセッションへ届く
    func submitReview(task key: TaskKey, summary: String) async throws {
        let source = try requireSource(key.machine)
        _ = try await source.setReviewSummary(task: key.number, ReviewSummaryRequest(summary: summary))
        _ = try await source.submitReview(task: key.number)
    }

    func deleteDocument(_ key: DocKey) async throws {
        try await requireSource(key.machine).deleteDocument(id: key.id)
        if openDoc == key { openDoc = nil }
    }
}
