import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import TaskboardKit

/// host の会話（`ConversationService`）。端末の token でも通す（端末の token は、この Mac の操作を全部できる資格情報として扱う。`docs/daemon.md`「認証」）
extension APIServer {
    static func registerConversationRoutes(
        v1: RouterGroup<TaskboardRequestContext>, daemonOnly: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, encoder: JSONEncoder, logger: Logger
    ) {
        @Sendable func service() throws -> ConversationService {
            guard let service = dependencies.conversations else { throw APIError.unavailable("会話の host が無い") }
            return service
        }
        @Sendable func id(_ context: TaskboardRequestContext) throws -> String {
            let raw = try context.parameters.require("id")
            return raw.removingPercentEncoding ?? raw
        }

        v1.post("conversations") { request, context in
            let body = try await request.decode(as: ConversationStartRequest.self, context: context)
            return try await mapConversationError { try json(try await service().start(body), encoder) }
        }
        v1.get("conversations") { _, _ in
            try json(await service().list(), encoder)
        }
        // 音声入力で文字にした文の校正（このマシンの Claude Code で回す。会話には送らない）
        v1.post("dictation/polish") { request, context in
            let body = try await request.decode(as: DictationPolishRequest.self, context: context)
            if let violation = body.violation { throw APIError.invalid(violation) }
            return try await mapConversationError { try json(try await service().polishDictation(body), encoder) }
        }
        // Claude Code のモデルの一覧（会話と `conversation check` の initialize の答えから。まだ受けていなければ models が無い）
        v1.get("claude") { _, _ in
            try json(await service().claudeMachine(), encoder)
        }
        // 会話をまたいだ全文検索（`ConversationSearchIndex`）
        v1.get("conversations/search") { request, _ in
            guard let search = dependencies.conversationSearch else { throw APIError.unavailable("会話の検索が無い") }
            let query = request.uri.queryParameters
            let text = query.get("q").map { String($0) } ?? ""
            guard text.count <= ConversationSearchResponse.maxQueryLength else { throw APIError.invalid("q は \(ConversationSearchResponse.maxQueryLength) 字まで") }
            let limit = query.get("limit", as: Int.self) ?? ConversationSearchResponse.defaultLimit
            guard (1...ConversationSearchResponse.maxLimit).contains(limit) else { throw APIError.invalid("limit は 1〜\(ConversationSearchResponse.maxLimit)") }
            return try json(try await search.search(text, limit: limit), encoder)
        }
        daemonOnly.post("conversations/search/rebuild") { _, _ in
            guard let search = dependencies.conversationSearch else { throw APIError.unavailable("会話の検索が無い") }
            await search.requestRebuild()
            return Response(status: .noContent)
        }
        v1.get("conversations/{id}") { _, context in
            try await mapConversationError { try json(try await service().get(id(context)), encoder) }
        }
        v1.post("conversations/{id}/messages") { request, context in
            let body = try await request.decode(as: ConversationSendRequest.self, context: context)
            guard body.attachments.count <= ChatAttachment.maxCount else { throw APIError.invalid("画像は \(ChatAttachment.maxCount) 枚まで") }
            guard body.files.count <= ChatAttachment.maxFiles else { throw APIError.invalid("ファイルは \(ChatAttachment.maxFiles) 個まで") }
            return try await mapConversationError {
                try json(ConversationSendResponse(outcome: try await service().send(id(context), body).rawValue), encoder)
            }
        }
        // 本文は画像のバイト列そのもの。pane の添付と同じ置き場・大きさ・種類の確かめ
        v1.post("conversations/{id}/attachments") { request, context in
            _ = try await mapConversationError { try await service().get(id(context)) }
            return try json(try await saveAttachment(request, dependencies: dependencies), encoder)
        }
        // 画像でないファイル（本文はバイト列そのもの、名前は ?name=）。別のマシン・iPhone から添付するときに使い、返したパスを送信の files に載せる
        v1.post("conversations/{id}/files") { request, context in
            _ = try await mapConversationError { try await service().get(id(context)) }
            guard let name = request.uri.queryParameters.get("name"), !name.isEmpty else { throw APIError.invalid("name が無い") }
            return try json(try await saveFile(request, name: name, dependencies: dependencies), encoder)
        }
        v1.post("conversations/{id}/answers") { request, context in
            let body = try await request.decode(as: ConversationAnswerRequest.self, context: context)
            try await mapConversationError { try await service().answer(id(context), body) }
            return Response(status: .noContent)
        }
        v1.post("conversations/{id}/control") { request, context in
            let body = try await request.decode(as: ConversationControlRequest.self, context: context)
            return try await mapConversationError { try json(try await service().control(id(context), body), encoder) }
        }
        v1.get("conversations/{id}/commands") { _, context in
            try await mapConversationError { try json(try await service().commands(id(context)), encoder) }
        }
        v1.post("conversations/{id}/fork") { request, context in
            let body = try await request.decode(as: ConversationForkRequest.self, context: context)
            return try await mapConversationError { try json(try await service().fork(id(context), body), encoder) }
        }
        v1.post("conversations/{id}/rewind") { request, context in
            let body = try await request.decode(as: ConversationRewindRequest.self, context: context)
            return try await mapConversationError { try json(try await service().rewind(id(context), body), encoder) }
        }
        v1.post("conversations/{id}/rewind/undo") { request, context in
            let body = try await request.decode(as: ConversationSessionGuard.self, context: context)
            return try await mapConversationError { try json(try await service().undoRewind(id(context), body), encoder) }
        }
        v1.post("conversations/{id}/rewind/redo") { request, context in
            let body = try await request.decode(as: ConversationSessionGuard.self, context: context)
            return try await mapConversationError { try json(try await service().redoRewind(id(context), body), encoder) }
        }
        v1.post("conversations/prewarm") { request, context in
            let body = try await request.decode(as: ConversationPrewarmRequest.self, context: context)
            try await mapConversationError { try await service().prewarm(body) }
            return Response(status: .noContent)
        }
        // 差分の範囲（`?scope=`）。無ければすべての変更
        @Sendable func diffScope(_ request: Request) throws -> ConversationDiffScope {
            guard let value = request.uri.queryParameters.get("scope") else { return .all }
            guard let scope = ConversationDiffScope(rawValue: String(value)) else {
                throw APIError.invalid("scope は \(ConversationDiffScope.allCases.map(\.rawValue).joined(separator: "・"))")
            }
            return scope
        }
        v1.get("conversations/{id}/diff") { request, context in
            let scope = try diffScope(request)
            return try await mapConversationError { try json(try await service().diff(id(context), scope: scope), encoder) }
        }
        v1.get("conversations/{id}/diff/file") { request, context in
            guard let path = request.uri.queryParameters.get("path"), !path.isEmpty else { throw APIError.invalid("path が無い") }
            let scope = try diffScope(request)
            return try await mapConversationError { try json(try await service().fileDiff(id(context), path: path, scope: scope), encoder) }
        }
        // 入力欄の `@` の候補。打った文字だけを受け、引く場所は会話の作業ディレクトリに限る
        v1.get("conversations/{id}/workfiles") { request, context in
            let query = request.uri.queryParameters
            let text = query.get("q").map { String($0) } ?? ""
            guard text.count <= MentionTyping.maxQueryLength else { throw APIError.invalid("q は \(MentionTyping.maxQueryLength) 字まで") }
            let limit = query.get("limit", as: Int.self) ?? ConversationWorkFilesResponse.defaultLimit
            guard (1...ConversationWorkFilesResponse.maxLimit).contains(limit) else {
                throw APIError.invalid("limit は 1〜\(ConversationWorkFilesResponse.maxLimit)")
            }
            return try await mapConversationError { try json(try await service().workFiles(id(context), query: text, limit: limit), encoder) }
        }
        v1.post("conversations/{id}/shell") { _, context in
            try await mapConversationError { try json(ConversationShellResponse(pane: try await service().shell(id(context))), encoder) }
        }
        v1.delete("conversations/{id}/shell") { _, context in
            try await mapConversationError { try await service().stopShell(id(context)) }
            return Response(status: .noContent)
        }
        @Sendable func runID(_ context: TaskboardRequestContext) throws -> String {
            guard let raw = context.parameters.get("run"), let value = raw.removingPercentEncoding, !value.isEmpty else { throw APIError.invalid("run が無い") }
            return value
        }
        v1.post("conversations/{id}/runs") { request, context in
            let body = try await request.decode(as: ConversationRunRequest.self, context: context)
            return try await mapConversationError { try json(try await service().startRun(id(context), body), encoder) }
        }
        v1.post("conversations/{id}/runs/reset") { _, context in
            try await mapConversationError { try await service().resetRuns(id(context)) }
            return Response(status: .noContent)
        }
        v1.get("conversations/{id}/runs/{run}") { _, context in
            try await mapConversationError { try json(try await service().run(id(context), runID(context)), encoder) }
        }
        v1.delete("conversations/{id}/runs/{run}") { _, context in
            try await mapConversationError { try await service().cancelRun(id(context), runID(context)) }
            return Response(status: .noContent)
        }
        v1.post("conversations/{id}/stop") { _, context in
            try await mapConversationError { try await service().stop(id(context), cause: .person) }
            return Response(status: .noContent)
        }
        v1.post("conversations/{id}/close") { request, context in
            let body = try await request.decode(as: ConversationCloseRequest.self, context: context)
            try await mapConversationError {
                if body.afterTurn == true { try await service().closeAfterTurn(id(context)) } else { try await service().close(id(context)) }
            }
            return Response(status: .noContent)
        }
        v1.post("conversations/{id}/resume") { _, context in
            try await mapConversationError { try json(try await service().resume(id(context)), encoder) }
        }
        v1.delete("conversations/{id}") { _, context in
            try await mapConversationError { try await service().delete(id(context)) }
            return Response(status: .noContent)
        }
        v1.get("conversations/{id}/history") { request, context in
            let query = request.uri.queryParameters
            let limit = query.get("limit", as: Int.self) ?? 20
            guard (1...ConversationHistoryResponse.maxLimit).contains(limit) else { throw APIError.invalid("limit は 1〜\(ConversationHistoryResponse.maxLimit)") }
            return try await mapConversationError {
                do {
                    let history = try await service().history(
                        id(context), before: query.get("before").map { String($0) }, limit: limit, subagents: query.get("subagents") == "1")
                    return try json(history, encoder)
                } catch is ConversationHistory.InvalidCursor {
                    throw ConversationError.invalid("before が違う")
                }
            }
        }
    }

    /// `…/conversations/{id}/events?after=<seq>`。`after` より後の出来事を送ってから続きを送る（E1 は daemon の token だけ）
    static func registerConversationSocket(sockets: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, encoder: JSONEncoder) {
        sockets.ws("conversations/{id}/events") { _, _ in
            .upgrade()
        } onUpgrade: { inbound, outbound, context in
            guard context.requestContext.principal == .daemonToken else {
                try await outbound.close(.unknown(4401), reason: nil)
                return
            }
            guard let service = dependencies.conversations, let raw = context.requestContext.parameters.get("id") else {
                try await outbound.close(.unexpectedServerError, reason: "会話が無い")
                return
            }
            let after = context.request.uri.queryParameters.get("after").flatMap { Int($0) } ?? 0
            let stream: AsyncStream<ConversationEvent>
            do {
                stream = try await service.events(raw.removingPercentEncoding ?? raw, after: after)
            } catch {
                try await outbound.close(.unexpectedServerError, reason: "会話が無い")
                return
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { for try await _ in inbound {} }
                group.addTask {
                    for await event in stream {
                        try await outbound.write(.text(String(decoding: try encoder.encode(event), as: UTF8.self)))
                    }
                }
                _ = try await group.next()
                group.cancelAll()
            }
        }
    }

    static func mapConversationError<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ConversationError {
            throw APIError(HTTPResponse.Status(code: error.status), error.code, error.description, params: error.params)
        } catch let error as StoreError {
            throw error.apiError
        }
    }
}
