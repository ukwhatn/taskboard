// ui-copy:ignore-file
// このファイルの文は、daemon が pane に人の発話として入れ、Claude Code が読む（docs/ui-copy.md の対象外）。
// 端末にも人の入力として映るので、言語は人がセッションで使う日本語に合わせている。画面の部品の文ではない。
// 人の答えを運ぶ文なので、通知の頭の文（`TaskboardNotice.mark`）と送り主の項目は付けない。1 行目の印（HTML のコメント）は、会話の画面が
// 知らせを見分けるために付ける（Markdown では見えず、人の発言でないとは書いていない）
import Foundation

extension FeedbackText {
    /// daemon が pane に人の発話として入れる文（`FeedbackPaneDelivery`）。`included` は文に載せた分で、受領済みにしてよいのはそれだけ。
    /// 上限に収まらなければ forHook と同じくレビューから項目ごとに落とし、残りは未受領のまま次の配送か feedback_list に回す。
    /// 1 件も収まらなければ `included` は空で、文は feedback_list を頼む案内だけになる
    public struct Prompt: Hashable, Sendable {
        public var text: String
        public var included: FeedbackBundle
        public var clipped: Bool
    }

    static let promptClipNotice = Copy.text("agent.notice.feedbackPrompt.promptClipNotice")
    static let promptTooLong = TaskboardNotice.feedbackTooLong

    public static func forPrompt(_ bundle: FeedbackBundle, limitChars: Int = 4_000) -> Prompt {
        let full = promptText(bundle)
        if full.count <= limitChars { return Prompt(text: full, included: bundle, clipped: false) }
        var kept = bundle
        while kept.count > 1, let next = kept.droppingLast() {
            kept = next
            let text = promptText(kept) + "\n\n" + promptClipNotice
            if text.count <= limitChars { return Prompt(text: text, included: kept, clipped: true) }
        }
        return Prompt(text: promptTooLong, included: FeedbackBundle(), clipped: true)
    }

    static func promptText(_ bundle: FeedbackBundle) -> String {
        var blocks: [String] = []
        for ask in bundle.answeredAsks {
            var lines = [TaskboardNotice.answerPrefix + "\(ask.taskNumber)）。"]
            for question in ask.questions {
                let answer = ask.answers?.first { $0.questionID == question.id }
                let selected = answer?.selected ?? []
                lines.append("- 「\(question.question)」→ " + (selected.isEmpty ? Copy.text("agent.notice.feedbackPrompt.selected") : selected.joined(separator: "、")))
                if let free = answer?.freeText, !free.isEmpty { lines.append(Copy.text("agent.notice.feedbackPrompt.selected.2", ["free": "\(free)"])) }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        for (number, items) in Dictionary(grouping: bundle.finishedWork, by: \.taskNumber).sorted(by: { $0.key < $1.key }) {
            var lines = [TaskboardNotice.finishedPrefix + "\(number)）。"]
            for item in items.sorted(by: { ($0.finishedAt, $0.itemID) < ($1.finishedAt, $1.itemID) }) {
                lines.append(Copy.text("agent.notice.feedbackPrompt.lines", ["itemID": "\(item.itemID)", "title": "\(item.title)", "request": "\(item.request)"]))
            }
            lines.append(Copy.text("agent.notice.feedbackPrompt.lines.2"))
            blocks.append(lines.joined(separator: "\n"))
        }
        for (number, items) in Dictionary(grouping: bundle.drafts, by: \.taskNumber).sorted(by: { $0.key < $1.key }) {
            var lines = [TaskboardNotice.draftPrefix + "\(number)）。"]
            for item in items.sorted(by: { ($0.answeredAt, $0.answerID) < ($1.answeredAt, $1.answerID) }) {
                lines.append(
                    Copy.text(
                        item.edited ? "agent.notice.feedbackPrompt.draft.edited" : "agent.notice.feedbackPrompt.draft",
                        ["id": item.partID, "to": item.to, "body": item.body]))
            }
            lines.append(Copy.text("agent.notice.feedbackPrompt.draft.send"))
            blocks.append(lines.joined(separator: "\n"))
        }
        for entry in bundle.reviews {
            var lines = [TaskboardNotice.reviewPrefix + "\(entry.review.taskNumber)）。"]
            if !entry.review.summary.isEmpty { lines.append(Copy.text("agent.notice.feedbackPrompt.lines.3", ["summary": "\(entry.review.summary)"])) }
            for comment in entry.comments {
                let quote = comment.anchor.map { "「\($0.exact)」" } ?? ""
                lines.append(Copy.text("agent.notice.feedbackPrompt.quote", ["docName": "\(comment.docName)", "rev": "\(comment.rev)", "quote": "\(quote)", "id": "\(comment.id)", "body": "\(comment.body)"]))
            }
            for reply in entry.replies {
                lines.append(Copy.text("agent.notice.feedbackPrompt.quote.2", ["commentID": "\(reply.reply.commentID)", "commentBody": "\(reply.commentBody)", "body": "\(reply.reply.body)"]))
            }
            if !entry.comments.isEmpty || !entry.replies.isEmpty {
                lines.append(Copy.text("agent.notice.feedbackPrompt.quote.3"))
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return "" }
        return marker(bundle) + "\n" + blocks.joined(separator: "\n\n")
    }

    /// 回答があれば回答、無ければ済ませた手作業、それも無ければレビューの印。値は最初の項目のタスクと文書・作業項目
    static func marker(_ bundle: FeedbackBundle) -> String {
        if let ask = bundle.answeredAsks.first {
            return TaskboardNotice.marker(.answer, ["task": String(ask.taskNumber), "ask": String(ask.askID), "doc": String(ask.docID)])
        }
        if let item = bundle.finishedWork.first {
            return TaskboardNotice.marker(.finished, ["task": String(item.taskNumber), "work": String(item.itemID)])
        }
        if let item = bundle.drafts.first {
            return TaskboardNotice.marker(.draft, ["task": String(item.taskNumber), "part": item.partID])
        }
        return TaskboardNotice.marker(.review, ["task": bundle.reviews.first.map { String($0.review.taskNumber) } ?? ""])
    }
}
