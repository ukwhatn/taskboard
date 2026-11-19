import Foundation
#if os(macOS)
import AppKit
#endif
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

    #if os(macOS)
    /// 文書の元のファイルを Finder かエディタで開く（文書がこの Mac のもので、元のファイルがあるときだけ呼ぶ）
    func openSourceFile(_ key: DocKey, in app: DocumentSourceApp, window: WindowID) async {
        let event: LocalizedStringResource = app == .finder ? "Finderで表示できませんでした" : "エディタで開けませんでした"
        do {
            guard let path = try await requireSource(key.machine).documentSourceFile(id: key.id).path, FileManager.default.fileExists(atPath: path) else {
                fail(UserFacingError(event, cause: String(localized: "元のファイルが見つかりません")), in: window)
                return
            }
            switch app {
            case .finder:
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            case .editor:
                let template = AppDefaults.store.string(forKey: AppPreferences.docEditorURLKey) ?? ""
                guard let url = DocumentEditorURL.url(template: template, path: path), NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                    fail(UserFacingError(event, cause: String(localized: "エディタのURLを開けるアプリが見つかりません"), remedy: String(localized: "［設定］>［表示］のエディタのURLを確認してください")), in: window)
                    return
                }
                NSWorkspace.shared.open(url)
            }
        } catch {
            fail(event, error, in: window)
        }
    }
    #endif

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

    /// 文書を開いて、本文の中の質問か送る文面の欄（`ask:q1`・`draft:id`）まで送る
    func openDocument(_ key: DocKey, at slot: String?, from source: NavigationSource) {
        navigate(to: .doc(key), from: source)
        docFormFocus = slot.map { DocFormFocus(doc: key, slot: $0) }
    }

    /// 文書の送る文面の［承認］。本文は人が編集した後のもの。承認と本文は publish した会話に届く
    func approveDocDraft(_ key: DocKey, draft: String, body: String) async throws {
        _ = try await requireSource(key.machine).approveDocDraft(doc: key.id, draft: draft, body: body)
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

    /// 開いている質問の束の、最初の質問の欄（受信箱と「判断待ち」から開く先）
    static func formSlot(for ask: Ask) -> String? {
        ask.questions.first.map { formSlot(for: ask, question: $0.id) }
    }

    /// 質問の欄の名前。本文の印に入る束は印と同じ `ask:q1`、`ask_user` で後から付けた束は束の id を添える
    /// （束ごとに q1 から振るので、添えないと本文の回答済みの欄と末尾の未回答の欄が同じ名前になる）。`DocumentForms.script` の `cardName` と同じ規則
    static func formSlot(for ask: Ask, question id: String) -> String {
        DocMarker(kind: .ask, id: ask.inBody ? id : "\(ask.askID).\(id)").slot
    }

    func deleteDocument(_ key: DocKey) async throws {
        try await requireSource(key.machine).deleteDocument(id: key.id)
        if openDoc == key { openDoc = nil }
    }
}

/// 文書の中で送る先の欄。送る文書と欄の名前（`DocMarker.slot`）。押すたびに別の値にする（同じ欄をもう一度押しても送る）
struct DocFormFocus: Equatable {
    var doc: DocKey
    var slot: String
    var id = UUID()
}
