import Foundation
import Hummingbird
import TaskboardKit

/// 文書・質問・コメント・レビュー（kairan の置き換え）と、回答・レビューの受け渡し
extension APIServer {
    static func registerDocumentRoutes(v1: RouterGroup<TaskboardRequestContext>, daemonOnly: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("tasks/{number}/docs") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            return try json(try mapStoreError { try dependencies.requireStore().documents(task: number) }, encoder)
        }
        v1.post("tasks/{number}/docs") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            let body = try await request.decode(as: DocPublishRequest.self, context: context)
            let store = try dependencies.requireStore()
            let requester = body.questions == nil && body.drafts == nil ? nil : await dependencies.feedback?.requesterSessionID(body.requester)
            let result = try mapStoreError { try store.publish(task: number, body, requester: requester) }
            return try json(result, encoder)
        }
        v1.post("docs/{id}/asks") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decode(as: DocAskRequest.self, context: context)
            let store = try dependencies.requireStore()
            let requester = await dependencies.feedback?.requesterSessionID(body.requester)
            let result = try mapStoreError { try store.attachQuestions(doc: id, questions: body.questions, requester: requester, workItem: body.workItem) }
            return try json(result, encoder)
        }
        // 文書の送る文面の［承認］。承認と本文は publish した会話に届く（概況の送る文面と同じ束）。返すのは承認の後の文書
        v1.post("docs/{id}/drafts/{draft}/approve") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            // Hummingbird は path の引数を decode しない
            let draft = try context.parameters.require("draft").removingPercentEncoding ?? context.parameters.require("draft")
            let body = try await request.decode(as: PanelDraftApproveRequest.self, context: context)
            let store = try dependencies.requireStore()
            let number = try mapStoreError { try store.approveDocDraft(doc: id, draftID: draft, body: body.body) }
            try await dependencies.requireFeedback().notify(task: number)
            guard let doc = try store.document(id: id) else { throw APIError.notFound(.document, "文書 \(id) が無い") }
            return try json(doc, encoder)
        }
        v1.get("docs/{id}") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            guard let doc = try dependencies.requireStore().document(id: id) else { throw APIError.notFound(.document, "文書 \(id) が無い") }
            return try json(doc, encoder)
        }
        v1.delete("docs/{id}") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            _ = try mapStoreError { try dependencies.requireStore().deleteDocument(id: id) }
            return Response(status: .noContent)
        }
        v1.get("docs/{id}/revisions") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            return try json(try mapStoreError { try dependencies.requireStore().revisions(doc: id) }, encoder)
        }
        v1.get("docs/{id}/content") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let rev = request.uri.queryParameters.get("rev", as: Int.self)
            return try json(try mapStoreError { try dependencies.requireStore().content(doc: id, rev: rev) }, encoder)
        }
        v1.get("docs/{id}/comments") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            return try json(try mapStoreError { try dependencies.requireStore().comments(doc: id) }, encoder)
        }
        v1.post("docs/{id}/comments") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decode(as: CommentCreateRequest.self, context: context)
            let comment = try mapStoreError { try dependencies.requireStore().createDraftComment(doc: id, body) }
            return try json(comment, encoder)
        }
        v1.patch("comments/{id}") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decode(as: CommentUpdateRequest.self, context: context)
            return try json(try mapStoreError { try dependencies.requireStore().updateDraftComment(id: id, body: body.body) }, encoder)
        }
        v1.delete("comments/{id}") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            _ = try mapStoreError { try dependencies.requireStore().deleteDraftComment(id: id) }
            return Response(status: .noContent)
        }
        v1.post("comments/{id}/reply") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decode(as: CommentReplyRequest.self, context: context)
            let reply = try mapStoreError { try dependencies.requireStore().addReply(comment: id, author: body.author, body: body.body, resolve: body.resolve) }
            return try json(reply, encoder)
        }
        for (path, resolved) in [("comments/{id}/resolve", true), ("comments/{id}/reopen", false)] {
            v1.post(RouterPath(path)) { _, context in
                let id = try context.parameters.require("id", as: Int64.self)
                let comment = try mapStoreError { try dependencies.requireStore().setCommentResolved(id: id, resolved) }
                return try json(comment, encoder)
            }
        }
        v1.get("tasks/{number}/review") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            return try json(try mapStoreError { try dependencies.requireStore().reviewDraft(task: number) }, encoder)
        }
        v1.patch("tasks/{number}/review") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            let body = try await request.decode(as: ReviewSummaryRequest.self, context: context)
            return try json(try mapStoreError { try dependencies.requireStore().setReviewSummary(task: number, summary: body.summary) }, encoder)
        }
        v1.post("tasks/{number}/review/submit") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            let review = try mapStoreError { try dependencies.requireStore().submitReview(task: number) }
            try await dependencies.requireFeedback().notify(task: number)
            return try json(review, encoder)
        }
        v1.post("tasks/{number}/review-request") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            let body = try await request.decode(as: ReviewRequestCreate.self, context: context)
            let requester = await dependencies.feedback?.requesterSessionID(body.requester)
            let (result, _) = try mapStoreError { try dependencies.requireStore().requestReview(task: number, note: body.note, requester: requester) }
            return try json(result, encoder)
        }
        v1.get("tasks/{number}/asks") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            return try json(try mapStoreError { try dependencies.requireStore().asks(task: number) }, encoder)
        }
        // state に載せない（変わるたびに task.updated を流さない）。MCP の work_list・task_get が読む
        v1.get("tasks/{number}/link-notices") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            let store = try dependencies.requireStore()
            guard try store.task(number: number) != nil else { throw APIError.notFound(.task, "タスク #\(number) が無い") }
            return try json(try mapStoreError { try store.linkNotices(task: number) }, encoder)
        }
        v1.post("asks/{id}/answer") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decode(as: AskAnswerRequest.self, context: context)
            let ask = try mapStoreError { try dependencies.requireStore().answerAsk(id: id, answers: body.answers) }
            try await dependencies.requireFeedback().notify(task: ask.taskNumber)
            return try json(ask, encoder)
        }
        v1.post("asks/{id}/cancel") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            _ = try mapStoreError { try dependencies.requireStore().cancelAsk(id: id) }
            return Response(status: .noContent)
        }
        daemonOnly.post("feedback/claim") { request, context in
            let body = try await request.decode(as: FeedbackClaimRequest.self, context: context)
            return try json(try await mapStoreError { try await dependencies.requireFeedback().claim(body) }, encoder)
        }
        daemonOnly.post("feedback/ack") { request, context in
            let body = try await request.decode(as: FeedbackAckRequest.self, context: context)
            guard try await mapStoreError({ try await dependencies.requireFeedback().ack(claimID: body.claimID) }) else {
                throw APIError.notFound(.claim, "claim \(body.claimID) が無い")
            }
            return Response(status: .noContent)
        }
        daemonOnly.post("tasks/{number}/feedback/take") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            guard try dependencies.requireStore().task(number: number) != nil else { throw APIError.notFound(.task, "タスク #\(number) が無い") }
            return try json(FeedbackTakeResponse(bundle: try await mapStoreError { try await dependencies.requireFeedback().take(task: number) }), encoder)
        }
    }
}
