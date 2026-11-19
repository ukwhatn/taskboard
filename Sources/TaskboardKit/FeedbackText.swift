// ui-copy:ignore-file
import Foundation

/// セッションが読む形の整形。内部 id や配信管理の欄は出さない。
public enum FeedbackText {
    public static let guidance =
        Copy.text("agent.notice.feedbackText.guidance")
        + Copy.text("agent.notice.feedbackText.guidance.2")

    static let clipNotice =
        Copy.text("agent.notice.feedbackText.clipNotice")

    struct Digest: Encodable {
        struct ReviewDigest: Encodable {
            struct CommentDigest: Encodable {
                var commentId: Int64
                var file: String
                var rev: Int
                var quote: String?
                var comment: String
            }
            struct ReplyDigest: Encodable {
                var commentId: Int64
                var originalComment: String
                var reply: String
            }
            var summary: String?
            var comments: [CommentDigest]
            var replies: [ReplyDigest]
        }
        struct AskDigest: Encodable {
            struct AnswerDigest: Encodable {
                var question: String
                var selected: [String]
                var freeText: String?
            }
            var answers: [AnswerDigest]
        }
        struct FinishedDigest: Encodable {
            var workItem: Int64
            var title: String
            var request: String
        }
        var reviews: [ReviewDigest]
        var answeredQuestions: [AskDigest]
        var finishedWork: [FinishedDigest]
        struct DraftDigest: Encodable {
            var part: String
            var to: String
            /// 人が承認した本文（編集していれば編集後）
            var body: String
            var edited: Bool
        }
        var approvedDrafts: [DraftDigest]
    }

    static func digest(_ bundle: FeedbackBundle) -> Digest {
        Digest(
            reviews: bundle.reviews.map { entry in
                Digest.ReviewDigest(
                    summary: entry.review.summary.isEmpty ? nil : entry.review.summary,
                    comments: entry.comments.map {
                        .init(commentId: $0.id, file: $0.docName, rev: $0.rev, quote: $0.anchor?.exact, comment: $0.body)
                    },
                    replies: entry.replies.map { .init(commentId: $0.reply.commentID, originalComment: $0.commentBody, reply: $0.reply.body) })
            },
            answeredQuestions: bundle.answeredAsks.map { ask in
                Digest.AskDigest(
                    answers: ask.questions.map { q in
                        let answer = ask.answers?.first { $0.questionID == q.id }
                        return .init(question: q.question, selected: answer?.selected ?? [], freeText: answer?.freeText)
                    })
            },
            finishedWork: bundle.finishedWork.map { .init(workItem: $0.itemID, title: $0.title, request: $0.request) },
            approvedDrafts: bundle.drafts.map { .init(part: $0.partID, to: $0.to, body: $0.body, edited: $0.edited) })
    }

    /// `feedback_list` と `review_request --wait` が返す全文。
    public static func render(_ bundle: FeedbackBundle) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: (try? encoder.encode(digest(bundle))) ?? Data("{}".utf8), as: UTF8.self)
        return guidance + json + "\n"
    }

    /// Stop hook の stderr に載せる本文。上限（文字数）に収まらなければ項目単位で落とす（JSON の途中で切らない）。
    /// 落とすならレビュー、質問の回答、済ませた手作業の順（`feedback_list` で取り直せる。回答と手作業はこのターンの判断材料）。
    /// `clipped` なら全文が届いていないので、呼び出し側は ack しない。
    public static func forHook(_ bundle: FeedbackBundle, limitChars: Int = 10_000) -> (text: String, clipped: Bool) {
        let full = render(bundle)
        if full.count <= limitChars { return (full, false) }
        var kept = bundle
        while kept.count > 1, let next = kept.droppingLast() {
            kept = next
            let text = render(kept) + clipNotice
            if text.count <= limitChars { return (text, true) }
        }
        return (guidance + clipNotice, true)
    }
}
